/**
 * webxr.ts — WebXR `immersive-ar` camera-assisted pose tracking (SENS-V2-03).
 *
 * This module is the drift-resistant replacement for IMU-only dead-reckoning
 * on supported Android/ARCore devices. It calls the raw `navigator.xr` API
 * directly — no Three.js, no new npm package (phone.ts has no renderer).
 *
 * Call contract from phone.ts (wired in Plan 03):
 *   1. `isXrSupported()` — feature-detect once at calibration (D-05); never throws.
 *   2. `startWebXrPoseTracking(tracker)` — request an immersive-ar session and
 *      drive an internal rAF loop that calls `tracker.ingest()` every frame.
 *      Returns the live `XRSession`, or `null` on any failure (caller falls
 *      back to the existing ZUPT/Kalman pipeline).
 *   3. On each outgoing SensorPacket tick, phone.ts reads `tracker.getState()`
 *      for the camera-derived x/y/z, dx/dy/dz (D-03), and driftConfidence (D-02).
 *
 * Tracking-state → driftConfidence mapping (D-02):
 *   getViewerPose() null           → driftConfidence 0 (lost)
 *   pose.emulatedPosition === true → driftConfidence 0.5 (limited)
 *   pose.emulatedPosition === false→ driftConfidence 1 (normal)
 *
 * Freeze-on-lost (Pitfall 5 / D-06): a null pose NEVER resets the tracked
 * x/y/z to 0/NaN — the last-known-good value is retained and returned with
 * driftConfidence 0, mirroring kalman.ts's guard-first/return-last-known-good
 * idiom.
 *
 * No exported/public identifier named `position` is introduced here — camera
 * data is exposed as `pose` / `x,y,z` / `driftConfidence` (SDK-05).
 *
 * Never requests the raw-camera-pixel WebXR feature (T-06.1-01) — only the
 * `local` reference-space feature is required, and `dom-overlay` is optional.
 */

/** A single timestamped camera-derived position sample (D-03 ring buffer). */
interface PosSample {
  t: number;
  x: number;
  y: number;
  z: number;
}

/**
 * Derive `{ pos, driftConfidence }` from a single XR frame's viewer pose.
 * Pure function — no state, no side effects (D-02).
 *
 * @param frame     Current XRFrame from session.requestAnimationFrame.
 * @param refSpace  Reference space obtained via session.requestReferenceSpace.
 */
export function readPoseAndConfidence(
  frame: XRFrame,
  refSpace: XRReferenceSpace,
): { pos: { x: number; y: number; z: number } | null; driftConfidence: 0 | 0.5 | 1 } {
  const pose = frame.getViewerPose(refSpace);
  if (!pose) {
    return { pos: null, driftConfidence: 0 }; // D-02: lost
  }
  const p = pose.transform.position;
  if (pose.emulatedPosition) {
    return { pos: { x: p.x, y: p.y, z: p.z }, driftConfidence: 0.5 }; // D-02: limited
  }
  return { pos: { x: p.x, y: p.y, z: p.z }, driftConfidence: 1 }; // D-02: normal
}

/**
 * WebXrPoseTracker maintains:
 *   - a rolling ~300ms ring buffer of camera-position samples, used to
 *     compute a continuous gestureDisplacement delta (D-03, no discrete
 *     ZUPT-style reset event while WebXR tracking is active);
 *   - the last-known-good camera position, retained across tracking-loss
 *     frames so getState() never reports 0/NaN on a lost pose
 *     (Pitfall 5 / D-06).
 */
export class WebXrPoseTracker {
  private readonly windowMs: number;
  private readonly _window: PosSample[] = [];

  /** Last-known-good camera position. Never mutated by a lost/null pose. */
  private _lastGood: { x: number; y: number; z: number } = { x: 0, y: 0, z: 0 };

  /** Current driftConfidence, updated every ingest() call. */
  private _driftConfidence: 0 | 0.5 | 1 = 0;

  /**
   * @param windowMs  Rolling gestureDisplacement window duration in ms. Default 300.
   */
  constructor(windowMs = 300) {
    this.windowMs = windowMs;
  }

