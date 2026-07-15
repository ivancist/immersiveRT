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
/// Collapses any number of concurrent touches into a single boolean +
/// location signal (D-04's touch signal is single-finger; multi-touch
/// disambiguation is out of scope — "double touch" is deliberately NOT
/// coded, per product direction). `active` reflects whether AT LEAST ONE
/// touch is currently down; it only goes `false` once every tracked touch
/// has terminated.
///
/// REGRESSION FIX (on-device bug report, round 2: "the touch event is
/// triggered but never goes off"): an earlier version tracked a single
/// named `primaryTouch` identity. `CornerLongPressRecognizer`'s hidden
/// 2-finger corner-hold reveal gesture observes touches ALONGSIDE this
/// view (`cancelsTouchesInView = false`) rather than stealing them, so its
/// corner touches land on THIS view too. With a single-identity tracker,
/// whichever touch arrived first (a corner-hold finger, or the real
/// control finger) claimed the sole `primaryTouch` slot; a second,
/// different touch beginning afterward was silently ignored (never
/// tracked) — so if the real control touch lost the race, its own
/// `touchesEnded` never reset anything, and the flag kept following
/// whichever finger WAS being tracked instead. Tracking SET MEMBERSHIP
/// instead of a single identity removes this class of bug entirely: any
/// touch beginning is recorded, any touch ending is removed, and `active`
/// is derived purely from "is the set empty" — no single touch's identity
/// can desynchronize the flag from what's actually still touching the
/// screen.
///
/// (Prior fix, still in effect: each tracked `UITouch` is held STRONGLY,
/// mirroring `CornerLongPressRecognizer`'s dictionary-value storage — a
/// `weak` reference could be deallocated between `touchesBegan` and the
/// later terminating call, silently dropping the touch from tracking.)
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

        /// Every currently-down touch this view is tracking — strongly
        /// held (see type-level doc comment): membership, not identity, is
        /// what drives `active`.
        private var activeTouches: Set<UITouch> = []

        /// The single touch whose location is reported while `active` is
        /// `true` ("double touch isn't coded, treat as single" — only one
        /// location matters at a time). Re-promoted from the remaining
        /// set if it lifts while another touch is still down.
        private var leadTouch: UITouch?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            activeTouches.formUnion(touches)
            if leadTouch == nil {
                leadTouch = touches.first
            }
            guard let leadTouch else { return }
            onTouchChanged?(true, leadTouch.location(in: self))
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            guard let leadTouch, touches.contains(leadTouch) else { return }
            onTouchChanged?(true, leadTouch.location(in: self))
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
            let endedLeadLocation = leadTouch.map { $0.location(in: self) }
            let wasLead = leadTouch.map(touches.contains) ?? false

            activeTouches.subtract(touches)

            if activeTouches.isEmpty {
                leadTouch = nil
                onTouchChanged?(false, endedLeadLocation ?? .zero)
                return
            }

            guard wasLead else { return }
            // The lead touch just ended but others remain down — promote
            // one so location keeps tracking a live touch, and stay active.
            leadTouch = activeTouches.first
            if let leadTouch {
                onTouchChanged?(true, leadTouch.location(in: self))
            }
        }
    }
}
