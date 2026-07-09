/**
 * zupt.ts — Zero-Velocity Update (ZUPT) detector (SENS-03).
 *
 * ZUPTDetector maintains a sliding window of accelerometer-magnitude samples
 * over a configurable time horizon (default 300 ms). It returns `true`
 * (stationary) only when:
 *   - the window holds at least 5 samples, AND
 *   - the population variance of magnitude values is below `adaptiveThreshold`.
 *
 * The threshold is intentionally public so phone.ts can update it live from a
 * hold-still calibration measurement (SENS-03 requirement).
 *
 * NaN inputs are silently dropped — a single bad DeviceMotion sample cannot
 * corrupt the accumulated window (T-05-01 mitigation).
 *
 * Thread/re-entrancy: ZUPTDetector is not shared across workers; each phone
 * client creates exactly one instance.
 */

interface Sample {
  /** Accelerometer magnitude (m/s²), finite-checked before insertion. */
  v: number;
  /** Timestamp in milliseconds (e.g. from DeviceMotionEvent.timeStamp). */
  t: number;
}

export class ZUPTDetector {
  private readonly _window: Sample[] = [];
  private readonly windowMs: number;

  /**
   * Variance threshold below which the detector considers the device still.
   * Updated at runtime from hold-still calibration (SENS-03).
   * Default 0.01 (m/s²)² — empirically safe starting value; tune on device.
   */
  public adaptiveThreshold: number;

  /**
   * @param windowMs   Sliding-window duration in ms. Default 300.
   * @param threshold  Initial variance threshold. Default 0.01.
   */
  constructor(windowMs = 300, threshold = 0.01) {
    this.windowMs = windowMs;
    this.adaptiveThreshold = threshold;
  }

  /**
   * Add a new accelerometer-magnitude sample and return whether the device
   * appears stationary right now.
   *
   * @param accelMag  Magnitude of linear acceleration (m/s²). NaN → silently ignored.
   * @param nowMs     Current timestamp in milliseconds.
   * @returns `true` if the window variance is below `adaptiveThreshold` AND
   *          the window has accumulated at least 5 samples; `false` otherwise.
   */
  update(accelMag: number, nowMs: number): boolean {
    // T-05-01: Guard against non-finite sensor values before mutating state.
    if (!Number.isFinite(accelMag)) {
      // Evict stale entries even when we skip the bad sample, to keep the
      // window bounded (T-05-13 mitigation).
      this._evict(nowMs);
      return this._evaluate();
    }

    this._window.push({ v: accelMag, t: nowMs });
    this._evict(nowMs);
    return this._evaluate();
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

  /**
   * Return true when the window has ≥5 samples and population variance < threshold.
   * Called after every push+evict cycle.
   */
  private _evaluate(): boolean {
    if (this._window.length < 5) return false;

    const vals = this._window.map(s => s.v);
    const mean = vals.reduce((a, b) => a + b, 0) / vals.length;
    const variance = vals.reduce((a, v) => a + (v - mean) ** 2, 0) / vals.length;
    return variance < this.adaptiveThreshold;
  }
}
