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

    var roomCode: String? { transportManager.roomCode }
    var username: String? { transportManager.myUsername }

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
    }

    /// Kicks off the connect → pair → fan-out flow (`TransportManager.start`)
    /// and starts the throttled UI poll — called from `ContentView` on a
    /// successful QR scan.
    func start(token: String, host: String) {
        startPolling()
        Task {
            await transportManager.start(token: token, host: host)
        }
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

    var body: some View {
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
}
