import Foundation

/// Pure, deterministic pose-delta stillness detector (D-10 — the automatic
/// hold-still calibration gate mirroring the web client's `runCalibration`
/// hold-still convention in `client/src/sensor/encode.ts`).
///
/// Derives stillness ONLY from frame-to-frame `ARCamera.transform` position
/// deltas fed in by the caller — never from CoreMotion/accelerometer input
/// (RESEARCH.md Open Question 3, lines 429-432). This intentionally avoids
/// the `accelerationIncludingGravity`-vs-linear-acceleration bug class the
/// web client's `runCalibration` has to navigate, and does NOT constitute a
/// parallel CoreMotion orientation pipeline — it consumes ARKit-derived
/// position only, so D-01 (ARKit supersedes CoreMotion for orientation AND
/// position) is respected.
///
/// Fully time-parameterized (`nowMs` is an explicit parameter, never
/// `Date()`/`ProcessInfo` internally) so behavior is deterministic and
/// clock-independent in tests, mirroring `ARPoseTracker`'s pure-function
/// testability shape (no live `ARSession` needed to exercise this type).
final class HoldStillDetector {

    /// Frame-to-frame Euclidean displacement (meters) below which a sample
    /// is considered part of a still window.
    ///
    /// Claude's Discretion (CONTEXT.md defers exact tuning): 3mm/frame sits
    /// comfortably above ARKit's typical sub-millimeter positional jitter
    /// floor while staying an order of magnitude below the smallest
    /// deliberate motion verified on-device (06.3-CHECKPOINT.md Task 2:
    /// "very accurate" at 5cm resolution across a 20cm range) — so ordinary
    /// hand tremor while holding the phone still does not spuriously reset
    /// the window, but any real repositioning does.
    static let defaultDisplacementThresholdMeters: Double = 0.003

    /// Continuous duration (milliseconds) displacement must remain below
    /// `displacementThresholdMeters` before `ingest` reports `true`.
    ///
    /// Claude's Discretion: 750ms balances a snappy calibration UX (D-10
    /// happens once, at session start) against rejecting a single
    /// lucky-low-jitter frame as a false "still" signal.
    static let defaultRequiredStillDurationMs: Double = 750

    private let displacementThresholdMeters: Double
    private let requiredStillDurationMs: Double

    private var previousPosition: (x: Double, y: Double, z: Double)?
    private var stillWindowStartMs: Double?

    init(
        displacementThresholdMeters: Double = HoldStillDetector.defaultDisplacementThresholdMeters,
        requiredStillDurationMs: Double = HoldStillDetector.defaultRequiredStillDurationMs
    ) {
        self.displacementThresholdMeters = displacementThresholdMeters
        self.requiredStillDurationMs = requiredStillDurationMs
    }

    /// Ingests one ARKit-derived position sample (meters) at `nowMs`
    /// (caller-supplied — production callers pass a monotonic timestamp
    /// derived from the pose stream, tests pass fully synthetic values).
    ///
    /// Returns whether the device has now been continuously still (every
    /// frame-to-frame displacement below `displacementThresholdMeters`) for
    /// at least `requiredStillDurationMs`. A single frame-to-frame
    /// displacement above the threshold resets the still-accumulation
    /// window entirely — `ingest` then returns `false` until the window
    /// re-accumulates from scratch.
    @discardableResult
    func ingest(px: Double, py: Double, pz: Double, nowMs: Double) -> Bool {
        defer { previousPosition = (x: px, y: py, z: pz) }

        guard let previous = previousPosition else {
            // First-ever sample: nothing to diff against, so start the
            // still-window here rather than reporting a spurious jump.
            stillWindowStartMs = nowMs
            return false
        }

        let dx = px - previous.x
        let dy = py - previous.y
        let dz = pz - previous.z
        let displacement = (dx * dx + dy * dy + dz * dz).squareRoot()

        guard displacement <= displacementThresholdMeters else {
            // Motion detected: reset the still-accumulation window.
            stillWindowStartMs = nowMs
            return false
        }

        guard let windowStart = stillWindowStartMs else {
            stillWindowStartMs = nowMs
            return false
        }

        return (nowMs - windowStart) >= requiredStillDurationMs
    }
}
