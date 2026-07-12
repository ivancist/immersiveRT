import Foundation
import WebRTC

/// Per-peer WebRTC state — Swift port of `phone.ts`'s `peerConnections` map
/// entry shape (`{ pc, dc, channelOpen, flagClose }`, line 712).
final class PeerConnectionEntry {
    let pc: RTCPeerConnection
    var dc: RTCDataChannel?
    var channelOpen: Bool = false
    /// WR-11: set immediately before an intentional close (`closePeer`) so
    /// `dc.onclose`'s equivalent (`dataChannelDidChangeState`) doesn't treat
    /// the close as a failure. Mirrors phone.ts's `flagClose` closure,
    /// stored here as a plain flag on the entry.
    var intentionalClose: Bool = false
    /// Threaded through to `dc.onopen`'s equivalent: `true` when this open
    /// is a self-heal reopen (after `failed`) or reconnect-path reopen, so a
    /// `phone-state: channel-recovered` gets sent in addition to
    /// `rtc-channel-ready` (phone.ts:685-693).
    var isRecovery: Bool

    init(pc: RTCPeerConnection, isRecovery: Bool) {
        self.pc = pc
        self.isRecovery = isRecovery
    }
}

/// Ports `client/src/phone.ts`'s `openChannelToPeer()` (lines 634-713) — one
/// `RTCPeerConnection` + one unreliable "sensor" `RTCDataChannel` per
/// desktop peer in the room (PHONE-03), self-healing on connection failure.
///
/// Real multi-desktop fan-out + DTLS-role behavior against a live desktop is
/// verified on-device in Plan 09 (referenced here, not claimed by this
/// type's unit tests). `PeerConnectionManagerTests` unit-verifies
/// `makeDataChannelConfig()`'s field values and the offline-constructible
/// per-peer fan-out shape (peer-connection/data-channel object creation
/// needs no network/ICE negotiation); the failure self-heal / offer-ICE
/// dispatch wiring below is code-review-verified per the plan's acceptance
/// criteria.
final class PeerConnectionManager: NSObject {
    private let factory: RTCPeerConnectionFactory
    private let transport: SignalingTransport
    private let myId: String
    private let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

    /// STUN/TURN servers from the pair-ack payload (`ICEConfig.iceServers(from:)`).
    var iceServers: [RTCIceServer]

    /// Mirrors phone.ts's top-level `registered` flag — the self-heal
    /// reopen-on-`failed` path (and `sendPhoneState`'s guard) only fires
    /// while this is `true` (phone.ts:653, 1198).
    var registered: Bool = true

    private var peers: [String: PeerConnectionEntry] = [:]

    /// Total open "sensor" data channels across all peers — mirrors
    /// phone.ts's `openChannelCount` (used to drive `chan-open` UI).
    private(set) var openChannelCount: Int = 0

    init(transport: SignalingTransport, myId: String, iceServers: [RTCIceServer] = []) {
        self.transport = transport
        self.myId = myId
        self.iceServers = iceServers
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        super.init()
    }

    // MARK: - Locked data channel config (D-05, Phase 4)

    /// `isOrdered = false`, `maxRetransmits = 0` — the project-wide locked
    /// unreliable data-channel contract (D-05, phone.ts:639).
    ///
    /// `maxPacketLifeTime` is intentionally NEVER assigned here, and MUST
    /// NEVER be assigned or even READ elsewhere on a config/channel that
    /// uses `maxRetransmits`: `maxPacketLifeTime` and `maxRetransmits` are
    /// mutually exclusive per the WebRTC data channel spec (RESEARCH.md
    /// Anti-Patterns), and on this project's pinned `stasel/WebRTC` M150
    /// binary the mutual exclusivity is enforced on READ, not just on
    /// simultaneous write — reading `maxPacketLifeTime` when it was left
    /// unset aborts the process (`SIGABRT`, confirmed via a live crash
    /// during Task 3 test verification). The public header's "-1 if unset"
    /// comment describes the underlying C++ `absl::optional`'s default, but
    /// the getter itself does not tolerate reading that default.
    static func makeDataChannelConfig() -> RTCDataChannelConfiguration {
        let config = RTCDataChannelConfiguration()
        config.isOrdered = false
        config.maxRetransmits = 0
        return config
    }

