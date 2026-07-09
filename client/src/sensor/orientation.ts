/**
 * orientation.ts — Dual orientation pipeline for ImmersiveRT (Plan 05-04).
 *
 * PRIMARY path  — OS-fused: eulerToQuat(alpha, beta, gamma)
 *   Converts DeviceOrientationEvent Z-X-Y Euler angles to a unit quaternion using
 *   the exact W3C formula (RESEARCH Pattern 2, Pitfall 3). This is D-03's primary
 *   orientation source — the OS sensor stack has already fused gyro + magnetometer
 *   so do NOT run a second Madgwick pass on it.
 *
 * SECONDARY path — Madgwick: updateMadgwick(e: DeviceMotionEvent)
 *   Feeds raw DeviceMotionEvent (rotationRate + accelerationIncludingGravity) into
 *   the ahrs Madgwick filter with correct unit conversions:
 *     rotationRate deg/s → rad/s  (× Math.PI/180)          — RESEARCH Pitfall 1
 *     acceleration m/s² → g       (÷ 9.81)                  — RESEARCH Pitfall 2
 *   Used when OS orientation is unavailable (SENS-01).
 *
 * Beta ramp (SENS-02) — rampBeta(frameDelta)
 *   Lowers ahrs.beta from the cold-start value 0.3 toward the steady-state floor 0.1
 *   once the per-frame quaternion delta falls below the convergence threshold.
 *   Never raises beta and never goes below 0.1.
 *
 * NaN guard (V5 / T-05-01) — safeFloat
 *   Every rotationRate/acceleration argument to ahrs.update() is sanitised via
 *   safeFloat so a null or NaN reading cannot poison the filter state.
 */

import AHRS from 'ahrs';
import { safeFloat } from './encode';
import type { Quaternion } from '../types';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const DEG_TO_RAD = Math.PI / 180;

/**
 * Per-frame quaternion-delta convergence threshold for rampBeta.
 * When the incoming frameDelta is below this value the filter is considered
 * converged and beta is stepped down toward the steady-state floor.
 * (Tuned on-device — see STATE.md blocker: Madgwick beta empirical tuning)
 */
const CONVERGE_DELTA = 0.005;

/** Steady-state floor for ahrs.beta. Never ramp below this value. */
const BETA_FLOOR = 0.1;

/** Step size for each rampBeta call that is below the convergence threshold. */
const BETA_STEP = 0.005;

// ---------------------------------------------------------------------------
// PRIMARY orientation source: OS-fused eulerToQuat (D-03 / RESEARCH Pattern 2)
// ---------------------------------------------------------------------------

/**
 * Convert DeviceOrientationEvent Z-X-Y Euler angles to a unit quaternion.
 *
 * Uses the exact W3C Z-X-Y formula; do NOT substitute an aerospace Z-Y-X or
 * Three.js intrinsic conversion — they produce wrong rotations for compass-fused
 * OS output (RESEARCH Pitfall 3).
 *
 * @param alpha  Yaw in degrees   (rotation about device Z)
 * @param beta   Pitch in degrees (rotation about device X)
 * @param gamma  Roll in degrees  (rotation about device Y)
 */
export function eulerToQuat(alpha: number, beta: number, gamma: number): Quaternion {
  const _x = beta  * DEG_TO_RAD; // pitch
  const _y = gamma * DEG_TO_RAD; // roll
  const _z = alpha * DEG_TO_RAD; // yaw

  const cX = Math.cos(_x / 2), sX = Math.sin(_x / 2);
  const cY = Math.cos(_y / 2), sY = Math.sin(_y / 2);
  const cZ = Math.cos(_z / 2), sZ = Math.sin(_z / 2);

  return {
    w: cX * cY * cZ - sX * sY * sZ,
    x: sX * cY * cZ - cX * sY * sZ,
    y: cX * sY * cZ + sX * cY * sZ,
    z: cX * cY * sZ + sX * sY * cZ,
  };
}

// ---------------------------------------------------------------------------
// SECONDARY orientation source: Madgwick filter via ahrs (SENS-01, D-05)
// ---------------------------------------------------------------------------

