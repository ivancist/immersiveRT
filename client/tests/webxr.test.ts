/**
 * webxr.test.ts — RED-phase tests for webxr.ts (SENS-V2-03).
 *
 * Covers the module's pure/jsdom-testable surface:
 *   - readPoseAndConfidence: WebXR tracking-state → driftConfidence mapping (D-02)
 *   - WebXrPoseTracker.getState(): rolling ~300ms gestureDisplacement delta (D-03)
 *   - WebXrPoseTracker.getState(): freeze-on-lost last-known-good retention (Pitfall 5 / D-06)
 *   - isXrSupported(): exception-safe feature detection (Pitfall 7 / D-05)
 *
 * These tests must FAIL before webxr.ts is created (RED), then all pass (GREEN).
 */
import { describe, it, expect, afterEach } from 'vitest';
import { isXrSupported, readPoseAndConfidence, WebXrPoseTracker } from '../src/sensor/webxr';

// ---------------------------------------------------------------------------
// readPoseAndConfidence — driftConfidence mapping (D-02)
// ---------------------------------------------------------------------------

describe('readPoseAndConfidence — driftConfidence mapping', () => {
  it('returns driftConfidence 0 and pos null when getViewerPose returns null (lost)', () => {
    const frame = {
      getViewerPose: () => null,
    } as unknown as XRFrame;
    const refSpace = {} as unknown as XRReferenceSpace;

    const result = readPoseAndConfidence(frame, refSpace);
    expect(result.pos).toBeNull();
    expect(result.driftConfidence).toBe(0);
  });

  it('returns driftConfidence 0.5 when emulatedPosition is true (limited)', () => {
    const frame = {
      getViewerPose: () => ({
        emulatedPosition: true,
        transform: { position: { x: 1, y: 2, z: 3 } },
      }),
    } as unknown as XRFrame;
    const refSpace = {} as unknown as XRReferenceSpace;

    const result = readPoseAndConfidence(frame, refSpace);
    expect(result.pos).toEqual({ x: 1, y: 2, z: 3 });
    expect(result.driftConfidence).toBe(0.5);
  });

  it('returns driftConfidence 1 when emulatedPosition is false (normal)', () => {
    const frame = {
      getViewerPose: () => ({
        emulatedPosition: false,
        transform: { position: { x: 4, y: 5, z: 6 } },
      }),
    } as unknown as XRFrame;
    const refSpace = {} as unknown as XRReferenceSpace;

    const result = readPoseAndConfidence(frame, refSpace);
    expect(result.pos).toEqual({ x: 4, y: 5, z: 6 });
    expect(result.driftConfidence).toBe(1);
  });
});

// ---------------------------------------------------------------------------
// WebXrPoseTracker — rolling ~300ms gestureDisplacement delta (D-03)
// ---------------------------------------------------------------------------

function makeFrame(x: number, y: number, z: number, emulatedPosition = false): XRFrame {
  return {
    getViewerPose: () => ({
      emulatedPosition,
      transform: { position: { x, y, z } },
    }),
  } as unknown as XRFrame;
}

function makeNullFrame(): XRFrame {
  return {
    getViewerPose: () => null,
  } as unknown as XRFrame;
}

