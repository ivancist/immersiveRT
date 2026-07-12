import XCTest
@testable import immersiveRT

final class Http3FramingTests: XCTestCase {

    // MARK: - QUIC varint (RFC 9000 §16)

    func test_encodeVarint_boundaryValues() {
        // RFC 9000 §16: 2-bit length prefix selects 1/2/4/8-byte encoding.
        XCTAssertEqual(Http3Framing.encodeVarint(0), [0x00])
        XCTAssertEqual(Http3Framing.encodeVarint(63), [0x3F]) // 6-bit max, still 1 byte
        XCTAssertEqual(Http3Framing.encodeVarint(64), [0x40, 0x40]) // overflows 1 byte -> 2 bytes
        XCTAssertEqual(Http3Framing.encodeVarint(16383), [0x7F, 0xFF]) // 14-bit max, still 2 bytes
        XCTAssertEqual(Http3Framing.encodeVarint(16384), [0x80, 0x00, 0x40, 0x00]) // overflows 2 bytes -> 4 bytes
        XCTAssertEqual(Http3Framing.encodeVarint(1_073_741_823), [0xBF, 0xFF, 0xFF, 0xFF]) // 30-bit max, still 4 bytes
        XCTAssertEqual(
            Http3Framing.encodeVarint(1_073_741_824),
            [0xC0, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00]
        ) // overflows 4 bytes -> 8 bytes
    }

    func test_encodeVarint_rfc9000AppendixWorkedExamples() {
        // RFC 9000 §16, Appendix A.1's canonical worked examples.
        XCTAssertEqual(Http3Framing.encodeVarint(37), [0x25])
        XCTAssertEqual(Http3Framing.encodeVarint(15293), [0x7B, 0xBD])
        XCTAssertEqual(Http3Framing.encodeVarint(494_878_333), [0x9D, 0x7F, 0x3E, 0x7D])
        XCTAssertEqual(
            Http3Framing.encodeVarint(151_288_809_941_952_652),
            [0xC2, 0x19, 0x7C, 0x5E, 0xFF, 0x14, 0xE8, 0x8C]
        )
    }

    func test_decodeVarint_roundTripsBoundaryValues() {
        let values: [UInt64] = [
            0, 63, 64, 16383, 16384, 1_073_741_823, 1_073_741_824, 151_288_809_941_952_652,
        ]
        for value in values {
            let encoded = Http3Framing.encodeVarint(value)
            let decoded = Http3Framing.decodeVarint(encoded)
            XCTAssertEqual(decoded?.value, value, "round trip failed for \(value)")
            XCTAssertEqual(decoded?.bytesRead, encoded.count, "bytesRead mismatch for \(value)")
        }
    }

    func test_decodeVarint_toleratesTrailingBytes() {
        // A real decode call site reads a varint from the front of a larger
        // buffer (e.g. a frame header followed by payload) — decodeVarint
        // must only consume its own bytes, not the whole buffer.
        let decoded = Http3Framing.decodeVarint([0x40, 0x40, 0xFF, 0xFF])
        XCTAssertEqual(decoded?.value, 64)
        XCTAssertEqual(decoded?.bytesRead, 2)
    }

    // MARK: - decodeVarint bounds safety (T-06.2-07: DoS via malformed input)

    func test_decodeVarint_emptyInput_returnsNil() {
        XCTAssertNil(Http3Framing.decodeVarint([]))
    }

    func test_decodeVarint_truncatedInput_returnsNil() {
        // First byte's prefix declares an 8-byte encoding but only 3 bytes are present.
        XCTAssertNil(Http3Framing.decodeVarint([0xC2, 0x19, 0x7C]))
    }

    func test_decodeVarint_truncated2ByteInput_returnsNil() {
        // First byte's prefix declares a 2-byte encoding but the buffer is empty after it.
        XCTAssertNil(Http3Framing.decodeVarint([0x40]))
    }

    // MARK: - HTTP/3 SETTINGS frame (RFC 9114 §7.2.4)

    func test_settingsFrame_emptyDefaultFrame() {
        // Frame type 0x04 (SETTINGS), length 0, no payload.
        XCTAssertEqual(Http3Framing.settingsFrame(), [0x04, 0x00])
    }

    // MARK: - WebTransport stream-type prefix (RFC 9220 §4.2)

    func test_wtStreamTypePrefix_unidirectional() {
        // WEBTRANSPORT_STREAM stream type = 0x54 (84 decimal). 84 > 63 (the
        // QUIC varint's 1-byte/6-bit boundary, RFC 9000 §16), so the
        // canonical minimal-length encoding is 2 bytes: 84 | 0x4000 = 0x4054.
        XCTAssertEqual(Http3Framing.wtStreamTypePrefix(bidi: false), [0x40, 0x54])
    }