/**
 * Madgwick filter instance — wrapped to expose a functional beta setter.
 *
 * ahrs@1.3.3 stores its gain as a closure-local variable in Madgwick.js, so
 * writing to `instance.beta` has no effect on filter behaviour.  The wrapper
 * below rebuilds the AHRS instance whenever beta changes; quaternion state
 * (q0-q3) is lost on rebuild, which is acceptable during the convergence period.
 *
 * algorithm: 'Madgwick' — D-05 mandates Madgwick (not Mahony) for the secondary path.
 * sampleInterval: 60    — matches the 60 Hz Device Motion API ceiling (iOS Safari).
 * Initial beta: 0.3     — rampBeta() steps it toward BETA_FLOOR on convergence.
 */
let _beta = 0.3;
let _ahrsInner = new AHRS({ sampleInterval: 60, algorithm: 'Madgwick', beta: _beta });

export const ahrs = {
  get beta() { return _beta; },
  set beta(v: number) {
    if (v === _beta) { return; }
    _beta = v;
    // Rebuild the filter with the new beta — the only way to change the gain
    // in ahrs 1.3.3 since beta is a closure-local variable in Madgwick.js.
    // State (q0-q3) is lost on rebuild — acceptable during convergence.
    _ahrsInner = new AHRS({ sampleInterval: 60, algorithm: 'Madgwick', beta: _beta });
  },
  getQuaternion() { return _ahrsInner.getQuaternion(); },
  update(...args: Parameters<typeof _ahrsInner.update>) { return _ahrsInner.update(...args); },
};

/**
 * Feed a raw DeviceMotionEvent into the Madgwick filter and return the current
 * quaternion (SENS-01).
 *
 * Unit conversions (RESEARCH Pitfalls 1 & 2):
 *   rotationRate  deg/s → rad/s  : multiply by Math.PI/180
 *   acceleration  m/s² → g       : divide by 9.81
 *
 * Every argument is safeFloat-guarded before ahrs.update() (V5 / T-05-01).
 *
 * Returns the identity quaternion { w:1, x:0, y:0, z:0 } when sensors report null.
 */
export function updateMadgwick(e: DeviceMotionEvent): Quaternion {
  const rr = e.rotationRate;
  const a  = e.accelerationIncludingGravity;

  if (!rr || !a) return { w: 1, x: 0, y: 0, z: 0 };

  ahrs.update(
    safeFloat(rr.alpha) * DEG_TO_RAD,
    safeFloat(rr.beta)  * DEG_TO_RAD,
    safeFloat(rr.gamma) * DEG_TO_RAD,
    safeFloat(a.x) / 9.81,
    safeFloat(a.y) / 9.81,
    safeFloat(a.z) / 9.81,
  );

  const q = ahrs.getQuaternion(); // returns { w, x, y, z }
  return { w: q.w, x: q.x, y: q.y, z: q.z };
}

// ---------------------------------------------------------------------------
// Beta ramp (SENS-02)
// ---------------------------------------------------------------------------

/**
 * Step ahrs.beta toward the steady-state floor when the per-frame quaternion
 * delta is below the convergence threshold (SENS-02).
 *
 * @param frameDelta  Quaternion change magnitude between the last two frames.
 *
 * Behaviour:
 *   - frameDelta < CONVERGE_DELTA  → filter is converging; lower beta by BETA_STEP
 *                                    but never below BETA_FLOOR (0.1).
 *   - frameDelta >= CONVERGE_DELTA → device is still moving; leave beta unchanged.
 *
 * Never raises beta above its current value.
 *
 * NOTE: Ramp timing constants (CONVERGE_DELTA, BETA_STEP) require empirical
 * tuning on a real device before shipping — see STATE.md blocker.
 */
export function rampBeta(frameDelta: number): void {
  if (frameDelta < CONVERGE_DELTA) {
    ahrs.beta = Math.max(BETA_FLOOR, ahrs.beta - BETA_STEP);
  }
  // else: still moving — do not lower beta
}
