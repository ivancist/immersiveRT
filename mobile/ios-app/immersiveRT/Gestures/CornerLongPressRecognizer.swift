import UIKit

/// Which top corner a tracked touch currently falls within, per the hidden
/// 2-finger corner long-press reveal gesture (D-12).
enum Corner: Equatable {
    case topLeft
    case topRight
}

/// Custom `UIGestureRecognizer` for the hidden Recenter/Disconnect menu
/// reveal (D-12). Per RESEARCH.md Pattern 3, SwiftUI has no primitive for
/// "N touches, each constrained to a screen region, held for a duration" —
/// touch tracking, hold-timer arming, and the SwiftUI hosting wrapper are
/// implemented in Task 2. This class currently exposes only the pure
/// hit-test geometry (Task 1).
final class CornerLongPressRecognizer: UIGestureRecognizer {

    // MARK: - Pure hit-test geometry (Task 1)

    /// Fraction of `bounds.height`, measured from the top edge, that counts
    /// as "top" for corner classification.
    static let cornerHeightFraction: CGFloat = 0.25

    /// Fraction of `bounds.width`, measured from each side edge, that counts
    /// as the left/right corner band.
    static let cornerWidthFraction: CGFloat = 0.3

    /// Classifies `point` as `.topLeft`, `.topRight`, or `nil` (no corner),
    /// given the landscape-locked `bounds` of the touch-capture view.
    ///
    /// Pure function — bounds + point in, enum out. No `UITouch`/runtime
    /// dependency, so this is unit-testable with no Simulator touch
    /// injection required (`CornerGestureRegionTests`).
    ///
    /// The top band is `[bounds.minY, bounds.minY + cornerHeightFraction *
    /// height)`; the left band is `[bounds.minX, bounds.minX +
    /// cornerWidthFraction * width)`; the right band is
    /// `(bounds.maxX - cornerWidthFraction * width, bounds.maxX]`. A point
    /// must fall within the top band AND one of the side bands to classify
    /// as a corner.
    static func corner(for point: CGPoint, in bounds: CGRect) -> Corner? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let cornerHeight = bounds.height * cornerHeightFraction
        let cornerWidth = bounds.width * cornerWidthFraction

        guard point.y >= bounds.minY, point.y < bounds.minY + cornerHeight else {
            return nil
        }

        if point.x >= bounds.minX, point.x < bounds.minX + cornerWidth {
            return .topLeft
        }

        if point.x > bounds.maxX - cornerWidth, point.x <= bounds.maxX {
            return .topRight
        }

        return nil
    }
}
