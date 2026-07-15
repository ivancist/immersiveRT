import XCTest
import ARKit
import simd
@testable import immersiveRT

/// Pure-function tests for the ARKit pose -> wire-packet conversion layer
/// (SENS-V2-03, D-02/D-07). No live `ARSession` is created anywhere in this
/// file — `simd_float4x4` fixtures and directly-constructed
/// `ARCamera.TrackingState` cases are enough to exercise the conversion
/// functions in the iOS Simulator, per RESEARCH.md's Validation Architecture
/// constraint (ARKit itself does not run in the Simulator).
final class ARPoseConversionTests: XCTestCase {

    // MARK: - Position extraction

    /// Position extraction pulls the translation column (columns.3.x/y/z) of
    /// a known `simd_float4x4` through the D-16-fix axis compensation
    /// (wire.px = -arkit.tx, wire.py = arkit.tz, wire.pz = -arkit.ty; see
    /// `arKitPacketPosition`'s doc comment) into px/py/pz.
    ///
    /// Fixture: tx=1.5, ty=-2.0, tz=3.25. Recomputed expected values:
    /// px = -tx = -1.5, py = tz = 3.25, pz = -ty = -(-2.0) = 2.0.
    func test_arKitPacketPosition_extractsTranslationColumn() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(1.5, -2.0, 3.25, 1)

        let position = arKitPacketPosition(from: transform)

