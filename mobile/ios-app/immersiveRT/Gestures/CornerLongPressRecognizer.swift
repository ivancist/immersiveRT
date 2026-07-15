import UIKit
import SwiftUI

/// Which top corner a tracked touch currently falls within, per the hidden
/// 2-finger corner long-press reveal gesture (D-12).
enum Corner: Equatable {
    case topLeft
    case topRight
}

/// Custom `UIGestureRecognizer` for the hidden Recenter/Disconnect menu
/// reveal (D-12). Per RESEARCH.md Pattern 3, SwiftUI has no primitive for
/// "N touches, each constrained to a screen region, held for a duration" —
/// this tracks each `UITouch`'s `location(in:)` independently via
/// `touchesBegan`/`touchesMoved`/`touchesEnded`/`touchesCancelled`,
/// classifies each with the pure `corner(for:in:)` hit-test below, and arms
/// a hold timer only once one touch is held in `.topLeft` AND another in
/// `.topRight` simultaneously.
///
/// CRITICAL (D-04/D-12): this recognizer must OBSERVE alongside the
/// single-finger tap+drag touch capture (Plan 04), never consume/block it —
/// `cancelsTouchesInView = false` is set in `init`, and no touches are ever
/// marked `.ended`/`.cancelled` on the underlying view by this recognizer.
final class CornerLongPressRecognizer: UIGestureRecognizer {

    // MARK: - Pure hit-test geometry (Task 1)

    /// Fraction of `bounds.width`, measured from each side edge, that counts
    /// as the left/right corner band.
    static let cornerWidthFraction: CGFloat = 0.3

    /// Floor for `topInset` on devices that somehow report a zero/near-zero
    /// safe-area top inset — keeps the band usable rather than vanishing.
    static let minimumTopInset: CGFloat = 20

    /// Classifies `point` as `.topLeft`, `.topRight`, or `nil` (no corner),
    /// given the landscape-locked `bounds` of the touch-capture view and the
    /// height of the top band to treat as "corner zone".
    ///
    /// Pure function — bounds + point + topInset in, enum out. No
    /// `UITouch`/runtime dependency, so this is unit-testable with no
    /// Simulator touch injection required (`CornerGestureRegionTests`).
    ///
    /// The top band is `[bounds.minY, bounds.minY + topInset)`; the left
    /// band is `[bounds.minX, bounds.minX + cornerWidthFraction * width)`;
    /// the right band is `(bounds.maxX - cornerWidthFraction * width,
    /// bounds.maxX]`. A point must fall within the top band AND one of the
    /// side bands to classify as a corner.
    ///
    /// NARROWED HEIGHT BAND (on-device request, round 2: "isolate the
    /// [corner-hold] detection ONLY for the highest zone, from dynamic
    /// island (or notch) to the top"): previously a flat 25%-of-height
    /// fraction, which on a ~850pt-tall screen carved out a ~210pt band —
    /// much taller than the actual notch/Dynamic Island (`safeAreaInsets.top`
    /// is ~44-59pt), so it very plausibly overlapped normal single-finger
    /// control touches near the top of the screen and made the two touch
    /// surfaces (this reveal gesture vs. `TouchCaptureView`'s control
    /// signal) compete for the same real estate. `topInset` is now the
    /// caller-supplied `view.safeAreaInsets.top` (see call sites below) —
    /// the exact system-reserved sliver around the notch/island — clamped
    /// to `minimumTopInset` as a floor, so the corner-hold zone tracks the
    /// actual per-device hardware cutout instead of an arbitrary fraction.
    ///
    /// `bounds` itself is still `view.bounds` where `view` is the `UIWindow`
    /// this recognizer is attached to (`CornerLongPressOverlay` adds it via
    /// `window.addGestureRecognizer(_:)`) — always the FULL physical screen
    /// size, unaffected by safe-area layout.
    static func corner(for point: CGPoint, in bounds: CGRect, topInset: CGFloat) -> Corner? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let cornerHeight = max(topInset, minimumTopInset)
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

    // MARK: - Touch tracking state

    var onReveal: (() -> Void)?

    /// How long both corners must be held before `onReveal` fires.
    /// 0.6s — Claude's Discretion per CONTEXT.md/RESEARCH.md Pattern 3;
    /// long enough to be very hard to trigger by accident on a full-screen
    /// touch-capture surface, short enough not to feel broken when
    /// deliberately invoked.
    var holdDuration: TimeInterval = 0.6

    /// Tolerance (in points) a tracked touch may drift outside its
    /// originally-claimed corner region before the gesture cancels.
    private let driftTolerance: CGFloat = 24

    private var cornerTouches: [ObjectIdentifier: (touch: UITouch, corner: Corner)] = [:]
    private var armTimer: Timer?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        // D-04/D-12: never consume/block the primary touch-capture surface —
        // this recognizer only ever observes.
        cancelsTouchesInView = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let view else { return }
        let topInset = view.safeAreaInsets.top

        for touch in touches {
            let point = touch.location(in: view)
            guard let corner = Self.corner(for: point, in: view.bounds, topInset: topInset) else { continue }
            guard !isOccupied(corner) else { continue }
            cornerTouches[ObjectIdentifier(touch)] = (touch, corner)
        }

        armIfBothCornersHeld()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let view else { return }
        let topInset = view.safeAreaInsets.top

