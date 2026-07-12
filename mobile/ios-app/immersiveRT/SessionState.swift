import Foundation

/// Enum-driven session state mirroring the web client's named views
/// (`view-connecting` / `view-active` / `view-error-pair` / `view-ended` —
/// PATTERNS.md "ContentView.swift / new ActiveSessionView.swift", analog of
/// `client/src/phone.ts`'s `showView()` (lines 87-100),
/// `showReconnecting()`/`showReconnected()` (lines 493-505), and
/// `updateConnectingUI()` (lines 715-728)).
///
/// Pure `Foundation`-only enum + reducer — deliberately no `SwiftUI`
/// import — so it is unit-testable without a simulator/UI host
/// (`swiftc -typecheck` sandbox pre-check, Task 1 acceptance criteria).
/// `SessionViewModel` (Task 2, `ActiveSessionView.swift`) is the only
/// consumer that wires `TransportManager` events into this reducer.
enum SessionState: Equatable {
    case connecting
    case paired
    case reconnecting
    case active(ActiveChannels)
    case error(String)
    case ended

    /// Open-channel / total-peer counts shown while `.active` — mirrors the
    /// `chan-open`/`chan-total`/`active-channels` DOM elements driven by
    /// `updateConnectingUI()` (phone.ts lines 715-728).
    struct ActiveChannels: Equatable {
        var openChannels: Int
        var totalPeers: Int
    }
}

extension SessionState {
    /// Events driving `reduce(state:event:)`, sourced from `TransportManager`
    /// callbacks/polling (Task 2) — named after the transitions documented
    /// in PATTERNS.md's `ContentView.swift`/`ActiveSessionView.swift` entry.
    enum Event: Equatable {
        /// Server ack'd pairing (`pair-ack`) — `.connecting → .paired`.
        case pairAck
        /// A pairing attempt failed server-side (`pair-error`), or the
        /// initial connect failed outright (e.g. TLS trust, Pitfall 2) —
        /// `→ .error(message)`.
        case pairError(String)
        /// A data channel opened (first one, or any open-count change while
        /// paired/active) — carries the current open/total counts, mirrors
        /// `updateConnectingUI()`'s `chan-open` update.
        case channelOpen(open: Int, total: Int)
        /// A data channel closed (open-count decreased while remaining
        /// paired/active) — same shape as `.channelOpen`, kept distinct for
        /// call-site clarity even though the resulting state is identical.
        case channelClose(open: Int, total: Int)
        /// The active transport dropped and `attemptReconnect()` took over
        /// (mirrors `showReconnecting()`, phone.ts lines 493-497) —
        /// `→ .reconnecting`.
        case transportClosed
        /// Reconnect succeeded (`join-ack`) — mirrors `showReconnected()`
        /// (phone.ts lines 502-505) — `→ .paired`.
        case reconnected
        /// Terminal: no reconnect token, or reconnect attempts exhausted
        /// (`showView('view-ended')`) — `→ .ended`.
        case terminal
    }

    /// Pure state-transition function mirroring the web client's `showView`
    /// dispatch: `pair-ack` moves `.connecting → .paired`; a first-open-
    /// channel event moves `→ .active` (carrying open/total counts); a
    /// transport-close event moves `→ .reconnecting`; a terminal reason
    /// moves `→ .ended`; a pair-error moves `→ .error(message)`.
    ///
    /// Deliberately ignores the incoming `state` for most transitions
    /// (each event fully determines the next state on its own) — `state` is
    /// threaded through only so future transitions could depend on it, and
    /// so call sites always express "apply this event to the current
    /// state," matching a conventional reducer signature.
    static func reduce(state: SessionState, event: Event) -> SessionState {
        switch event {
        case .pairAck:
            return .paired
        case .pairError(let message):
            return .error(message)
        case .channelOpen(let open, let total), .channelClose(let open, let total):
            return .active(ActiveChannels(openChannels: open, totalPeers: total))
        case .transportClosed:
            return .reconnecting
        case .reconnected:
            return .paired
        case .terminal:
            return .ended
        }
    }
}
