/**
 * encode.test.ts — RED-phase tests for the 36-byte binary sensor packet encoder.
 *
 * These tests define the exact wire contract (schema v1, D-14) that Phase 6 decodes.
 * They must FAIL before encode.ts is created (RED), then all pass after (GREEN).
 */
import { describe, it, expect } from 'vitest';
import { getFloat16 } from '@petamoriken/float16';
import {
  encodePacket,
  safeFloat,
  computeCalibration,
  SCHEMA_VERSION,
  BUF_SIZE,
} from '../src/sensor/encode';
import type { SensorPacket } from '../src/types';

/** A minimal valid packet with zero motion, used as a base for most tests. */
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
// encodePacket — byte layout (D-14)
// ---------------------------------------------------------------------------

describe('encodePacket — byte count', () => {
  it('returns a Uint8Array of exactly 36 bytes', () => {
    const result = encodePacket(basePkt);
    expect(result.byteLength).toBe(36);
  });
});

describe('encodePacket — version byte', () => {
  it('offset 0 is schema version 1', () => {
    const result = encodePacket(basePkt);
    expect(result[0]).toBe(1);
  });
});

describe('encodePacket — float16 quaternion', () => {
  it('qw round-trips within ±0.002', () => {
    const pkt: SensorPacket = { ...basePkt, qw: 0.707 };
    const result = encodePacket(pkt);
    const view = new DataView(result.buffer, result.byteOffset);
    const recovered = getFloat16(view, 7, true);
    expect(Math.abs(recovered - 0.707)).toBeLessThan(0.002);
  });
});

describe('encodePacket — seq wrapping', () => {
  it('seq 65536 wraps to uint16 0 at offset 1', () => {
    const pkt: SensorPacket = { ...basePkt, seq: 65536 };
    const result = encodePacket(pkt);
    const view = new DataView(result.buffer, result.byteOffset);
    expect(view.getUint16(1, true)).toBe(0);
  });

  it('seq 65537 wraps to uint16 1 at offset 1', () => {
    const pkt: SensorPacket = { ...basePkt, seq: 65537 };
    const result = encodePacket(pkt);
    const view = new DataView(result.buffer, result.byteOffset);
    expect(view.getUint16(1, true)).toBe(1);
  });
});

describe('encodePacket — touch encoding', () => {
  it('touchActive true → byte 31 === 1', () => {
    const pkt: SensorPacket = { ...basePkt, touchActive: true, touchX: 0.5, touchY: 0.0 };
    const result = encodePacket(pkt);
    expect(result[31]).toBe(1);
  });

  it('touchX 0.5 → uint16 at offset 32 ≈ 32768 (±1)', () => {
    const pkt: SensorPacket = { ...basePkt, touchActive: true, touchX: 0.5, touchY: 0.0 };
    const result = encodePacket(pkt);
    const view = new DataView(result.buffer, result.byteOffset);
    const tx = view.getUint16(32, true);
    expect(Math.abs(tx - 32768)).toBeLessThanOrEqual(1);
  });

  it('touchActive false → byte 31 === 0', () => {
    const pkt: SensorPacket = { ...basePkt, touchActive: false };
    const result = encodePacket(pkt);
    expect(result[31]).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// safeFloat — input sanitisation (V5)
// ---------------------------------------------------------------------------

describe('safeFloat', () => {
  it('safeFloat(NaN) === 0', () => {
    expect(safeFloat(NaN)).toBe(0);
  });

  it('safeFloat(Infinity) === 0', () => {
    expect(safeFloat(Infinity)).toBe(0);
  });

  it('safeFloat(-Infinity) === 0', () => {
    expect(safeFloat(-Infinity)).toBe(0);
  });

  it('safeFloat(null) === 0', () => {
    expect(safeFloat(null as unknown as number)).toBe(0);
  });

  it('safeFloat(undefined) === 0', () => {
    expect(safeFloat(undefined as unknown as number)).toBe(0);
  });

  it('safeFloat(1.5) === 1.5', () => {
    expect(safeFloat(1.5)).toBe(1.5);
  });

  it('NaN qw encodes to finite float16 value 0 (T-05-01 mitigation)', () => {
    const pkt: SensorPacket = { ...basePkt, qw: NaN };
    const result = encodePacket(pkt);
    const view = new DataView(result.buffer, result.byteOffset);
    const qw = getFloat16(view, 7, true);
    expect(isFinite(qw)).toBe(true);
    expect(qw).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// computeCalibration — pure math, no DeviceMotion dependency
// ---------------------------------------------------------------------------

describe('computeCalibration', () => {
  it('constant samples → zero variance → threshold 0, kalmanQ 0', () => {
    const result = computeCalibration([1, 1, 1, 1, 1]);
    expect(result.threshold).toBe(0);
    expect(result.kalmanQ).toBe(0);
  });

  it('[0, 2] → variance 1 → threshold 2, kalmanQ 0.1', () => {
    // mean = 1, population variance = ((0-1)² + (2-1)²) / 2 = 1
    const result = computeCalibration([0, 2]);
    expect(result.threshold).toBeCloseTo(2, 5);
    expect(result.kalmanQ).toBeCloseTo(0.1, 5);
  });
});

// ---------------------------------------------------------------------------
// Module constants
// ---------------------------------------------------------------------------

describe('module constants', () => {
  it('SCHEMA_VERSION is 1', () => {
    expect(SCHEMA_VERSION).toBe(1);
  });

  it('BUF_SIZE is 36', () => {
    expect(BUF_SIZE).toBe(36);
  });
});
