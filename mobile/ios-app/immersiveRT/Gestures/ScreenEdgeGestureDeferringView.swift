import SwiftUI
import UIKit

/// Defers the system's top-edge gesture recognizers (Control Center /
/// Notification Center swipe) while `isActive` is `true` — scoped to "is
/// this session currently connected", since D-12's hidden corner-hold
/// gesture is only reachable in that same window and there is nothing to
/// defer top-edge system gestures FOR otherwise.
///
/// NOTE: this view previously also tried to hide the status bar via
/// `prefersStatusBarHidden` on the SAME child controller, on the assumption
/// that SwiftUI's `WindowGroup` hosting forwards that query exactly like it
/// forwards `preferredScreenEdgesDeferringSystemGestures`. On-device
/// verification showed that assumption was wrong — the status bar stayed
/// visible. Status-bar hiding now uses SwiftUI's native, directly-supported
/// `.statusBar(hidden:)` view modifier instead (`ActiveSessionView.swift`),
/// which does not depend on this child-controller-forwarding mechanism at
/// all. Keeping this type single-purpose (edge-gesture deferral only)
/// avoids re-coupling two mechanisms that turned out to have different
/// reliability characteristics.
///
/// Originally fixed an on-device bug report: "If I put my fingers at the
/// corner of the phone, where there is the system bar, it doesn't work."
///
/// ROOT CAUSE: `CornerLongPressRecognizer`'s top-corner hit-test regions
/// (`cornerHeightFraction` = 25% of height, `cornerWidthFraction` = 30% of
/// width, measured from each top corner) overlap the screen-edge band iOS
/// reserves for its OWN system gesture recognizers (Control Center /
/// Notification Center). Per Apple's documented behavior for
/// `UIViewController.preferredScreenEdgesDeferringSystemGestures` (default
/// `UIRectEdge.none` — no edges deferred to the app), a touch that begins
/// inside a reserved system-gesture edge band is intercepted by the
/// SYSTEM's gesture recognizers (which live above every app window) before
/// it is ever delivered into the app's `UIWindow`/`UIGestureRecognizer`s,
/// unless the currently active view controller opts an edge back in by
/// overriding this property.
///
/// PROPAGATION FOR SWIFTUI: the system determines "the currently active
/// view controller" by walking `childForScreenEdgesDeferringSystemGestures`
/// starting from the on-screen root view controller. This app is a plain
/// SwiftUI `WindowGroup` (`immersiveRTApp.swift`) with no directly
/// subclassable root `UIHostingController` — but SwiftUI's hosting
/// machinery forwards this exact query (and its sibling "preferred X"
/// queries: `prefersStatusBarHidden`, `prefersHomeIndicatorAutoHidden`,
/// `supportedInterfaceOrientations`) down to whichever
/// `UIViewControllerRepresentable`-backed child view controller is
/// currently part of the on-screen content tree — the SAME forwarding
/// mechanism this codebase already relies on for `CustomHostingView`
/// overriding `prefersStatusBarHidden` (`DynamicToast/CustomHostingView.swift`).
/// Embedding this tiny, invisible child view controller anywhere in
/// `ActiveSessionView`'s content is therefore sufficient for its override
/// to be consulted for the REAL WindowGroup window — the same window
/// `CornerLongPressOverlay` attaches its recognizer to via `view.window`.
///
/// Deferring `.top` only (not `.all`): both corner-hold regions are
/// anchored to the top band in the CURRENT interface orientation (matching
/// `CornerLongPressRecognizer.corner(for:in:)`'s own top-band hit test), so
/// only the top edge's system gestures need to be deferred. Bottom-edge
/// behavior (e.g. the Home indicator) is governed separately by
/// `prefersHomeIndicatorAutoHidden` and is unaffected by this property.
struct ScreenEdgeGestureDeferringView: UIViewControllerRepresentable {
    /// Whether the connected-session top-edge defer should be in effect
    /// right now.
    var isActive: Bool

    func makeUIViewController(context: Context) -> DeferringViewController {
        let controller = DeferringViewController()
        controller.isActive = isActive
        return controller
    }

    func updateUIViewController(_ uiViewController: DeferringViewController, context: Context) {
        uiViewController.isActive = isActive
    }

    /// Zero-size, non-interactive child view controller whose only purpose
    /// is to override `preferredScreenEdgesDeferringSystemGestures`, and be
    /// present in the on-screen SwiftUI content tree so that override is
    /// consulted (see type-level doc comment for the propagation mechanism).
    final class DeferringViewController: UIViewController {
        var isActive: Bool = false {
            didSet {
                guard isActive != oldValue else { return }
                setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            }
        }

        override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
            isActive ? .top : []
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        }
    }
}
