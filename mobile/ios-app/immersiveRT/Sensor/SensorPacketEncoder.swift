import Foundation

/// Mirrors `client/src/types.ts`'s `SensorPacket` interface — the wire contract
/// consumed by the desktop `decode.ts` (Phase 6, unchanged).
///
/// Per D-09, only orientation (`qw`/`qx`/`qy`/`qz`) carries real CoreMotion data
/// in 06.2. Gesture displacement (`dx`/`dy`/`dz`), dead-reckoning position
/// (`px`/`py`/`pz`), and `driftConfidence` default to zero so call sites that
/// only set the quaternion automatically produce the stubbed-field layout
/// `SensorPacketEncoder` writes to the wire — real position data lands in
/// 06.3's ARKit integration.
struct SensorPacket {
    var seq: Int
    var timestamp: Double

    var qw: Double
    var qx: Double
    var qy: Double
    var qz: Double

    var dx: Double = 0
    var dy: Double = 0
    var dz: Double = 0

    var px: Double = 0
    var py: Double = 0
    var pz: Double = 0

    var driftConfidence: Double = 0

    var touchActive: Bool = false
    var touchX: Double = 0
    var touchY: Double = 0
}

/// Returns `fallback` (default 0) when `v` is NaN or ±Infinity — mirrors
/// `encode.ts`'s `safeFloat`. Applied to every float field before writing so a
/// transient CoreMotion glitch can never produce a poison float16 byte pattern
/// the desktop decoder reads (V5, T-06.2-03).
func safeFloat(_ v: Double, fallback: Double = 0) -> Double {
    guard v.isFinite else { return fallback }
    return v
}

/// Byte-identical Swift port of `client/src/sensor/encode.ts`'s `encodePacket`
/// (D-14 schema v1, 36-byte fixed layout, little-endian throughout):
///
/// ```
/// offset  0 : uint8   schema version (= 1)
/// offset  1 : uint16  seq mod 65536
/// offset  3 : uint32  timestamp (ms since session start)
/// offset  7 : float16 qw
/// offset  9 : float16 qx
/// offset 11 : float16 qy
/// offset 13 : float16 qz
/// offset 15 : float16 dx (gesture displacement — 0 in 06.2, D-09)
/// offset 17 : float16 dy
/// offset 19 : float16 dz
/// offset 21 : float16 px (dead-reckoning position — 0 in 06.2, D-09)
/// offset 23 : float16 py
/// offset 25 : float16 pz
/// offset 27 : float32 driftConfidence (0 in 06.2, D-09)
/// offset 31 : uint8   touchActive (1 or 0)
/// offset 32 : uint16  touchX (round(clamp01(x) * 65535))
/// offset 34 : uint16  touchY (round(clamp01(y) * 65535))
/// total  36 bytes
/// ```
///
/// The desktop `decode.ts` (Phase 6, unchanged) is the fixed consumer of this
/// layout — any byte drift silently corrupts every rendered frame, so this
/// encoder must never diverge from `encode.ts`'s output for the same input.
enum SensorPacketEncoder {
    /// Total byte size of one encoded packet (D-14 schema v1).
    static let bufSize = 36

    /// Creates a buffer pre-reserved at `bufSize` capacity, ready to be reused
    /// across calls to `encodePacket(_:into:)` without per-tick heap
    /// allocation (mirrors `encode.ts`'s module-scope `_packetBuf` reuse
    /// pattern — Pitfall 5, no per-tick GC at 60Hz).
    ///
    /// Callers must copy the buffer's contents before the next `encodePacket`
    /// call if they need to retain the bytes past that point — `encodePacket`
    /// resets and overwrites `buf` in place on every call.
    static func makeBuffer() -> Data {
        Data(capacity: bufSize)
    }

    /// Encodes `pkt` into `buf` using the D-14 layout, resetting `buf` first
    /// (`removeAll(keepingCapacity:)`) so the same buffer can be reused every
    /// tick without reallocating.
    static func encodePacket(_ pkt: SensorPacket, into buf: inout Data) {
        buf.removeAll(keepingCapacity: true)

        // offset 0: schema version
        buf.append(1)

        // offset 1: sequence counter, wraps at 65536 (uint16, little-endian).
        // Matches encode.ts's `pkt.seq % 65536` for non-negative seq values.
        let seqValue = UInt16(truncatingIfNeeded: pkt.seq)
        withUnsafeBytes(of: seqValue.littleEndian) { buf.append(contentsOf: $0) }

        // offset 3: timestamp (uint32, ms since session start, little-endian).
        // Matches encode.ts's `safeFloat(pkt.timestamp) >>> 0` (truncate toward
        // zero, then wrap to uint32 range).
        let sanitizedTimestamp = safeFloat(pkt.timestamp)
        let timestampValue = UInt32(truncatingIfNeeded: Int64(sanitizedTimestamp.rounded(.towardZero)))
        withUnsafeBytes(of: timestampValue.littleEndian) { buf.append(contentsOf: $0) }

        // offsets 7,9,11,13,15,17,19,21,23,25: quaternion + displacement + position (float16).
        for value in [pkt.qw, pkt.qx, pkt.qy, pkt.qz, pkt.dx, pkt.dy, pkt.dz, pkt.px, pkt.py, pkt.pz] {
            let f16 = Float16(safeFloat(value))
            withUnsafeBytes(of: f16.bitPattern.littleEndian) { buf.append(contentsOf: $0) }
        }

        // offset 27: drift confidence (float32, little-endian).
        let driftValue = Float32(safeFloat(pkt.driftConfidence))
        withUnsafeBytes(of: driftValue.bitPattern.littleEndian) { buf.append(contentsOf: $0) }

        // offset 31: touch active flag (uint8).
        buf.append(pkt.touchActive ? 1 : 0)

        // offsets 32,34: normalized touch coordinates, clamped to [0,1] THEN
        // scaled by 65535 THEN rounded (order matters for edge-case
        // correctness — matches encode.ts lines 118-123).
        let clampX = min(1, max(0, safeFloat(pkt.touchX)))
        let tx = UInt16((clampX * 65535).rounded())
        withUnsafeBytes(of: tx.littleEndian) { buf.append(contentsOf: $0) }

        let clampY = min(1, max(0, safeFloat(pkt.touchY)))
        let ty = UInt16((clampY * 65535).rounded())
        withUnsafeBytes(of: ty.littleEndian) { buf.append(contentsOf: $0) }
    }
}