    func test_wtStreamTypePrefix_bidirectional() {
        // WEBTRANSPORT_STREAM frame type (bidi streams have no stream type)
        // = 0x41 (65 decimal). 65 > 63, so the canonical minimal-length
        // varint encoding is 2 bytes: 65 | 0x4000 = 0x4041.
        XCTAssertEqual(Http3Framing.wtStreamTypePrefix(bidi: true), [0x40, 0x41])
    }

    // MARK: - Extended-CONNECT header block (RFC 9204 QPACK, static-table only)

    func test_extendedConnectHeaders_isDeterministic() {
        let a = Http3Framing.extendedConnectHeaders(authority: "example.com:4433", path: "/")
        let b = Http3Framing.extendedConnectHeaders(authority: "example.com:4433", path: "/")
        XCTAssertEqual(a, b)
    }

    func test_extendedConnectHeaders_noDynamicTableReferences() {
        // RFC 9204 §4.5.1: Required Insert Count=0, Delta Base S=0/value=0 —
        // this encoder never references the QPACK dynamic table.
        let bytes = Http3Framing.extendedConnectHeaders(authority: "h", path: "/")
        XCTAssertEqual(Array(bytes.prefix(2)), [0x00, 0x00])
    }

    func test_extendedConnectHeaders_methodConnectIsIndexedRightAfterPrefix() {
        // :method: CONNECT is an exact QPACK static-table entry (index 15) —
        // an Indexed Field Line: 0xC0 | 15 = 0xCF, emitted immediately after
        // the 2-byte field-section prefix (fixed position, first header).
        let bytes = Http3Framing.extendedConnectHeaders(authority: "h", path: "/")
        XCTAssertEqual(bytes[2], 0xCF)
    }

    func test_extendedConnectHeaders_containsIndexedSchemeHttps() {
        // :scheme: https is an exact QPACK static-table entry (index 23) —
        // an Indexed Field Line: 0xC0 | 23 = 0xD7.
        let bytes = Http3Framing.extendedConnectHeaders(authority: "h", path: "/")
        XCTAssertTrue(bytes.contains(0xD7))
    }

    func test_extendedConnectHeaders_containsProtocolWebtransportLiteral() {
        // No QPACK static-table entry exists for `:protocol` — it must
        // appear as literal ASCII bytes (Literal Field Line Without Name
        // Reference), unlike :method/:scheme above.
        let bytes = Http3Framing.extendedConnectHeaders(authority: "h", path: "/")
        XCTAssertTrue(containsSubsequence(Array(":protocol".utf8), in: bytes))
        XCTAssertTrue(containsSubsequence(Array("webtransport".utf8), in: bytes))
    }

    func test_extendedConnectHeaders_containsAuthorityAndPathValues() {
        let bytes = Http3Framing.extendedConnectHeaders(authority: "myhost.local", path: "/session")
        XCTAssertTrue(containsSubsequence(Array("myhost.local".utf8), in: bytes))
        XCTAssertTrue(containsSubsequence(Array("/session".utf8), in: bytes))
    }

    func test_extendedConnectHeaders_exactByteFixture_shortAuthorityAndRootPath() {
        // Hand-derived byte-for-byte fixture (RFC 9204 §4.5.1/§4.5.2/§4.5.4/§4.5.6,
        // RFC 7541 §5.1 prefix-integer encoding) for authority="h", path="/":
        //   [0x00,0x00]                                  field-section prefix (no dynamic table)
        //   [0xCF]                                        :method: CONNECT   (indexed, static #15)
        //   [0x27,0x02, ":protocol" bytes, 0x0C, "webtransport" bytes]  :protocol: webtransport (literal, no name ref)
        //   [0xD7]                                        :scheme: https     (indexed, static #23)
        //   [0x51,0x01,0x2F]                               :path: /           (literal w/ name ref, static #1)
        //   [0x50,0x01,0x68]                               :authority: h      (literal w/ name ref, static #0)
        let expected: [UInt8] = [
            0x00, 0x00,
            0xCF,
            0x27, 0x02, 0x3A, 0x70, 0x72, 0x6F, 0x74, 0x6F, 0x63, 0x6F, 0x6C,
            0x0C, 0x77, 0x65, 0x62, 0x74, 0x72, 0x61, 0x6E, 0x73, 0x70, 0x6F, 0x72, 0x74,
            0xD7,
            0x51, 0x01, 0x2F,
            0x50, 0x01, 0x68,
        ]
        XCTAssertEqual(Http3Framing.extendedConnectHeaders(authority: "h", path: "/"), expected)
    }

    // MARK: - Helpers

    private func containsSubsequence(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                return true
            }
        }
        return false
    }
}