    // MARK: - Test/introspection surface

    var peerCount: Int { peers.count }

    func dataChannel(for peerId: String) -> RTCDataChannel? {
        peers[peerId]?.dc
    }

    /// All currently OPEN "sensor" data channels — added in Plan 07 so
    /// `TransportManager`'s sensor encode/send loop can fan a single encoded
    /// packet out to every connected desktop peer without needing to track
    /// peer IDs itself (mirrors `phone.ts`'s implicit
    /// `peerConnections.forEach` broadcast inside its sensor pipeline).
    /// `peers` stays `private` — this is a read-only projection, not a
    /// roster leak.
    var openDataChannels: [RTCDataChannel] {
        peers.values.compactMap { $0.channelOpen ? $0.dc : nil }
    }

    // MARK: - Fan-out

    /// Opens one peer connection + one "sensor" data channel for `peerId`.
    /// Direct port of `openChannelToPeer()` (phone.ts:634-713).
    func openChannel(toPeer peerId: String, isRecovery: Bool = false) {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan

        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            return
        }

        let entry = PeerConnectionEntry(pc: pc, isRecovery: isRecovery)
        peers[peerId] = entry

        let dc = pc.dataChannel(forLabel: "sensor", configuration: Self.makeDataChannelConfig())
        entry.dc = dc
        dc?.delegate = self
    }

    /// WR-11 intentional close — mirrors `closePeer()` (phone.ts:1204-1212).
    /// Flags the entry so the data-channel-closed handler doesn't treat
    /// this as a failure, tears down the peer connection, and removes it
    /// from the roster.
    func closePeer(_ peerId: String) {
        guard let entry = peers[peerId] else { return }
        entry.intentionalClose = true
        entry.pc.close()
        peers.removeValue(forKey: peerId)
        if entry.channelOpen, openChannelCount > 0 {
            openChannelCount -= 1
        }
    }

    /// Applies a remote `answer` SDP to the peer's connection — mirrors
    /// `handleServerPush`'s `case 'answer'` (phone.ts:1124-1136). Accepts
    /// the raw envelope (payload shape `{type, sdp}`, matching the browser's
    /// `RTCSessionDescriptionInit` wire format) so callers (the future
    /// `TransportManager`, Plan 07/08) can route pushes straight through
    /// without re-parsing.
    func applyRemoteAnswer(_ envelope: SignalingEnvelope, for peerId: String) {
        guard let entry = peers[peerId],
              let sdpString = envelope.payload["sdp"]?.value as? String,
              let typeString = envelope.payload["type"]?.value as? String else {
            return
        }
        let setup = Self.setupRole(fromSdp: sdpString)
        print("[WebRTC] answer a=setup:\(setup ?? "?") from=\(String(peerId.prefix(8)))")

        let sdpType = RTCSessionDescription.type(for: typeString)
        let sessionDescription = RTCSessionDescription(type: sdpType, sdp: sdpString)
        entry.pc.setRemoteDescription(sessionDescription) { error in
            if let error {
                print("[WebRTC] setRemoteDescription(answer) failed for \(peerId): \(error)")
            }
        }
    }

    /// Adds a remote ICE candidate — mirrors `handleServerPush`'s
    /// `case 'ice-candidate'` (phone.ts:1139-1143). Payload shape
    /// `{candidate, sdpMid, sdpMLineIndex}` matches the browser's
    /// `RTCIceCandidateInit` wire format (`room.ts`/`phone.ts` both read
    /// `msg.payload as RTCIceCandidateInit`).
    func addRemoteCandidate(_ envelope: SignalingEnvelope, for peerId: String) {
        guard let entry = peers[peerId],
              let candidateSdp = envelope.payload["candidate"]?.value as? String else {
            return
        }
        let sdpMLineIndexValue = envelope.payload["sdpMLineIndex"]?.value
        let sdpMLineIndex: Int32
        if let intValue = sdpMLineIndexValue as? Int {
            sdpMLineIndex = Int32(intValue)
        } else if let doubleValue = sdpMLineIndexValue as? Double {
            sdpMLineIndex = Int32(doubleValue)
        } else {
            sdpMLineIndex = 0
        }
        let sdpMid = envelope.payload["sdpMid"]?.value as? String

        let candidate = RTCIceCandidate(sdp: candidateSdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        entry.pc.add(candidate) { error in
            if let error {
                print("[WebRTC] addIceCandidate failed for \(peerId): \(error)")
            }
        }
    }

    /// Reopens any peer whose data channel is closed/closing or whose peer
    /// connection state is `.failed` — the collect-then-reopen pattern from
    /// `attemptReconnect()` (phone.ts:594-604), avoiding mutation of `peers`
    /// while iterating it. Called by the reconnect loop (Plan 07) after a
    /// successful `join-ack`.
    func reopenStaleChannels() {
        let stalePeerIds = peers.compactMap { peerId, entry -> String? in
            let dcState = entry.dc?.readyState
            let isStaleChannel = dcState == .closed || dcState == .closing
            let isFailedConnection = entry.pc.connectionState == .failed
            return (isStaleChannel || isFailedConnection) ? peerId : nil
        }
        for peerId in stalePeerIds {
            peers.removeValue(forKey: peerId)
            openChannel(toPeer: peerId, isRecovery: true)
        }
    }

    // MARK: - Signaling dispatch (via the injected SignalingTransport)

    private func sendOffer(_ sdp: RTCSessionDescription, to peerId: String) {
        let setup = Self.setupRole(fromSdp: sdp.sdp)
        print("[WebRTC] offer a=setup:\(setup ?? "?") p=\(String(peerId.prefix(8)))")
        let payload: [String: AnyCodable] = [
            "type": AnyCodable(RTCSessionDescription.string(for: sdp.type)),
            "sdp": AnyCodable(sdp.sdp),
        ]
        transport.send(SignalingEnvelope(
            type: SignalingEnvelope.SignalingType.offer,
            from: myId,
            to: peerId,
            payload: payload
        ))
    }

    private func sendIceCandidate(_ candidate: RTCIceCandidate, to peerId: String) {
        let payload: [String: AnyCodable] = [
            "candidate": AnyCodable(candidate.sdp),
            "sdpMLineIndex": AnyCodable(Int(candidate.sdpMLineIndex)),
            "sdpMid": AnyCodable(candidate.sdpMid),
        ]
        transport.send(SignalingEnvelope(
            type: SignalingEnvelope.SignalingType.iceCandidate,
            from: myId,
            to: peerId,
            payload: payload
        ))
    }

    private func sendRtcChannelReady(for peerId: String) {
        transport.send(SignalingEnvelope(
            type: SignalingEnvelope.SignalingType.rtcChannelReady,
            from: myId,
            to: "",
            payload: ["with": AnyCodable(peerId)]
        ))
    }

    /// Mirrors `sendPhoneState()` (phone.ts:1197-1200) — guarded on
    /// `registered`, `to` always empty (server routes phone-state by `from`).
    private func sendPhoneState(_ state: String, with peerId: String) {
        guard registered else { return }
        transport.send(SignalingEnvelope(
            type: SignalingEnvelope.SignalingType.phoneState,
            from: myId,
            to: "",
            payload: ["state": AnyCodable(state), "with": AnyCodable(peerId)]
        ))
    }

    // MARK: - Event handlers (invoked from delegate callbacks below)

    /// Self-healing reconnect-on-failure — direct port of
    /// `onconnectionstatechange`'s `'failed'` branch (phone.ts:641-655).
    private func handleConnectionFailed(peerId: String, peerConnection: RTCPeerConnection) {
        let entry = peers[peerId]
        let wasOpen = entry?.channelOpen ?? false
        if let entry, entry.channelOpen {
            entry.channelOpen = false
            if openChannelCount > 0 { openChannelCount -= 1 }
        }
        if registered {
            peers.removeValue(forKey: peerId)
            peerConnection.close()
            openChannel(toPeer: peerId, isRecovery: wasOpen)
        }
    }

    private func handleChannelOpen(peerId: String) {
        guard let entry = peers[peerId] else { return }
        entry.channelOpen = true
        openChannelCount += 1
        sendRtcChannelReady(for: peerId)
        if entry.isRecovery {
            sendPhoneState("channel-recovered", with: peerId)
        }
    }

    private func handleChannelClose(peerId: String) {
        guard let entry = peers[peerId] else { return }
        if entry.intentionalClose { return }  // WR-11
        if entry.channelOpen {
            entry.channelOpen = false
            if openChannelCount > 0 { openChannelCount -= 1 }
        }
        sendPhoneState("channel-lost", with: peerId)
    }

    // MARK: - Peer/data-channel identity lookup

    private func peerId(for peerConnection: RTCPeerConnection) -> String? {
        peers.first(where: { $0.value.pc === peerConnection })?.key
    }

    private func peerId(for dataChannel: RTCDataChannel) -> String? {
        peers.first(where: { $0.value.dc === dataChannel })?.key
    }

    /// Extracts the `a=setup:` DTLS role value from an SDP string — Swift
    /// equivalent of phone.ts's `sdp.match(/a=setup:(\S+)/)`, used only for
    /// diagnostic logging (the DTLS-passive-role patch itself lives
    /// server-side in `room.ts`'s `handleOffer()`).
    private static func setupRole(fromSdp sdp: String) -> String? {
        guard let range = sdp.range(of: "a=setup:") else { return nil }
        let value = sdp[range.upperBound...].prefix { !$0.isWhitespace }
        return value.isEmpty ? nil : String(value)
    }
}

