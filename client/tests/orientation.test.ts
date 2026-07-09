/**
 * orientation.test.ts — RED-phase tests for the dual orientation pipeline (Plan 05-04).
 *
 * Tests the W3C Z-X-Y OS-fused primary path (eulerToQuat) and the Madgwick secondary
 * path (updateMadgwick via ahrs), including the runtime-configurable beta ramp (SENS-02)
 * and the NaN guard (T-05-01 / V5).
 *
 * These tests MUST FAIL before orientation.ts is created (RED), then all pass after (GREEN).
 */
import { describe, it, expect, beforeEach } from 'vitest';
import { eulerToQuat, updateMadgwick, ahrs, rampBeta } from '../src/sensor/orientation';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Quaternion magnitude helper. */
function quatNorm(q: { w: number; x: number; y: number; z: number }): number {
  return Math.sqrt(q.w ** 2 + q.x ** 2 + q.y ** 2 + q.z ** 2);
}

/**
 * Construct a minimal DeviceMotionEvent-shaped object for testing.
 * jsdom does not emit real motion events, so we fake the shape.
 */
function makeFakeMotionEvent(
  alpha: number,
  beta: number,
  gamma: number,
  ax = 0,
  ay = 0,
  az = 9.81,
): DeviceMotionEvent {
  return {
    rotationRate: { alpha, beta, gamma },
    accelerationIncludingGravity: { x: ax, y: ay, z: az },
  } as unknown as DeviceMotionEvent;
}

// ---------------------------------------------------------------------------
// eulerToQuat — identity / unit norm (W3C Z-X-Y primary, D-03)
// ---------------------------------------------------------------------------

describe('eulerToQuat — identity', () => {
  it('eulerToQuat(0, 0, 0) returns {w:1, x:0, y:0, z:0}', () => {
    const q = eulerToQuat(0, 0, 0);
    expect(q.w).toBeCloseTo(1, 6);
    expect(q.x).toBeCloseTo(0, 6);
    expect(q.y).toBeCloseTo(0, 6);
    expect(q.z).toBeCloseTo(0, 6);
  });
});

describe('eulerToQuat — unit norm', () => {
  it('arbitrary angles (30, 45, 60) produce unit quaternion within ±1e-6', () => {
    const q = eulerToQuat(30, 45, 60);
    const norm = quatNorm(q);
    expect(Math.abs(norm - 1)).toBeLessThan(1e-6);
  });

  it('large angles (270, 180, 90) still produce unit quaternion', () => {
    const q = eulerToQuat(270, 180, 90);
    const norm = quatNorm(q);
    expect(Math.abs(norm - 1)).toBeLessThan(1e-6);
  });
});

// ---------------------------------------------------------------------------
// eulerToQuat — known rotation (W3C Z-X-Y, Pitfall 3)
// ---------------------------------------------------------------------------

describe('eulerToQuat — known yaw', () => {
  it('alpha=90° (yaw 90° about Z) → w ≈ cos(45°) ≈ 0.7071, z ≈ sin(45°) ≈ 0.7071', () => {
    const q = eulerToQuat(90, 0, 0);
    const cos45 = Math.cos(Math.PI / 4);
    const sin45 = Math.sin(Math.PI / 4);
    // W3C Z-X-Y: pure yaw about Z should give w = cos(yaw/2), z = sin(yaw/2)
    expect(Math.abs(q.w - cos45)).toBeLessThan(1e-3);
    expect(Math.abs(q.z - sin45)).toBeLessThan(1e-3);
    expect(Math.abs(q.x)).toBeLessThan(1e-3);
    expect(Math.abs(q.y)).toBeLessThan(1e-3);
  });
});

// ---------------------------------------------------------------------------
// Madgwick secondary pipeline (SENS-01, ahrs package, deg→rad and m/s²→g)
// ---------------------------------------------------------------------------

describe('Madgwick filter — unit norm after 50 updates', () => {
  it('getQuaternion() magnitude within ±1e-3 of 1 after 50 synthetic updates', () => {
    const steadyEvent = makeFakeMotionEvent(0.1, 0.1, 0.1, 0, 0, 9.81);
    for (let i = 0; i < 50; i++) {
      updateMadgwick(steadyEvent);
    }
    const q = ahrs.getQuaternion();
    const norm = quatNorm(q);
    expect(Math.abs(norm - 1)).toBeLessThan(1e-3);
  });

  it('all quaternion components are finite (no NaN) after 50 updates', () => {
    const steadyEvent = makeFakeMotionEvent(0.5, 0.5, 0.5, 0.1, 0.1, 9.81);
    for (let i = 0; i < 50; i++) {
      updateMadgwick(steadyEvent);
    }
    const q = ahrs.getQuaternion();
    expect(isFinite(q.w)).toBe(true);
    expect(isFinite(q.x)).toBe(true);
    expect(isFinite(q.y)).toBe(true);
    expect(isFinite(q.z)).toBe(true);
  });
});

