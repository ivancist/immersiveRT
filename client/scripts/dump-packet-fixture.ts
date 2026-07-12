/**
 * dump-packet-fixture.ts — Captures a ground-truth byte fixture from the real
 * `encodePacket` implementation (client/src/sensor/encode.ts), so the Swift
 * SensorPacketEncoder port (mobile/ios-app/immersiveRT/Sensor/SensorPacketEncoder.swift)
 * can be asserted byte-for-byte identical to the live TypeScript encoder — not
 * eyeballed or independently re-derived.
 *
 * Run with: npx tsx scripts/dump-packet-fixture.ts   (from client/)
 *
 * Writes: ../mobile/ios-app/immersiveRTTests/Fixtures/packet_v1_fixture.json
 */
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { encodePacket, BUF_SIZE } from '../src/sensor/encode';
import type { SensorPacket } from '../src/types';

const __dirname = dirname(fileURLToPath(import.meta.url));

/** Lowercase hex encoding of a Uint8Array — matches the format the Swift test fixture expects. */
function toHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

interface FixtureEntry {
  name: string;
  input: SensorPacket;
  bytesHex: string;
}

// (a) Identity-orientation packet: no rotation, no motion, no touch.
const identityPacket: SensorPacket = {
  seq: 1,
  timestamp: 1000,
  qw: 1,
  qx: 0,
  qy: 0,
  qz: 0,
  dx: 0,
  dy: 0,
  dz: 0,
  px: 0,
  py: 0,
  pz: 0,
  driftConfidence: 0,
  touchActive: false,
  touchX: 0,
  touchY: 0,
};

// (b) Non-trivial orientation: 90° rotation about the Y axis (normalized quaternion),
// max seq (wraps at 65536 boundary), large timestamp, active touch.
// Gesture/position/driftConfidence stay hard-zero, matching 06.2's stubbed-field
// contract (D-09) — this entry proves the Swift encoder writes zeros at offsets 15-30
// even when the quaternion carries real data.
const HALF_SQRT2 = Math.SQRT1_2; // 0.7071067811865476
const nonTrivialPacket: SensorPacket = {
  seq: 65535,
  timestamp: 4000000,
  qw: HALF_SQRT2,
  qx: 0,
  qy: HALF_SQRT2,
  qz: 0,
  dx: 0,
  dy: 0,
  dz: 0,
  px: 0,
  py: 0,
  pz: 0,
  driftConfidence: 0,
  touchActive: true,
  touchX: 0.25,
  touchY: 0.75,
};

// (c) Edge packet: touchX clamps from 1.5 -> 1 (-> 0xFFFF), and a NaN quaternion
// component must be sanitised to 0 via safeFloat (T-05-01 mitigation).
const edgePacket: SensorPacket = {
  seq: 100,
  timestamp: 2000,
  qw: 1,
  qx: NaN,
  qy: 0,
  qz: 0,
  dx: 0,
  dy: 0,
  dz: 0,
  px: 0,
  py: 0,
  pz: 0,
  driftConfidence: 0,
  touchActive: true,
  touchX: 1.5,
  touchY: 0.5,
};

const entries: { name: string; input: SensorPacket }[] = [
  { name: 'identity-orientation', input: identityPacket },
  { name: 'non-trivial-orientation', input: nonTrivialPacket },
  { name: 'edge-clamp-and-nan', input: edgePacket },
];

const fixture: FixtureEntry[] = entries.map(({ name, input }) => {
  // Use a fresh buffer per entry (not the shared module-scope _packetBuf) so
  // capturing one entry never overwrites bytes read for a previous entry
  // (mirrors the Phase 06.1 Plan 02 encode.test.ts convention).
  const buf = new ArrayBuffer(BUF_SIZE);
  const bytes = encodePacket(input, buf);
  return { name, input, bytesHex: toHex(bytes) };
});

const outPath = resolve(
  __dirname,
  '../../mobile/ios-app/immersiveRTTests/Fixtures/packet_v1_fixture.json',
);

writeFileSync(outPath, JSON.stringify(fixture, null, 2) + '\n', 'utf-8');

// eslint-disable-next-line no-console
console.log(`Wrote ${fixture.length} fixture entries to ${outPath}`);
