import XCTest
@testable import immersiveRT

/// Regression coverage for `WebTransportSignaling.responseIndicatesStatus200(_:)`
/// — the extended-CONNECT success detector. Added after 06.2-09 on-device
/// verification found the original single-byte heuristic (checking for the
/// fully-static-indexed `0xD9` encoding of `:status: 200`) never matched
/// against the real server, which encodes the same header as a Literal
/// Field Line With Name Reference + Huffman-compressed value instead —
/// causing the client to treat every successful handshake as a failure and
/// tear down the connection itself.
final class WebTransportSignalingTests: XCTestCase {

    /// The exact bytes captured from the real dev server's extended-CONNECT
    /// response during on-device testing (Xcode console, 06.2-09), with the
    /// HTTP/3 HEADERS frame type+length prefix (`01 07`) already stripped —
    /// `:status: 200` encoded as Literal Field Line With Name Reference
    /// (static index 24, Huffman-compressed value "200").
    private let realServerHeaderPayload: [UInt8] = [0x00, 0x00, 0x5f, 0x09, 0x82, 0x10, 0x01]

    func test_recognizesRealServerEncoding_literalWithNameReferenceAndHuffmanValue() {
        XCTAssertTrue(WebTransportSignaling.responseIndicatesStatus200(realServerHeaderPayload))
    }

    func test_recognizesFullyIndexedStaticEncoding() {
        // RIC=0, DeltaBase=0, then Indexed Field Line static index 25 (0xC0 | 25 = 0xD9).
        let bytes: [UInt8] = [0x00, 0x00, 0xD9]
        XCTAssertTrue(WebTransportSignaling.responseIndicatesStatus200(bytes))
    }

    func test_recognizesLiteralWithNameReference_unHuffmanedValue() {
        // Name index 24 (":status" name — 4-bit prefix maxes at 15, so index
        // 24 needs a continuation byte: 0x5f 0x09, same as the real-server
        // fixture), literal (non-Huffman) ASCII value "200" (H=0, len=3).
        let bytes: [UInt8] = [0x00, 0x00, 0x5f, 0x09, 0x03, 0x32, 0x30, 0x30]
        XCTAssertTrue(WebTransportSignaling.responseIndicatesStatus200(bytes))
    }

    func test_rejectsStatus404() {
        // Same name-reference-to-:status shape as the real server's 200
        // response, but with literal value "404" — must NOT be reported as
        // success.
        let bytes: [UInt8] = [0x00, 0x00, 0x5f, 0x09, 0x03, 0x34, 0x30, 0x34]
        XCTAssertFalse(WebTransportSignaling.responseIndicatesStatus200(bytes))
    }

    func test_rejectsEmptyPayload() {
        XCTAssertFalse(WebTransportSignaling.responseIndicatesStatus200([]))
    }

    func test_rejectsUnrelatedFieldLines() {
        // Indexed Field Line static index 0 (:authority) only — no status field at all.
        let bytes: [UInt8] = [0x00, 0x00, 0xC0]
        XCTAssertFalse(WebTransportSignaling.responseIndicatesStatus200(bytes))
    }
}
