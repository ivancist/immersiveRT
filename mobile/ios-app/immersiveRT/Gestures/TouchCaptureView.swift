import SwiftUI
import UIKit

/// Full-screen raw UIKit touch capture (D-04) for `ActiveSessionView`'s
/// single-finger touch signal (Plan 04, SENS-06).
///
/// `active` is simply "is at least one touch currently down", counted with
/// a plain `Int` — no per-touch identity tracking. Per the `UIResponder`
/// contract, every touch this view begins tracking is guaranteed a
/// terminating `touchesEnded` or `touchesCancelled` call, so the counter
/// always returns to exactly 0 once every finger has lifted. Product
/// direction is explicit that multi-touch disambiguation is out of scope
/// ("double touch isn't coded, treat as single") — this counts touches, it
/// does not try to identify or distinguish them.
struct TouchCaptureView: UIViewRepresentable {
    var onTouchChanged: (_ active: Bool, _ location: CGPoint) -> Void

    func makeUIView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onTouchChanged = onTouchChanged
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        return view
    }

    func updateUIView(_ uiView: TrackingView, context: Context) {
        uiView.onTouchChanged = onTouchChanged
    }

    final class TrackingView: UIView {
        var onTouchChanged: ((Bool, CGPoint) -> Void)?
        private var touchCount = 0

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            touchCount += touches.count
            report(touches)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            report(touches)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            endTracking(touches)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            endTracking(touches)
        }

        private func report(_ touches: Set<UITouch>) {
            guard let touch = touches.first else { return }
            onTouchChanged?(true, touch.location(in: self))
        }

        private func endTracking(_ touches: Set<UITouch>) {
            touchCount = max(0, touchCount - touches.count)
            let location = touches.first?.location(in: self) ?? .zero
            onTouchChanged?(touchCount > 0, location)
        }
    }
}