describe('Madgwick filter — returns identity on null sensors', () => {
  it('returns {w:1,x:0,y:0,z:0} when rotationRate is null', () => {
    const nullEvent = {
      rotationRate: null,
      accelerationIncludingGravity: { x: 0, y: 0, z: 9.81 },
    } as unknown as DeviceMotionEvent;
    const q = updateMadgwick(nullEvent);
    expect(q.w).toBe(1);
    expect(q.x).toBe(0);
    expect(q.y).toBe(0);
    expect(q.z).toBe(0);
  });

  it('returns {w:1,x:0,y:0,z:0} when accelerationIncludingGravity is null', () => {
    const nullEvent = {
      rotationRate: { alpha: 0, beta: 0, gamma: 0 },
      accelerationIncludingGravity: null,
    } as unknown as DeviceMotionEvent;
    const q = updateMadgwick(nullEvent);
    expect(q.w).toBe(1);
    expect(q.x).toBe(0);
    expect(q.y).toBe(0);
    expect(q.z).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// ahrs.beta — cold-start default (SENS-02, D-03)
// ---------------------------------------------------------------------------

describe('ahrs.beta — cold-start default', () => {
  it('ahrs.beta is 0.3 immediately after module load (cold-start default)', () => {
    // This checks the property we set on the exported ahrs instance.
    // The internal Madgwick closure is initialized with beta:0.3 at construction time.
    expect((ahrs as unknown as Record<string, number>).beta).toBe(0.3);
  });
});

// ---------------------------------------------------------------------------
// rampBeta — SENS-02 convergence beta ramp
// ---------------------------------------------------------------------------

describe('rampBeta — lowers beta on small delta', () => {
  // Reset beta before these tests so state does not bleed from filter tests.
  beforeEach(() => {
    (ahrs as unknown as Record<string, number>).beta = 0.3;
  });

  it('rampBeta with frameDelta below threshold lowers ahrs.beta', () => {
    const betaBefore = (ahrs as unknown as Record<string, number>).beta as number;
    rampBeta(0.001); // well below CONVERGE_DELTA (0.005)
    const betaAfter = (ahrs as unknown as Record<string, number>).beta as number;
    expect(betaAfter).toBeLessThan(betaBefore);
  });

  it('repeated rampBeta with small delta lowers beta monotonically', () => {
    let prev = (ahrs as unknown as Record<string, number>).beta as number;
    for (let i = 0; i < 20; i++) {
      rampBeta(0.001);
      const cur = (ahrs as unknown as Record<string, number>).beta as number;
      // Each call with small delta must not raise beta
      expect(cur).toBeLessThanOrEqual(prev);
      prev = cur;
    }
  });

  it('ahrs.beta never goes below 0.1 (floor)', () => {
    // Drive beta all the way to the floor
    for (let i = 0; i < 100; i++) {
      rampBeta(0.001);
    }
    const betaFinal = (ahrs as unknown as Record<string, number>).beta as number;
    expect(betaFinal).toBeGreaterThanOrEqual(0.1);
    expect(betaFinal).toBeCloseTo(0.1, 5);
  });
});

describe('rampBeta — does NOT lower beta on large delta', () => {
  beforeEach(() => {
    (ahrs as unknown as Record<string, number>).beta = 0.2; // Set a non-default mid value
  });

  it('rampBeta with frameDelta above threshold does not change beta', () => {
    const betaBefore = (ahrs as unknown as Record<string, number>).beta as number;
    rampBeta(0.1); // well above CONVERGE_DELTA (0.005) — still moving
    const betaAfter = (ahrs as unknown as Record<string, number>).beta as number;
    expect(betaAfter).toBe(betaBefore);
  });
});

// ---------------------------------------------------------------------------
// NaN guard — T-05-01 / V5: safeFloat prevents filter poisoning
// ---------------------------------------------------------------------------

describe('NaN guard — updateMadgwick with NaN rotationRate', () => {
  it('NaN rotationRate.alpha does not make getQuaternion() return NaN', () => {
    const nanEvent = makeFakeMotionEvent(NaN, 0, 0, 0, 0, 9.81);
    updateMadgwick(nanEvent);
    const q = ahrs.getQuaternion();
    expect(isNaN(q.w)).toBe(false);
    expect(isNaN(q.x)).toBe(false);
    expect(isNaN(q.y)).toBe(false);
    expect(isNaN(q.z)).toBe(false);
  });

  it('NaN accelerationIncludingGravity.x does not make getQuaternion() return NaN', () => {
    const nanEvent = makeFakeMotionEvent(0, 0, 0, NaN, 0, 9.81);
    updateMadgwick(nanEvent);
    const q = ahrs.getQuaternion();
    expect(isNaN(q.w)).toBe(false);
    expect(isNaN(q.x)).toBe(false);
    expect(isNaN(q.y)).toBe(false);
    expect(isNaN(q.z)).toBe(false);
  });
});
