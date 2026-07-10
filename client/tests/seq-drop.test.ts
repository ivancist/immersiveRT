/**
 * seq-drop.test.ts — RED-phase tests for the uint16 sequence-drop predicate.
 *
 * isNewerSeq implements RFC 1982 half-distance serial number comparison.
 * Covers all 6 documented truth-table cases from PATTERNS.md:
 *   1. Normal increment
 *   2. Duplicate (same seq)
 *   3. Backwards (old packet)
 *   4. Wraparound: 65535 → 0
 *   5. Wraparound: 65534 → 1
 *   6. Large forward jump > 32767 (treated as old by RFC 1982)
 *
 * These tests MUST FAIL before decode.ts is created (RED), then pass after (GREEN).
 */
import { describe, it, expect } from 'vitest';
import { isNewerSeq } from '../src/sensor/decode';

describe('isNewerSeq', () => {
  it('accepts normal increment: (2, 1) → true', () => {
    expect(isNewerSeq(2, 1)).toBe(true);
  });

  it('drops duplicate (same seq): (5, 5) → false', () => {
    expect(isNewerSeq(5, 5)).toBe(false);
  });

  it('drops backwards packet: (50, 100) → false', () => {
    expect(isNewerSeq(50, 100)).toBe(false);
  });

  it('accepts wraparound 65535→0: (0, 65535) → true', () => {
    expect(isNewerSeq(0, 65535)).toBe(true);
  });

  it('accepts wraparound 65534→1: (1, 65534) → true', () => {
    expect(isNewerSeq(1, 65534)).toBe(true);
  });

  it('drops large forward jump >32767 treated as old: (200, 33000) → false', () => {
    expect(isNewerSeq(200, 33000)).toBe(false);
  });
});
