import Combine
import SwiftUI
import UIKit

/// SwiftUI-observable wrapper around `TransportManager` — the connective
/// tissue between the imperative connect/pair/fan-out orchestrator (Plan 07)
/// and `ActiveSessionView`'s rendering, per PATTERNS.md's "ContentView.swift
/// / new ActiveSessionView.swift" entry.
///
/// `TransportManager` exposes plain (non-`@Published`) properties updated
/// synchronously on the main actor; this view-model polls them on a
/// throttled `Timer` (Pitfall 3: "only hop to @MainActor for UI-visible
/// state... at a throttled rate — not per-packet") rather than wiring a
/// callback into the 60Hz CoreMotion/WebRTC send path, translating each
/// snapshot into a `SessionState.Event` fed through the pure
/// `SessionState.reduce(state:event:)` (Task 1).
@MainActor
final class SessionViewModel: ObservableObject {
    @Published private(set) var sessionState: SessionState = .connecting

    /// Presented via `dynamicIslandToast` (D-15) for D-09 (start-blocked)
    /// and D-08 (tracking-limited) local feedback — `currentToast`'s value
    /// is only meaningful while `isToastPresented` is `true`; it defaults to
    /// a harmless placeholder otherwise (mirrors `ContentView`'s existing
    /// `dynamicIslandToast(isPresented:duration:value:)` usage pattern).
    @Published private(set) var currentToast: Toast = .arUnavailable
    @Published var isToastPresented = false

    var roomCode: String? { transportManager.roomCode }
    var username: String? { transportManager.myUsername }

    /// D-13 branch: `true` while `transportManager` has an active or
    /// in-progress session — the overlay menu's Disconnect/Back button
    /// reads this to decide between `disconnect()` and `onExit` (Plan 08).
    var isConnected: Bool { transportManager.isConnected }

    private let transportManager: TransportManager
    private var pollTimer: Timer?

    /// Throttled poll interval for UI-visible state — deliberately coarse
    /// (well below the 60Hz sensor rate) per Pitfall 3.
    private let pollInterval: TimeInterval = 0.25

    // `TransportManager()` is intentionally NOT a default-parameter-value
    // expression — default argument expressions are type-checked in a
    // nonisolated context regardless of the module's
    // `-default-isolation=MainActor` build setting, so calling a MainActor
    // initializer there only warns today but is fragile; constructing it in
    // the init body instead sidesteps the whole class of issue (matches the
    // fix applied to `ContentView.init`).
    init(transportManager: TransportManager? = nil) {
        self.transportManager = transportManager ?? TransportManager()
        self.transportManager.trackingLimitedMessageHandler = { [weak self] message in
            self?.handleTrackingLimitedMessage(message)
        }
    }

    /// Kicks off the connect → pair → fan-out flow (`TransportManager.start`)
    /// and starts the throttled UI poll — called from `ContentView` on a
    /// successful QR scan. D-09 gate: `ARPoseSource.checkARStartupPreconditions()`
    /// runs FIRST — if ARKit is unsupported or camera access is denied, the
    /// session is hard-blocked (`presentStartupError(_:)`) and NEITHER
    /// `startPolling()` NOR `transportManager.start(...)` is ever reached.
    /// This is a hard block, never a silent CoreMotion-style degrade
    /// (consistent with D-18's no-silent-degrade rule) — there is no
    /// CoreMotion fallback path in this app at all (ARKit superseded it
    /// entirely, per `ARPoseSource`'s own doc comment).
    ///
    /// BUG FIX (on-device: after Disconnect/Back → Home → starting a NEW
    /// session, the stale "Session Ended" text from the PREVIOUS session
    /// briefly/indefinitely reappeared): `SessionViewModel` is a single
    /// app-lifetime-shared instance (`immersiveRTApp` owns it, required for
    /// scenePhase handling) — `sessionState` is a `@Published` property
    /// initialized ONCE at construction, so it is never implicitly reset
    /// between sessions. `pollTransportState()`'s `.connecting`/`.idle`
    /// case is deliberately a no-op ("nothing to reduce yet — stays at the
    /// default `.connecting`"), an assumption that only holds if
    /// `sessionState` actually STARTS at `.connecting` for this session —
    /// which is false for every session after the first, since a prior
    /// session's terminal `.ended`/`.error` value otherwise survives
    /// untouched until some future pairAck/pairError/channelOpen event
    /// happens to overwrite it. Reset explicitly to a clean slate here,
    /// before either the D-09 precondition check or `startPolling()`, so
    /// every new session always begins from `.connecting` (matching this
    /// property's own declared default) rather than whatever the previous
    /// session left behind. `isToastPresented` is reset for the same
    /// reason (a stale D-08/D-09 toast from the last session must not
    /// carry over either).
    func start(token: String, host: String) {
        sessionState = .connecting
        isToastPresented = false
        Task {
            if let startupError = await ARPoseSource.checkARStartupPreconditions() {
                presentStartupError(startupError)
                return
            }
            startPolling()
            await transportManager.start(token: token, host: host)
        }
    }