        XCTAssertEqual(position.px, -1.5, accuracy: 1e-6)
        XCTAssertEqual(position.py, 3.25, accuracy: 1e-6)
        XCTAssertEqual(position.pz, 2.0, accuracy: 1e-6)
    }

    // MARK: - Quaternion extraction

    /// Quaternion extraction of a known rotation matrix (90 degrees about the
    /// X axis) yields the expected qw/qx/qy/qz, normalized.
    ///
    /// Post-D-16-fix mapping is qw=w, qx=x, qy=-z, qz=y (see
    /// `arKitPacketQuaternion`'s doc comment). For a pure X-axis rotation the
    /// raw ARKit quaternion's y and z imaginary components are both exactly
    /// zero, and swap/negate of zero is still zero — so this fixture's
    /// expected values are numerically IDENTICAL before and after the fix
    /// (recomputed and confirmed below, not copy-pasted). This fixture alone
    /// cannot discriminate the old pass-through mapping from the new
    /// swap-and-negate mapping; `test_arKitPacketQuaternion_swapsAndNegatesYZForRotationWithNonzeroYZComponents`
    /// below uses a Z-axis rotation specifically to exercise that distinction.
    func test_arKitPacketQuaternion_extractsNormalizedQuaternionFromKnownRotation() {
        // 90-degree rotation about the X axis:
        //   columns.0 = (1, 0, 0, 0)
        //   columns.1 = (0, 0, 1, 0)
        //   columns.2 = (0, -1, 0, 0)
        //   columns.3 = (0, 0, 0, 1)
        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(1, 0, 0, 0)
        transform.columns.1 = SIMD4<Float>(0, 0, 1, 0)
        transform.columns.2 = SIMD4<Float>(0, -1, 0, 0)
        transform.columns.3 = SIMD4<Float>(0, 0, 0, 1)

        let quaternion = arKitPacketQuaternion(from: transform)

        // Raw ARKit quaternion for this fixture: w=x=halfAngle, y=z=0.
        // New mapping: qw=w, qx=x, qy=-z=-0=0, qz=y=0 -- unchanged from before the fix.
        let halfAngle = sqrt(2.0) / 2.0 // cos(45deg) == sin(45deg)
        XCTAssertEqual(quaternion.qw, halfAngle, accuracy: 1e-5)
        XCTAssertEqual(quaternion.qx, halfAngle, accuracy: 1e-5)
        XCTAssertEqual(quaternion.qy, 0, accuracy: 1e-5)
        XCTAssertEqual(quaternion.qz, 0, accuracy: 1e-5)

        let magnitude = sqrt(
            quaternion.qw * quaternion.qw
                + quaternion.qx * quaternion.qx
                + quaternion.qy * quaternion.qy
                + quaternion.qz * quaternion.qz
        )
        XCTAssertEqual(magnitude, 1.0, accuracy: 1e-5, "Extracted quaternion must be normalized")
    }

    /// Quaternion extraction of a 90-degree rotation about the Z axis
    /// specifically exercises the D-16-fix's y/z swap-and-negate (unlike the
    /// X-axis fixture above, this rotation's raw ARKit quaternion has a
    /// nonzero z imaginary component and zero y, so old pass-through vs. new
    /// swap-and-negate produce numerically different results).
    func test_arKitPacketQuaternion_swapsAndNegatesYZForRotationWithNonzeroYZComponents() {
        // 90-degree rotation about the Z axis:
        //   columns.0 = (0, 1, 0, 0)
        //   columns.1 = (-1, 0, 0, 0)
        //   columns.2 = (0, 0, 1, 0)
        //   columns.3 = (0, 0, 0, 1)
        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(0, 1, 0, 0)
        transform.columns.1 = SIMD4<Float>(-1, 0, 0, 0)
        transform.columns.2 = SIMD4<Float>(0, 0, 1, 0)
        transform.columns.3 = SIMD4<Float>(0, 0, 0, 1)

        let quaternion = arKitPacketQuaternion(from: transform)

        // Raw ARKit quaternion for this fixture (via the standard
        // trace-based rotation-matrix-to-quaternion formula, matching
        // simd_quaternion(transform)): w=halfAngle, x=0, y=0, z=halfAngle.
        // New mapping: qw=w=halfAngle, qx=x=0, qy=-z=-halfAngle, qz=y=0.
        let halfAngle = sqrt(2.0) / 2.0
        XCTAssertEqual(quaternion.qw, halfAngle, accuracy: 1e-5)
        XCTAssertEqual(quaternion.qx, 0, accuracy: 1e-5)
        XCTAssertEqual(quaternion.qy, -halfAngle, accuracy: 1e-5)
        XCTAssertEqual(quaternion.qz, 0, accuracy: 1e-5)

        let magnitude = sqrt(
            quaternion.qw * quaternion.qw
                + quaternion.qx * quaternion.qx
                + quaternion.qy * quaternion.qy
                + quaternion.qz * quaternion.qz
        )
        XCTAssertEqual(magnitude, 1.0, accuracy: 1e-5, "Extracted quaternion must be normalized")
    }

    // MARK: - driftConfidence mapping (D-07/D-08)

    /// `driftConfidence(for:)` returns 1.0 for `.normal`, 0.5 for
    /// `.limited(.excessiveMotion)` AND `.limited(.initializing)` (D-08 flat
    /// 0.5, sub-reason not differentiated on the wire), 0.0 for
    /// `.notAvailable`.
    func test_driftConfidence_mapsTrackingStateExactlyPerD07() {
        XCTAssertEqual(driftConfidence(for: .normal), 1.0)
        XCTAssertEqual(driftConfidence(for: .limited(.excessiveMotion)), 0.5)
        XCTAssertEqual(driftConfidence(for: .limited(.initializing)), 0.5)
        XCTAssertEqual(driftConfidence(for: .notAvailable), 0.0)
    }

    // MARK: - ARPoseTracker freeze-on-loss (D-07, webxr.ts precedent)

    /// `ARPoseTracker.ingest` updates last-known-good on `.normal` and on
    /// `.limited`, but does NOT mutate last-known-good on `.notAvailable`
    /// (freeze), while `driftConfidence` still drops to 0.0 on
    /// `.notAvailable`.
    func test_arPoseTracker_updatesThroughNormalAndLimited_freezesOnNotAvailable() {
        let tracker = ARPoseTracker()

        // Position assertions below use the D-16-fix axis compensation
        // (wire.px = -arkit.tx, wire.py = arkit.tz, wire.pz = -arkit.ty; see
        // `arKitPacketPosition`'s doc comment), independently recomputed from
        // each fixture's columns.3 below (not copied from any prior value).
        var normalTransform = matrix_identity_float4x4
        normalTransform.columns.3 = SIMD4<Float>(1, 2, 3, 1)
        tracker.ingest(transform: normalTransform, trackingState: .normal)

        // Fixture: tx=1, ty=2, tz=3 -> px=-tx=-1, py=tz=3, pz=-ty=-2.
        XCTAssertEqual(tracker.driftConfidence, 1.0)
        XCTAssertEqual(tracker.currentPose().px, -1, accuracy: 1e-6)
        XCTAssertEqual(tracker.currentPose().py, 3, accuracy: 1e-6)
        XCTAssertEqual(tracker.currentPose().pz, -2, accuracy: 1e-6)

        var limitedTransform = matrix_identity_float4x4
        limitedTransform.columns.3 = SIMD4<Float>(4, 5, 6, 1)
        tracker.ingest(transform: limitedTransform, trackingState: .limited(.excessiveMotion))

        // Fixture: tx=4, ty=5, tz=6 -> px=-tx=-4, py=tz=6, pz=-ty=-5.
        // webxr.ts precedent: keep updating last-known-good through .limited.
        XCTAssertEqual(tracker.driftConfidence, 0.5)
        XCTAssertEqual(tracker.currentPose().px, -4, accuracy: 1e-6)
        XCTAssertEqual(tracker.currentPose().py, 6, accuracy: 1e-6)
        XCTAssertEqual(tracker.currentPose().pz, -5, accuracy: 1e-6)

        var lostTransform = matrix_identity_float4x4
        lostTransform.columns.3 = SIMD4<Float>(99, 99, 99, 1)
        tracker.ingest(transform: lostTransform, trackingState: .notAvailable)

        // Freeze: last-known-good stays at the .limited sample's position
        // (px=-4, py=6, pz=-5), NOT the discarded .notAvailable sample.
        XCTAssertEqual(tracker.currentPose().px, -4, accuracy: 1e-6)
        XCTAssertEqual(tracker.currentPose().py, 6, accuracy: 1e-6)
        XCTAssertEqual(tracker.currentPose().pz, -5, accuracy: 1e-6)
        // driftConfidence still drops to 0.0 on .notAvailable.
        XCTAssertEqual(tracker.driftConfidence, 0.0)
    }

    // MARK: - trackingLimitedReasonMessage (D-08, local-UI-only)

    /// `trackingLimitedReasonMessage` returns a distinct non-empty string per
    /// reason (`.initializing`/`.excessiveMotion`/`.insufficientFeatures`/
    /// `.relocalizing`).
    func test_trackingLimitedReasonMessage_returnsDistinctNonEmptyStringPerReason() {
        let reasons: [ARCamera.TrackingState.Reason] = [
            .initializing, .excessiveMotion, .insufficientFeatures, .relocalizing,
        ]
        let messages = reasons.map { trackingLimitedReasonMessage($0) }

        for message in messages {
            XCTAssertFalse(message.isEmpty)
        }
        XCTAssertEqual(
            Set(messages).count, messages.count,
            "Expected a distinct message per ARCamera.TrackingState.Reason case"
        )
    }
}
