import ARKit
import simd

/// ARKit `ARCamera.transform` -> wire-packet conversion layer (SENS-V2-03,
/// D-02/D-07). This is the single isolated axis-conversion seam RESEARCH.md
/// mandates so the axis convention can be corrected on-device (by the Plan 03
/// checkpoint) without touching unrelated code — this project has shipped an
/// analytically-reasoned axis fix that was wrong on-device twice
/// (`260710-w83` and the huge-position-drift debug cycle).
///
/// Every function here is pure: it takes a `simd_float4x4`/
/// `ARCamera.TrackingState`-equivalent input and returns plain packet-field
/// values, with no live `ARSession` dependency — testable in the iOS
/// Simulator exactly like `SensorPacketEncoderTests.swift`'s fixture-driven
/// approach (RESEARCH.md's Validation Architecture constraint: ARKit itself
/// does not run in the Simulator, but this conversion math does not need it
/// to).

/// A single ARKit-derived pose in wire-packet field order.
struct ARPose {
    var px: Double
    var py: Double
    var pz: Double
    var qw: Double
    var qx: Double
    var qy: Double
    var qz: Double
    var driftConfidence: Double
}

/// Extracts the wire-packet position (px, py, pz) from an ARKit camera
/// transform's translation column (`transform.columns.3`).
///
/// ⚠️ UNVERIFIED (D-02/Pitfall 3): this is a DIRECT starting-point axis
/// mapping (px=t.x, py=t.y, pz=t.z) — no sign/reorder constants are
/// hard-coded here, per RESEARCH.md's explicit instruction not to
/// analytically guess final axis constants (this project has shipped a wrong
/// analytically-reasoned axis fix twice: `260710-w83` and the huge-position-
/// drift debug cycle). Treat this mapping as a reasoned starting point, not a
/// settled answer, until Plan 03's on-device axis checkpoint (D-16) passes.
func arKitPacketPosition(from transform: simd_float4x4) -> (px: Double, py: Double, pz: Double) {
    let translation = transform.columns.3
    return (px: Double(translation.x), py: Double(translation.y), pz: Double(translation.z))
}

/// Extracts the wire-packet quaternion (qw, qx, qy, qz) from an ARKit camera
/// transform using the vetted one-call `simd_quaternion(transform)` (per
/// RESEARCH.md's Don't Hand-Roll table — never hand-roll a 3x3-to-quaternion
/// conversion).
///
/// ⚠️ UNVERIFIED (D-02/Pitfall 3): the resulting quaternion is passed through
/// DIRECTLY in packet-field order (qw/qx/qy/qz straight from the simd
/// quaternion's real/imaginary parts) — no sign/reorder constants are
/// hard-coded here. Treat this mapping as a reasoned starting point, not a
/// settled answer, until Plan 03's on-device axis checkpoint (D-16) passes.
func arKitPacketQuaternion(from transform: simd_float4x4) -> (qw: Double, qx: Double, qy: Double, qz: Double) {
    let quaternion = simd_quaternion(transform)
    return (
        qw: Double(quaternion.real),
        qx: Double(quaternion.imag.x),
        qy: Double(quaternion.imag.y),
        qz: Double(quaternion.imag.z)
    )
}

/// Maps `ARCamera.TrackingState` to the wire-level `driftConfidence` scalar,
/// matching `webxr.ts`'s `readPoseAndConfidence` pattern exactly (D-07):
/// `.normal` -> 1.0, `.limited` -> 0.5 (flat — sub-reason not differentiated
/// on the wire per D-08), `.notAvailable` -> 0.0.
func driftConfidence(for trackingState: ARCamera.TrackingState) -> Double {
    switch trackingState {
    case .normal:
        return 1.0
    case .limited:
        return 0.5
    case .notAvailable:
        return 0.0
    @unknown default:
        return 0.0
    }
}

/// Returns a distinct, human-readable string per `ARCamera.TrackingState`
/// `.limited` sub-reason (D-08). Surfaced locally via DynamicToast only —
/// never placed on the wire (the wire `driftConfidence` stays a flat 0.5 for
/// any `.limited(reason:)`, per `driftConfidence(for:)` above).
func trackingLimitedReasonMessage(_ reason: ARCamera.TrackingState.Reason) -> String {
    switch reason {
    case .initializing:
        return "Initializing tracking…"
    case .excessiveMotion:
        return "Moving too fast — slow down"
    case .insufficientFeatures:
        return "Point at a more detailed surface"
    case .relocalizing:
        return "Recovering tracking…"
    @unknown default:
        return "Tracking limited"
    }
}

/// Holds the last-known-good ARKit pose and freezes it on tracking loss,
/// mirroring `webxr.ts`'s `WebXrPoseTracker` freeze-on-lost idiom (D-07).
///
/// Freeze condition (resolved against the `webxr.ts` precedent per
/// RESEARCH.md's Open Question 1): `webxr.ts` freezes only on a NULL pose
/// (driftConfidence 0), and continues updating position through the
/// `.limited`/emulatedPosition state (driftConfidence 0.5). This tracker
/// mirrors that exactly — `lastGoodTransform` updates on both `.normal` and
/// `.limited`, and freezes ONLY on `.notAvailable`. This is a deliberate
/// choice, not an oversight: D-07's "position freezes at last-known-good on
/// loss" is interpreted as "loss" == `.notAvailable` (driftConfidence 0)
/// specifically, matching the named porting source.
final class ARPoseTracker {
    private(set) var lastGoodTransform: simd_float4x4 = matrix_identity_float4x4
    private(set) var driftConfidence: Double = 0

    /// Ingests one ARKit frame's camera transform + tracking state.
    ///
    /// Updates `lastGoodTransform` whenever `trackingState != .notAvailable`
    /// (i.e. on both `.normal` and `.limited`) — freeze only on
    /// `.notAvailable`, per the webxr.ts precedent documented above.
    /// `driftConfidence` always reflects the CURRENT frame's tracking state,
    /// even when the frozen transform is retained.
    func ingest(transform: simd_float4x4, trackingState: ARCamera.TrackingState) {
        driftConfidence = immersiveRT.driftConfidence(for: trackingState)
        if trackingState != .notAvailable {
            lastGoodTransform = transform
        }
    }

    /// Returns the current wire-ready pose: position + quaternion derived
    /// from `lastGoodTransform` (frozen on `.notAvailable`), and the current
    /// `driftConfidence`.
    func currentPose() -> ARPose {
        let position = arKitPacketPosition(from: lastGoodTransform)
        let quaternion = arKitPacketQuaternion(from: lastGoodTransform)
        return ARPose(
            px: position.px, py: position.py, pz: position.pz,
            qw: quaternion.qw, qx: quaternion.qx, qy: quaternion.qy, qz: quaternion.qz,
            driftConfidence: driftConfidence
        )
    }
}
