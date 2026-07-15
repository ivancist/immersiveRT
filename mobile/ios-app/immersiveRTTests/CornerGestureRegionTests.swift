import XCTest
@testable import immersiveRT

/// Pure geometry tests for the hidden 2-finger corner long-press reveal
/// gesture's hit-test region (D-12). `CornerLongPressRecognizer.corner(for:in:)`
/// is a free/static pure function — no `UIGestureRecognizer`/touch runtime
/// is instantiated here, so this is Simulator-safe and fully deterministic.
final class CornerGestureRegionTests: XCTestCase {

    /// Landscape-locked bounds used across all cases — matches the shape of
    /// the phone's full-screen touch-capture surface (D-04).
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)

    // MARK: - Corner classification

    func test_topLeftPoint_classifiesAsTopLeft() {
        let point = CGPoint(x: 50, y: 50)
        XCTAssertEqual(CornerLongPressRecognizer.corner(for: point, in: bounds), .topLeft)
    }

    func test_topRightPoint_classifiesAsTopRight() {
        let point = CGPoint(x: 950, y: 50)
        XCTAssertEqual(CornerLongPressRecognizer.corner(for: point, in: bounds), .topRight)
    }

    func test_centerPoint_classifiesAsNil() {
        let point = CGPoint(x: 500, y: 250)
        XCTAssertNil(CornerLongPressRecognizer.corner(for: point, in: bounds))
    }

    func test_bottomLeftPoint_classifiesAsNil() {
        let point = CGPoint(x: 50, y: 450)
        XCTAssertNil(CornerLongPressRecognizer.corner(for: point, in: bounds))
    }

    func test_bottomRightPoint_classifiesAsNil() {
        let point = CGPoint(x: 950, y: 450)
        XCTAssertNil(CornerLongPressRecognizer.corner(for: point, in: bounds))
    }

    // MARK: - Boundary cases (region is a defined inset — top 25% height,
    // left/right 30% width; see CornerLongPressRecognizer.swift)

    func test_pointJustInsideTopLeftRegion_classifiesAsTopLeft() {
        // cornerHeight = 500 * 0.25 = 125; cornerWidth = 1000 * 0.30 = 300.
        // (299, 124) is just inside both the height and width bands.
        let point = CGPoint(x: 299, y: 124)
        XCTAssertEqual(CornerLongPressRecognizer.corner(for: point, in: bounds), .topLeft)
    }

    func test_pointJustOutsideTopLeftRegion_byWidth_classifiesAsNil() {
        // x = 300 is exactly at the left-band boundary (band is [0, 300)) —
        // just outside.
        let point = CGPoint(x: 300, y: 124)
        XCTAssertNil(CornerLongPressRecognizer.corner(for: point, in: bounds))
    }

    func test_pointJustOutsideTopLeftRegion_byHeight_classifiesAsNil() {
        // y = 125 is exactly at the top-band boundary (band is [0, 125)) —
        // just outside.
        let point = CGPoint(x: 150, y: 125)
        XCTAssertNil(CornerLongPressRecognizer.corner(for: point, in: bounds))
    }

    func test_pointJustInsideTopRightRegion_classifiesAsTopRight() {
        // maxX = 1000; right band is (700, 1000]. 701 is just inside.
        let point = CGPoint(x: 701, y: 124)
        XCTAssertEqual(CornerLongPressRecognizer.corner(for: point, in: bounds), .topRight)
    }

    func test_pointJustOutsideTopRightRegion_byWidth_classifiesAsNil() {
        // x = 700 is exactly at the right-band boundary — just outside.
        let point = CGPoint(x: 700, y: 124)
        XCTAssertNil(CornerLongPressRecognizer.corner(for: point, in: bounds))
    }

    // MARK: - Degenerate bounds

    func test_zeroSizeBounds_classifiesAsNil() {
        let degenerate = CGRect(x: 0, y: 0, width: 0, height: 0)
        XCTAssertNil(CornerLongPressRecognizer.corner(for: CGPoint(x: 0, y: 0), in: degenerate))
    }
}
