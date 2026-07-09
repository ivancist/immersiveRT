/**
 * kalman.test.ts — RED-phase tests for Kalman1D (SENS-04).
 *
 * Kalman1D is a per-axis dead-reckoning filter:
 *   - predict(accel, dt) integrates acceleration → velocity → position and
 *     grows covariance P by Q·dt.
 *   - resetVelocity() zeroes velocity and reduces P (Kalman gain update).
 *   - driftConfidence() returns a scalar in [0, 1]: near 1 after resetVelocity,
 *     decaying as P grows through subsequent predict() calls.
 *   - NaN inputs must not corrupt accumulated pos/vel state (T-05-01).
 *
 * These tests must FAIL before kalman.ts is created (RED), then all pass (GREEN).
 */
import { describe, it, expect, beforeEach } from 'vitest';
import { Kalman1D } from '../src/sensor/kalman';

// ---------------------------------------------------------------------------
// Integration — predict() accumulates velocity and position
// ---------------------------------------------------------------------------

describe('Kalman1D — integration', () => {
  it('starting at rest, repeated predict(1.0, 0.1) increases position monotonically', () => {
    const k = new Kalman1D();
    const positions: number[] = [];
    for (let i = 0; i < 10; i++) {
      positions.push(k.predict(1.0, 0.1)); // 1 m/s² over 0.1s steps
    }
    // Each call should yield a higher position than the previous
    for (let i = 1; i < positions.length; i++) {
      expect(positions[i]).toBeGreaterThan(positions[i - 1]);
    }
  });

  it('zero acceleration does not change position (once velocity is zero)', () => {
    const k = new Kalman1D();
    // Start with a reset to ensure velocity is 0
    k.resetVelocity();
    const pos1 = k.predict(0, 0.1);
    const pos2 = k.predict(0, 0.1);
    // With zero accel and zero velocity, position must not change
    expect(pos2).toBeCloseTo(pos1, 10);
  });

  it('predict returns a finite number for valid inputs', () => {
    const k = new Kalman1D();
    const result = k.predict(9.81, 0.016); // ~60Hz tick
    expect(Number.isFinite(result)).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// resetVelocity — zeroes velocity and shrinks covariance P
// ---------------------------------------------------------------------------

describe('Kalman1D — resetVelocity', () => {
  it('after resetVelocity, predict(0, dt) does not change position', () => {
    const k = new Kalman1D();
    // Build up some velocity through several predict calls
    for (let i = 0; i < 5; i++) {
      k.predict(1.0, 0.1);
    }
    const posBefore = k.predict(0, 0.1); // will drift because velocity > 0

    // Reset velocity — effectively zeroes vel
    k.resetVelocity();

    // Now with zero accel, position must remain stable
    const posAfterReset = k.predict(0, 0.1);
    const posAfterReset2 = k.predict(0, 0.1);
    expect(posAfterReset2).toBeCloseTo(posAfterReset, 10);
    // Position is still greater than posBefore (we did not reset pos)
    expect(posAfterReset).toBeGreaterThanOrEqual(posBefore);
  });

  it('resetVelocity can be called multiple times without error', () => {
    const k = new Kalman1D();
    expect(() => {
      k.resetVelocity();
      k.resetVelocity();
      k.resetVelocity();
    }).not.toThrow();
  });
});

// ---------------------------------------------------------------------------
// driftConfidence — always in [0, 1]
// ---------------------------------------------------------------------------

describe('Kalman1D — driftConfidence range', () => {
  it('driftConfidence() returns a value in [0, 1] initially', () => {
    const k = new Kalman1D();
    const conf = k.driftConfidence();
    expect(conf).toBeGreaterThanOrEqual(0);
    expect(conf).toBeLessThanOrEqual(1);
  });

  it('driftConfidence() stays in [0, 1] after many predict() calls', () => {
    const k = new Kalman1D();
    for (let i = 0; i < 100; i++) {
      k.predict(1.0, 0.1);
    }
    const conf = k.driftConfidence();
    expect(conf).toBeGreaterThanOrEqual(0);
    expect(conf).toBeLessThanOrEqual(1);
  });

  it('driftConfidence() stays in [0, 1] after resetVelocity', () => {
    const k = new Kalman1D();
    for (let i = 0; i < 5; i++) {
      k.predict(1.0, 0.1);
    }
    k.resetVelocity();
    const conf = k.driftConfidence();
    expect(conf).toBeGreaterThanOrEqual(0);
    expect(conf).toBeLessThanOrEqual(1);
  });
});

// ---------------------------------------------------------------------------
// driftConfidence — decays as uncertainty P grows
// ---------------------------------------------------------------------------

describe('Kalman1D — driftConfidence decay', () => {
  it('confidence is at/near max right after resetVelocity', () => {
    const k = new Kalman1D();
    // Many predict calls grow P substantially
    for (let i = 0; i < 50; i++) {
      k.predict(1.0, 0.1);
    }
    const confBefore = k.driftConfidence();

    // Reset — P shrinks via Kalman gain update
    k.resetVelocity();
    const confAfterReset = k.driftConfidence();

    // Confidence must be higher after reset (or at least not lower)
    expect(confAfterReset).toBeGreaterThanOrEqual(confBefore);
  });

  it('confidence decreases (or stays ≤ previous) as more predict() calls grow P', () => {
    const k = new Kalman1D();
    k.resetVelocity();
    const confAfterReset = k.driftConfidence();

    // Additional predict() calls grow P → confidence should drop
    for (let i = 0; i < 20; i++) {
      k.predict(1.0, 0.1);
    }
    const confAfterDrift = k.driftConfidence();

    expect(confAfterDrift).toBeLessThanOrEqual(confAfterReset);
  });

  it('confidence after reset is strictly higher than after sustained drift (Q>0)', () => {
    const k = new Kalman1D(0.01); // nonzero Q so P grows
    // Let P grow significantly
    for (let i = 0; i < 100; i++) {
      k.predict(0, 0.1);
    }
    const confLow = k.driftConfidence();

    k.resetVelocity();
    const confHigh = k.driftConfidence();

    expect(confHigh).toBeGreaterThan(confLow);
  });
});

// ---------------------------------------------------------------------------
// NaN guard — bad sensor sample must not corrupt pos/vel (T-05-01)
// ---------------------------------------------------------------------------

describe('Kalman1D — NaN guard', () => {
  it('predict(NaN, 0.1) does not turn position into NaN', () => {
    const k = new Kalman1D();
    k.predict(1.0, 0.1); // build up some state
    k.predict(NaN, 0.1); // bad sample — must be guarded
    const pos = k.predict(0, 0.1); // state must still be finite
    expect(Number.isFinite(pos)).toBe(true);
    expect(isNaN(pos)).toBe(false);
  });

  it('predict(NaN, 0.1) does not turn velocity into NaN (next predict is stable)', () => {
    const k = new Kalman1D();
    k.predict(1.0, 0.1);
    k.predict(NaN, 0.1);
    // Two more preds — if velocity were NaN they would diverge
    const p1 = k.predict(0, 0.1);
    const p2 = k.predict(0, 0.1);
    // If vel is non-zero but finite, p2 !== p1 but both finite
    // If vel were NaN, both would be NaN
    expect(Number.isFinite(p1)).toBe(true);
    expect(Number.isFinite(p2)).toBe(true);
  });

  it('predict(Infinity, 0.1) does not corrupt state', () => {
    const k = new Kalman1D();
    k.predict(1.0, 0.1);
    k.predict(Infinity, 0.1);
    const pos = k.predict(0, 0.1);
    expect(Number.isFinite(pos)).toBe(true);
  });

  it('driftConfidence() returns finite value even after NaN predict', () => {
    const k = new Kalman1D();
    k.predict(NaN, 0.1);
    const conf = k.driftConfidence();
    expect(Number.isFinite(conf)).toBe(true);
    expect(conf).toBeGreaterThanOrEqual(0);
    expect(conf).toBeLessThanOrEqual(1);
  });
});
