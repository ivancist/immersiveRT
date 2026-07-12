import Foundation
import Network

/// WebTransport-over-HTTP/3 signaling transport — originated as the D-05
/// time-boxed spike, now a working transport confirmed end-to-end on-device
/// (06.2-09): connect, extended-CONNECT, register, pair, WebRTC
/// offer/answer/ICE relay, and heartbeat all round-trip successfully over
/// native QUIC/h3, with no WebSocket fallback needed. Three bugs found and
/// fixed during that session (control stream not retained past connect,
/// ack/error envelopes missing from/to failing to decode, and the
/// extended-CONNECT success check only recognizing one of two valid QPACK
/// encodings of `:status: 200`) — see the fix commits and
/// `06.2-SPIKE-FINDINGS.md` for detail. `TransportManager` (Plan 07) still
/// tries WT first and falls back to WS on any failure, so this remains a
/// safe degrade path, not a hard dependency.
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

    /// Held for the connection's entire lifetime — RFC 9114 §6.2.1 requires
    /// the HTTP/3 control stream to remain open until the connection ends;
    /// closing it at any point is a connection error the spec names
    /// `H3_CLOSED_CRITICAL_STREAM`. Previously `openControlStream(_:)` only
    /// held this in a local variable, so ARC released (and the underlying
    /// `Network.framework` stream tore down) the instant that function
    /// returned — the server then correctly observed the control stream
    /// close and aborted with `ClosedCriticalStreamError`. Found during
    /// 06.2-09 on-device verification (server-side error was 100%
    /// reproducible across every WT attempt).
    private var controlStream: QUIC.Stream<QUICStream>?
    private var healthMonitorTask: Task<Void, Never>?

    /// QPACK static-table index 25 — `:status: 200` — encoded as an Indexed
    /// Field Line (RFC 9204 §4.5.2): `0xC0 | 25 = 0xD9`. One of two response
    /// encodings `responseIndicatesStatus200(_:)` recognizes; see that
    /// function's doc comment for the other (the one the real server
    /// actually uses).
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
            startConnectionHealthMonitor(conn)
            _ = try await sendAndDrain(
                SignalingEnvelope(type: SignalingEnvelope.SignalingType.register, from: myId, to: "", payload: [:])
            )
        } catch {
            healthMonitorTask?.cancel()
            healthMonitorTask = nil
            connection = nil
            connectStream = nil
            controlStream = nil
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
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        connectStream = nil
        controlStream = nil
        connection = nil
        // `NetworkConnection`'s declarative API (iOS 26+) exposes no
        // explicit `cancel()`/`close()` in this SDK snapshot — unlike the
        // classic `NWConnection`, which does. Connection teardown happens
        // via ARC when the last strong reference is released.
    }

    /// Actively polls `conn.state` for the connection's lifetime and fires
    /// `onClosed` on `.failed`/`.cancelled`.
    ///
    /// Found necessary during 06.2-09 on-device verification: after
    /// backgrounding the app and returning, the QUIC connection eventually
    /// timed out (`nw_connection_group_handle_connection_state_changed ...
    /// failed with error Operation timed out`), but `TransportManager`
    /// never learned about it — `startInboundStreamListener`'s reliance on
    /// `conn.inboundStreams { ... }` throwing on connection failure does
    /// not reliably fire (the async sequence appears to simply stop rather
    /// than throw). Without `onClosed` firing, `handleTransportClosed(_:)`
    /// never runs and the reconnect loop never starts — the app silently
    /// stayed on "Streaming" with a dead signaling channel indefinitely
    /// (heartbeat sends into it silently no-op; only the already-negotiated
    /// WebRTC data channel, unaffected by this, kept delivering motion
    /// data, masking the problem from a purely visual check). This poll is
    /// the reliable signal; 1s interval is coarse deliberately — connection
    /// health, not handshake-latency-sensitive.
    private func startConnectionHealthMonitor(_ conn: NetworkConnection<QUIC>) {
        healthMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                switch conn.state {
                case .failed, .cancelled:
                    self?.onClosed?("wt-net")
                    return
                default:
                    break
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
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
        let stream = try await conn.openStream(directionality: .unidirectional)
        var payload = Http3Framing.encodeVarint(0x00) // HTTP/3 control stream type (RFC 9114 §6.2.1)
        payload.append(contentsOf: Http3Framing.settingsFrame())
        try await stream.send(Data(payload), endOfStream: false)
        // Retain on `self` — see `controlStream`'s doc comment. Must survive
        // this function returning; a local `let` does not.
        controlStream = stream
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

        // Strip the HTTP/3 HEADERS frame's type+length varint prefix
        // (RFC 9114 §7.2.2) before handing the payload to the QPACK
        // field-line walker — `response.content` is the raw stream bytes,
        // frame header included, not just the QPACK-encoded field section.
        let responseBytes = Array(response.content)
        guard let (frameType, typeLen) = Http3Framing.decodeVarint(responseBytes), frameType == 0x01,
              let (frameLen, lenLen) = Http3Framing.decodeVarint(Array(responseBytes[typeLen...])),
              responseBytes.count >= typeLen + lenLen + Int(frameLen)
        else {
            throw WebTransportSignalingError.wtNet(nil)
        }
        let headerPayload = Array(responseBytes[(typeLen + lenLen)...])

        guard Self.responseIndicatesStatus200(headerPayload) else {
            throw WebTransportSignalingError.wtNet(nil)
        }

        connectStream = stream
        webTransportSessionID = stream.streamID
    }

    /// Determines whether an extended-CONNECT response's HTTP/3 HEADERS
    /// frame payload carries `:status: 200`.
    ///
    /// On-device verification (06.2-09) against the real server showed
    /// `wtransport`'s QPACK encoder does NOT use the fully-static Indexed
    /// Field Line for `:status: 200` (RFC 9204 §4.5.2, static index 25,
    /// byte `0xD9`) that this spike originally assumed. Instead it encodes
    /// `:status` as a Literal Field Line With Name Reference (§4.5.4) to the
    /// nearby static index 24 (`:status: 103` — only the NAME is reused) and
    /// Huffman-compresses the literal value "200" (§4.5.4 + RFC 7541 §5.2).
    /// Both are spec-valid encodings of the identical header; this walker
    /// recognizes both rather than one fixed byte pattern.
    ///
    /// `bytes` is the raw HEADERS frame payload (Required Insert Count +
    /// Delta Base prefix, RFC 9204 §4.5.1, followed by encoded field lines).
    /// Only the two field-line representations observed in practice are
    /// handled — sufficient to answer "is this a 200 response", not a
    /// general-purpose QPACK decoder (deliberately out of scope, per this
    /// file's original design note).
    static func responseIndicatesStatus200(_ bytes: [UInt8]) -> Bool {
        // Required Insert Count: 8-bit prefix integer (RFC 7541 §5.1).
        guard let (_, ricLen) = qpackPrefixIntDecode(bytes, prefixBits: 8) else { return false }
        // Delta Base: 7-bit prefix integer: bit 7 of the first byte is the
        // sign (S), the low 7 bits (plus continuation) are the magnitude.
        guard ricLen < bytes.count,
              let (_, deltaLen) = qpackPrefixIntDecode(Array(bytes[ricLen...]), prefixBits: 7)
        else { return false }

        var offset = ricLen + deltaLen
        while offset < bytes.count {
            let first = bytes[offset]
            if first & 0b1100_0000 == 0b1100_0000 {
                // Indexed Field Line (§4.5.2): `1 T Index(6+)`, T=1 (static).
                guard let (index, len) = qpackPrefixIntDecode(Array(bytes[offset...]), prefixBits: 6) else { return false }
                if index == 25 { return true } // :status: 200, fully indexed
                offset += len
            } else if first & 0b1100_0000 == 0b0100_0000 {
                // Literal Field Line With Name Reference (§4.5.4):
                // `01 N T NameIndex(4+)` then `H VLen(7+)` + value bytes.
                guard let (nameIndex, nameLen) = qpackPrefixIntDecode(Array(bytes[offset...]), prefixBits: 4) else { return false }
                var valueOffset = offset + nameLen
                guard valueOffset < bytes.count else { return false }
                let huffman = bytes[valueOffset] & 0b1000_0000 != 0
                guard let (valueLen, valueLenBytes) = qpackPrefixIntDecode(Array(bytes[valueOffset...]), prefixBits: 7) else { return false }
                valueOffset += valueLenBytes
                guard valueOffset + Int(valueLen) <= bytes.count else { return false }
                let valueBytes = Array(bytes[valueOffset..<(valueOffset + Int(valueLen))])
                if nameIndex == 24 || nameIndex == 25 { // both are ":status" entries
                    let value = huffman
                        ? decodeHuffmanDigits(valueBytes, expectedDigitCount: 3)
                        : String(bytes: valueBytes, encoding: .ascii)
                    if value == "200" { return true }
                }
                offset = valueOffset + Int(valueLen)
            } else {
                // An unrecognized field-line pattern (literal without name
                // reference, post-base forms) — not observed against the
                // real server for this response; bail rather than
                // mis-parse further bytes.
                return false
            }
        }
        return false
    }

    /// HPACK/QPACK "prefix integer" decode (RFC 7541 §5.1) — the inverse of
    /// `Http3Framing`'s private `qpackPrefixInt` encoder. Returns the
    /// decoded value and the number of bytes it (and any continuation bytes)
    /// consumed. `prefixBits` excludes the pattern bits already consumed by
    /// the caller (e.g. 6 for an Indexed Field Line's `1 T` prefix).
    private static func qpackPrefixIntDecode(_ bytes: [UInt8], prefixBits: Int) -> (value: UInt64, bytesRead: Int)? {
        guard let first = bytes.first else { return nil }
        let maxPrefixValue: UInt64 = (1 << prefixBits) - 1
        var value = UInt64(first) & maxPrefixValue
        if value < maxPrefixValue { return (value, 1) }

        var index = 1
        var shift: UInt64 = 0
        while true {
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            value += UInt64(byte & 0x7F) << shift
            index += 1
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return (value, index)
    }

    /// Decodes a Huffman-encoded ASCII-digit string (RFC 7541 Appendix B:
    /// '0'-'9' are each contiguous, prefix-free 5-bit codes `00000`-`01001`)
    /// — the only Huffman-encoded value shape this minimal response reader
    /// needs to understand, since an HTTP status code is always exactly 3
    /// ASCII digits. Not a general Huffman decoder (deliberately narrow).
    private static func decodeHuffmanDigits(_ bytes: [UInt8], expectedDigitCount: Int) -> String? {
        var bits: [UInt8] = []
        bits.reserveCapacity(bytes.count * 8)
        for byte in bytes {
            for i in (0..<8).reversed() {
                bits.append((byte >> i) & 1)
            }
        }
        guard bits.count >= expectedDigitCount * 5 else { return nil }

        var result = ""
        var index = 0
        for _ in 0..<expectedDigitCount {
            var digit: UInt8 = 0
            for i in 0..<5 {
                digit = (digit << 1) | bits[index + i]
            }
            guard digit <= 9 else { return nil }
            result.append(Character(UnicodeScalar(48 + digit)))
            index += 5
        }
        return result
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
