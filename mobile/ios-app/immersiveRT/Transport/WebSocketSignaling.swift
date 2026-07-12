import Foundation

/// Errors surfaced by `WebSocketSignaling`'s `request(_:)` continuations.
enum WebSocketSignalingError: Error, Equatable {
    /// A pending pair/reconnect request was rejected — either by an explicit
    /// `pair-error`/`join-error` server envelope (carrying the server's
    /// `reason` payload field) or by the socket closing (`reason: "ws-closed"`).
    case requestFailed(reason: String)

    /// `request(_:)` was called with an envelope `type` other than `pair`
    /// or `reconnect` (the only two request/response message kinds).
    case unsupportedRequestType(String)
}

/// The WebSocket signaling transport (D-05 fallback-of-last-resort) — a
/// zero-dependency `SignalingTransport` conformance on
/// `URLSessionWebSocketTask` (iOS 13+, no SPM dependency).
///
/// Ported from `client/src/phone.ts`'s `connectPhoneWS`/`sendWsMsg`/
/// `onPhoneWsMessage` (lines 251-313). This transport carries signaling
/// (register/pair/reconnect) AND ongoing communication (offer/answer/ICE,
/// heartbeat, phone-state) per D-04 — it is not scoped to signaling alone.
///
/// The URL host is always injected via `init(host:)` — never derived from
/// `location.hostname` (no native equivalent) and never hardcoded (Pitfall 5).
/// Callers (`TransportManager`, Plan 06) are expected to source `host` from
/// `QRTokenParser.host(from:)`.
final class WebSocketSignaling: SignalingTransport {

    let isWebTransport = false

    /// Persistent client ID (Shared Pattern: generated once, reused across
    /// reconnects). Defaults to a fresh UUID when the caller doesn't supply
    /// one, but callers that manage reconnects should pass the same value
    /// on every re-construction/re-connect.
    let myId: String

    /// Set by the transport manager while a managed reconnect loop is
    /// active. Mirrors `phone.ts`'s `_reconnecting` guard around
    /// `showView('view-ended')` (`ws.onclose`, line 279): when `true`, the
    /// close handler still rejects any in-flight request and reports the
    /// closure reason via `onClosed`'s reason parameter is still meaningful
    /// to callers, but this flag lets the manager suppress a *terminal*
    /// "ended" transition it would otherwise drive off of `onClosed` firing.
    var isReconnecting: Bool = false

    var onServerPush: ((SignalingEnvelope) -> Void)?
    var onClosed: ((String) -> Void)?

    private let host: String
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    private var pairContinuation: CheckedContinuation<SignalingEnvelope, Error>?
    private var reconnectContinuation: CheckedContinuation<SignalingEnvelope, Error>?

    /// Exposed for tests to poll for continuation registration without a
    /// real socket round trip.
    var hasPendingPairRequest: Bool { pairContinuation != nil }
    var hasPendingReconnectRequest: Bool { reconnectContinuation != nil }

    init(host: String, myId: String = UUID().uuidString, session: URLSession = .shared) {
        self.host = host
        self.myId = myId
        self.session = session
    }

    /// `wss://{host}:9090` — host is always the injected/scanned value,
    /// never `location.hostname` (no native equivalent) and never hardcoded.
    var url: URL {
        // Constructed from a caller-supplied host string; well-formed by
        // construction (scheme + host + fixed port), so force-unwrap here
        // is safe and mirrors other transport URL builders in this codebase.
        guard let url = URL(string: "wss://\(host):9090") else {
            preconditionFailure("WebSocketSignaling: failed to construct URL from host \(host)")
        }
        return url
    }

    func connect() async throws {
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        listen()
        try await sendRaw(makeRegisterEnvelope())
    }

    func send(_ envelope: SignalingEnvelope) {
        Task { try? await self.sendRaw(envelope) }
    }

