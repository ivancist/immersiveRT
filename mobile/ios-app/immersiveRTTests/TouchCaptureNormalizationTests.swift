import XCTest
@testable import immersiveRT

/// Fixture-driven pure-function tests for `normalizedTouch(location:in:)`
/// (D-05) — mirrors `SensorPacketEncoderTests.swift`'s fixture-driven style
/// (PATTERNS.md). No gesture runtime or view hierarchy is exercised; every
/// case is a direct call against an explicit `CGRect` bounds argument.
final class TouchCaptureNormalizationTests: XCTestCase {

    private let bounds = CGRect(x: 100, y: 200, width: 800, height: 400)

    // MARK: - Corners

    func test_topLeftCorner_mapsToZeroZero() {
        let result = normalizedTouch(location: CGPoint(x: bounds.minX, y: bounds.minY), in: bounds)
        XCTAssertEqual(result.x, 0, accuracy: 0.0001)
        XCTAssertEqual(result.y, 0, accuracy: 0.0001)
    }

    func test_bottomRightCorner_mapsToOneOne() {
        let result = normalizedTouch(location: CGPoint(x: bounds.maxX, y: bounds.maxY), in: bounds)
        XCTAssertEqual(result.x, 1, accuracy: 0.0001)
        XCTAssertEqual(result.y, 1, accuracy: 0.0001)
    }

    func test_topRightCorner_mapsToOneZero() {
        let result = normalizedTouch(location: CGPoint(x: bounds.maxX, y: bounds.minY), in: bounds)
        XCTAssertEqual(result.x, 1, accuracy: 0.0001)
        XCTAssertEqual(result.y, 0, accuracy: 0.0001)
    }

    func test_bottomLeftCorner_mapsToZeroOne() {
        let result = normalizedTouch(location: CGPoint(x: bounds.minX, y: bounds.maxY), in: bounds)
        XCTAssertEqual(result.x, 0, accuracy: 0.0001)
        XCTAssertEqual(result.y, 1, accuracy: 0.0001)
    }

    // MARK: - Center

    func test_center_mapsToHalfHalf() {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let result = normalizedTouch(location: center, in: bounds)
        XCTAssertEqual(result.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.y, 0.5, accuracy: 0.0001)
    }

    // MARK: - Out-of-bounds clamping

    func test_locationLeftOfBounds_clampsXToZero() {
        let result = normalizedTouch(location: CGPoint(x: bounds.minX - 50, y: bounds.midY), in: bounds)
        XCTAssertEqual(result.x, 0, accuracy: 0.0001)
    }

    func test_locationRightOfBounds_clampsXToOne() {
        let result = normalizedTouch(location: CGPoint(x: bounds.maxX + 50, y: bounds.midY), in: bounds)
        XCTAssertEqual(result.x, 1, accuracy: 0.0001)
    }

    func test_locationAboveBounds_clampsYToZero() {
        let result = normalizedTouch(location: CGPoint(x: bounds.midX, y: bounds.minY - 50), in: bounds)
        XCTAssertEqual(result.y, 0, accuracy: 0.0001)
    }

    func test_locationBelowBounds_clampsYToOne() {
        let result = normalizedTouch(location: CGPoint(x: bounds.midX, y: bounds.maxY + 50), in: bounds)
        XCTAssertEqual(result.y, 1, accuracy: 0.0001)
    }

    func test_locationFarOutsideBounds_clampsBothAxes() {
        let result = normalizedTouch(location: CGPoint(x: -10000, y: 10000), in: bounds)
        XCTAssertEqual(result.x, 0, accuracy: 0.0001)
        XCTAssertEqual(result.y, 1, accuracy: 0.0001)
    }

    // MARK: - Degenerate bounds

    func test_zeroSizeBounds_returnsZeroZeroRatherThanNaNOrCrash() {
        let degenerate = CGRect(x: 0, y: 0, width: 0, height: 0)
        let result = normalizedTouch(location: CGPoint(x: 10, y: 10), in: degenerate)
        XCTAssertEqual(result.x, 0, accuracy: 0.0001)
        XCTAssertEqual(result.y, 0, accuracy: 0.0001)
    }
}