  /**
   * Ingest one XR frame: read the pose, update last-known-good + the rolling
   * window on a valid pose, or freeze (leave last-known-good untouched, set
   * driftConfidence 0) on a lost pose.
   *
   * @param frame     Current XRFrame.
   * @param refSpace  Reference space to sample the pose against.
   * @param nowMs     Sample timestamp in ms. Defaults to performance.now() —
   *                  exposed as a parameter for deterministic unit testing.
   */
  ingest(frame: XRFrame, refSpace: XRReferenceSpace, nowMs: number = performance.now()): void {
    const { pos, driftConfidence } = readPoseAndConfidence(frame, refSpace);

    if (pos === null) {
      // Pitfall 5 / D-06: freeze — never mutate last-known-good on tracking loss.
      this._driftConfidence = 0;
      return;
    }

    this._lastGood = pos;
    this._driftConfidence = driftConfidence;

    this._window.push({ t: nowMs, x: pos.x, y: pos.y, z: pos.z });
    this._evict(nowMs);
  }

  /**
   * Return the current tracked state: last-known-good x/y/z, the rolling
   * ~300ms gestureDisplacement delta (dx/dy/dz), and driftConfidence.
   */
  getState(): {
    x: number;
    y: number;
    z: number;
    dx: number;
    dy: number;
    dz: number;
    driftConfidence: 0 | 0.5 | 1;
  } {
    const { x, y, z } = this._lastGood;
    const oldest = this._window[0] ?? { x, y, z };
    return {
      x,
      y,
      z,
      dx: x - oldest.x,
      dy: y - oldest.y,
      dz: z - oldest.z,
      driftConfidence: this._driftConfidence,
    };
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /** Remove samples whose timestamp is more than windowMs behind nowMs. */
  private _evict(nowMs: number): void {
    while (this._window.length > 0 && nowMs - this._window[0].t > this.windowMs) {
      this._window.shift();
    }
  }
}

/**
 * Feature-detect WebXR `immersive-ar` support (Pitfall 7 / D-05).
 * Never throws — resolves `false` when `navigator.xr` is absent, or when
 * `isSessionSupported` rejects (e.g. SecurityError on a non-HTTPS origin).
 */
export async function isXrSupported(): Promise<boolean> {
  if (typeof navigator === 'undefined' || !('xr' in navigator) || !navigator.xr) {
    return false;
  }
  try {
    return await navigator.xr.isSessionSupported('immersive-ar');
  } catch {
    return false;
  }
}

/**
 * Request an `immersive-ar` WebXR session, satisfy the spec's mandatory
 * base-layer requirement with a throwaway 1x1 canvas that is never drawn
 * into (the "opaque layer trick"), and drive an internal rAF loop that
 * feeds every frame into `tracker.ingest()`.
 *
 * Never requests the raw-camera-pixel feature (T-06.1-01) — only `local`
 * (required) and `dom-overlay` (optional, rooted at document.body so the
 * existing phone UI visually replaces the raw camera passthrough).
 *
 * @returns The live XRSession, or `null` on any failure so the caller falls
 *          back to the existing ZUPT/Kalman pipeline (D-04).
 */
export async function startWebXrPoseTracking(tracker: WebXrPoseTracker): Promise<XRSession | null> {
  try {
    if (typeof navigator === 'undefined' || !navigator.xr) {
      return null;
    }

    const session = await navigator.xr.requestSession('immersive-ar', {
      requiredFeatures: ['local'],
      optionalFeatures: ['dom-overlay'],
      domOverlay: { root: document.body },
    });

    // Spec requires a base layer even though nothing is ever rendered into it —
    // this is the structural half of the "opaque layer trick"; dom-overlay (or
    // a solid-clear fallback, handled by the caller) hides the passthrough visually.
    const canvas = document.createElement('canvas'); // 1x1, never appended to DOM
    const gl = canvas.getContext('webgl', { xrCompatible: true }) as WebGLRenderingContext;
    await session.updateRenderState({ baseLayer: new XRWebGLLayer(session, gl) });

    const refSpace = await session.requestReferenceSpace('local');

    const onFrame = (_time: number, frame: XRFrame): void => {
      tracker.ingest(frame, refSpace);
      session.requestAnimationFrame(onFrame);
    };
    session.requestAnimationFrame(onFrame);

    return session;
  } catch {
    return null;
  }
}