describe('WebXrPoseTracker — gestureDisplacement rolling window', () => {
  it('dx/dy/dz equal delta between current position and oldest sample still within ~300ms window', () => {
    const tracker = new WebXrPoseTracker(300);
    const refSpace = {} as unknown as XRReferenceSpace;

    // t=0: pos (0,0,0)
    tracker.ingest(makeFrame(0, 0, 0), refSpace, 0);
    // t=100: pos (1,0,0)
    tracker.ingest(makeFrame(1, 0, 0), refSpace, 100);
    // t=200: pos (2,1,0) — still within 300ms of t=0
    tracker.ingest(makeFrame(2, 1, 0), refSpace, 200);

    const state = tracker.getState();
    // oldest sample still within window (t=0, pos (0,0,0)); current is (2,1,0)
    expect(state.dx).toBeCloseTo(2);
    expect(state.dy).toBeCloseTo(1);
    expect(state.dz).toBeCloseTo(0);
  });

  it('evicts samples older than the window when computing the delta', () => {
    const tracker = new WebXrPoseTracker(300);
    const refSpace = {} as unknown as XRReferenceSpace;

    tracker.ingest(makeFrame(0, 0, 0), refSpace, 0);
    tracker.ingest(makeFrame(5, 0, 0), refSpace, 100);
    // t=500: sample at t=0 is now 500ms old — evicted from the window.
    // The oldest surviving sample within 300ms of t=500 is t=100 (age 400ms) —
    // still older than window, so only the current sample remains → delta 0.
    tracker.ingest(makeFrame(10, 0, 0), refSpace, 500);

    const state = tracker.getState();
    // Both t=0 and t=100 samples are >300ms old relative to t=500 — evicted.
    // Only the current sample remains, so dx/dy/dz should be 0 (delta against self).
    expect(state.dx).toBeCloseTo(0);
    expect(state.dy).toBeCloseTo(0);
    expect(state.dz).toBeCloseTo(0);
  });
});

// ---------------------------------------------------------------------------
// WebXrPoseTracker — freeze-on-lost (Pitfall 5 / D-06)
// ---------------------------------------------------------------------------

describe('WebXrPoseTracker — freeze on tracking loss', () => {
  it('retains last-known-good x/y/z (finite, unchanged) with driftConfidence 0 when pose is lost', () => {
    const tracker = new WebXrPoseTracker(300);
    const refSpace = {} as unknown as XRReferenceSpace;

    tracker.ingest(makeFrame(3, 4, 5), refSpace, 0);
    tracker.ingest(makeFrame(6, 7, 8), refSpace, 60);

    // Tracking lost.
    tracker.ingest(makeNullFrame(), refSpace, 120);

    const state = tracker.getState();
    expect(state.x).toBe(6);
    expect(state.y).toBe(7);
    expect(state.z).toBe(8);
    expect(Number.isFinite(state.x)).toBe(true);
    expect(Number.isFinite(state.y)).toBe(true);
    expect(Number.isFinite(state.z)).toBe(true);
    expect(state.driftConfidence).toBe(0);
  });

  it('never returns 0/0/0 or NaN as a freeze artifact when last-known-good was non-zero', () => {
    const tracker = new WebXrPoseTracker(300);
    const refSpace = {} as unknown as XRReferenceSpace;

    tracker.ingest(makeFrame(42, -17, 3.5), refSpace, 0);
    tracker.ingest(makeNullFrame(), refSpace, 50);
    tracker.ingest(makeNullFrame(), refSpace, 100);

    const state = tracker.getState();
    expect(state.x).toBe(42);
    expect(state.y).toBe(-17);
    expect(state.z).toBe(3.5);
    expect(isNaN(state.x)).toBe(false);
    expect(isNaN(state.y)).toBe(false);
    expect(isNaN(state.z)).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// isXrSupported — exception-safe feature detection (Pitfall 7 / D-05)
// ---------------------------------------------------------------------------

describe('isXrSupported — feature detection', () => {
  const originalXr = (globalThis.navigator as unknown as { xr?: unknown }).xr;

  afterEach(() => {
    if (originalXr === undefined) {
      delete (globalThis.navigator as unknown as { xr?: unknown }).xr;
    } else {
      (globalThis.navigator as unknown as { xr?: unknown }).xr = originalXr;
    }
  });

  it('resolves false and never throws when navigator.xr is absent', async () => {
    delete (globalThis.navigator as unknown as { xr?: unknown }).xr;
    await expect(isXrSupported()).resolves.toBe(false);
  });

  it('resolves the isSessionSupported result when navigator.xr is present', async () => {
    (globalThis.navigator as unknown as { xr?: unknown }).xr = {
      isSessionSupported: async () => true,
    };
    await expect(isXrSupported()).resolves.toBe(true);
  });

  it('resolves false when isSessionSupported rejects', async () => {
    (globalThis.navigator as unknown as { xr?: unknown }).xr = {
      isSessionSupported: async () => {
        throw new Error('SecurityError');
      },
    };
    await expect(isXrSupported()).resolves.toBe(false);
  });
});
