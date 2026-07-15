import XCTest
@testable import immersiveRT

/// Asserts `SensorPacketEncoder` is byte-identical to the real `encode.ts`
/// output, using a fixture captured from the live TypeScript encoder
/// (`client/scripts/dump-packet-fixture.ts` -> `Fixtures/packet_v1_fixture.json`),
/// not eyeballed or independently re-derived (PHONE-05).
final class SensorPacketEncoderTests: XCTestCase {

    // MARK: - Fixture-driven byte-identity

    func test_fixtureEntries_encodeByteIdenticalToTypeScriptEncoder() throws {
        let entries = try loadFixtureEntries()
        XCTAssertGreaterThanOrEqual(entries.count, 3, "Expected at least 3 fixture entries from dump-packet-fixture.ts")

        for entry in entries {
            let packet = entry.input.asSensorPacket()
            var buf = SensorPacketEncoder.makeBuffer()
            SensorPacketEncoder.encodePacket(packet, into: &buf)

            XCTAssertEqual(
                hexString(from: buf),
                entry.bytesHex,
                "Entry '\(entry.name)' did not encode byte-identical to the encode.ts fixture"
            )
        }
    }

    // MARK: - Stubbed-field zero guarantee (D-09)

    /// Offsets 15-30 (dx,dy,dz,px,py,pz,driftConfidence) must be zero when a
    /// packet is built with only the quaternion set and everything else left
    /// at `SensorPacket`'s struct defaults.
    func test_quaternionOnlyPacket_writesZeroAtStubbedOffsets() {
        let packet = SensorPacket(seq: 1, timestamp: 1000, qw: 0.5, qx: 0.5, qy: 0.5, qz: 0.5)

        var buf = SensorPacketEncoder.makeBuffer()
        SensorPacketEncoder.encodePacket(packet, into: &buf)
        let bytes = [UInt8](buf)

        XCTAssertEqual(bytes.count, SensorPacketEncoder.bufSize)
        for offset in 15...30 {
            XCTAssertEqual(bytes[offset], 0, "Expected zero byte at offset \(offset) for a stubbed field (D-09)")
        }
    }

    // MARK: - Non-zero position/drift regression (SDK-05)

    /// Regression guard for the ARKit position now flowing through the
    /// encoder (06.3-02 Task 2): a packet with non-zero `px`/`py`/`pz` and
    /// `driftConfidence` must produce non-zero bytes in the position region
    /// (offsets 21-26, float16) and the drift region (offsets 27-30,
    /// float32), while offsets 0-20 (schema/seq/timestamp/quaternion) and
    /// the touch region (31-35) stay consistent with the unchanged D-14
    /// layout — the complement of `test_quaternionOnlyPacket_writesZeroAtStubbedOffsets`'s
    /// zero-stub guarantee. Proves the frozen wire schema still carries real
    /// position/drift correctly without any change to `SensorPacketEncoder.swift`.
    func test_nonZeroPositionAndDrift_writesExpectedBytesAtPositionOffsets() {
        let packet = SensorPacket(
            seq: 42,
            timestamp: 123456,
            qw: 1, qx: 0, qy: 0, qz: 0,
            px: 0.5, py: -0.25, pz: 1.0,
            driftConfidence: 0.5,
            touchActive: true, touchX: 0.25, touchY: 0.75
        )

        var buf = SensorPacketEncoder.makeBuffer()
        SensorPacketEncoder.encodePacket(packet, into: &buf)
        let bytes = [UInt8](buf)

        XCTAssertEqual(bytes.count, SensorPacketEncoder.bufSize)

        // offset 0: schema version.
        XCTAssertEqual(bytes[0], 1)

        // offsets 21-26: px/py/pz (float16 each), must NOT be all-zero given
        // the non-zero position values above.
        let positionBytes = bytes[21..<27]
        XCTAssertTrue(positionBytes.contains { $0 != 0 }, "Expected non-zero bytes in the position region (offsets 21-26) for non-zero px/py/pz")

        // offset 27-30: driftConfidence (float32), must NOT be all-zero
        // given driftConfidence = 0.5.
        let driftBytes = bytes[27..<31]
        XCTAssertTrue(driftBytes.contains { $0 != 0 }, "Expected non-zero bytes in the drift region (offsets 27-30) for driftConfidence 0.5")

        // offset 31: touchActive flag — sanity-checks the touch region
        // wasn't disturbed by the position/drift encoding path.
        XCTAssertEqual(bytes[31], 1)

        // Decode the float16 position triple directly to confirm the exact
        // values round-trip (not just "some non-zero byte").
        func decodeFloat16(_ lo: UInt8, _ hi: UInt8) -> Float {
            let bits = UInt16(lo) | (UInt16(hi) << 8)
            return Float(Float16(bitPattern: bits))
        }
        let decodedPx = decodeFloat16(bytes[21], bytes[22])
        let decodedPy = decodeFloat16(bytes[23], bytes[24])
        let decodedPz = decodeFloat16(bytes[25], bytes[26])
        XCTAssertEqual(decodedPx, 0.5, accuracy: 0.001)
        XCTAssertEqual(decodedPy, -0.25, accuracy: 0.001)
        XCTAssertEqual(decodedPz, 1.0, accuracy: 0.001)

        // Decode the float32 driftConfidence to confirm the exact value.
        let driftBits = UInt32(bytes[27]) | (UInt32(bytes[28]) << 8) | (UInt32(bytes[29]) << 16) | (UInt32(bytes[30]) << 24)
        let decodedDrift = Float32(bitPattern: driftBits)
        XCTAssertEqual(decodedDrift, 0.5, accuracy: 0.0001)
    }

