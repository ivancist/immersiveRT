/**
 * encode.ts — Binary sensor packet encoder (schema v1, D-14).
 *
 * Writes a SensorPacket into a fixed 36-byte DataView layout using:
 *   - uint8  for schema version and touch flag
 *   - uint16 for seq (mod 65536), touchX, touchY
 *   - uint32 for timestamp
 *   - float16 (via @petamoriken/float16) for quaternion + displacement + position
 *   - float32 for driftConfidence
 *
 * All float fields are sanitised through safeFloat() before writing (V5 — T-05-01).
 * The shared ArrayBuffer is allocated once at module scope (Pitfall 5 — no per-tick GC).
 */

import { setFloat16 } from '@petamoriken/float16';
import type { SensorPacket } from '../types';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/** Schema version written into byte 0 of every packet. */
export const SCHEMA_VERSION = 1;

/** Total byte size of one encoded packet (D-14). */
export const BUF_SIZE = 36;

/**
 * Module-level reusable ArrayBuffer — allocated ONCE, never inside encodePacket.
 * Callers that need to send the buffer over WebRTC must copy before the next encode.
 * (Pitfall 5: per-tick allocation at 60 Hz causes measurable GC pressure)
 */
export const _packetBuf = new ArrayBuffer(BUF_SIZE);

// ---------------------------------------------------------------------------
// Input sanitisation (V5 / T-05-01)
// ---------------------------------------------------------------------------

/**
 * Returns `fallback` (default 0) when `v` is null, undefined, NaN, or ±Infinity.
 * Applied to every float field before the DataView write so the Phase 6 decoder
 * never reads a poison float16 byte pattern.
 */
export function safeFloat(v: number | null | undefined, fallback = 0): number {
  if (v == null || !isFinite(v as number)) return fallback;
  return v as number;
}

// ---------------------------------------------------------------------------
// Packet encoder
// ---------------------------------------------------------------------------

/**
 * Encode `pkt` into `buf` (defaults to the module-level `_packetBuf`) using
 * the D-14 fixed-offset schema v1 layout (little-endian throughout).
 *
 * Returns a Uint8Array VIEW over `buf` — not a copy.  Callers sending the
 * bytes over an unreliable WebRTC data channel must copy the Uint8Array
 * (e.g. `result.slice()`) if they need to hold it past the next encode call.
 *
 * D-14 byte layout:
 *   offset  0 : uint8   schema version (= 1)
 *   offset  1 : uint16  seq mod 65536
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
 *   offset 31 : uint8   touchActive (1 or 0)
 *   offset 32 : uint16  touchX (round(clamp01(x) * 65535))
 *   offset 34 : uint16  touchY (round(clamp01(y) * 65535))
 *   total  36 bytes
 */
export function encodePacket(
  pkt: SensorPacket,
  buf: ArrayBuffer = _packetBuf,
): Uint8Array {
  const view = new DataView(buf);

  // offset 0: schema version
  view.setUint8(0, SCHEMA_VERSION);

  // offset 1: sequence counter (wraps at 65536)
  view.setUint16(1, pkt.seq % 65536, /* littleEndian */ true);

  // offset 3: timestamp (uint32, ms since session start)
  view.setUint32(3, safeFloat(pkt.timestamp) >>> 0, true);

  // offsets 7,9,11,13: orientation quaternion (float16, OS-fused primary)
  setFloat16(view, 7,  safeFloat(pkt.qw), true);
  setFloat16(view, 9,  safeFloat(pkt.qx), true);
  setFloat16(view, 11, safeFloat(pkt.qy), true);
  setFloat16(view, 13, safeFloat(pkt.qz), true);

  // offsets 15,17,19: gesture displacement since last ZUPT reset (float16)
  setFloat16(view, 15, safeFloat(pkt.dx), true);
  setFloat16(view, 17, safeFloat(pkt.dy), true);
  setFloat16(view, 19, safeFloat(pkt.dz), true);

  // offsets 21,23,25: dead-reckoning position (float16)
  setFloat16(view, 21, safeFloat(pkt.px), true);
  setFloat16(view, 23, safeFloat(pkt.py), true);
  setFloat16(view, 25, safeFloat(pkt.pz), true);

  // offset 27: drift confidence (float32)
  view.setFloat32(27, safeFloat(pkt.driftConfidence), true);

  // offset 31: touch active flag (uint8)
  view.setUint8(31, pkt.touchActive ? 1 : 0);

  // offsets 32,34: normalized touch coordinates (uint16, clamped to [0,1])
  const clampX = Math.max(0, Math.min(1, safeFloat(pkt.touchX)));
  view.setUint16(32, Math.round(clampX * 65535), true);

  const clampY = Math.max(0, Math.min(1, safeFloat(pkt.touchY)));
  view.setUint16(34, Math.round(clampY * 65535), true);

  return new Uint8Array(buf);
}

// ---------------------------------------------------------------------------
// Calibration — pure math, unit-testable in jsdom (D-08)
// ---------------------------------------------------------------------------

/**
 * Derive ZUPT and Kalman parameters from a hold-still accel-magnitude sample window.
 *
 * Pure function — no side effects, no DOM access.
 * @param samples  Array of |a| magnitudes collected during the hold-still window.
 * @returns
 *   threshold — ZUPT variance threshold (population variance × 2, i.e. 2× noise-floor headroom)
 *   kalmanQ   — Kalman process-noise Q (population variance × 0.1)
 *
 * (RESEARCH Pattern 9 / Pitfall 6)
 */
export function computeCalibration(
  samples: number[],
): { threshold: number; kalmanQ: number } {
  if (samples.length === 0) return { threshold: 0, kalmanQ: 0 };

  const n = samples.length;
  const mean = samples.reduce((sum, v) => sum + v, 0) / n;
  const variance = samples.reduce((sum, v) => sum + (v - mean) ** 2, 0) / n;

  return {
    threshold: variance * 2,
    kalmanQ: variance * 0.1,
  };
}

// ---------------------------------------------------------------------------
// Calibration — device-motion wrapper (thin; delegates math to computeCalibration)
// ---------------------------------------------------------------------------

/** Duration of the hold-still calibration window in milliseconds. */
const DURATION_MS = 3000;

/**
 * Attach a `devicemotion` listener for DURATION_MS, collect linear-acceleration
 * magnitudes (safeFloat-guarded), then remove the listener and call `onComplete`
 * with the derived ZUPT threshold and Kalman Q.
 *
 * The numeric core lives in computeCalibration so calibration math is fully
 * unit-testable without DeviceMotionEvent in jsdom (D-08).
 */
export function runCalibration(
  onComplete: (threshold: number, kalmanQ: number) => void,
): void {
  const samples: number[] = [];

  const handler = (e: DeviceMotionEvent): void => {
    const ag = e.acceleration;
    if (ag) {
      const mag = Math.hypot(
        safeFloat(ag.x),
        safeFloat(ag.y),
        safeFloat(ag.z),
      );
      samples.push(mag);
    }
  };

  window.addEventListener('devicemotion', handler);

  setTimeout(() => {
    window.removeEventListener('devicemotion', handler);
    const { threshold, kalmanQ } = computeCalibration(samples);
    onComplete(threshold, kalmanQ);
  }, DURATION_MS);
}
