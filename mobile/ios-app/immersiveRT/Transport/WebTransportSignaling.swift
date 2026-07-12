import Foundation
import Network

/// WebTransport-over-HTTP/3 signaling transport — the D-05 time-boxed spike.
///
/// TIME-BOX (D-05): this class gets exactly ONE implementation cycle (this
/// plan, 06.2-05) plus ONE on-device debug session (06.2-09's WebTransport
/// checkpoint). Success there = open a QUIC/h3 connection, complete the
/// extended-CONNECT handshake, open a bidirectional stream, and round-trip
/// (or at minimum successfully send) a `register` envelope against the
/// running dev server. If that is not demonstrated within that on-device
/// session, WebSocket-only (`WebSocketSignaling`, Plan 04) becomes the
/// working transport path for Phase 06.2 and this spike's findings are
/// documented for a future revisit — per D-04/D-05 that must be the OUTCOME
/// of this documented spike, never a shortcut taken upfront. Because
/// `TransportManager` (Plan 07) already tries WT first then falls back to
/// WS at runtime, a failed spike requires NO code restructure: `connect()`
/// simply throws a `wt-net`-reason error and the manager degrades safely.
///
/// This is genuinely greenfield low-level protocol work (PATTERNS.md
/// "No Analog Found" — no first-party or mature third-party native Swift
/// WebTransport client exists as of RESEARCH.md's research date, A4). It
/// hand-rolls the RFC 9220 WebTransport-over-HTTP/3 handshake on top of
/// Apple's `Network.framework` declarative `NetworkConnection<QUIC>` API
/// (iOS 26+, WWDC25 session 250), using the pure framing helpers from
/// `Http3Framing.swift` (Task 1). No third-party WebTransport/QUIC SPM
/// dependency is used — RESEARCH.md's Package Legitimacy Audit flags
/// `Quiver`/`swift-quic`/`kixelated/web-transport` as SUS; none are
/// referenced here.
final class WebTransportSignaling: SignalingTransport {
    let isWebTransport = true

    var onServerPush: ((SignalingEnvelope) -> Void)?
    var onClosed: ((String) -> Void)?

    /// This client's self-generated identity, sent as `from` on every
    /// envelope — mirrors `phone.ts`'s `myId = crypto.randomUUID()`
    /// (generated once, reused for this object's lifetime). A future
    /// `TransportManager` (Plan 07) that needs the SAME id shared across a
    /// WT/WS fallback pair can inject one explicitly via `init(myId:)`
    /// rather than accepting a freshly generated one.
    let myId: String

    private let host: String
    private let port: UInt16
    private var connection: NetworkConnection<QUIC>?
    private var connectStream: QUIC.Stream<QUICStream>?
    private var webTransportSessionID: UInt64?

    /// QPACK static-table index 25 — `:status: 200` — encoded as an Indexed
    /// Field Line (RFC 9204 §4.5.2): `0xC0 | 25 = 0xD9`. Used as a
    /// best-effort success heuristic for the extended-CONNECT response; see
    /// `performExtendedConnect`'s doc comment for why a full QPACK response
    /// decoder is deliberately out of scope for this spike.
    private static let qpackIndexedStatus200: UInt8 = 0xD9

    init(host: String, port: UInt16 = 4433, myId: String = UUID().uuidString) {
        self.host = host
        self.port = port
        self.myId = myId
    }

    // MARK: - SignalingTransport

