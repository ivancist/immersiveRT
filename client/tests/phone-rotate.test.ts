/**
 * phone-rotate.test.ts — Locks the device→world rotation convention used by
 * rotateDeviceToWorld() (fix for quick task 260711-0lh).
 *
 * The old implementation applied the CONJUGATE of primaryQuat instead of the
 * quaternion directly, flipping rotated acceleration on every tilt and causing
 * unbounded position drift. These tests assert the correct convention and
 * would have failed against the old conjugate bug.
 */
import { describe, it, expect } from 'vitest';
import { rotateDeviceToWorld } from '../src/phone';
import { eulerToQuat } from '../src/sensor/orientation';

describe('rotateDeviceToWorld — device→world convention (+90° yaw)', () => {
  it('device-frame (1,0,0) maps to world-frame (0,1,0) — NOT (0,-1,0)', () => {
    const q = eulerToQuat(90, 0, 0);
    const result = rotateDeviceToWorld(1, 0, 0, q);
    expect(result.x).toBeCloseTo(0, 6);
    expect(result.y).toBeCloseTo(1, 6);
    expect(result.z).toBeCloseTo(0, 6);
    // Explicit regression guard: the old conjugate bug produced y ≈ -1.
    expect(result.y).toBeGreaterThan(0);
  });

  it('device-frame (0,1,0) maps to world-frame (-1,0,0) — NOT (1,0,0)', () => {
    const q = eulerToQuat(90, 0, 0);
    const result = rotateDeviceToWorld(0, 1, 0, q);
    expect(result.x).toBeCloseTo(-1, 6);
    expect(result.y).toBeCloseTo(0, 6);
    expect(result.z).toBeCloseTo(0, 6);
  });
});

describe('rotateDeviceToWorld — identity quaternion', () => {
  it('leaves an arbitrary vector unchanged', () => {
    const identity = { w: 1, x: 0, y: 0, z: 0 };
    const result = rotateDeviceToWorld(1, 2, 3, identity);
    expect(result.x).toBeCloseTo(1, 6);
    expect(result.y).toBeCloseTo(2, 6);
    expect(result.z).toBeCloseTo(3, 6);
  });
});
