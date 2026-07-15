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
        XCTAssertEqual(CornerLongPressRecognizer.corner(for: point, in: bounds, topInset: 125), .topLeft)
    }

    func test_topRightPoint_classifiesAsTopRight() {
        let point = CGPoint(x: 950, y: 50)
        XCTAssertEqual(CornerLongPressRecognizer.corner(for: point, in: bounds, topInset: 125), .topRight)
    }

    func test_centerPoint_classifiesAsNil() {
        let point = CGPoint(x: 500, y: 250)
        XCTAssertNil(CornerLongPressRecognizer.corner(for: point, in: bounds, topInset: 125))
    }

    func test_bottomLeftPoint_classifiesAsNil() {
        let point = CGPoint(x: 50, y: 450)
        XCTAssertNil(CornerLongPressRecognizer.corner(for: point, in: bounds, topInset: 125))
    }

    func test_bottomRightPoint_classifiesAsNil() {
        let point = CGPoint(x: 950, y: 450)
        XCTAssertNil(CornerLongPressRecognizer.corner(for: point, in: bounds, topInset: 125))
    }

    // MARK: - Boundary cases (region is a defined inset — top band height is
    // the caller-supplied topInset, left/right 30% of width;
    // see CornerLongPressRecognizer.swift)

    func test_pointJustInsideTopLeftRegion_classifiesAsTopLeft() {
        // cornerHeight = topInset = 125; cornerWidth = 1000 * 0.30 = 300.
        // (299, 124) is just inside both the height and width bands.
        let point = CGPoint(x: 299, y: 124)
        XCTAssertEqual(CornerLongPressRecognizer.corner(for: point, in: bounds, topInset: 125), .topLeft)
    }

    func test_pointJustOutsideTopLeftRegion_byWidth_classifiesAsNil() {
        // x = 300 is exactly at the left-band boundary (band is [0, 300)) —
        // just outside.
        let point = CGPoint(x: 300, y: 124)
        XCTAssertNil(CornerLongPressRecognizer.corner(for: point, in: bounds, topInset: 125))
    }

    func test_pointJustOutsideTopLeftRegion_byHeight_classifiesAsNil() {
        // y = 125 is exactly at the top-band boundary (band is [0, 125)) —
        // just outside.
        let point = CGPoint(x: 150, y: 125)
        XCTAssertNil(CornerLongPressRecognizer.corner(for: point, in: bounds, topInset: 125))
    }

    func test_pointJustInsideTopRightRegion_classifiesAsTopRight() {
        // maxX = 1000; right band is (700, 1000]. 701 is just inside.
        let point = CGPoint(x: 701, y: 124)
        XCTAssertEqual(CornerLongPressRecognizer.corner(for: point, in: bounds, topInset: 125), .topRight)
    }

    func test_pointJustOutsideTopRightRegion_byWidth_classifiesAsNil() {
        // x = 700 is exactly at the right-band boundary — just outside.
        let point = CGPoint(x: 700, y: 124)
        XCTAssertNil(CornerLongPressRecognizer.corner(for: point, in: bounds, topInset: 125))
    }

    // MARK: - Degenerate bounds

    func test_zeroSizeBounds_classifiesAsNil() {
        let degenerate = CGRect(x: 0, y: 0, width: 0, height: 0)
        XCTAssertNil(CornerLongPressRecognizer.corner(for: CGPoint(x: 0, y: 0), in: degenerate, topInset: 125))
    }

    // MARK: - True physical corner coverage (Refinement D on-device request:
    // "move the two finger long touch in the real corners... where now
    // there are time and ISP [status bar icons]")
    //
    // `bounds` here always represents the recognizer's attached `UIWindow`'s
    // `.bounds` at the real call sites (`CornerLongPressRecognizer.swift`'s
    // `corner(for:in:)` doc comment) — the FULL physical screen, never
    // reduced by safe-area insets. These cases assert points immediately
    // adjacent to the literal corner pixel (well within where a status
    // bar's clock/signal icons sit) still classify correctly, confirming
    // the pure hit-test geometry itself was never the constraint; the fix
    // was `ActiveSessionView` extending its visible/interactive surface to
    // match via `.ignoresSafeArea()`.
    func test_pointAdjacentToLiteralTopLeftCorner_classifiesAsTopLeft() {
        let point = CGPoint(x: 1, y: 1)
        XCTAssertEqual(CornerLongPressRecognizer.corner(for: point, in: bounds, topInset: 125), .topLeft)
    }

    func test_pointAdjacentToLiteralTopRightCorner_classifiesAsTopRight() {
        let point = CGPoint(x: 999, y: 1)
        XCTAssertEqual(CornerLongPressRecognizer.corner(for: point, in: bounds, topInset: 125), .topRight)
    }

    func test_pointAtExactTopLeftOrigin_classifiesAsTopLeft() {
        let point = CGPoint(x: bounds.minX, y: bounds.minY)
        XCTAssertEqual(CornerLongPressRecognizer.corner(for: point, in: bounds, topInset: 125), .topLeft)
    }

    func test_pointAtExactTopRightOrigin_classifiesAsTopRight() {
        let point = CGPoint(x: bounds.maxX, y: bounds.minY)
        XCTAssertEqual(CornerLongPressRecognizer.corner(for: point, in: bounds, topInset: 125), .topRight)
    }

    // MARK: - Narrowed zone (on-device request, round 2: "isolate the
    // [corner-hold] detection ONLY for the highest zone, from dynamic
    // island (or notch) to the top") — topInset is now the real device's
    // `safeAreaInsets.top` rather than a flat 25%-of-height fraction, so a
    // point that used to classify as a corner under the old fraction (e.g.
    // y=124 on a 500pt-tall surface) must now classify as `nil` once the
    // band shrinks to a realistic Dynamic Island inset (~59pt).

    func test_pointBelowRealisticDynamicIslandInset_classifiesAsNil() {
        // 59pt mirrors ToastView.swift's own `haveDynamicIsland` threshold.
        let point = CGPoint(x: 50, y: 60)
        XCTAssertNil(CornerLongPressRecognizer.corner(for: point, in: bounds, topInset: 59))
    }

    func test_pointWithinRealisticDynamicIslandInset_classifiesAsTopLeft() {
        let point = CGPoint(x: 50, y: 58)
        XCTAssertEqual(CornerLongPressRecognizer.corner(for: point, in: bounds, topInset: 59), .topLeft)
    }

    func test_zeroTopInset_fallsBackToMinimumFloor() {
        // A device/state reporting a zero safe-area inset must not produce
        // an unusably tiny (zero-height) band — minimumTopInset (20pt) is
        // the floor.
        let point = CGPoint(x: 50, y: 19)
        XCTAssertEqual(CornerLongPressRecognizer.corner(for: point, in: bounds, topInset: 0), .topLeft)
    }

    func test_zeroTopInset_pointBeyondMinimumFloor_classifiesAsNil() {
        let point = CGPoint(x: 50, y: 20)
        XCTAssertNil(CornerLongPressRecognizer.corner(for: point, in: bounds, topInset: 0))
    }
}
