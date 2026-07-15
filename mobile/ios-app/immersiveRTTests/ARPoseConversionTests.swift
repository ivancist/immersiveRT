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
    /// a known `simd_float4x4` into px/py/pz through the axis-conversion
    /// function.
    func test_arKitPacketPosition_extractsTranslationColumn() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(1.5, -2.0, 3.25, 1)

        let position = arKitPacketPosition(from: transform)

        XCTAssertEqual(position.px, 1.5, accuracy: 1e-6)
        XCTAssertEqual(position.py, -2.0, accuracy: 1e-6)
        XCTAssertEqual(position.pz, 3.25, accuracy: 1e-6)
    }

    // MARK: - Quaternion extraction

    /// Quaternion extraction of a known rotation matrix (90 degrees about the
    /// X axis) yields the expected qw/qx/qy/qz, normalized.
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

        var normalTransform = matrix_identity_float4x4
        normalTransform.columns.3 = SIMD4<Float>(1, 2, 3, 1)
        tracker.ingest(transform: normalTransform, trackingState: .normal)

        XCTAssertEqual(tracker.driftConfidence, 1.0)
        XCTAssertEqual(tracker.currentPose().px, 1, accuracy: 1e-6)
        XCTAssertEqual(tracker.currentPose().py, 2, accuracy: 1e-6)
        XCTAssertEqual(tracker.currentPose().pz, 3, accuracy: 1e-6)

        var limitedTransform = matrix_identity_float4x4
        limitedTransform.columns.3 = SIMD4<Float>(4, 5, 6, 1)
        tracker.ingest(transform: limitedTransform, trackingState: .limited(.excessiveMotion))

        // webxr.ts precedent: keep updating last-known-good through .limited.
        XCTAssertEqual(tracker.driftConfidence, 0.5)
        XCTAssertEqual(tracker.currentPose().px, 4, accuracy: 1e-6)
        XCTAssertEqual(tracker.currentPose().py, 5, accuracy: 1e-6)
        XCTAssertEqual(tracker.currentPose().pz, 6, accuracy: 1e-6)

        var lostTransform = matrix_identity_float4x4
        lostTransform.columns.3 = SIMD4<Float>(99, 99, 99, 1)
        tracker.ingest(transform: lostTransform, trackingState: .notAvailable)

        // Freeze: last-known-good stays at the .limited sample's position,
        // NOT the discarded .notAvailable sample.
        XCTAssertEqual(tracker.currentPose().px, 4, accuracy: 1e-6)
        XCTAssertEqual(tracker.currentPose().py, 5, accuracy: 1e-6)
        XCTAssertEqual(tracker.currentPose().pz, 6, accuracy: 1e-6)
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
