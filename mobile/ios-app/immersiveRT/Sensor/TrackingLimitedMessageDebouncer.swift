import Foundation

/// Pure, deterministic min-dwell debouncer for `ARPoseSource`'s D-08
/// tracking-limited message stream.
///
/// On-device testing (06.3-06 Task 3) found that real `ARCamera.TrackingState`
/// can genuinely flicker frame-to-frame between different `.limited(reason:)`
/// sub-reasons, or briefly bounce to `.normal` and back to the same
/// `.limited` reason, during unstable real-world conditions. A strict
/// equality-only dedup (the original `reportTrackingLimitedMessageIfChanged`
/// shape) treats every such flicker as a "change", re-presenting the shared
/// `ToastView` overlay repeatedly in quick succession — reading to the user
/// as toasts "accumulating", including repeated toasts of the SAME type.
///
/// This type adds a minimum continuous-dwell requirement before a candidate
/// message is promoted to "reported": a candidate must be the CURRENT
/// per-frame value for at least `dwellDurationMs`, continuously, before
/// `ingest(candidate:nowMs:)` returns `.report(_)`. Any per-frame change to a
/// different candidate before the dwell threshold elapses resets the pending
/// window entirely — mirroring `HoldStillDetector`'s "a single
/// threshold-breaking sample resets accumulation" shape exactly, just
/// applied to message identity instead of position displacement. The `nil`
/// (tracking recovered / no longer limited) case is treated as an ordinary
/// candidate value here — it goes through the exact same dwell gate, so a
/// brief flicker back to `.limited` cannot cause the toast to flash away and
/// immediately reappear either.
///
/// Fully time-parameterized (`nowMs` is an explicit parameter, never
/// `Date()` internally) so behavior is deterministic and clock-independent
/// in tests, mirroring `HoldStillDetector`'s own testability shape (no live
/// `ARSession`/`Timer` needed to exercise this type).
///
/// Never affects the wire `driftConfidence`, which is computed independently
/// in `ARPoseTracker`/`ARPoseConversion.swift` and stays a flat 0.5 for any
/// `.limited` reason (D-07/D-08) — this class is purely about how often the
/// LOCAL `onTrackingLimitedMessageChanged` callback (and therefore the local
/// toast) fires.
final class TrackingLimitedMessageDebouncer {

    /// Continuous duration (milliseconds) a candidate message must remain
    /// the CURRENT per-frame value before it is promoted to "reported".
    ///
    /// Claude's Discretion: 500ms sits comfortably above any realistic
    /// single-or-few-frame flicker at ARKit's frame rate (16-33ms/frame, so
    /// 500ms is roughly 15-30 consecutive frames of stability) while staying
    /// short enough that genuinely sustained states relevant to Task 3's
    /// on-device verification (`initializing` at startup, `excessiveMotion`,
    /// `insufficientFeatures`) — which in practice persist for at least a
    /// second or more — are still promptly visible, not swallowed.
    static let defaultDwellDurationMs: Double = 500

    /// Outcome of one `ingest(candidate:nowMs:)` call.
    enum Result: Equatable {
        /// Nothing new to report this call — either the candidate matches
        /// the already-reported value, or it hasn't been stable long enough
        /// yet. Callers must NOT invoke `onTrackingLimitedMessageChanged`
        /// for `.noChange`.
        case noChange
        /// The candidate has now been continuously stable for the full
        /// dwell duration and should be reported (fired) exactly once.
        case report(String?)
    }

    private let dwellDurationMs: Double

    /// The last value actually reported (fired) to the caller. Starts `nil`
    /// — matching the original dedup field's initial value — representing
    /// "not limited / no toast shown yet", so a `nil` candidate on the very
    /// first `ingest` call correctly produces `.noChange`, not a spurious
    /// initial report.
    private var lastReportedMessage: String?

    /// The per-frame candidate currently being evaluated for promotion, and
    /// when it was first observed. `String??` (double optional):
    /// outer `nil` means "no candidate is currently pending" (nothing to
    /// evaluate); `.some(nil)` means the pending candidate IS the
    /// nil/recovered value — distinct from "no pending candidate at all".
    private var pendingCandidate: String??
    private var pendingCandidateStartMs: Double?

    init(dwellDurationMs: Double = TrackingLimitedMessageDebouncer.defaultDwellDurationMs) {
        self.dwellDurationMs = dwellDurationMs
    }

    /// Ingests one per-frame candidate tracking-limited message (`nil` when
    /// tracking is not currently `.limited`) at `nowMs` (caller-supplied
    /// monotonic timestamp; production callers pass the same
    /// `Date().timeIntervalSince1970 * 1000` convention `ARPoseSource`
    /// already uses for `HoldStillDetector`, tests pass synthetic values).
    ///
    /// Returns `.report(message)` exactly once per genuine, sustained
    /// change — the first call where `message` has been the continuous
    /// per-frame candidate for at least `dwellDurationMs`. Returns
    /// `.noChange` every other call, including: candidates matching the
    /// already-reported value (nothing changed), and candidates still
    /// within their dwell window (not yet confirmed stable).
    @discardableResult
    func ingest(candidate: String?, nowMs: Double) -> Result {
        guard candidate != lastReportedMessage else {
            // Back to the already-reported value (including a flicker that
            // bounced away and immediately back) — nothing to report, and
            // any in-flight pending candidate for a DIFFERENT value is now
            // moot.
            pendingCandidate = nil
            pendingCandidateStartMs = nil
            return .noChange
        }

        if pendingCandidate == .some(candidate), let start = pendingCandidateStartMs {
            // Same candidate as the frame(s) since the pending window
            // started — check whether it has dwelled long enough yet.
            guard nowMs - start >= dwellDurationMs else { return .noChange }
            lastReportedMessage = candidate
            pendingCandidate = nil
            pendingCandidateStartMs = nil
            return .report(candidate)
        }

        // A new candidate (different from both the last-reported value AND
        // whatever was previously pending) — (re)start its dwell window.
        pendingCandidate = candidate
        pendingCandidateStartMs = nowMs
        return .noChange
    }
}
