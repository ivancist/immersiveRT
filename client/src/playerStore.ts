/**
 * playerStore.ts — Per-player target-state store (DESK-04, D-10).
 *
 * Holds the latest decoded SensorPacket fields for each connected phone,
 * keyed by phoneId (string). The rAF loop in scene.ts reads from this
 * Map every frame; packet decode in room.ts writes to it on message receipt.
 *
 * Design decisions:
 *   - Plain numbers only — no THREE types (keeps store jsdom-testable, decoupled
 *     from Three.js; scene.ts owns quaternion/vector allocation per PATTERNS.md)
 *   - Module-level Map (singleton) — single source of truth per browser tab
 *   - updateTargetState is a simple upsert; caller decides whether to call it
 *     (isNewerSeq + isSafePacket guards live in room.ts plan-04 wiring)
 *   - Inherent DoS protection: one Map entry per sender, no accumulation (T-06-07)
 *
 * Note: playerStore imports no 3D library types (scene.ts owns quaternion allocation).
 */

import type { SensorPacket } from './types';

// ---------------------------------------------------------------------------
// PlayerState interface
// ---------------------------------------------------------------------------

/**
 * Snapshot of the latest sensor data for a single connected phone.
 *
 * Fields mirror SensorPacket but are stored as plain numbers (not THREE types)
 * so the store can be tested in jsdom without a WebGL context. The Three.js
 * scene allocates its own Quaternion/Vector3 objects and reads from here.
 */
export interface PlayerState {
  // Orientation quaternion (OS-fused, float16 precision from wire)
  qw: number;
  qx: number;
  qy: number;
  qz: number;

  // Gesture displacement since last ZUPT reset (float16 precision from wire)
  dx: number;
  dy: number;
  dz: number;

  // Dead-reckoning position (float16 precision from wire)
  px: number;
  py: number;
  pz: number;

  /** Dead-reckoning reliability: 0 = high drift, 1 = just zeroed by ZUPT. */
  driftConfidence: number;

  touchActive: boolean;
  /** Normalized horizontal touch coordinate in [0, 1]. */
  touchX: number;
  /** Normalized vertical touch coordinate in [0, 1]. */
  touchY: number;

  /** uint16 sequence counter of the last accepted packet for this sender. */
  lastSeq: number;
  /** Timestamp (ms since session start) of the last accepted packet. */
  lastTimestamp: number;
}

// ---------------------------------------------------------------------------
// Module-level store (DESK-04, D-10)
// ---------------------------------------------------------------------------

/**
 * Singleton Map from phoneId → PlayerState.
 *
 * Updated by updateTargetState on every accepted packet (~60 Hz per sender).
 * Read by the Three.js rAF loop (~60 Hz) every frame.
 * Inherently rate-safe: one entry per sender, no unbounded growth (T-06-07).
 */
export const targetStateStore = new Map<string, PlayerState>();

// ---------------------------------------------------------------------------
// Store mutations
// ---------------------------------------------------------------------------

/**
 * Upsert the PlayerState for `phoneId` from the given SensorPacket.
 *
 * Sets all decoded fields plus lastSeq = pkt.seq and lastTimestamp = pkt.timestamp.
 * Does NOT enforce isNewerSeq or isSafePacket — the caller (room.ts wiring, plan 04)
 * applies those guards before calling this function.
 */
export function updateTargetState(phoneId: string, pkt: SensorPacket): void {
  targetStateStore.set(phoneId, {
    qw: pkt.qw,
    qx: pkt.qx,
    qy: pkt.qy,
    qz: pkt.qz,
    dx: pkt.dx,
    dy: pkt.dy,
    dz: pkt.dz,
    px: pkt.px,
    py: pkt.py,
    pz: pkt.pz,
    driftConfidence: pkt.driftConfidence,
    touchActive: pkt.touchActive,
    touchX: pkt.touchX,
    touchY: pkt.touchY,
    lastSeq: pkt.seq,
    lastTimestamp: pkt.timestamp,
  });
}

/**
 * Remove the PlayerState entry for `phoneId`.
 *
 * Called when a phone disconnects or leaves the room so the rAF loop
 * no longer tries to update a departed player's scene object.
 */
export function removePlayerState(phoneId: string): void {
  targetStateStore.delete(phoneId);
}
