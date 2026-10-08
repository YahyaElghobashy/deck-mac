import Foundation

/// Tells a hold from a tap on the dictation chord. Pure state, no timers: the host feeds it key
/// presses, releases and clock ticks, and does what it says.
///
/// - Hold past `tapMax`: push-to-talk; letting go finishes.
/// - A quick tap, then a second press within `doubleTapWindow`: hands-free lock. Recording starts
///   on the first press and simply carries on, so nothing said between the taps is lost.
/// - A lone quick tap: cancelled once the window has passed.
/// - Any press while locked: finishes.
public struct ChordGesture {
    public enum Action: Equatable {
        case none
        case start        // begin recording, push-to-talk for now
        case lock         // keep recording, hands-free
        case finish       // stop and transcribe
        case cancelTap    // a lone tap: discard the recording
    }

    enum Phase: Equatable {
        case idle
        case holding(since: TimeInterval)
        case awaitingSecondTap(releasedAt: TimeInterval)
        case locked
        case finishingLocked   // the press that ended a locked recording, until its release
    }

    public var tapMax: TimeInterval = DictationLimits.tapMaxSeconds
    public var doubleTapWindow: TimeInterval = DictationLimits.doubleTapWindow
    private(set) var phase: Phase = .idle

    public init() {}

    /// When the host should call `tick`, if it is waiting on the double-tap window.
    public var tickDeadline: TimeInterval? {
        if case .awaitingSecondTap(let at) = phase { return at + doubleTapWindow }
        return nil
    }

    public mutating func press(at t: TimeInterval) -> Action {
        switch phase {
        case .idle, .finishingLocked:
            phase = .holding(since: t)
            return .start
        case .holding:
            return .none                        // a repeat of the same press
        case .awaitingSecondTap(let releasedAt):
            if t - releasedAt <= doubleTapWindow { phase = .locked; return .lock }
            phase = .holding(since: t)           // the window had passed: a fresh start
            return .start
        case .locked:
            phase = .finishingLocked
            return .finish
        }
    }

    public mutating func release(at t: TimeInterval) -> Action {
        switch phase {
        case .holding(let since):
            if t - since < tapMax { phase = .awaitingSecondTap(releasedAt: t); return .none }
            phase = .idle
            return .finish
        case .finishingLocked:
            phase = .idle
            return .none
        default:
            return .none
        }
    }

    public mutating func tick(at t: TimeInterval) -> Action {
        if case .awaitingSecondTap(let releasedAt) = phase, t - releasedAt > doubleTapWindow {
            phase = .idle
            return .cancelTap
        }
        return .none
    }

    /// The recording ended some other way (Esc, the HUD's stop, the length limit, an error).
    public mutating func reset() { phase = .idle }
}