    // MARK: - Fixture loading

    private struct FixtureInput: Decodable {
        let seq: Int
        let timestamp: Double
        let qw: Double?
        let qx: Double?
        let qy: Double?
        let qz: Double?
        let dx: Double?
        let dy: Double?
        let dz: Double?
        let px: Double?
        let py: Double?
        let pz: Double?
        let driftConfidence: Double?
        let touchActive: Bool
        let touchX: Double?
        let touchY: Double?

        /// Missing/`null` fields (e.g. a NaN quaternion component,
        /// serialized as `null` by `JSON.stringify`) become `Double.nan`
        /// here, so `SensorPacketEncoder`'s `safeFloat` guard exercises the
        /// exact NaN -> 0 sanitisation path the fixture is testing for.
        func asSensorPacket() -> SensorPacket {
            SensorPacket(
                seq: seq,
                timestamp: timestamp,
                qw: qw ?? .nan,
                qx: qx ?? .nan,
                qy: qy ?? .nan,
                qz: qz ?? .nan,
                dx: dx ?? .nan,
                dy: dy ?? .nan,
                dz: dz ?? .nan,
                px: px ?? .nan,
                py: py ?? .nan,
                pz: pz ?? .nan,
                driftConfidence: driftConfidence ?? .nan,
                touchActive: touchActive,
                touchX: touchX ?? .nan,
                touchY: touchY ?? .nan
            )
        }
    }

    private struct FixtureEntry: Decodable {
        let name: String
        let input: FixtureInput
        let bytesHex: String
    }

    private func loadFixtureEntries() throws -> [FixtureEntry] {
        let data = try loadFixtureData()
        return try JSONDecoder().decode([FixtureEntry].self, from: data)
    }

    private func loadFixtureData() throws -> Data {
        let bundle = Bundle(for: SensorPacketEncoderTests.self)

        if let url = bundle.url(forResource: "packet_v1_fixture", withExtension: "json", subdirectory: "Fixtures") {
            return try Data(contentsOf: url)
        }
        if let url = bundle.url(forResource: "packet_v1_fixture", withExtension: "json") {
            return try Data(contentsOf: url)
        }
        // Last resort: some Xcode synced-group configurations flatten or
        // relocate resources unpredictably — search the bundle on disk.
        if let resourcePath = bundle.resourcePath {
            let fileManager = FileManager.default
            if let enumerator = fileManager.enumerator(atPath: resourcePath) {
                for case let path as String in enumerator where path.hasSuffix("packet_v1_fixture.json") {
                    return try Data(contentsOf: URL(fileURLWithPath: resourcePath).appendingPathComponent(path))
                }
            }
        }
        throw XCTSkip("packet_v1_fixture.json not found in test bundle — run Task 1's fixture generation first")
    }

    private func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
