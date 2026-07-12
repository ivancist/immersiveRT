import Foundation

/// Pure HTTP/3 / QUIC / WebTransport-over-HTTP/3 byte-framing helpers
/// (RFC 9000 §16, RFC 9114, RFC 9204, RFC 9220).
///
/// These helpers back `WebTransportSignaling.swift` (06.2-05 Task 2) — the
/// D-05 time-boxed WebTransport spike. This file is deliberately
/// Foundation-only and side-effect-free: no networking, no Network.framework
/// import, no state. Every function is a deterministic byte transform that
/// can be unit-tested against known RFC byte fixtures without a live
/// connection, isolating the risky network-I/O work (in
/// `WebTransportSignaling.swift`) from the byte-encoding logic (here).
///
/// The Rust server (`server/src/wt_server.rs`) uses `wtransport::Endpoint`,
/// which implements the real WebTransport-over-HTTP/3 spec (RFC 9220) — not
/// a bespoke lightweight protocol. A client MUST speak the full HTTP/3
/// SETTINGS exchange + extended-CONNECT handshake to interoperate; there is
/// no shortcut. See RESEARCH.md "Architecture Patterns → Pattern 1" for the
/// full handshake sequence this file's helpers support.
enum Http3Framing {

    // MARK: - QUIC variable-length integers (RFC 9000 §16)

    /// Encodes `value` as a QUIC variable-length integer (RFC 9000 §16).
    ///
    /// The two most-significant bits of the first byte select the encoded
    /// length: `00` → 1 byte (6-bit value, max 63), `01` → 2 bytes (14-bit
    /// value, max 16383), `10` → 4 bytes (30-bit value, max 1073741823),
    /// `11` → 8 bytes (62-bit value). This encoder always chooses the
    /// smallest length that fits `value`, matching RFC 9000's canonical
    /// encoding and every worked example in Appendix A.1.
    ///
    /// - Precondition: `value` must fit in 62 bits (`< 2^62`) — the QUIC
    ///   varint's maximum representable value. Values outside this range are
    ///   clamped to the 8-byte encoding's low 62 bits rather than trapping,
    ///   since this is a pure helper with no error-reporting channel; no
    ///   caller in this codebase is expected to pass an out-of-range value.
    static func encodeVarint(_ value: UInt64) -> [UInt8] {
        switch value {
        case 0...0x3F:
            return [UInt8(value)]
        case 0...0x3FFF:
            let v = UInt16(value) | 0x4000
            return [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        case 0...0x3FFF_FFFF:
            let v = UInt32(value) | 0x8000_0000
            return [
                UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF),
            ]
        default:
            let v = (value & 0x3FFF_FFFF_FFFF_FFFF) | 0xC000_0000_0000_0000
            return (0..<8).map { UInt8((v >> ((7 - $0) * 8)) & 0xFF) }
        }
    }

    /// Decodes a QUIC variable-length integer from the start of `bytes`
    /// (RFC 9000 §16). Returns `nil` if `bytes` is empty or shorter than the
    /// length the first byte's prefix declares — a malformed/truncated input
    /// fails safely (returns `nil`) rather than over-reading past the end of
    /// the buffer (T-06.2-07: DoS via a hand-rolled parser on untrusted
    /// server bytes).
    ///
    /// - Returns: The decoded value and the number of bytes consumed from
    ///   the front of `bytes`, or `nil` on malformed/insufficient input.
    static func decodeVarint(_ bytes: [UInt8]) -> (value: UInt64, bytesRead: Int)? {
        guard let first = bytes.first else { return nil }
        let length = 1 << ((first & 0xC0) >> 6) // 1, 2, 4, or 8
        guard bytes.count >= length else { return nil }
        var value = UInt64(first & 0x3F)
        for i in 1..<length {
            value = (value << 8) | UInt64(bytes[i])
        }
        return (value, length)
    }

    // MARK: - HTTP/3 SETTINGS frame (RFC 9114 §7.2.4)

    /// Encodes a minimal/empty HTTP/3 SETTINGS frame: frame type `0x04`,
    /// length `0`, no payload. Every HTTP/3 endpoint must send a SETTINGS
    /// frame as the first frame on its control stream before anything else
    /// (RFC 9114 §7.2.4) — an empty settings set is valid and sufficient for
    /// this minimal client (RESEARCH.md Pattern 1, step 2).
    static func settingsFrame() -> [UInt8] {
        encodeVarint(0x04) + encodeVarint(0)
    }

    // MARK: - Extended-CONNECT pseudo-header block (RFC 9204 QPACK, static table only)

    /// QPACK static-table indices used below (RFC 9204 Appendix A). No
    /// static entry exists for `:protocol` (the extended-CONNECT
    /// pseudo-header, RFC 8441/9220) — the static table predates
    /// WebTransport, so `:protocol: webtransport` is always encoded as a
    /// literal field line without a name reference.
    private static let qpackStaticMethodConnect: UInt64 = 15 // ":method: CONNECT"
    private static let qpackStaticSchemeHttps: UInt64 = 23 // ":scheme: https"
    private static let qpackStaticAuthorityName: UInt64 = 0 // ":authority" (name only)
    private static let qpackStaticPathName: UInt64 = 1 // ":path" (name only; static value is "/")

