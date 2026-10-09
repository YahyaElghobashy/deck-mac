import AppKit
import AVFoundation
import Combine
import Foundation
import Murmur

/// Owns the chord → record → whisper → paste loop (Murmur's app delegate, minus the status item).
@MainActor
final class DictationController {
    static let shared = DictationController()

    let state = DictationState()
    private lazy var hud = DictationHUD(state: state)
    private let hotkey = HotkeyMonitor()
    private let recorder = Recorder()
    private var ticker: Timer?
    private var watchdog: Timer?
    private var bag = Set<AnyCancellable>()
    private var recordingStart: Date?
    private var store: Store?
    private var gesture = ChordGesture()
    private var gestureTimer: Timer?
    /// Transcribes the current recording in pieces while it goes on (DIC-02), fed every 250 ms.
    private var stream: StreamingTranscriber?
    private var feedTimer: Timer?
    /// This dictation's kept recording and the language decisions made for it (KeptRecordings).
    private var keptRecording: URL?
    private var streamEvents: [String] = []

    private init() {}

    func start() {
        DictationPaths.modelPathProvider = { DictationPrefs.model.path(besides: DeckSettings.load().whisperModelPath) }
        DictationPrefs.migrateFromMurmur()
        DictationPrefs.adoptAutoLanguageOnce()
        state.lang = DictationPrefs.lang
        state.autoPaste = DictationPrefs.autoPaste
        state.sounds = DictationPrefs.sounds
        state.model = DictationPrefs.model
        state.totalWords = DictationPrefs.totalWords
        applyShortcutKeys()
        WhisperEngine.shared.idleUnload = TimeInterval(state.keepModelMinutes * 60)
        KeptRecordings.directory = DeckPaths.dir.appendingPathComponent("recordings", isDirectory: true)
        if state.keepRecordings { KeptRecordings.prune() } else { KeptRecordings.removeAll() }
        WhisperEngine.shared.onLoad = { [weak self] ms in
            DispatchQueue.main.async { self?.metric("model_load", ms: ms) }
        }
        openStore()
        warmIfNewBuild()
        DebugLog.write("dictation: ax=\(Permissions.accessibility) whisper=\(DictationPaths.whisper ?? "nil") model=\(DictationPaths.modelExists)")
        wireHotkey()
        state.onPauseToggle = { [weak self] in self?.togglePause() }
        state.onStop = { [weak self] in self?.finishRecording() }
        state.onCancel = { [weak self] in self?.cancel() }
        recorder.onLevel = { [weak self] v in
            guard let self else { return }
            self.state.level = self.state.level * 0.55 + v * 0.45
            self.state.pushLevel(v)
        }
        state.$phase.receive(on: RunLoop.main).sink { [weak self] p in
            guard let self else { return }
            if case .recording(true, _) = p { self.hud.setInteractive(true) } else { self.hud.setInteractive(false) }
        }.store(in: &bag)
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.hotkey.reenableIfNeeded() }
        }
        Recorder.requestMic { ok in DebugLog.write("mic granted=\(ok)") }
        armIfPermitted()
        if !SetupStatus.read().ready { presentSetup() }
        // The grant can arrive any time (or vanish after a rebuild); keep checking, cheaply.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let ok = Permissions.accessibility
                if ok, !self.state.armed { self.armIfPermitted(); DebugLog.write("dictation armed late") }
                if !ok, self.state.armed { self.state.armed = false; self.hotkey.stop(); DebugLog.write("dictation lost accessibility") }
            }
        }
    }

    func stop() {
        recorder.discard()
        hotkey.stop()
        WhisperEngine.shared.shutdown()
    }

    // MARK: Permissions

    @discardableResult
    func armIfPermitted() -> Bool {
        guard Permissions.accessibility else { state.armed = false; return false }
        let ok = hotkey.start()
        state.armed = ok
        return ok
    }

    /// Opens "Set up dictation". Called at launch when dictation cannot work, and from the
    /// Dashboard and the menu. Polls so the chord arms the moment Accessibility is granted.
    func presentSetup() {
        DebugLog.write("setup opened: \(SetupStatus.read())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NotificationCenter.default.post(name: SetupStatus.openNotification, object: nil)
        }
        if !state.armed { pollForPermission() }
    }

    func pollForPermission() {
        var tries = 0
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                tries += 1
                if self.armIfPermitted() {
                    t.invalidate()
                    self.flash(.warning("Dictation armed — hold ⌃⌥Z"), for: 1.6)
                } else if tries > 60 {
                    t.invalidate()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    // MARK: Hotkey wiring

    private func wireHotkey() {
        hotkey.onPressStart = { [weak self] in
            guard let self else { return }
            self.act(self.gesture.press(at: Self.now))
        }
        hotkey.onPressEnd = { [weak self] in
            guard let self else { return }
            self.act(self.gesture.release(at: Self.now))
        }
        hotkey.onEscape = { [weak self] in self?.cancel() }
        hotkey.onPasteLast = { [weak self] in self?.pasteLast() }
        hotkey.onCopyLast = { [weak self] in self?.copyLast() }
        hotkey.onCycleLang = { [weak self] in
            guard let self else { return }
            self.state.cycleLang()
            if !self.state.isBusy { self.flash(.warning("Language: \(self.state.lang.long)"), for: 1.3) }
        }
    }

    // MARK: Recording lifecycle

    private func beginRecording(locked: Bool) {
        guard !state.isBusy else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) != .denied else { return fail(VoiceError.micDenied) }
        do { try recorder.start() } catch { return fail(error) }
        WhisperEngine.shared.preload(model: DictationPaths.model)   // loads while you talk
        startStream()
        recordingStart = Date()
        state.level = 0
        state.elapsed = 0
        state.phase = .recording(locked: locked, paused: false)
        hud.show()
        DictationSound.start()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recordingStart != nil else { return }
                self.state.elapsed = self.recorder.duration
                if self.state.elapsed >= DictationLimits.maxRecordSeconds { self.finishRecording() }
            }
        }
    }

    private func lockRecording() {
        switch state.phase {
        case .recording(_, let paused):
            state.phase = .recording(locked: true, paused: paused)
            hud.setInteractive(true)
            hud.show()
            DictationSound.tick()
        case .transcribing:
            break
        default:
            beginRecording(locked: true)
        }
    }

    // MARK: Transcribing while you talk

    /// A fresh StreamingTranscriber per recording: it cuts at pauses, probes the language (AUTO)
    /// and transcribes each piece in the background, so only the tail is left at release.
    private func startStream() {
        stopStream()
        let s = StreamingTranscriber(lang: state.lang, model: DictationPaths.model)
        streamEvents = []
        s.onEvent = { [weak self] kind, ms, detail in
            self?.metric(kind == "piece" ? "piece.whisper" : kind, ms: ms, detail: detail)
            self?.streamEvents.append("\(kind) \(ms) ms  \(detail ?? "")")
        }
        stream = s
        feedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let stream = self.stream, case .recording(_, false) = self.state.phase else { return }
                stream.feed(self.recorder.snapshot())
            }
        }
    }

    private func stopStream() {
        feedTimer?.invalidate(); feedTimer = nil
        stream?.cancel()
        stream = nil
    }

    // MARK: Hold, tap, double-tap

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Does what the chord gesture decided, and arms a timer while it waits for a second tap.
    private func act(_ action: ChordGesture.Action) {
        gestureTimer?.invalidate(); gestureTimer = nil
        switch action {
        case .none:
            break
        case .start:
            if case .recording = state.phase { discardQuietly() }   // a lone tap still recording
            beginRecording(locked: false)
        case .lock:
            lockRecording()
        case .finish:
            finishRecording()
        case .cancelTap:
            discardQuietly()
            flash(.warning("Hold ⌃⌥Z to talk · double-tap to lock"), for: 1.4)
        }
        if let deadline = gesture.tickDeadline {
            gestureTimer = Timer.scheduledTimer(withTimeInterval: max(0, deadline - Self.now) + 0.02, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.act(self.gesture.tick(at: Self.now))
                }
            }
        }
    }

    /// Drops the current recording without a sound or a message (a lone tap).
    private func discardQuietly() {
        stopStream()
        ticker?.invalidate(); ticker = nil
        recordingStart = nil
        recorder.discard()
        hud.setInteractive(false)
        state.phase = .idle
        hud.hide(after: 0)
    }

    private func togglePause() {
        guard case .recording(let locked, let paused) = state.phase else { return }
        if paused { recorder.resume() } else { recorder.pause() }
        state.phase = .recording(locked: locked, paused: !paused)
        DictationSound.tick()
        hud.show()
    }

    private func cancel() {
        guard state.isBusy else { return }
        gesture.reset(); gestureTimer?.invalidate(); gestureTimer = nil
        stopStream()
        hud.setInteractive(false)
        ticker?.invalidate(); ticker = nil
        recordingStart = nil
        recorder.discard()
        DictationSound.stop()
        flash(.warning("Cancelled"), for: 1.2)
    }

    private func finishRecording() {
        guard case .recording = state.phase else { return }
        gesture.reset(); gestureTimer?.invalidate(); gestureTimer = nil
        let releasedAt = Date()
        if recorder.isPaused { recorder.resume() }
        ticker?.invalidate(); ticker = nil
        feedTimer?.invalidate(); feedTimer = nil
        recordingStart = nil
        let heardSound = recorder.sawSound
        let (url, secs) = recorder.stop()
        let samples = recorder.snapshot()
        DictationSound.stop()
        guard let url else { stopStream(); return fail(VoiceError.engineFailed("no audio captured")) }
        if secs < DictationLimits.minRecordSeconds { stopStream(); try? FileManager.default.removeItem(at: url); return flash(.warning("Too short, ignored"), for: 1.3) }
        if !heardSound { stopStream(); try? FileManager.default.removeItem(at: url); return flash(.warning("Nothing heard"), for: 1.6) }
        state.phase = .transcribing
        hud.show()
        keptRecording = state.keepRecordings ? KeptRecordings.keep(url) : nil
        let lang = state.lang
        guard let stream else { return transcribeWholeFile(url, lang: lang, seconds: secs, releasedAt: releasedAt) }
        self.stream = nil
        stream.finish(samples) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let t):
                try? FileManager.default.removeItem(at: url)   // the audio goes on every path
                self.deliver(t, seconds: secs, releasedAt: releasedAt, pieces: stream.piecesSoFar + 1)
            case .failure(VoiceError.empty):
                try? FileManager.default.removeItem(at: url)
                self.fail(VoiceError.empty)
            case .failure(let error):
                // The in-process engine failed mid-way: do the whole file again, with the CLI fallback.
                DebugLog.write("streaming failed (\(error)); transcribing the whole recording")
                self.transcribeWholeFile(url, lang: lang, seconds: secs, releasedAt: releasedAt)
            }
        }
    }

    /// The whole recording in one go, falling back to whisper-cli when the engine can't run.
    private func transcribeWholeFile(_ url: URL, lang: Lang, seconds secs: TimeInterval, releasedAt: Date) {
        Transcriber.run(wav: url, lang: lang) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let t): self.deliver(t, seconds: secs, releasedAt: releasedAt, pieces: 1)
            case .failure(let err): self.fail(err)
            }
        }
    }

    private func deliver(_ t: Transcript, seconds secs: TimeInterval, releasedAt: Date, pieces: Int) {
        let text = t.text
        let releaseMs = Int(Date().timeIntervalSince(releasedAt) * 1000)
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        LastDictation.record(text)
        let pasted = Inserter.deliver(text) { [weak self] verdict in self?.pasteChecked(verdict, text: text) }
        let method = Inserter.lastMethod.rawValue
        DebugLog.write("dictation \(t.language) via \(t.engine), \(pieces) piece(s), text \(releaseMs) ms after release, delivered via \(method)")
        KeptRecordings.annotate(keptRecording, ["text: \(text)", "language: \(t.language) via \(t.engine) \(state.model.whisperName), \(pieces) piece(s)",
                                                 "release to text: \(releaseMs) ms, delivered via \(method)", ""] + streamEvents)
        keptRecording = nil
        save(DictationRecord(text: text, lang: t.language, engine: t.engine, delivery: method,
                             appBundleID: app, audioSeconds: secs, transcribeMs: t.inferMs))
        metric("release_to_text.\(t.engine)", ms: releaseMs,
               detail: String(format: "%.1fs %@ %d piece(s) %@", t.audioSeconds, t.language, pieces, state.model.whisperName))
        metric("transcribe.\(t.engine)", ms: t.inferMs)
        if t.engine != "whisper" { metric("fallback.\(t.engine)") }
        metric("delivery.\(method)")
        DictationPrefs.totalWords += text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        state.totalWords = DictationPrefs.totalWords
        state.phase = .done(text: text, pasted: pasted)
        DictationSound.ok()
        hud.show()
        hud.hide(after: 2.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if case .done = self.state.phase { self.state.phase = .idle } }
    }

    /// A new build of the app compiles whisper's Metal shaders on its first model load, which takes
    /// about 9 s instead of 2.5 s. Do that once, in the background shortly after launch, so the
    /// first dictation after an update doesn't wait for it. The model then unloads as usual.
    private func warmIfNewBuild() {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard !build.isEmpty, DictationPrefs.warmedBuild != build, DictationPaths.modelExists else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            WhisperEngine.shared.preload(model: DictationPaths.model)
            DictationPrefs.warmedBuild = build
            DebugLog.write("warming whisper for build \(build)")
        }
    }

    // MARK: Storage

    private func openStore() {
        do {
            let s = try Store(url: DeckPaths.database)
            store = s
            if let last = try s.latestDictation() { LastDictation.record(last.text, at: last.at) }
            DebugLog.write("store open, schema v\(s.schemaVersion), \(try s.dictationCount()) dictations")
        } catch {
            DebugLog.write("store unavailable: \(error)")
        }
    }

    private func save(_ record: DictationRecord) {
        do { try store?.addDictation(record) } catch { DebugLog.write("store write failed: \(error)") }
    }

    /// Local metrics only (FND-10): written to the database, shown in the Metrics window.
    func metric(_ path: String, ms: Int? = nil, detail: String? = nil) {
        do { try store?.addMetric(path, ms: ms, detail: detail) } catch { DebugLog.write("metric write failed: \(error)") }
    }

    func metricSummaries() -> [Store.MetricSummary] { (try? store?.metricSummaries()) ?? [] }
    func clearMetrics() { try? store?.clearMetrics() }

    /// DEL-03: a paste that provably didn't arrive leaves the text on the clipboard and says so.
    private func pasteChecked(_ verdict: PasteVerdict, text: String) {
        metric("paste_check.\(verdict.rawValue)")
        guard verdict == .failed else { return }
        ClipboardSession.shared.put(text, restore: false)
        DebugLog.write("paste did not land; left on the clipboard")
        flash(.warning("Copied, press ⌘V"), for: 2.5)
    }

    // MARK: Paste last, copy last

    private func pasteLast() {
        guard !state.isBusy else { return }
        guard let text = LastDictation.text else { return flash(.warning("No dictation in the last 24 hours"), for: 1.6) }
        let pasted = Inserter.deliver(text, force: true)
        flash(.warning(pasted ? "Pasted the last dictation" : "No text field here · copied instead"), for: 1.4)
    }

    private func copyLast() {
        guard !state.isBusy else { return }
        guard let text = LastDictation.text else { return flash(.warning("No dictation in the last 24 hours"), for: 1.6) }
        ClipboardSession.shared.put(text, restore: false)
        flash(.warning("Copied the last dictation"), for: 1.4)
    }

    private func applyShortcutKeys() {
        hotkey.pasteLastCode = DictationKeys.code(for: state.pasteLastKey)
        hotkey.copyLastCode = DictationKeys.code(for: state.copyLastKey)
    }

    // MARK: Feedback

    private func fail(_ error: Error) {
        gesture.reset(); gestureTimer?.invalidate(); gestureTimer = nil
        ticker?.invalidate(); ticker = nil
        recordingStart = nil
        let ve = error as? VoiceError
        let msg = ve?.errorDescription ?? error.localizedDescription
        KeptRecordings.annotate(keptRecording, ["failed: \(msg)", ""] + streamEvents)
        keptRecording = nil
        state.phase = .failed(msg)
        DictationSound.fail()
        hud.show()
        hud.hide(after: 3.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.7) { if case .failed = self.state.phase { self.state.phase = .idle } }
        if case .micDenied = ve { Permissions.openMicrophoneSettings() }
    }

    private func flash(_ phase: DictationPhase, for seconds: TimeInterval) {
        state.phase = phase
        hud.show()
        hud.hide(after: seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.3) { if self.state.phase == phase { self.state.phase = .idle } }
    }

    // MARK: Settings from the UI

    func setLang(_ l: Lang) { state.lang = l; DictationPrefs.lang = l }
    func setAutoPaste(_ on: Bool) { DictationPrefs.autoPaste = on; state.autoPaste = on }
    func setSounds(_ on: Bool) { DictationPrefs.sounds = on; state.sounds = on }
    func setPasteLastKey(_ k: String) { DictationPrefs.pasteLastKey = k; state.pasteLastKey = k; applyShortcutKeys() }
    func setCopyLastKey(_ k: String) { DictationPrefs.copyLastKey = k; state.copyLastKey = k; applyShortcutKeys() }
    func modelAvailable(_ m: SpeechModel) -> Bool {
        FileManager.default.fileExists(atPath: m.path(besides: DeckSettings.load().whisperModelPath))
    }

    /// Switches the speech model. A loaded model is swapped now, unless a dictation is running:
    /// then the next one loads it (it is preloaded on ⌃⌥Z).
    func setModel(_ m: SpeechModel) {
        guard m != state.model else { return }
        guard modelAvailable(m) else {
            flash(.warning("\(m.label) model not downloaded (\(m.fileName))"), for: 2.0)
            return
        }
        DictationPrefs.model = m; state.model = m
        DebugLog.write("speech model: \(m.whisperName)")
        if !state.isBusy, WhisperEngine.shared.isLoaded { WhisperEngine.shared.preload(model: DictationPaths.model) }
    }

    func setKeepRecordings(_ on: Bool) {
        DictationPrefs.keepRecordings = on; state.keepRecordings = on
        if !on { KeptRecordings.removeAll() }
    }
    func setKeepModelMinutes(_ m: Int) {
        DictationPrefs.keepModelMinutes = m; state.keepModelMinutes = m
        WhisperEngine.shared.idleUnload = TimeInterval(m * 60)
    }
}
