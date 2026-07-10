/**
 * Shared sensor type contract for ImmersiveRT.
 *
 * These interfaces are the single source of truth for the sensor data flowing
 * from phone to desktop. They are imported by sensor modules (encode.ts,
 * orientation.ts, etc.) and by the desktop decoder (Phase 6).
 *
 * NOTE: Field ORDER here documents intent but does NOT fix wire layout.
 * The binary wire layout is determined by byte offsets in encode.ts (D-14).
 * Do not reorder fields here expecting the packet format to change —
 * only encode.ts DataView offsets control the wire format.
 */

/** Unit quaternion representing device orientation. */
export interface Quaternion {
  w: number;
  x: number;
  y: number;
  z: number;
}

/** 3-axis vector (position, displacement, acceleration). */
export interface Vector3 {
  x: number;
  y: number;
  z: number;
}

/** Normalized touch state for a single contact point. */
export interface TouchState {
  /** Whether a touch is currently active. */
  active: boolean;
  /** Normalized horizontal position in [0, 1]. */
  x: number;
  /** Normalized vertical position in [0, 1]. */
  y: number;
}

/**
 * Schema v1 sensor packet — D-14.
 *
 * Sent from phone to desktop at up to 60 Hz over an unreliable WebRTC data
 * channel. The binary wire format is exactly 36 bytes (see encode.ts).
 *
 * Fields:
 *   seq          — uint16 counter, wraps at 65535
 *   timestamp    — ms since session start (uint32)
 *   qw/qx/qy/qz — orientation quaternion (OS-fused primary, float16 each)
 *   dx/dy/dz     — gesture displacement since last ZUPT reset (float16 each)
 *   px/py/pz     — dead-reckoning position (float16 each)
 *   driftConfidence — 0 = high drift, 1 = just ZUPTed (float32)
 *   touchActive  — whether a touch contact is active
 *   touchX/touchY — normalized touch coordinates in [0, 1]
 */
export interface SensorPacket {
  seq: number;
  timestamp: number;

  // Orientation quaternion (OS-fused; float16 precision on wire)
  qw: number;
  qx: number;
  qy: number;
  qz: number;

  // Gesture displacement since last ZUPT reset (float16 precision on wire)
  dx: number;
  dy: number;
  dz: number;

  // Dead-reckoning position (float16 precision on wire)
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
}
