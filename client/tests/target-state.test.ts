/**
 * target-state.test.ts — RED-phase tests for the per-player target-state store.
 *
 * Tests:
 *   - updateTargetState writes all SensorPacket fields into targetStateStore
 *   - updateTargetState sets lastSeq = pkt.seq and lastTimestamp = pkt.timestamp
 *   - Two distinct phoneIds are stored independently (per-sender isolation)
 *   - removePlayerState deletes the entry for a phoneId
 *
 * These tests MUST FAIL before playerStore.ts is created (RED), then pass after (GREEN).
 */
import { describe, it, expect, beforeEach } from 'vitest';
import { updateTargetState, targetStateStore, removePlayerState } from '../src/playerStore';
import type { SensorPacket } from '../src/types';

/** A decoded SensorPacket literal used as input to updateTargetState. */
const pkt: SensorPacket = {
  seq: 10,
  timestamp: 5000,
  qw: 0.707,
  qx: 0.0,
  qy: 0.707,
  qz: 0.0,
  dx: 0.1,
  dy: 0.2,
  dz: 0.3,
  px: 1.0,
  py: 2.0,
  pz: 3.0,
  driftConfidence: 0.9,
  touchActive: true,
  touchX: 0.5,
  touchY: 0.75,
};

describe('updateTargetState — single sender', () => {
  beforeEach(() => {
    targetStateStore.clear();
  });

  it('creates an entry in targetStateStore for the given phoneId', () => {
    updateTargetState('phone-1', pkt);
    expect(targetStateStore.has('phone-1')).toBe(true);
  });

  it('stores qw, qx, qy, qz from the packet', () => {
    updateTargetState('phone-1', pkt);
    const state = targetStateStore.get('phone-1')!;
    expect(state.qw).toBe(pkt.qw);
    expect(state.qx).toBe(pkt.qx);
    expect(state.qy).toBe(pkt.qy);
    expect(state.qz).toBe(pkt.qz);
  });

  it('stores dx, dy, dz from the packet', () => {
    updateTargetState('phone-1', pkt);
    const state = targetStateStore.get('phone-1')!;
    expect(state.dx).toBe(pkt.dx);
    expect(state.dy).toBe(pkt.dy);
    expect(state.dz).toBe(pkt.dz);
  });

  it('stores px, py, pz from the packet', () => {
    updateTargetState('phone-1', pkt);
    const state = targetStateStore.get('phone-1')!;
    expect(state.px).toBe(pkt.px);
    expect(state.py).toBe(pkt.py);
    expect(state.pz).toBe(pkt.pz);
  });

  it('stores driftConfidence, touchActive, touchX, touchY', () => {
    updateTargetState('phone-1', pkt);
    const state = targetStateStore.get('phone-1')!;
    expect(state.driftConfidence).toBe(pkt.driftConfidence);
    expect(state.touchActive).toBe(pkt.touchActive);
    expect(state.touchX).toBe(pkt.touchX);
    expect(state.touchY).toBe(pkt.touchY);
  });

  it('sets lastSeq === pkt.seq', () => {
    updateTargetState('phone-1', pkt);
    expect(targetStateStore.get('phone-1')!.lastSeq).toBe(pkt.seq);
  });

  it('sets lastTimestamp === pkt.timestamp', () => {
    updateTargetState('phone-1', pkt);
    expect(targetStateStore.get('phone-1')!.lastTimestamp).toBe(pkt.timestamp);
  });

  it('overwrites existing entry on subsequent calls (upsert)', () => {
    updateTargetState('phone-1', pkt);
    const pkt2: SensorPacket = { ...pkt, seq: 20, timestamp: 9000, qw: 0.0 };
    updateTargetState('phone-1', pkt2);
    const state = targetStateStore.get('phone-1')!;
    expect(state.lastSeq).toBe(20);
    expect(state.qw).toBe(0.0);
  });
});

describe('updateTargetState — per-sender isolation', () => {
  beforeEach(() => {
    targetStateStore.clear();
  });

  it('stores two senders at independent keys', () => {
    const pkt2: SensorPacket = { ...pkt, seq: 20, timestamp: 9000, qw: 0.0 };
    updateTargetState('phone-1', pkt);
    updateTargetState('phone-2', pkt2);
    expect(targetStateStore.size).toBe(2);
    expect(targetStateStore.get('phone-1')!.lastSeq).toBe(pkt.seq);
    expect(targetStateStore.get('phone-2')!.lastSeq).toBe(pkt2.seq);
  });

  it('updating phone-2 does not affect phone-1 state', () => {
    updateTargetState('phone-1', pkt);
    const pkt2: SensorPacket = { ...pkt, seq: 99, qw: 0.0 };
    updateTargetState('phone-2', pkt2);
    expect(targetStateStore.get('phone-1')!.qw).toBe(pkt.qw);
  });
});

describe('removePlayerState', () => {
  beforeEach(() => {
    targetStateStore.clear();
  });

  it('removes the entry for the given phoneId', () => {
    updateTargetState('phone-1', pkt);
    removePlayerState('phone-1');
    expect(targetStateStore.has('phone-1')).toBe(false);
  });

  it('does not affect other senders when removing one', () => {
    updateTargetState('phone-1', pkt);
    updateTargetState('phone-2', pkt);
    removePlayerState('phone-1');
    expect(targetStateStore.has('phone-2')).toBe(true);
  });
});
