import SwiftUI
import UIKit

/// Full-screen raw UIKit touch capture (D-04) for `ActiveSessionView`'s
/// single-finger touch signal (Plan 04, SENS-06) — replaces a SwiftUI
/// `DragGesture(minimumDistance: 0)`.
///
/// ROOT CAUSE (on-device bug report: "If I double touch the screen
/// (random) it sends continuously the touch signal, it doesn't
/// disappear"): `DragGesture` is a single-pointer-tracking SwiftUI gesture
/// that resolves gesture ambiguity/conflicts through its OWN internal state
/// machine layered on top of raw touches. A rapid double-tap (two
/// touch-down/up sequences in very close succession, possibly overlapping)
/// can produce an ambiguous sequence where `.onChanged` fires again without
/// SwiftUI ever delivering a matching `.onEnded`, or a touch gets dropped
/// by the system without `.onEnded` firing at all — leaving `touchActive`/
/// the wire touch state stuck `true` indefinitely.
///
/// FIX: mirror `CornerLongPressRecognizer`'s established pattern in this
/// codebase — track touches directly via a raw `UIView` overriding
/// `touchesBegan`/`touchesMoved`/`touchesEnded`/`touchesCancelled`. Per the
/// `UIResponder` touch-delivery contract, a touch this view begins
/// tracking is GUARANTEED to eventually receive a terminating
/// `touchesEnded` OR `touchesCancelled` call — both call sites here reset
/// tracking state and report `active: false`, so the touch signal cannot
/// get stuck true on any termination path, unlike `DragGesture`'s
/// higher-level ambiguity resolution.
///
/// Only ever tracks a single "primary" touch at a time (D-04's touch
/// signal is single-finger) — a second touch beginning while one is
/// already tracked is ignored, so a rapid/overlapping second tap cannot
/// clobber or desynchronize the tracked touch's own lifecycle.
struct TouchCaptureView: UIViewRepresentable {
    /// `active` mirrors the touch's begin/end lifecycle; `location` is in
    /// this view's own coordinate space (top-left origin), matching what
    /// `DragGesture`'s `value.location` previously provided to
    /// `normalizedTouch(location:in:)`.
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
        private weak var primaryTouch: UITouch?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            guard primaryTouch == nil, let touch = touches.first else { return }
            primaryTouch = touch
            onTouchChanged?(true, touch.location(in: self))
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            guard let primaryTouch, touches.contains(primaryTouch) else { return }
            onTouchChanged?(true, primaryTouch.location(in: self))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            endTrackingIfNeeded(touches)
        }

        /// A cancelled touch (e.g. the system interrupting for an
        /// incoming call, a system gesture stealing the touch, or the app
        /// backgrounding mid-touch) must reset tracking exactly like
        /// `touchesEnded` — this is the termination path `DragGesture`
        /// could silently drop, per the root-cause analysis above.
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            endTrackingIfNeeded(touches)
        }

        private func endTrackingIfNeeded(_ touches: Set<UITouch>) {
            guard let primaryTouch, touches.contains(primaryTouch) else { return }
            let location = primaryTouch.location(in: self)
            self.primaryTouch = nil
            onTouchChanged?(false, location)
        }
    }
}
