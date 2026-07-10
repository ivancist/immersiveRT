/**
 * devOverlay.ts — Dev-only tuning overlay for the phone client (D-15, Plan 07).
 *
 * Lazily injects a fixed-position `#dev-overlay` div that shows:
 *   - OS-fused quaternion (from the sent packet) vs Madgwick quaternion
 *   - Active ahrs.beta value
 *   - ZUPT fired indicator (latched for 500 ms)
 *   - Dead-reckoning drift confidence
 *   - Rolling packet Hz
 *
 * The entire module body is guarded by `if (!import.meta.env.DEV) return` so
 * Vite's tree-shaker removes every reference when building for production (D-15).
 * This file has no top-level side effects, so an unused import is safe to shake.
 *
 * Called by phone.ts inside an `if (import.meta.env.DEV)` block (the primary
 * tree-shake gate). The guard here is belt-and-suspenders only.
 */

import { ahrs } from './orientation';
import type { SensorPacket, Quaternion } from '../types';

// ---------------------------------------------------------------------------
// Module-scope overlay state
// ---------------------------------------------------------------------------

/** Timestamp of the most recent ZUPT fire (for 500 ms latch). */
let lastZuptFireTs = 0;

// ---------------------------------------------------------------------------
// Exported update function
// ---------------------------------------------------------------------------

/**
 * Update (or lazily create) the `#dev-overlay` div with the latest sensor
 * telemetry. Belt-and-suspenders DEV guard: returns immediately in production
 * so an accidental call outside the DEV gate is a no-op.
 *
 * @param pkt          The just-encoded sensor packet (carries OS-fused quat + drift).
 * @param madgwickQuat The Madgwick quaternion for this tick (secondary path).
 * @param zuptFired    True if ZUPTDetector returned true on this tick.
 * @param hz           Rolling packet rate in Hz (computed by phone.ts).
 */
export function updateOverlay(
  pkt: SensorPacket,
  madgwickQuat: Quaternion,
  zuptFired: boolean,
  hz: number,
): void {
  if (!import.meta.env.DEV) { return; }

  // Lazily inject the overlay div on first call.
  let el = document.getElementById('dev-overlay');
  if (!el) {
    el = document.createElement('div');
    el.id = 'dev-overlay';
    el.style.cssText =
      'position:fixed;bottom:0;left:0;z-index:9998;' +
      'font:10px/1.4 monospace;color:#0f0;' +
      'background:rgba(0,0,0,0.6);opacity:0.85;' +
      'padding:4px 8px;white-space:pre;pointer-events:none;';
    document.body.appendChild(el);
  }

  // Latch ZUPT indicator for 500 ms so brief firings are readable.
  if (zuptFired) { lastZuptFireTs = performance.now(); }
  const zuptStr = (performance.now() - lastZuptFireTs < 500) ? 'YES' : 'no';

  // Three decimal places for quaternion components.
  const f3 = (v: number): string => v.toFixed(3);

  el.textContent =
    `OS:  w=${f3(pkt.qw)} x=${f3(pkt.qx)} y=${f3(pkt.qy)} z=${f3(pkt.qz)}\n` +
    `MWK: w=${f3(madgwickQuat.w)} x=${f3(madgwickQuat.x)} y=${f3(madgwickQuat.y)} z=${f3(madgwickQuat.z)}\n` +
    `beta=${ahrs.beta.toFixed(3)} ZUPT:${zuptStr} drift=${pkt.driftConfidence.toFixed(2)} hz=${hz.toFixed(0)}`;
}