        for touch in touches {
            guard let entry = cornerTouches[ObjectIdentifier(touch)] else { continue }
            let point = touch.location(in: view)

            if let stillCorner = Self.corner(for: point, in: view.bounds, topInset: topInset), stillCorner == entry.corner {
                continue
            }

            // Allow small drift within tolerance before cancelling — a
            // held finger is never perfectly still.
            if withinDriftTolerance(point, of: touch, in: view) {
                continue
            }

            reset()
            return
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        if touches.contains(where: { cornerTouches[ObjectIdentifier($0)] != nil }) {
            reset()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        reset()
    }

    override func reset() {
        cornerTouches.removeAll()
        armTimer?.invalidate()
        armTimer = nil
        super.reset()
    }

    // MARK: - Private helpers

    private func isOccupied(_ corner: Corner) -> Bool {
        cornerTouches.values.contains { $0.corner == corner }
    }

    private func withinDriftTolerance(_ point: CGPoint, of touch: UITouch, in view: UIView) -> Bool {
        let previous = touch.previousLocation(in: view)
        let dx = point.x - previous.x
        let dy = point.y - previous.y
        return (dx * dx + dy * dy) <= (driftTolerance * driftTolerance)
    }

    private func armIfBothCornersHeld() {
        let hasTopLeft = cornerTouches.values.contains { $0.corner == .topLeft }
        let hasTopRight = cornerTouches.values.contains { $0.corner == .topRight }
        guard hasTopLeft, hasTopRight else { return }

        armTimer?.invalidate()
        armTimer = Timer.scheduledTimer(withTimeInterval: holdDuration, repeats: false) { [weak self] _ in
            self?.onReveal?()
            self?.reset()
        }
    }
}

// MARK: - SwiftUI hosting

/// Invisible marker overlay that attaches `CornerLongPressRecognizer` to the
/// enclosing `UIWindow`, suitable for layering into `ActiveSessionView`
/// (wired in Plan 08).
///
/// Gesture recognizers only receive touches for the ancestor chain of
/// whichever view UIKit hit-tests for a given touch — never for unrelated
/// sibling views. Since this overlay sits as a ZStack SIBLING of
/// `ActiveSessionView`'s full-screen touch-capture surface (not its
/// ancestor), attaching the recognizer to this marker view directly would
/// either (a) never observe any touches, or (b) have to win hit-testing
/// itself and thereby steal touches from the surface underneath — both
/// violate D-04/D-12's "observe alongside, never block" requirement.
///
/// The `UIWindow` is the one common ancestor of every view on screen, so a
/// recognizer attached there observes every touch regardless of which
/// descendant view is actually hit-tested, with zero risk of stealing
/// hit-test priority from the SwiftUI touch surface below. This marker view
/// itself is a zero-size, non-interactive placeholder used only to reach
/// `view.window` once SwiftUI inserts it into the hierarchy.
struct CornerLongPressOverlay: UIViewRepresentable {
    /// Optional override for tests/tuning — defaults to
    /// `CornerLongPressRecognizer.holdDuration`.
    var holdDuration: TimeInterval? = nil
    var onReveal: () -> Void

    func makeUIView(context: Context) -> UIView {
        let marker = UIView(frame: .zero)
        marker.isUserInteractionEnabled = false
        marker.isHidden = true
        context.coordinator.attach(to: marker, holdDuration: holdDuration)
        return marker
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onReveal = onReveal
        context.coordinator.attach(to: uiView, holdDuration: holdDuration)
    }

    /// Removes the recognizer from its window when this view is torn down
    /// (e.g. `ActiveSessionView` gates mounting this overlay on D-13's
    /// `isConnected`, so it now unmounts on every disconnect) — without
    /// this, the recognizer would stay attached to the window indefinitely,
    /// a harmless-but-leaked object (its `onReveal` closure captures the
    /// coordinator `weak`, so it goes inert on deinit — but there's no
    /// reason to keep the leak now that unmounting is a normal, frequent
    /// transition rather than an app-lifetime-rare event).
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onReveal: onReveal)
    }

    final class Coordinator: NSObject {
        var onReveal: () -> Void
        private weak var recognizer: CornerLongPressRecognizer?
        private weak var attachedWindow: UIWindow?

        init(onReveal: @escaping () -> Void) {
            self.onReveal = onReveal
        }

        /// Attaches the recognizer to `view.window` once the marker view is
        /// actually inserted into the hierarchy (`window` is nil during
        /// `makeUIView`, before SwiftUI has placed it) — deferred one
        /// runloop tick, and guarded so re-attaching the same window is a
        /// no-op (both `makeUIView` and `updateUIView` call this).
        func attach(to view: UIView, holdDuration: TimeInterval?) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, let window = view.window else { return }
                guard self.attachedWindow !== window else { return }

                if let previous = self.recognizer, let previousWindow = self.attachedWindow {
                    previousWindow.removeGestureRecognizer(previous)
                }

                let recognizer = CornerLongPressRecognizer(target: nil, action: nil)
                if let holdDuration {
                    recognizer.holdDuration = holdDuration
                }
                recognizer.onReveal = { [weak self] in self?.onReveal() }
                window.addGestureRecognizer(recognizer)
                self.recognizer = recognizer
                self.attachedWindow = window
            }
        }

        /// Removes the recognizer from its window immediately (see
        /// `dismantleUIView` above) — synchronous, unlike `attach`, since
        /// there is no need to wait for a window to become available on
        /// teardown.
        func detach() {
            if let recognizer, let attachedWindow {
                attachedWindow.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            attachedWindow = nil
        }
    }
}
