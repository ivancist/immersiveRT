/**
 * kalman.ts — 1-D Kalman filter for dead-reckoning position (SENS-04).
 *
 * Kalman1D tracks a single spatial axis (x, y, or z). Phone.ts creates three
 * instances (one per axis). On each DeviceMotion tick it calls:
 *
 *   const pos = kalman.predict(accelMs2, dtSec);
 *
 * When ZUPTDetector fires (device is stationary), phone.ts calls:
 *
 *   kalman.resetVelocity();
 *
 * Then reads confidence:
 *
 *   const conf = kalman.driftConfidence(); // → SensorPacket.driftConfidence
 *
 * NaN/Infinity inputs are silently dropped — a single bad DeviceMotion sample
 * cannot corrupt accumulated position or velocity (T-05-01 mitigation).
 *
 * Parameters Q and R control the noise model:
 *   Q — process noise (how fast uncertainty grows per second). Lower Q = smoother
 *       position but slower response to real motion. Default: 0.001.
 *   R — measurement noise (covariance of the ZUPT "measurement"). Default: 0.1.
 *
 * Both are settable from computeCalibration() output (Plan 03, SENS-03).
 */

export class Kalman1D {
  private pos = 0;
  private vel = 0;
  private P = 1; // error covariance; starts at 1 (high uncertainty)

  /**
   * @param Q  Process noise variance per second. Default 0.001.
   * @param R  Measurement noise variance (used in resetVelocity Kalman gain). Default 0.1.
   */
  constructor(
    private Q = 0.001,
    private R = 0.1,
  ) {}

  /**
   * Integrate a new accelerometer reading into velocity and position.
   *
   * Follows the constant-acceleration motion model:
   *   vel += accel * dt
   *   pos += vel * dt
   *   P   += Q * dt   (covariance grows with time — position drifts)
   *
   * NaN and non-finite accel values are silently ignored; state is unchanged
   * for that tick (T-05-01 mitigation).
   *
   * @param accelMs2  Linear acceleration along this axis in m/s². NaN → skip.
   * @param dtSec     Time since last call in seconds (e.g. 1/60 ≈ 0.0167).
   * @returns Current position estimate in metres.
   */
  predict(accelMs2: number, dtSec: number): number {
    // T-05-01: guard non-finite inputs before mutating state.
    if (!Number.isFinite(accelMs2)) return this.pos;
    if (!Number.isFinite(dtSec) || dtSec <= 0) return this.pos;

    this.vel += accelMs2 * dtSec;
    this.pos += this.vel * dtSec;
    this.P += this.Q * dtSec;
    return this.pos;
  }

  /**
   * Apply a ZUPT correction: the device is stationary so true velocity is 0.
   *
   * Uses a standard Kalman gain update:
   *   K = P / (P + R)
   *   vel = 0          (zero-velocity measurement)
   *   P *= (1 - K)     (covariance shrinks — we just got reliable info)
   *
   * Call this when ZUPTDetector.update() returns true.
   */
  resetVelocity(): void {
    const K = this.P / (this.P + this.R);
    this.vel = 0;
    this.P *= (1 - K);
  }

  /**
   * Return a dead-reckoning reliability estimate in [0, 1].
   *
   * 1.0  — just after resetVelocity (P is near 0 → high confidence)
   * 0.0  — P has grown to 1 or beyond (high drift uncertainty)
   *
   * Formula: max(0, 1 − min(1, P))
   */
  driftConfidence(): number {
    return Math.max(0, 1 - Math.min(1, this.P));
  }
}
