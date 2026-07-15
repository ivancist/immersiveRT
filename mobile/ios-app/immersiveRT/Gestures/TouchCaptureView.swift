import SwiftUI
import UIKit

/// Full-screen single-finger touch signal (D-04, Plan 04, SENS-06) for
/// `ActiveSessionView`.
///
/// Three different raw-`UIView` touch-tracking implementations here were
/// all unreliable on-device (stuck-active, or stopped reporting entirely
/// after the first touch) despite sound-looking logic. `CornerLongPressRecognizer`
/// — a `UIGestureRecognizer` attached directly to the window, exactly like
/// `CornerLongPressOverlay` below — has never had that problem. So this
/// mirrors that exact, proven pattern instead of a fourth variant of the
/// `UIViewRepresentable`-hosted-view approach: a `UIGestureRecognizer`
/// attached to the window (`cancelsTouchesInView = false`, so it only
/// observes, never blocks anything), counting touches with a single `Int`.
/// `active` is "is at least one touch currently down" — no per-touch
/// identity tracking, no location-ownership bookkeeping. Per the
/// `UIResponder` contract, every touch that begins is guaranteed a
/// terminating `touchesEnded`/`touchesCancelled`, so the counter always
/// returns to exactly 0 once every finger has lifted.
struct TouchCaptureView: UIViewRepresentable {
    var onTouchChanged: (_ active: Bool, _ location: CGPoint) -> Void

    func makeUIView(context: Context) -> UIView {
        let marker = UIView(frame: .zero)
        marker.isUserInteractionEnabled = false
        marker.isHidden = true
        context.coordinator.attach(to: marker)
        return marker
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTouchChanged = onTouchChanged
        context.coordinator.attach(to: uiView)
    }

    /// Removes the recognizer from its window when this view is torn down
    /// — mirrors `CornerLongPressOverlay.dismantleUIView`.
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTouchChanged: onTouchChanged)
    }

    final class Coordinator: NSObject {
        var onTouchChanged: (Bool, CGPoint) -> Void
        private weak var recognizer: TouchSignalRecognizer?
        private weak var attachedWindow: UIWindow?

        init(onTouchChanged: @escaping (Bool, CGPoint) -> Void) {
            self.onTouchChanged = onTouchChanged
        }

        /// Attaches the recognizer to `view.window` once the marker view is
        /// actually inserted into the hierarchy — deferred one runloop
        /// tick, and a no-op if already attached to the same window
        /// (mirrors `CornerLongPressOverlay.Coordinator.attach(to:holdDuration:)`).
        func attach(to view: UIView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, let window = view.window else { return }
                guard self.attachedWindow !== window else { return }

                if let previous = self.recognizer, let previousWindow = self.attachedWindow {
                    previousWindow.removeGestureRecognizer(previous)
                }

                let recognizer = TouchSignalRecognizer(target: nil, action: nil)
                recognizer.onTouchChanged = { [weak self] active, location in
                    self?.onTouchChanged(active, location)
                }
                window.addGestureRecognizer(recognizer)
                self.recognizer = recognizer
                self.attachedWindow = window
            }
        }

        func detach() {
            if let recognizer, let attachedWindow {
                attachedWindow.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            attachedWindow = nil
        }
    }
}

/// See `TouchCaptureView`'s doc comment for why this is a
/// `UIGestureRecognizer` (mirroring `CornerLongPressRecognizer`) rather than
/// a raw `UIView` touch tracker.
final class TouchSignalRecognizer: UIGestureRecognizer {
    var onTouchChanged: ((Bool, CGPoint) -> Void)?
    private var touchCount = 0

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        // Only ever observes — never consumes/blocks touches meant for
        // anything else on screen (SwiftUI Buttons, the corner-hold
        // recognizer, etc.).
        cancelsTouchesInView = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        touchCount += touches.count
        report(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        report(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        endTracking(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        endTracking(touches)
    }

    override func reset() {
        touchCount = 0
        super.reset()
    }

    private func report(_ touches: Set<UITouch>) {
        guard let view, let touch = touches.first else { return }
        onTouchChanged?(true, touch.location(in: view))
    }

    private func endTracking(_ touches: Set<UITouch>) {
        touchCount = max(0, touchCount - touches.count)
        guard let view else { return }
        let location = touches.first?.location(in: view) ?? .zero
        onTouchChanged?(touchCount > 0, location)
    }
}
