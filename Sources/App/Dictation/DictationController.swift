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

    private init() {}

    func start() {
        DictationPaths.modelPathProvider = { DeckSettings.load().whisperModelPath }
        DictationPrefs.migrateFromMurmur()
        state.lang = DictationPrefs.lang
        state.autoPaste = DictationPrefs.autoPaste
        state.sounds = DictationPrefs.sounds
        state.totalWords = DictationPrefs.totalWords
        applyShortcutKeys()
        WhisperEngine.shared.idleUnload = TimeInterval(state.keepModelMinutes * 60)
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
        recordingStart = nil
        let heardSound = recorder.sawSound
        let (url, secs) = recorder.stop()
        DictationSound.stop()
        guard let url else { return fail(VoiceError.engineFailed("no audio captured")) }
        if secs < DictationLimits.minRecordSeconds { try? FileManager.default.removeItem(at: url); return flash(.warning("Too short, ignored"), for: 1.3) }
        if !heardSound { try? FileManager.default.removeItem(at: url); return flash(.warning("Nothing heard"), for: 1.6) }
        state.phase = .transcribing
        hud.show()
        let lang = state.lang
        Transcriber.run(wav: url, lang: lang) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let t):
                let text = t.text
                let releaseMs = Int(Date().timeIntervalSince(releasedAt) * 1000)
                let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                LastDictation.record(text)
                let pasted = Inserter.deliver(text)
                let method = Inserter.lastMethod.rawValue
                DebugLog.write("dictation \(t.language) via \(t.engine), text \(releaseMs) ms after release, delivered via \(method)")
                self.save(DictationRecord(text: text, lang: t.language, engine: t.engine, delivery: method,
                                          appBundleID: app, audioSeconds: secs, transcribeMs: t.inferMs))
                self.metric("release_to_text.\(t.engine)", ms: releaseMs, detail: String(format: "%.1fs %@", t.audioSeconds, t.language))
                self.metric("transcribe.\(t.engine)", ms: t.inferMs)
                if t.engine != "whisper" { self.metric("fallback.\(t.engine)") }
                self.metric("delivery.\(method)")
                DictationPrefs.totalWords += text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
                self.state.totalWords = DictationPrefs.totalWords
                self.state.phase = .done(text: text, pasted: pasted)
                DictationSound.ok()
                self.hud.show()
                self.hud.hide(after: 2.2)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if case .done = self.state.phase { self.state.phase = .idle } }
            case .failure(let err):
                self.fail(err)
            }
        }
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
    func setKeepModelMinutes(_ m: Int) {
        DictationPrefs.keepModelMinutes = m; state.keepModelMinutes = m
        WhisperEngine.shared.idleUnload = TimeInterval(m * 60)
    }
}