    /// D-09: hard-blocks session start by transitioning `sessionState` to
    /// `.error` (reuses the existing `.pairError` reduction so the red error
    /// text + `pair-error-body` accessibility identifier already wired in
    /// `ActiveSessionView` work unchanged) AND separately presents the
    /// matching `Toast.arUnavailable`/`Toast.cameraPermissionDenied` (D-15).
    private func presentStartupError(_ error: ARStartupError) {
        let message: String
        switch error {
        case .deviceUnsupported:
            currentToast = .arUnavailable
            message = "This device does not support ARKit world tracking."
        case .cameraDenied, .cameraRestricted:
            currentToast = .cameraPermissionDenied
            message = "Camera access is required for motion tracking."
        }
        isToastPresented = true
        sessionState = SessionState.reduce(state: sessionState, event: .pairError(message))
    }

    /// D-08: presents `Toast.trackingLimited(_:)` for the current
    /// `.limited(reason:)` sub-reason, or dismisses it once tracking
    /// recovers (`message == nil`). Called only when `ARPoseSource`'s
    /// tracking-limited message CHANGES (via `TransportManager`'s forward of
    /// `ARPoseSource.onTrackingLimitedMessageChanged`), never once per ARKit
    /// frame — the wire `driftConfidence` is unaffected (stays flat 0.5 for
    /// any `.limited` reason, per `ARPoseConversion.swift`'s `driftConfidence(for:)`).
    private func handleTrackingLimitedMessage(_ message: String?) {
        guard let message else {
            isToastPresented = false
            return
        }
        currentToast = .trackingLimited(message)
        isToastPresented = true
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.pollTransportState()
            }
        }
    }

    /// One throttled snapshot: reads `TransportManager`'s current
    /// `ConnectionState` + channel counts, translates it into the matching
    /// `SessionState.Event`, and folds it through `reduce(state:event:)`.
    private func pollTransportState() {
        let wasStreaming = isStreaming(sessionState)
        let open = transportManager.openChannelCount
        let total = transportManager.peerIds.count

        switch transportManager.state {
        case .idle, .connecting:
            break // Nothing to reduce yet — stays at the default .connecting.
        case .paired:
            let event: SessionState.Event = open > 0
                ? .channelOpen(open: open, total: total)
                : .pairAck
            sessionState = SessionState.reduce(state: sessionState, event: event)
        case .reconnecting:
            sessionState = SessionState.reduce(state: sessionState, event: .transportClosed)
        case .ended:
            sessionState = SessionState.reduce(state: sessionState, event: .terminal)
            stopPolling()
        case .error(let message):
            sessionState = SessionState.reduce(state: sessionState, event: .pairError(message))
            stopPolling()
        }

        // Entering the active streaming state (PHONE-07) — mirrors
        // phone.ts's requestWakeLock() call sites. Only fires on the
        // paired/connecting -> paired/active transition, not every tick;
        // reset-on-background is driven separately by
        // handleScenePhaseChange(_:) below (Pitfall 4).
        if isStreaming(sessionState), !wasStreaming {
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Forwards continuous touch state to `TransportManager` (Plan 04,
    /// SENS-06, D-03) — called directly from `ActiveSessionView`'s
    /// full-screen `DragGesture`, mirroring the "direct call for control
    /// actions" half of the "throttled poll for UI, direct call for control
    /// actions" split documented on `start(token:host:)` above. Never routed
    /// through `pollTransportState()`'s throttled timer — touch must update
    /// as fast as the gesture fires, not at the 0.25s UI-poll cadence.
    func updateTouchState(active: Bool, x: Double, y: Double) {
        transportManager.updateTouchState(active: active, x: x, y: y)
    }

    /// D-11 (manual recenter), invoked by the Plan 08 overlay-menu Recenter
    /// button: delegates to `transportManager.recenter()` and briefly
    /// confirms via `Toast.recentered` (purely local UX; no wire effect).
    func recenter() {
        transportManager.recenter()
        currentToast = .recentered
        isToastPresented = true
    }

    /// D-13 (connected case), invoked by the Plan 08 overlay-menu
    /// Disconnect button — only meaningful while `isConnected`; the view
    /// is expected to branch to `onExit` instead when `isConnected` is
    /// `false` (already disconnected/errored).
    func disconnect() {
        transportManager.disconnect()
    }

    /// "Streaming" mirrors `TransportManager.registered` — the CoreMotion
    /// loop + heartbeat are already running once paired (not gated on a
    /// data channel being open), so the Wake Lock equivalent should be too.
    private func isStreaming(_ state: SessionState) -> Bool {
        switch state {
        case .paired, .active: return true
        case .connecting, .reconnecting, .error, .ended: return false
        }
    }

    // MARK: - Wake Lock equivalent + scenePhase lifecycle (Task 3, PHONE-07, Pitfall 4)

    /// Explicitly resets `isIdleTimerDisabled` on backgrounding — unlike the
    /// web Wake Lock API's auto-release, iOS persists the flag until reset
    /// (Pitfall 4) — and stops/resumes CoreMotion + the heartbeat via
    /// `TransportManager` to avoid draining battery while backgrounded,
    /// mirroring the intent of `phone.ts`'s `visibilitychange` handler
    /// (lines 1214-1231) even though the underlying API shape differs.
    /// Driven by `immersiveRTApp`'s `.onChange(of: scenePhase)`.
    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if isStreaming(sessionState) {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            transportManager.resumeFromBackground()
        case .inactive, .background:
            UIApplication.shared.isIdleTimerDisabled = false
            transportManager.pauseForBackground()
        @unknown default:
            break
        }
    }

    deinit {
        pollTimer?.invalidate()
    }
}

/// Replaces the placeholder `TokenDetailsView` (CONTEXT: UI treatment is
/// discretionary beyond proving the connection works). Renders the minimum
/// PATTERNS.md calls for: connection status text, open/total channel count
/// (mirrors `chan-open`/`chan-total`), room code/username, and a pairing-
/// error message region that surfaces the TLS-trust-specific message from
/// Pitfall 2 verbatim when the WS fallback also fails.
struct ActiveSessionView: View {
    @ObservedObject var viewModel: SessionViewModel

    /// D-13 (disconnected case): navigates back to the initial `HomeView`
    /// screen — called from the overlay menu's Disconnect/Back button when
    /// `viewModel.isConnected` is `false` (already disconnected/errored).
    /// Supplied by `ContentView`, which resets `hasStartedSession`.
    var onExit: () -> Void

    /// Drives the local visual feedback overlay (D-06) — `true` for the
    /// full duration a finger is down anywhere on the view, `false` the
    /// instant it lifts. Kept as plain `@State` (not routed through
    /// `viewModel`) since it is purely a rendering concern local to this
    /// view; the wire-bound touch state lives in `TransportManager` via
    /// `viewModel.updateTouchState(active:x:y:)`.
    @State private var touchActive = false
    @State private var touchLocation: CGPoint = .zero

    /// D-12: the ONLY thing that ever sets this to `true` is
    /// `CornerLongPressOverlay.onReveal` firing (the hidden 2-finger
    /// both-top-corners hold, Plan 07) — there is no always-visible
    /// Recenter/Disconnect affordance anywhere else in this view, by
    /// design, so the controls stay hard to trigger accidentally.
    @State private var isMenuRevealed = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Full-screen raw UIKit touch capture (D-04) — see
                // `TouchCaptureView`'s doc comment for why this replaced a
                // SwiftUI `DragGesture` (on-device bug: touch signal could
                // get stuck "active" after a rapid double-tap). Placed as
                // the bottom-most ZStack layer so it observes touches
                // everywhere on screen while `overlayMenu`'s real SwiftUI
                // Buttons (added later/higher in this ZStack) still win
                // hit-testing over it when tapped, exactly as they did over
                // the previous `.gesture(DragGesture(...))` attached to
                // this same outer container.
                TouchCaptureView { active, location in
                    touchActive = active
                    if active {
                        touchLocation = location
                    }
                    let normalized = normalizedTouch(location: location, in: geometry.frame(in: .local))
                    viewModel.updateTouchState(active: active, x: normalized.x, y: normalized.y)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)

                // Bug fix: lets touches at the true physical top corners
                // (where iOS reserves a Control Center/Notification Center
                // system-gesture band) reach `CornerLongPressRecognizer`
                // instead of being intercepted by the system first. See
                // `ScreenEdgeGestureDeferringView`'s doc comment for the
                // full mechanism/verification.
                ScreenEdgeGestureDeferringView()
                    .frame(width: 0, height: 0)

                VStack(spacing: 20) {
                    Spacer()

                    Image(systemName: statusSymbol)
                        .font(.system(size: 56))
                        .foregroundColor(statusColor)

                    Text(statusText)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    if let roomCode = viewModel.roomCode {
                        VStack(spacing: 4) {
                            Text("Room \(roomCode)")
                                .font(.headline)
                            if let username = viewModel.username {
                                Text(username)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    if case .active(let channels) = viewModel.sessionState {
                        Text("\(channels.openChannels)/\(channels.totalPeers) connected")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }

                    if case .error(let message) = viewModel.sessionState {
                        Text(message)
                            .font(.callout)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .accessibilityIdentifier("pair-error-body")
                    }

                    Spacer()
                }
                .padding()

                // Local visual feedback (D-06) — a small dot at the current
                // touch point, shown only while a finger is down. Ignores
                // hit testing so it never intercepts `TouchCaptureView`.
                if touchActive {
                    Circle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 44, height: 44)
                        .position(touchLocation)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("touch-feedback-indicator")
                }

                // D-12: hidden reveal — a ZStack SIBLING of the full-screen
                // touch-capture surface above, attaching its recognizer to
                // the enclosing UIWindow (Plan 07) so it observes every
                // touch without ever winning hit-testing over
                // `TouchCaptureView`. `isMenuRevealed` is the ONLY state
                // this sets; nothing else in this view ever surfaces the menu.
                CornerLongPressOverlay(onReveal: { isMenuRevealed = true })

                // D-11/D-12/D-13: the hidden overlay menu itself — only
                // ever mounted while `isMenuRevealed` is true (toggled
                // exclusively by the reveal gesture above), so there is no
                // always-visible Recenter/Disconnect affordance (D-12).
                if isMenuRevealed {
                    overlayMenu
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            // D-09 (start-blocked) / D-08 (tracking-limited) local feedback,
            // all routed through the existing DynamicToast component (D-15).
            // No auto-dismiss duration (unlike ContentView's `.invalidQRCode`
            // usage): D-08 dismissal is driven explicitly by
            // `handleTrackingLimitedMessage(_:)` on recovery, and a D-09
            // block should stay visible (swipe-to-dismiss, per `ToastView`'s
            // existing drag gesture) rather than silently vanish after a
            // fixed timeout while the session remains blocked.
            .dynamicIslandToast(isPresented: $viewModel.isToastPresented, value: viewModel.currentToast)
        }
    }

    private var statusText: String {
        switch viewModel.sessionState {
        case .connecting: return "Connecting…"
        case .paired: return "Paired — waiting for channels"
        case .active: return "Streaming"
        case .reconnecting: return "Reconnecting…"
        case .error: return "Connection Error"
        case .ended: return "Session Ended"
        }
    }

    private var statusColor: Color {
        switch viewModel.sessionState {
        case .active: return .green
        case .paired, .connecting: return .blue
        case .reconnecting: return .orange
        case .error, .ended: return .red
        }
    }

    private var statusSymbol: String {
        switch viewModel.sessionState {
        case .active: return "checkmark.circle.fill"
        case .paired, .connecting: return "antenna.radiowaves.left.and.right"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        case .ended: return "xmark.circle.fill"
        }
    }

    // MARK: - Hidden overlay menu (D-11/D-12/D-13, Plan 08)

    /// The reveal-gated menu card: Recenter (D-11) + Disconnect/Back (D-13).
    /// Includes a nearly-transparent tap-outside-dismiss background layer
    /// UNDER the card so tapping away from the card dismisses it, plus an
    /// explicit "Close" affordance (per this plan's action: "the menu is
    /// dismissable (tap-outside or an explicit close)"). Neither dismiss
    /// path is the reveal gesture itself — D-12 only governs how the menu
    /// APPEARS, not how it is dismissed.
    private var overlayMenu: some View {
        ZStack {
            // Effectively invisible but still hit-testable (a fully
            // `.clear` SwiftUI `Color` does not receive taps) — tapping
            // anywhere outside the card dismisses the menu.
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { isMenuRevealed = false }

            VStack(spacing: 16) {
                Button {
                    viewModel.recenter()
                    isMenuRevealed = false
                } label: {
                    Label("Recenter", systemImage: "location.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("overlay-menu-recenter")

                Button {
                    if viewModel.isConnected {
                        viewModel.disconnect()
                    } else {
                        onExit()
                    }
                    isMenuRevealed = false
                } label: {
                    Label(
                        viewModel.isConnected ? "Disconnect" : "Back",
                        systemImage: viewModel.isConnected ? "xmark.circle" : "chevron.left"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityIdentifier("overlay-menu-disconnect-or-back")

                Button("Close") { isMenuRevealed = false }
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 260)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("hidden-overlay-menu")
        }
    }
}
