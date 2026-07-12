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