    func request(_ envelope: SignalingEnvelope) async throws -> SignalingEnvelope {
        switch envelope.type {
        case SignalingEnvelope.SignalingType.pair:
            return try await withCheckedThrowingContinuation { continuation in
                self.pairContinuation = continuation
                Task { try? await self.sendRaw(envelope) }
            }
        case SignalingEnvelope.SignalingType.reconnect:
            return try await withCheckedThrowingContinuation { continuation in
                self.reconnectContinuation = continuation
                Task { try? await self.sendRaw(envelope) }
            }
        default:
            throw WebSocketSignalingError.unsupportedRequestType(envelope.type)
        }
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        handleClosure()
    }

    // MARK: - Testable dispatch (no real socket required)

    /// Dispatches a decoded server envelope: resolves/rejects the pending
    /// pair/reconnect continuation on `pair-ack`/`pair-error`/`join-ack`/
    /// `join-error`; everything else routes to `onServerPush`. Mirrors
    /// `onPhoneWsMessage` (`phone.ts` lines 290-313). Exposed (not private)
    /// so tests can drive it with synthetic envelopes.
    func handle(_ envelope: SignalingEnvelope) {
        switch envelope.type {
        case SignalingEnvelope.SignalingType.pairAck:
            resolvePair(.success(envelope))
        case SignalingEnvelope.SignalingType.pairError:
            resolvePair(.failure(.requestFailed(reason: reason(from: envelope, default: "pair-error"))))
        case SignalingEnvelope.SignalingType.joinAck:
            resolveReconnect(.success(envelope))
        case SignalingEnvelope.SignalingType.joinError:
            resolveReconnect(.failure(.requestFailed(reason: reason(from: envelope, default: "join-error"))))
        default:
            onServerPush?(envelope)
        }
    }

    /// Simulates the socket's close/error observation firing: rejects any
    /// in-flight pair/reconnect continuation with `ws-closed` (or the given
    /// reason) and, unless a managed reconnect is in progress, fires
    /// `onClosed`. Exposed (not private) so tests can drive close behavior
    /// without a real socket. Mirrors `ws.onclose` (`phone.ts` lines 271-280).
    func handleClosure(reason: String = "ws-closed") {
        resolvePair(.failure(.requestFailed(reason: reason)))
        resolveReconnect(.failure(.requestFailed(reason: reason)))
        if !isReconnecting {
            onClosed?(reason)
        }
    }

    /// Builds the `register` envelope sent on connect — a separate,
    /// directly-testable function so "myId reused across reconnects" can be
    /// asserted without a real socket (myId is `let`, so every call carries
    /// the identical value by construction).
    func makeRegisterEnvelope() -> SignalingEnvelope {
        SignalingEnvelope(type: SignalingEnvelope.SignalingType.register, from: myId, to: "", payload: [:])
    }

    // MARK: - Private helpers

    private func resolvePair(_ result: Result<SignalingEnvelope, WebSocketSignalingError>) {
        guard let continuation = pairContinuation else { return }
        pairContinuation = nil
        switch result {
        case .success(let envelope): continuation.resume(returning: envelope)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    private func resolveReconnect(_ result: Result<SignalingEnvelope, WebSocketSignalingError>) {
        guard let continuation = reconnectContinuation else { return }
        reconnectContinuation = nil
        switch result {
        case .success(let envelope): continuation.resume(returning: envelope)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    private func reason(from envelope: SignalingEnvelope, default defaultReason: String) -> String {
        (envelope.payload["reason"]?.value as? String) ?? defaultReason
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.handleClosure()
            case .success(let message):
                if let envelope = self.decode(message) {
                    self.handle(envelope)
                }
                self.listen()
            }
        }
    }

    private func decode(_ message: URLSessionWebSocketTask.Message) -> SignalingEnvelope? {
        let data: Data?
        switch message {
        case .string(let text):
            data = text.data(using: .utf8)
        case .data(let raw):
            data = raw
        @unknown default:
            data = nil
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(SignalingEnvelope.self, from: data)
    }

    private func sendRaw(_ envelope: SignalingEnvelope) async throws {
        let data = try JSONEncoder().encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await task?.send(.string(text))
    }
}
