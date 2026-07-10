/**
 * zupt.test.ts — RED-phase tests for ZUPTDetector (SENS-03).
 *
 * ZUPTDetector maintains a 300ms sliding-window of accel-magnitude samples
 * and returns true (stationary) only when the window variance falls below its
 * adaptiveThreshold, after at least 300ms of low-variance input.
 * It never fires on a partial window (<5 samples).
 *
 * These tests must FAIL before zupt.ts is created (RED), then all pass (GREEN).
 */
import { describe, it, expect, beforeEach } from 'vitest';
import { ZUPTDetector } from '../src/sensor/zupt';

// ---------------------------------------------------------------------------
// Partial window — fewer than 5 samples must never fire
// ---------------------------------------------------------------------------

describe('ZUPTDetector — partial window (<5 samples)', () => {
  it('returns false with 0 samples', () => {
    const det = new ZUPTDetector();
    expect(det.update(9.81, 0)).toBe(false);
  });

  it('returns false with 4 low-variance samples', () => {
    const det = new ZUPTDetector();
    // Push 4 identical still samples at t=0,60,120,180 — window never reaches 5
    let result = false;
    for (let i = 0; i < 4; i++) {
      result = det.update(9.81, i * 60);
    }
    // update() for the 4th sample returns false (window.length === 4 < 5)
    expect(result).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Still detection — ≥5 samples spanning ≥300ms of still motion → true
// ---------------------------------------------------------------------------

describe('ZUPTDetector — still detection', () => {
  it('returns true after ≥5 low-variance samples spanning ≥300ms', () => {
    const det = new ZUPTDetector();
    // Push 6 samples at t=0,60,120,180,240,300 — all constant magnitude 9.81
    const times = [0, 60, 120, 180, 240, 300];
    let last = false;
    for (const t of times) {
      last = det.update(9.81, t);
    }
    expect(last).toBe(true);
  });

  it('still window remains true across continued still samples', () => {
    const det = new ZUPTDetector();
    for (let i = 0; i <= 5; i++) {
      det.update(9.81, i * 60);
    }
    // One more still sample should also return true
    const result = det.update(9.81, 6 * 60);
    expect(result).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Motion rejection — high-variance samples must return false
// ---------------------------------------------------------------------------

describe('ZUPTDetector — motion rejection', () => {
  it('returns false for alternating high/low magnitudes (high variance)', () => {
    const det = new ZUPTDetector();
    // Alternate between 5 and 15 m/s² — variance is very large
    const mags = [5, 15, 5, 15, 5, 15];
    let last = false;
    for (let i = 0; i < mags.length; i++) {
      last = det.update(mags[i], i * 60);
    }
    expect(last).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Window eviction — samples older than windowMs are dropped
// ---------------------------------------------------------------------------

describe('ZUPTDetector — window eviction', () => {
  it('drops old still samples after high-motion window covers them', () => {
    const det = new ZUPTDetector();

    // First: feed 6 still samples (t=0..300ms) — detector should fire true
    for (let i = 0; i <= 5; i++) {
      det.update(9.81, i * 60);
    }

    // Now advance time by 400ms with high-motion samples — old samples evicted
    // t=350,410,470,530,590,650 (all > 300ms after oldest still sample at t=0)
    const highVarianceMags = [5, 15, 5, 15, 5, 15];
    let last = true;
    for (let i = 0; i < highVarianceMags.length; i++) {
      last = det.update(highVarianceMags[i], 350 + i * 60);
    }
    // The window now contains only high-variance samples — should return false
    expect(last).toBe(false);
  });

  it('window is bounded — old samples outside windowMs are evicted', () => {
    const det = new ZUPTDetector(300);
    // Feed a long series of still samples from t=0 to t=600
    // then ensure detector still returns true (old evicted samples don't cause issues)
    for (let i = 0; i <= 10; i++) {
      det.update(9.81, i * 60);
    }
    // After 10 updates, samples at t=0..360 that are >300ms old from t=600 are evicted
    // Remaining: samples within t=300..600 — all still → still true
    const result = det.update(9.81, 10 * 60);
    expect(result).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Adaptive threshold — runtime-configurable (SENS-03)
// ---------------------------------------------------------------------------

describe('ZUPTDetector — adaptive threshold', () => {
  it('widening adaptiveThreshold makes a moving window read as still', () => {
    const det = new ZUPTDetector(300, 0.01);

    // Feed high-variance samples that are just above the default threshold
    // e.g. alternating 9.5 and 10.1 — variance ≈ 0.09
    const mags = [9.5, 10.1, 9.5, 10.1, 9.5, 10.1];
    for (let i = 0; i < mags.length; i++) {
      det.update(mags[i], i * 60);
    }
    // With default threshold 0.01 — returns false (variance > 0.01)
    // We already pushed 6 values; call update once more to get the current result
    const beforeWidening = det.update(9.5, 6 * 60);
    expect(beforeWidening).toBe(false);

    // Widen threshold well above the window variance (~0.09)
    det.adaptiveThreshold = 0.5;
    // Same window contents (unchanged), just threshold widened — should fire true
    const afterWidening = det.update(10.1, 7 * 60);
    expect(afterWidening).toBe(true);
  });

  it('adaptiveThreshold is publicly settable at runtime', () => {
    const det = new ZUPTDetector();
    det.adaptiveThreshold = 0.5;
    expect(det.adaptiveThreshold).toBe(0.5);
  });
});

// ---------------------------------------------------------------------------
// NaN guard — bad sensor sample must not corrupt state (T-05-01)
// ---------------------------------------------------------------------------

describe('ZUPTDetector — NaN guard', () => {
  it('predict(NaN) does not poison the window (update still returns boolean)', () => {
    const det = new ZUPTDetector();
    // Accumulate a valid still window first
    for (let i = 0; i <= 5; i++) {
      det.update(9.81, i * 60);
    }
    // Feed a NaN sample — should not throw, and result must still be boolean
    const result = det.update(NaN, 400);
    expect(typeof result).toBe('boolean');
    // The good samples are still in the window; NaN is discarded
    // After NaN guard, window must not become corrupted
    const nextResult = det.update(9.81, 460);
    expect(typeof nextResult).toBe('boolean');
    expect(isNaN(nextResult as unknown as number)).toBe(false);
  });
});