// MARK: - RTCPeerConnectionDelegate

extension PeerConnectionManager: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    /// Mirrors `onnegotiationneeded` (phone.ts:667-678): create an offer,
    /// `setLocalDescription()` it, then send the resulting offer via the
    /// injected transport. (The native binding has no single-call
    /// `setLocalDescription()`-infers-offer-or-answer equivalent to the JS
    /// zero-arg form, so the offer is created explicitly first — the
    /// standard `stasel/WebRTC` idiom, RESEARCH.md Pattern 2.)
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        guard let peerId = peerId(for: peerConnection) else { return }
        peerConnection.offer(for: constraints, completionHandler: { [weak self] sdp, error in
            guard let self else { return }
            if let error {
                print("[WebRTC] onnegotiationneeded offer creation failed for \(peerId): \(error)")
                return
            }
            guard let sdp else { return }
            peerConnection.setLocalDescription(sdp, completionHandler: { error in
                if let error {
                    print("[WebRTC] onnegotiationneeded setLocalDescription failed for \(peerId): \(error)")
                    return
                }
                self.sendOffer(sdp, to: peerId)
            })
        })
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    /// Mirrors `onicecandidate` (phone.ts:680-688) — send every non-nil
    /// candidate via the injected transport.
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard let peerId = peerId(for: peerConnection) else { return }
        sendIceCandidate(candidate, to: peerId)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    /// Mirrors `onconnectionstatechange` (phone.ts:641-655) — self-heal on
    /// `.failed`. `@objc optional` in the underlying protocol; implemented
    /// here since `PeerConnectionManager` is an `NSObject` subclass.
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        guard let peerId = peerId(for: peerConnection) else { return }
        if newState == .failed {
            handleConnectionFailed(peerId: peerId, peerConnection: peerConnection)
        }
    }
}

// MARK: - RTCDataChannelDelegate

extension PeerConnectionManager: RTCDataChannelDelegate {
    /// Mirrors `dc.onopen`/`dc.onclose` (phone.ts:685-701) — `readyState`
    /// transitions to `.open`/`.closed` are the Swift binding's equivalent
    /// of those two separate JS callbacks.
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard let peerId = peerId(for: dataChannel) else { return }
        switch dataChannel.readyState {
        case .open:
            handleChannelOpen(peerId: peerId)
        case .closed:
            handleChannelClose(peerId: peerId)
        case .connecting, .closing:
            break
        @unknown default:
            break
        }
    }

    /// The phone client only SENDS sensor packets on this channel — it does
    /// not decode peer-sent data (threat model: out of scope, no
    /// phone-to-phone data channel exists in this architecture).
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {}
}
