/**
 * decode.test.ts — RED-phase tests for the binary sensor packet decoder.
 *
 * Tests the exact inverse of encode.ts (D-14 schema v1).
 * These tests MUST FAIL before decode.ts is created (RED), then all pass after (GREEN).
 *
 * Coverage:
 *   - decodePacket roundtrip (seq, timestamp, qw float16 tolerance, touch flags/coords)
 *   - decodePacket guards (truncated buffer, wrong schema version)
 *   - isSafePacket (NaN/Infinity rejection, finite quaternion acceptance)
 */
import { describe, it, expect } from 'vitest';
import { decodePacket, isSafePacket } from '../src/sensor/decode';
import { encodePacket } from '../src/sensor/encode';
import type { SensorPacket } from '../src/types';

/** Minimal valid packet with identity quaternion, used as a base for most tests. */
const basePkt: SensorPacket = {
  seq: 1,
  timestamp: 1000,
  qw: 1.0,
  qx: 0.0,
  qy: 0.0,
  qz: 0.0,
  dx: 0.0,
  dy: 0.0,
  dz: 0.0,
  px: 0.0,
  py: 0.0,
  pz: 0.0,
  driftConfidence: 1.0,
  touchActive: false,
  touchX: 0.0,
  touchY: 0.0,
};

// ---------------------------------------------------------------------------
// decodePacket — roundtrip
// ---------------------------------------------------------------------------

describe('decodePacket — roundtrip: seq and timestamp', () => {
  it('recovers seq exactly', () => {
    const pkt = { ...basePkt, seq: 42 };
    const buf = encodePacket(pkt).buffer as ArrayBuffer;
    const decoded = decodePacket(buf);
    expect(decoded).not.toBeNull();
    expect(decoded!.seq).toBe(42);
  });

  it('recovers timestamp exactly', () => {
    const pkt = { ...basePkt, timestamp: 99999 };
    const buf = encodePacket(pkt).buffer as ArrayBuffer;
    const decoded = decodePacket(buf);
    expect(decoded).not.toBeNull();
    expect(decoded!.timestamp).toBe(99999);
  });
});

describe('decodePacket — roundtrip: quaternion (float16 precision)', () => {
  it('recovers qw = 0.707 within ±0.002', () => {
    const pkt = { ...basePkt, qw: 0.707 };
    const buf = encodePacket(pkt).buffer as ArrayBuffer;
    const decoded = decodePacket(buf);
    expect(decoded).not.toBeNull();
    expect(decoded!.qw).toBeCloseTo(0.707, 2);
  });

  it('recovers qx = 0.5 within float16 tolerance (toBeCloseTo 2)', () => {
    const pkt = { ...basePkt, qx: 0.5 };
    const buf = encodePacket(pkt).buffer as ArrayBuffer;
    const decoded = decodePacket(buf);
    expect(decoded).not.toBeNull();
    expect(decoded!.qx).toBeCloseTo(0.5, 2);
  });
});

describe('decodePacket — roundtrip: touch flags and coordinates', () => {
  it('recovers touchActive = true', () => {
    const pkt = { ...basePkt, touchActive: true, touchX: 0.5, touchY: 0.25 };
    const buf = encodePacket(pkt).buffer as ArrayBuffer;
    const decoded = decodePacket(buf);
    expect(decoded).not.toBeNull();
    expect(decoded!.touchActive).toBe(true);
  });

  it('recovers touchActive = false', () => {
    const pkt = { ...basePkt, touchActive: false };
    const buf = encodePacket(pkt).buffer as ArrayBuffer;
    const decoded = decodePacket(buf);
    expect(decoded).not.toBeNull();
    expect(decoded!.touchActive).toBe(false);
  });

  it('recovers touchX = 0.5 within uint16 tolerance (toBeCloseTo 2)', () => {
    const pkt = { ...basePkt, touchActive: true, touchX: 0.5, touchY: 0.0 };
    const buf = encodePacket(pkt).buffer as ArrayBuffer;
    const decoded = decodePacket(buf);
    expect(decoded).not.toBeNull();
    expect(decoded!.touchX).toBeCloseTo(0.5, 2);
  });

  it('recovers touchY = 0.75 within uint16 tolerance (toBeCloseTo 2)', () => {
    const pkt = { ...basePkt, touchActive: true, touchX: 0.0, touchY: 0.75 };
    const buf = encodePacket(pkt).buffer as ArrayBuffer;
    const decoded = decodePacket(buf);
    expect(decoded).not.toBeNull();
    expect(decoded!.touchY).toBeCloseTo(0.75, 2);
  });
});

// ---------------------------------------------------------------------------
// decodePacket — guards (T-06-03, T-06-04)
// ---------------------------------------------------------------------------

describe('decodePacket — guards', () => {
  it('returns null for a truncated buffer (10 bytes)', () => {
    expect(decodePacket(new ArrayBuffer(10))).toBeNull();
  });

  it('returns null when byte 0 is not SCHEMA_VERSION (mutated to 99)', () => {
    // Must slice to get a copy — avoids mutating the shared module-level _packetBuf
    const buf = encodePacket(basePkt).buffer.slice(0) as ArrayBuffer;
    new DataView(buf).setUint8(0, 99);
    expect(decodePacket(buf)).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// isSafePacket — finite-guard (T-06-06, security V5)
// ---------------------------------------------------------------------------

describe('isSafePacket', () => {
  it('returns false when qw is NaN', () => {
    const pkt: SensorPacket = { ...basePkt, qw: NaN };
    expect(isSafePacket(pkt)).toBe(false);
  });

  it('returns false when qx is NaN', () => {
    const pkt: SensorPacket = { ...basePkt, qx: NaN };
    expect(isSafePacket(pkt)).toBe(false);
  });

  it('returns false when qy is Infinity', () => {
    const pkt: SensorPacket = { ...basePkt, qy: Infinity };
    expect(isSafePacket(pkt)).toBe(false);
  });

  it('returns false when qz is -Infinity', () => {
    const pkt: SensorPacket = { ...basePkt, qz: -Infinity };
    expect(isSafePacket(pkt)).toBe(false);
  });

  it('returns true for a fully finite quaternion', () => {
    const pkt: SensorPacket = { ...basePkt, qw: 0.707, qx: 0.0, qy: 0.707, qz: 0.0 };
    expect(isSafePacket(pkt)).toBe(true);
  });
});