    /// Encodes the extended-CONNECT pseudo-header set — `:method: CONNECT`,
    /// `:protocol: webtransport`, `:scheme: https`, `:path: <path>`,
    /// `:authority: <authority>` — as a QPACK-encoded field section (RFC
    /// 9204 §4.5), using the static table only (no dynamic table
    /// references anywhere, so no `SETTINGS_QPACK_*` negotiation is
    /// required from this client). Deterministic: calling this twice with
    /// the same arguments produces byte-identical output.
    ///
    /// The returned bytes are the QPACK-encoded field section only (the
    /// "Encoded Field Section" of RFC 9204 §4.5, starting with the Required
    /// Insert Count / Delta Base prefix) — NOT wrapped in an HTTP/3 HEADERS
    /// frame. Callers (`WebTransportSignaling.swift`) wrap this in a
    /// HEADERS frame themselves using `encodeVarint(0x01)` (frame type) +
    /// `encodeVarint(header block length)` + these bytes, reusing the same
    /// varint primitive rather than a dedicated frame-wrapping helper here.
    static func extendedConnectHeaders(authority: String, path: String) -> [UInt8] {
        var bytes: [UInt8] = [0x00, 0x00] // Required Insert Count=0, Delta Base S=0/value=0 (§4.5.1) — no dynamic table used.
        bytes += qpackIndexedFieldLine(staticIndex: qpackStaticMethodConnect) // :method: CONNECT
        bytes += qpackLiteralWithoutNameRef(name: ":protocol", value: "webtransport") // no static entry
        bytes += qpackIndexedFieldLine(staticIndex: qpackStaticSchemeHttps) // :scheme: https
        bytes += qpackLiteralWithNameRef(staticNameIndex: qpackStaticPathName, value: path) // :path
        bytes += qpackLiteralWithNameRef(staticNameIndex: qpackStaticAuthorityName, value: authority) // :authority
        return bytes
    }

    /// RFC 9204 §4.5.2 "Indexed Field Line": pattern `1 T Index(6+)`, where
    /// `T=1` selects the static table. Used for pseudo-headers whose exact
    /// name AND value already appear verbatim in the static table
    /// (`:method: CONNECT`, `:scheme: https`).
    private static func qpackIndexedFieldLine(staticIndex: UInt64) -> [UInt8] {
        var bytes = qpackPrefixInt(Int(staticIndex), prefixBits: 6)
        bytes[0] |= 0b1100_0000
        return bytes
    }

    /// RFC 9204 §4.5.4 "Literal Field Line With Name Reference": pattern
    /// `01 N T NameIndex(4+)` followed by an `H VLen(7+)` length-prefixed
    /// value string. `N=0` (not never-indexed), `T=1` (static table).
    private static func qpackLiteralWithNameRef(staticNameIndex: UInt64, value: String) -> [UInt8] {
        var bytes = qpackPrefixInt(Int(staticNameIndex), prefixBits: 4)
        bytes[0] |= 0b0101_0000
        let valueBytes = Array(value.utf8)
        bytes += qpackPrefixInt(valueBytes.count, prefixBits: 7) // H=0 (no Huffman)
        bytes += valueBytes
        return bytes
    }

    /// RFC 9204 §4.5.6 "Literal Field Line Without Name Reference": pattern
    /// `001 N H NameLen(3+)` followed by the literal name bytes, then an
    /// `H VLen(7+)`-prefixed value string. `N=0`, `H=0` (no Huffman coding
    /// on either name or value — this encoder never Huffman-encodes).
    private static func qpackLiteralWithoutNameRef(name: String, value: String) -> [UInt8] {
        let nameBytes = Array(name.utf8)
        var bytes = qpackPrefixInt(nameBytes.count, prefixBits: 3)
        bytes[0] |= 0b0010_0000
        bytes += nameBytes
        let valueBytes = Array(value.utf8)
        bytes += qpackPrefixInt(valueBytes.count, prefixBits: 7) // H=0 (no Huffman)
        bytes += valueBytes
        return bytes
    }

    /// The HPACK/QPACK "prefix integer" representation (RFC 7541 §5.1,
    /// reused unmodified by QPACK/RFC 9204) — distinct from the QUIC varint
    /// above (different bit layout, different maximum prefix widths per
    /// field). Returns only the integer's own bytes (first byte holds the
    /// low `prefixBits` bits, unset above that); the caller ORs the
    /// field-line's pattern bits into `bytes[0]` before appending the rest.
    private static func qpackPrefixInt(_ value: Int, prefixBits: Int) -> [UInt8] {
        let maxPrefixValue = (1 << prefixBits) - 1
        if value < maxPrefixValue {
            return [UInt8(value)]
        }
        var bytes: [UInt8] = [UInt8(maxPrefixValue)]
        var remaining = value - maxPrefixValue
        while remaining >= 128 {
            bytes.append(UInt8((remaining % 128) + 128))
            remaining /= 128
        }
        bytes.append(UInt8(remaining))
        return bytes
    }

    // MARK: - WebTransport stream-type prefix (RFC 9220 §4.2)

    /// Encodes the RFC 9220 §4.2 WebTransport stream-type varint that must
    /// prefix every QUIC stream associated with a WebTransport session
    /// (after the extended-CONNECT handshake completes). Unidirectional
    /// streams use the `WEBTRANSPORT_STREAM` **stream type** `0x54`;
    /// bidirectional streams instead use the `WEBTRANSPORT_STREAM` **frame
    /// type** `0x41` at the start of the stream (bidirectional QUIC streams
    /// have no "stream type" concept in HTTP/3, so RFC 9220 uses a frame
    /// instead). Callers append the session ID (`encodeVarint(sessionID)`)
    /// immediately after this prefix — that varint is session-specific
    /// state, not something this pure/session-agnostic helper knows about.
    static func wtStreamTypePrefix(bidi: Bool) -> [UInt8] {
        encodeVarint(bidi ? 0x41 : 0x54)
    }
}
