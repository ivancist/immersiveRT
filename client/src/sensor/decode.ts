/**
 * decode.ts — Binary sensor packet decoder (schema v1, D-14).
 *
 * Exact inverse of encode.ts: reads the same fixed 36-byte DataView layout
 * using getFloat16 from @petamoriken/float16 (little-endian throughout).
 *
 * Exports:
 *   decodePacket(buf)  — returns SensorPacket or null for malformed/wrong-version input
 *   isNewerSeq(n, l)   — RFC 1982 half-distance uint16 comparison (DESK-03, D-09)
 *   isSafePacket(pkt)  — isFinite guard on quaternion fields (security V5, T-06-06)
 *
 * Threat mitigations applied here (T-06-03, T-06-04, T-06-06):
 *   - buf.byteLength < BUF_SIZE → null (no OOB read)
 *   - byte 0 !== SCHEMA_VERSION → null (version mismatch)
 *   - isSafePacket rejects non-finite quaternion components before they reach THREE
 */

import { getFloat16 } from '@petamoriken/float16';
import { SCHEMA_VERSION, BUF_SIZE } from './encode';
import type { SensorPacket } from '../types';

// ---------------------------------------------------------------------------
// Packet decoder (T-06-03, T-06-04)
// ---------------------------------------------------------------------------

/**
 * Decode a 36-byte D-14 schema v1 ArrayBuffer into a SensorPacket.
 *
 * Returns null when:
 *   - buf.byteLength < BUF_SIZE (truncated/garbage — T-06-03)
 *   - byte 0 !== SCHEMA_VERSION (version mismatch — T-06-04)
 *
 * D-14 byte layout (mirrors encode.ts exactly, all reads little-endian):
 *   offset  0 : uint8   schema version (= 1)
 *   offset  1 : uint16  seq
 *   offset  3 : uint32  timestamp (ms since session start)
 *   offset  7 : float16 qw
 *   offset  9 : float16 qx
 *   offset 11 : float16 qy
 *   offset 13 : float16 qz
 *   offset 15 : float16 dx (gesture displacement x)
 *   offset 17 : float16 dy
 *   offset 19 : float16 dz
 *   offset 21 : float16 px (dead-reckoning position x)
 *   offset 23 : float16 py
 *   offset 25 : float16 pz
 *   offset 27 : float32 driftConfidence
 *   offset 31 : uint8   touchActive (1 = true, 0 = false)
 *   offset 32 : uint16  touchX (uint16 / 65535 = normalized [0,1])
 *   offset 34 : uint16  touchY (uint16 / 65535 = normalized [0,1])
 *   total  36 bytes
 */
export function decodePacket(buf: ArrayBuffer): SensorPacket | null {
  if (buf.byteLength < BUF_SIZE) return null;          // T-06-03: truncated packet
  const view = new DataView(buf);
  if (view.getUint8(0) !== SCHEMA_VERSION) return null; // T-06-04: version mismatch

  return {
    seq:             view.getUint16(1, true),
    timestamp:       view.getUint32(3, true),
    qw: getFloat16(view, 7,  true),
    qx: getFloat16(view, 9,  true),
    qy: getFloat16(view, 11, true),
    qz: getFloat16(view, 13, true),
    dx: getFloat16(view, 15, true),
    dy: getFloat16(view, 17, true),
    dz: getFloat16(view, 19, true),
    px: getFloat16(view, 21, true),
    py: getFloat16(view, 23, true),
    pz: getFloat16(view, 25, true),
    driftConfidence: view.getFloat32(27, true),
    touchActive:     view.getUint8(31) === 1,
    touchX:          view.getUint16(32, true) / 65535,
    touchY:          view.getUint16(34, true) / 65535,
  };
}

// ---------------------------------------------------------------------------
// Sequence-drop predicate (DESK-03, D-09, T-06-05)
// ---------------------------------------------------------------------------

/**
 * Returns true if `newSeq` is strictly newer than `lastSeq` using RFC 1982
 * half-distance uint16 serial number arithmetic.
 *
 * Handles uint16 wraparound (65535 → 0) correctly.
 *
 * Cases:
 *   newSeq === lastSeq   → diff = 0          → false (duplicate)
 *   normal increment     → diff in [1,32767]  → true  (accept)
 *   backwards/old packet → diff in [32768,…]  → false (drop)
 *   wraparound (e.g. lastSeq=65535, newSeq=0) → diff = 1 → true (accept)
 */
export function isNewerSeq(newSeq: number, lastSeq: number): boolean {
  const diff = (newSeq - lastSeq) & 0xFFFF;
  return diff > 0 && diff <= 32767;
}

// ---------------------------------------------------------------------------
// Finite-guard (security V5, T-06-06)
// ---------------------------------------------------------------------------

/**
 * Returns true only if all quaternion components are finite (not NaN, not ±Infinity).
 *
 * Call this before applying a decoded packet's orientation to THREE.Quaternion.set()
 * to prevent non-finite values from poisoning the render state.
 *
 * Only quaternion fields are checked — non-finite displacement/position fields
 * produce visible glitches but not render-breaking NaN propagation.
 */
export function isSafePacket(pkt: SensorPacket): boolean {
  return isFinite(pkt.qw) && isFinite(pkt.qx) && isFinite(pkt.qy) && isFinite(pkt.qz);
}
