import XCTest
@testable import immersiveRT

/// Source-contract tests for ARKit world-origin recentering (D-10 auto,
/// D-11 manual). A live `ARSession`/`ARFrame` cannot be constructed or
/// driven in the iOS Simulator (RESEARCH.md's Validation Architecture
/// constraint — ARKit itself does not run there), so these tests inspect
/// the actual source text for the required call shape — the same
/// source-assertion pattern `TransportManagerTests` already uses for its
/// D-01 wiring proofs (`test_startSensorLoopIfNeeded_wiresARPoseSource_notMotionSource`).
final class ARPoseSourceRecenterTests: XCTestCase {

    private func sourceOfARPoseSource() throws -> String {
        try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "immersiveRTTests/ARPoseSourceRecenterTests.swift",
                with: "immersiveRT/Sensor/ARPoseSource.swift"
            ),
            encoding: .utf8
        )
    }

    private func sourceOfTransportManager() throws -> String {
        try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "immersiveRTTests/ARPoseSourceRecenterTests.swift",
                with: "immersiveRT/Transport/TransportManager.swift"
            ),
            encoding: .utf8
        )
    }

    /// D-11 / RESEARCH.md Pattern 2: `recenter()` must call
    /// `setWorldOrigin(relativeTransform:)`, and this file must never call
    /// `.resetTracking` anywhere — a `.resetTracking` restart would cause a
    /// visible tracking blip, which the recenter/calibration path must
    /// avoid (RESEARCH.md Anti-Patterns).
    func test_recenter_usesSetWorldOrigin_neverResetTracking() throws {
        let source = try sourceOfARPoseSource()
        guard let range = source.range(of: "func recenter()") else {
            XCTFail("recenter() not found in ARPoseSource.swift")
            return
        }
        let body = source[range.lowerBound...]
        XCTAssertTrue(
            body.contains("setWorldOrigin(relativeTransform:"),
            "recenter() must call setWorldOrigin(relativeTransform:)"
        )
        XCTAssertFalse(
            source.contains(".resetTracking"),
            "ARPoseSource.swift must never call .resetTracking for recenter/calibration (RESEARCH.md Anti-Patterns)"
        )
    }

    /// D-10: the `ARSessionDelegate` frame-update path must drive a
    /// `HoldStillDetector` from incoming poses and reach `recenter()` once
    /// its result flips to still — a one-time auto-calibration gate, not a
    /// per-frame recenter.
    func test_autoCalibration_gatesRecenterBehindHoldStillDetectorResult() throws {
        let source = try sourceOfARPoseSource()
        XCTAssertTrue(
            source.contains("HoldStillDetector"),
            "ARPoseSource must drive a HoldStillDetector for auto-calibration (D-10)"
        )
        guard let range = source.range(of: "didUpdate frame: ARFrame") else {
            XCTFail("ARSessionDelegate didUpdate not found in ARPoseSource.swift")
            return
        }
        let body = source[range.lowerBound...]
        XCTAssertTrue(
            body.contains("recenter()"),
            "the ARSessionDelegate callback path must reach recenter() once auto-calibration completes"
        )
    }

    /// D-11: `TransportManager.recenter()` must exist and delegate to
    /// `arPoseSource.recenter()` — the manual recenter path, additive to
    /// (not replacing) the desktop's R-key `resetAllPlayerPositions()`.
    func test_transportManagerRecenter_delegatesToARPoseSource() throws {
        let source = try sourceOfTransportManager()
        guard let range = source.range(of: "func recenter()") else {
            XCTFail("recenter() not found in TransportManager.swift")
            return
        }
        let body = source[range.lowerBound...]
        XCTAssertTrue(
            body.contains("arPoseSource.recenter()"),
            "TransportManager.recenter() must delegate to arPoseSource.recenter()"
        )
    }

    /// `ARPoseSource` must be directly constructible (default init) so
    /// `TransportManager`'s default `arPoseSource: ARPoseSource = ARPoseSource()`
    /// argument keeps working — constructing it never touches a live
    /// `ARSession` (that only happens inside `start()`, guarded by
    /// `ARWorldTrackingConfiguration.isSupported`).
    func test_arPoseSource_isDefaultConstructible() {
        let source = ARPoseSource()
        XCTAssertFalse(source.isCalibrated, "a freshly constructed ARPoseSource must not report calibrated yet")
    }
}
