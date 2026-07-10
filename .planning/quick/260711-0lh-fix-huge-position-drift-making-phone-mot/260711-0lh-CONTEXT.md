# Quick Task 260711-0lh: Fix huge position drift making phone motion controller unusable - Context

**Gathered:** 2026-07-10
**Status:** Ready for planning

<domain>
## Task Boundary

Fix huge position drift making phone motion controller unusable

</domain>

<decisions>
## Implementation Decisions

### Root cause (confirmed, not open for re-litigation)
`rotateDeviceToWorld()` in `client/src/phone.ts:772-787` rotates device-frame
acceleration into world frame by applying the **conjugate** of `primaryQuat`.
`primaryQuat` (from `eulerToQuat()`, `client/src/sensor/orientation.ts:66`) is
device→world (confirmed: `client/src/scene.ts:169-170` applies it directly,
unconjugated, to orient the mesh in world space — the same convention).
Applying the conjugate instead of `q` directly flips the sign/direction of
rotated acceleration on every tilt, injecting orientation-dependent spurious
acceleration into the Kalman integrator. ZUPT (`client/src/sensor/zupt.ts`)
only detects translational stillness, never rotational stillness, so it never
catches this — drift runs unbounded until the `POSITION_MAX` clamp.

Symptom confirmed by user: orientation/rotation display on the rendered cube
is correct; only position (translation) drifts/runs away. This is consistent
with the bug being isolated to `rotateDeviceToWorld()` (accel integration
path), separate from the orientation rendering path (`scene.ts`), which is
unaffected.

### Fix scope
- Fix rotation direction ONLY in `rotateDeviceToWorld()`: apply `primaryQuat`
  directly (standard active quaternion rotation `v' = v + w·t + q_vec × t`
  where `t = 2·(q_vec × v)`), not its conjugate.
- Do NOT add rotational ZUPT (gyro-based stillness detection) in this task —
  out of scope, deferred.
- Do NOT change `POSITION_MAX` clamp — out of scope, deferred.
- Update the stale comment at `phone.ts:773-776` that incorrectly describes
  `primaryQuat` as world→device.

### Verification
- Add a unit test asserting `rotateDeviceToWorld()` rotates a known device-frame
  vector correctly using a known quaternion (e.g. `eulerToQuat(90, 0, 0)`,
  which is a pure +90° yaw about Z) — device-frame `(1,0,0)` should map to
  world-frame `(0,1,0)`, not `(0,-1,0)`. This locks in the correct convention
  and would have caught this regression.
- No physical-phone manual UAT in this task — user will verify on-device
  after the fix lands.

### Claude's Discretion
- Exact test file location/naming (follow existing convention — likely
  alongside `client/tests/orientation.test.ts` or a new
  `client/tests/phone.test.ts` if `rotateDeviceToWorld` is not currently
  exported; export it if needed for testability).

</decisions>

<specifics>
## Specific Ideas

None beyond the above — root cause and fix are fully specified.

</specifics>

<canonical_refs>
## Canonical References

No external specs — requirements fully captured in decisions above.

</canonical_refs>
