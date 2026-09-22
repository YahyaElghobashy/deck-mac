import AppKit
import AVFoundation
import Combine
import Foundation

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

    private init() {}

    func start() {
        DictationPrefs.migrateFromMurmur()
        state.lang = DictationPrefs.lang
        state.autoPaste = DictationPrefs.autoPaste
        state.sounds = DictationPrefs.sounds
        state.totalWords = DictationPrefs.totalWords
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
        if !armIfPermitted() { presentFirstRun() }
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
    }

    // MARK: Permissions

    @discardableResult
    func armIfPermitted() -> Bool {
        guard Permissions.accessibility else { state.armed = false; return false }
        let ok = hotkey.start()
        state.armed = ok
        return ok
    }

    private func presentFirstRun() {
        flash(.failed("Turn Deck on in Accessibility to dictate"), for: 4.5)
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
        pollForPermission()
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
            if self.state.isLocked { self.finishRecording() } else { self.beginRecording(locked: false) }
        }
        hotkey.onDoubleTap = { [weak self] in self?.lockRecording() }
        hotkey.onPressEnd = { [weak self] in self?.releaseKey() }
        hotkey.onEscape = { [weak self] in self?.cancel() }
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

    private func releaseKey() {
        guard case .recording(let locked, _) = state.phase else { return }
        if locked { return }
        finishRecording()
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
        hud.setInteractive(false)
        ticker?.invalidate(); ticker = nil
        recordingStart = nil
        recorder.discard()
        DictationSound.stop()
        flash(.warning("Cancelled"), for: 1.2)
    }

    private func finishRecording() {
        guard case .recording = state.phase else { return }
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
        Transcriber.run(wav: url, lang: state.lang) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                let pasted = Inserter.deliver(text)
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

    // MARK: Feedback

    private func fail(_ error: Error) {
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
}