    func connect() async throws {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port)
        )
        let conn = NetworkConnection(to: endpoint) { QUIC(alpn: ["h3"]) }
        connection = conn

        do {
            try await waitUntilReady(conn)
            try await openControlStream(conn)
            try await performExtendedConnect(conn)

            // Mirrors phone.ts's startPhoneClient(): the push listener is
            // started BEFORE the register send so no early server push is
            // dropped while the register round trip is still in flight.
            startInboundStreamListener(conn)
            _ = try await sendAndDrain(
                SignalingEnvelope(type: SignalingEnvelope.SignalingType.register, from: myId, to: "", payload: [:])
            )
        } catch {
            connection = nil
            connectStream = nil
            throw WebTransportSignalingError.wtNet(error)
        }
    }

    func send(_ envelope: SignalingEnvelope) {
        Task { [weak self] in
            _ = try? await self?.sendAndDrain(envelope)
        }
    }

    func request(_ envelope: SignalingEnvelope) async throws -> SignalingEnvelope {
        let buffer = try await sendAndDrain(envelope)
        return try JSONDecoder().decode(SignalingEnvelope.self, from: buffer)
    }

    func close() {
        connectStream = nil
        connection = nil
        // `NetworkConnection`'s declarative API (iOS 26+) exposes no
        // explicit `cancel()`/`close()` in this SDK snapshot — unlike the
        // classic `NWConnection`, which does. Connection teardown happens
        // via ARC when the last strong reference is released.
    }

    // MARK: - Handshake (RESEARCH.md "Architecture Patterns → Pattern 1")

    /// Starts the connection and polls `state` until `.ready`, `.failed`,
    /// `.cancelled`, or `timeoutSeconds` elapses. Polling (rather than
    /// `onStateUpdate`'s `@isolated(any) @Sendable` callback) keeps this
    /// spike's concurrency story simple — no cross-actor mutable-state
    /// capture to reason about — at the cost of up to one poll interval of
    /// added latency, acceptable for a connect-time handshake.
    private func waitUntilReady(_ conn: NetworkConnection<QUIC>, timeoutSeconds: Double = 5.0) async throws {
        _ = conn.start() // returns Self (chainable); no further chaining needed here
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            switch conn.state {
            case .ready:
                return
            case .failed(let error):
                throw error
            case .cancelled:
                throw WebTransportSignalingError.wtNet(nil)
            default:
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms poll interval
            }
        }
        throw WebTransportSignalingError.wtNet(nil)
    }

    /// Opens the HTTP/3 client control stream and sends a minimal/empty
    /// SETTINGS frame (RESEARCH.md Pattern 1, step 2) — required before the
    /// server will accept any request stream. The control-stream type
    /// varint (`0x00`, RFC 9114 §6.2.1) is distinct from the WT
    /// stream-type prefix (RFC 9220) used later for session-associated
    /// streams, so it is encoded here directly via the shared
    /// `encodeVarint` primitive rather than a dedicated Http3Framing
    /// helper.
    private func openControlStream(_ conn: NetworkConnection<QUIC>) async throws {
        let controlStream = try await conn.openStream(directionality: .unidirectional)
        var payload = Http3Framing.encodeVarint(0x00) // HTTP/3 control stream type (RFC 9114 §6.2.1)
        payload.append(contentsOf: Http3Framing.settingsFrame())
        try await controlStream.send(Data(payload), endOfStream: false)
    }

    /// Opens the bidirectional "CONNECT stream" and sends the extended-CONNECT
    /// request (RESEARCH.md Pattern 1, steps 3-4). On success, this stream's
    /// ID becomes the WebTransport session ID (RFC 9220) that every
    /// subsequent WT-prefixed stream must carry.
    ///
    /// Response parsing here is a deliberately minimal heuristic, not a full
    /// QPACK decoder: `Http3Framing.swift` (Task 1) only implements the
    /// ENCODE side of QPACK — decoding was not in that task's helper list.
    /// A spec-complete response parser is exactly the kind of thing the
    /// Plan 09 on-device session should validate and, if needed, replace —
    /// this spike's job is to prove the shape of the approach, not ship a
    /// production-grade HTTP/3 client (RESEARCH.md A5).
    private func performExtendedConnect(_ conn: NetworkConnection<QUIC>) async throws {
        let stream = try await conn.openStream(directionality: .bidirectional)
        let headerBlock = Http3Framing.extendedConnectHeaders(authority: "\(host):\(port)", path: "/")
        var frame = Http3Framing.encodeVarint(0x01) // HTTP/3 HEADERS frame type (RFC 9114 §7.2.2)
        frame.append(contentsOf: Http3Framing.encodeVarint(UInt64(headerBlock.count)))
        frame.append(contentsOf: headerBlock)
        try await stream.send(Data(frame), endOfStream: false)

        let response = try await stream.receive(atLeast: 1, atMost: 4096)
        guard response.content.contains(Self.qpackIndexedStatus200) else {
            throw WebTransportSignalingError.wtNet(nil)
        }

        connectStream = stream
        webTransportSessionID = stream.streamID
    }

    // MARK: - Request/send (RESEARCH.md Pattern 1 — sendWtRequest/sendWtMessage)

    /// Opens a new WT-prefixed bidirectional stream, writes `envelope` as
    /// JSON, half-closes the write side, and drains the readable side to
    /// EOF — mirrors `sendWtRequest`/`sendWtMessage` in `client/src/phone.ts`
    /// (both share this exact shape; only the caller decides whether to
    /// parse the drained bytes as a response, via `request(_:)`, or discard
    /// them, via `send(_:)`).
    private func sendAndDrain(_ envelope: SignalingEnvelope) async throws -> Data {
        guard let conn = connection, let sessionID = webTransportSessionID else {
            throw WebTransportSignalingError.wtNet(nil)
        }
        let stream = try await conn.openStream(directionality: .bidirectional)
        var payload = Http3Framing.wtStreamTypePrefix(bidi: true)
        payload.append(contentsOf: Http3Framing.encodeVarint(sessionID))
        payload.append(contentsOf: try JSONEncoder().encode(envelope))
        try await stream.send(Data(payload), endOfStream: true)

        var buffer = Data()
        while true {
            let chunk = try await stream.receive(atLeast: 1, atMost: 4096)
            buffer.append(chunk.content)
            if chunk.metadata.endOfStream { break }
        }
        return buffer
    }

    // MARK: - Server push (RESEARCH.md Pattern 1 — listenForServerPushes/processWtPush)

    /// Pull-based reader loop over every inbound bidirectional stream on
    /// this connection — mirrors `phone.ts`'s `listenForServerPushes`
    /// comment: a `.getReader()`-style pull loop, not an async-iterator
    /// (that comment's specific browser-compat reason doesn't apply to
    /// native Swift, but the underlying pull-based-reader SHAPE is still
    /// the correct structural analog for `inboundStreams`).
    private func startInboundStreamListener(_ conn: NetworkConnection<QUIC>) {
        Task { [weak self] in
            do {
                try await conn.inboundStreams { stream in
                    await self?.drainPushStream(stream)
                }
            } catch {
                self?.onClosed?("wt-net")
            }
        }
    }

    private func drainPushStream(_ stream: QUIC.Stream<QUICStream>) async {
        do {
            var buffer = Data()
            while true {
                let chunk = try await stream.receive(atLeast: 1, atMost: 4096)
                buffer.append(chunk.content)
                if chunk.metadata.endOfStream { break }
            }
            let payload = try Self.stripWtStreamPrefix(from: buffer)
            if let envelope = try? JSONDecoder().decode(SignalingEnvelope.self, from: payload) {
                onServerPush?(envelope)
            }
        } catch {
            // A single malformed/short-lived push stream must not tear down
            // the whole connection — mirrors phone.ts's push-parse-err
            // handling (processWtPush's catch block logs and returns, it
            // does not propagate).
        }
    }

    /// Strips the RFC 9220 §4.2 WEBTRANSPORT_STREAM frame-type varint +
    /// session-ID varint from the front of an inbound bidirectional
    /// stream's bytes, returning the remaining JSON envelope payload.
    private static func stripWtStreamPrefix(from data: Data) throws -> Data {
        let bytes = Array(data)
        guard let (frameType, typeLen) = Http3Framing.decodeVarint(bytes), frameType == 0x41 else {
            throw WebTransportSignalingError.wtNet(nil)
        }
        let remaining = Array(bytes[typeLen...])
        guard let (_, sessionIDLen) = Http3Framing.decodeVarint(remaining) else {
            throw WebTransportSignalingError.wtNet(nil)
        }
        return Data(remaining[sessionIDLen...])
    }
}

/// Network/handshake failure for `WebTransportSignaling`. Always surfaces
/// as a `'wt-net'`-reason failure (matching `phone.ts`'s retryable-error
/// classification: `slot_not_held` / `ws-closed` / `wt-net` are the only
/// three reasons `TransportManager`, Plan 07, will treat as retryable). A
/// failed spike is a safe, visible degradation: the caller catches this,
/// `TransportManager` falls back to `WebSocketSignaling` (Plan 04) — no
/// crash, no code restructure required elsewhere (D-05).
enum WebTransportSignalingError: Error {
    case wtNet(Error?)
}
