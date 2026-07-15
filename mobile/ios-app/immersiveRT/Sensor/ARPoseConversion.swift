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
/// ✅ VERIFIED on-device (Plan 03 Task 1, D-16 axis checkpoint, second fix in
/// this iteration loop — quaternion was the first, see
/// `arKitPacketQuaternion`): a straight pass-through here (px=t.x, py=t.y,
/// pz=t.z) produced position axes that did not match device motion on the
/// real hardware HUD (raw numeric px/py/pz readout, not the visually-
/// confusing rendered cube). Root cause: `client/src/scene.ts`'s
/// `updateScene()` position-render formula (non-gesture branch) applies
/// `obj.mesh.position.set(-rpx, -rpz, rpy)` — i.e. `three.x=-wire.px,
/// three.y=-wire.pz, three.z=wire.py` — a mapping tuned for the OLD
/// device-frame dead-reckoning client (W3C earth-frame X=East/Y=North/Z=Up),
/// not for ARKit's world-frame translation column (Y-up, X-right,
/// Z-toward-viewer, i.e. -Z is forward).
///
/// On-device single-axis motion tests (lift/right/forward), cross-checked
/// against 3 independently-reported cube-movement observations run through
/// scene.ts's formula above, confirmed: lifting the phone increases raw
/// wire.py and moved the cube backward (+Z, toward viewer); moving the phone
/// right increased raw wire.px and moved the cube left (-X); moving the
/// phone forward decreased raw wire.pz and moved the cube up (+Y). All three
/// are consistent with the pass-through mapping combined with scene.ts's
/// formula above.
///
/// Fix: pre-compensate on the wire side so that, after scene.ts's fixed
/// formula is applied, phone motion maps to intuitive cube motion (up→up,
/// right→right, forward→into-scene/-Z). Solving scene.ts's formula backward
/// for the desired mapping gives: wire.px = -arkit.tx, wire.py = arkit.tz,
/// wire.pz = -arkit.ty. This does NOT touch `arKitPacketQuaternion` — that
/// mapping was fixed and verified separately in a prior commit of this same
/// checkpoint loop (D-16). Marked ✅ VERIFIED (empirically cross-checked
/// against 3 independent on-device axis tests), but — like any step in this
/// iteration loop — still subject to re-verification if the qualitative
/// feel-pass later in this checkpoint surfaces anything odd.
func arKitPacketPosition(from transform: simd_float4x4) -> (px: Double, py: Double, pz: Double) {
    let translation = transform.columns.3
    return (px: Double(-translation.x), py: Double(translation.z), pz: Double(-translation.y))
}

/// Extracts the wire-packet quaternion (qw, qx, qy, qz) from an ARKit camera
/// transform using the vetted one-call `simd_quaternion(transform)` (per
/// RESEARCH.md's Don't Hand-Roll table — never hand-roll a 3x3-to-quaternion
/// conversion).
///
/// ✅ VERIFIED on-device (Plan 03 Task 1, D-16 axis checkpoint): a straight
/// pass-through here produced roll/yaw swapped with coupled roll on the real
/// hardware HUD. Root cause: `client/src/scene.ts`'s `updateScene()` applies a
/// FIXED -90°-about-X conjugate swizzle to every incoming wire quaternion,
/// on the assumption it is expressed in the W3C `DeviceOrientationEvent` earth
/// frame (X=East, Y=North, Z=Up) —
/// `scratchQuat.set(state.qx, state.qz, -state.qy, state.qw)`, i.e.
/// `three.x=wire.qx, three.y=wire.qz, three.z=-wire.qy` (w unaffected by a
/// pure vector-part conjugation). ARKit's camera-transform quaternion is NOT
/// in that W3C frame — ARKit's own convention (Y-up, X-right, Z-toward-viewer)
/// is already structurally compatible with Three.js's default frame, so
/// letting scene.ts's W3C-specific swizzle apply unconditionally introduced an
/// unwanted rotation (the observed roll/yaw swap + coupling).
///
/// Fix: pre-apply the INVERSE of scene.ts's swizzle on the wire side, so the
/// net effect (wire -> scene.ts's swizzle -> Three.js) reproduces ARKit's raw
/// quaternion unchanged. Solving `three.{x,y,z} == arkit.{x,y,z}` for the
/// wire fields against scene.ts's mapping gives: wire.qx = arkit.qx (unchanged),
/// wire.qy = -arkit.qz, wire.qz = arkit.qy (qw always unchanged — pure vector
/// swap/negate). This does NOT touch `arKitPacketPosition` — position mapping
/// is a separate, still-pending iteration of this same checkpoint loop (D-16).
/// If a further axis issue surfaces later in this checkpoint's iteration, this
/// mapping is subject to re-verification like any other step in the loop.
func arKitPacketQuaternion(from transform: simd_float4x4) -> (qw: Double, qx: Double, qy: Double, qz: Double) {
    let quaternion = simd_quaternion(transform)
    return (
        qw: Double(quaternion.real),
        qx: Double(quaternion.imag.x),
        qy: Double(-quaternion.imag.z),
        qz: Double(quaternion.imag.y)
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
