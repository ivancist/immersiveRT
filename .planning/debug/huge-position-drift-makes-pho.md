---
status: abandoned
trigger: "Huge position drift makes phone motion controller unusable"
created: 2026-07-11T00:00:00Z
updated: 2026-07-11T03:00:00Z
---

## SUPERSEDED (2026-07-11)

User decided pure-IMU dead-reckoning cannot be tuned to an acceptable feel
(pass-2 fix was awaiting on-device confirmation when this decision landed)
and is pivoting to camera-assisted tracking instead: WebXR Device API
(ARCore) on Android, plus a third-party visual-inertial library (e.g. 8th
Wall, MindAR) to cover iOS Safari, which has no WebXR `immersive-ar` support.
The pass-2 IMU fix was discarded (working tree reverted, nothing committed)
per explicit user choice — the whole IMU-only approach is being replaced,
not patched further. This session's evidence trail (ZUPT signal-choice bug,
calibration-environment mismatch, origin-reset-as-perceived-inversion) stays
valuable context if IMU-only tracking is ever revisited as a fallback.

Follow-up work continues as a new GSD phase (camera-assisted spatial
tracking), not further debug iterations on this session.

## Current Focus
<!-- OVERWRITE on each update - always reflects NOW -->

hypothesis: PARTIAL-FIX REGRESSION — the prior fix reduced but did not eliminate drift and introduced two new symptoms (perceived axis inversion + intentional movement suppressed). All three now trace to ONE mechanism: ZUPT keyed on |accelerationIncludingGravity| variance FIRES MID-GESTURE. |accelerationIncludingGravity| sits at ~9.8 and its 300ms-window variance dips low at a gesture's velocity peak (linear accel passes through 0 there so magnitude is momentarily near-constant 9.8). The prior threshold WIDENING (x2 to x3, floor 0.001 to 0.01) made mid-gesture firing happen far more often. Each mid-gesture fire (a) zeroes Kalman velocity — killing gesture momentum, "remains almost still / filtered too much"; and (b) re-anchors gestureOrigin to the mid-gesture position, so the deceleration half then drives dx/dy/dz NEGATIVE — "all axes inverted." Residual stillness drift persists because ZUPT flickers and the velocity leak only bounds (not zeroes) drift between fires.
test: Numeric/unit verification (no device). Feed device-frame accel profiles through the pipeline: (A) in-hand still tremor -> ZUPT must fire; (B) sustained slow translation -> ZUPT must NOT fire across the whole gesture; (C) symmetric accelerate->decelerate gesture -> displacement sign stays correct (no inversion) when ZUPT does not re-anchor mid-gesture. Fix under test: switch the ZUPT stillness signal (runtime phone.ts + calibration encode.ts) from |accelerationIncludingGravity| to |linear acceleration| (the SAME vector the Kalman integrates), whose 300ms window variance stays elevated across the entire accel->decel gesture so ZUPT cannot fire mid-gesture.
expecting: Tests green; typecheck clean. ZUPT fires only on genuine stillness; gesture displacement direction preserved. Then human-verify on real device (only ground truth for feel).
next_action: DONE — signal-switch fix applied to phone.ts (ZUPT mag = |linear accel|) + encode.ts runCalibration (sample |e.acceleration|); thresholds kept x3/floor 0.01 (appropriate for the low-baseline linear signal). Tests updated/added, all pass, typecheck clean. Awaiting human on-device confirmation.
reasoning_checkpoint:
  hypothesis: "All three regression symptoms share ONE root: ZUPT is keyed on |accelerationIncludingGravity| variance, a poor motion detector that sits at ~9.8 and whose 300ms window variance drops to a low value at the velocity peak of any hand gesture (linear accel crosses 0 there so magnitude is momentarily near-constant 9.8). With the widened threshold (x3, floor 0.01) ZUPT therefore fires MID-GESTURE. resetVelocity() then kills the gesture momentum (suppression) and gestureOrigin re-anchors to the mid-gesture position so the deceleration half pushes dx/dy/dz negative (perceived inversion). Switching the ZUPT signal to |linear acceleration| — the exact vector the Kalman integrates — keeps window variance elevated across the whole accel->decel gesture (both halves have non-zero |la|), so ZUPT fires ONLY during genuine stillness (|la| near 0 sustained for 300ms), re-anchoring the origin only when the phone is actually at rest."
  confirming_evidence:
    - "phone.ts:900-910 (pre-fix): ZUPT mag = hypot(|accelerationIncludingGravity|), a ~9.8-baseline signal; Kalman integrates the DIFFERENT signal e.acceleration (linear). ZUPT and the drift source were on different signals."
    - "At a hand gesture's velocity peak the linear accel crosses zero so |accelerationIncludingGravity| is momentarily near-constant 9.8 -> 300ms window variance dips below threshold -> ZUPT fires mid-gesture. Widened threshold (prior fix) amplifies this."
    - "phone.ts:928-936 on ZUPT fire: resetVelocity() (zeroes momentum) AND gestureOrigin={rawPx,rawPy,rawPz} (re-anchor). Mid-gesture this truncates the forward half and the subsequent decel half yields dx<0 -> looks inverted. Numerically simulated (see Evidence)."
    - "encode.ts runCalibration (pre-fix) sampled |accelerationIncludingGravity| — same weak signal, so the derived threshold was on the wrong axis of variation."
    - "A constant gravity-subtraction bias in e.acceleration does NOT defeat variance-based ZUPT (constant -> variance near 0 -> still fires), so the residual 'drifts a lot' is explained by ZUPT flicker + leak-bounded (not zeroed) drift, not by a bias the variance test is blind to."
  falsification_test: "If, with the ZUPT signal switched to |linear accel|, a simulated symmetric accelerate->decelerate gesture STILL produced a net-inverted displacement WITHOUT any mid-gesture ZUPT fire, the mechanism would be wrong and the cause would lie in the leaky integrator's high-pass phase response (velTau too small) or an actual sign error, not in ZUPT re-anchoring."
  fix_rationale: "Switching ZUPT's stillness signal (both runtime in phone.ts and calibration in encode.ts) from |accelerationIncludingGravity| to |linear acceleration| structurally removes the mid-gesture fire: the 300ms window spans both the accel and decel halves of a gesture (both non-zero |la|), so variance stays high throughout a gesture and only collapses when |la| near 0 is sustained = genuine stillness. This fixes suppression (no mid-gesture resetVelocity), inversion (no mid-gesture re-anchor), and residual drift (reliable re-anchor during true stillness) with one coherent change, and makes ZUPT consistent with the signal the Kalman actually integrates."
  blind_spots: "Cannot exercise DeviceMotion here — final feel needs a real phone. Threshold values (x3, floor 0.01) are reasoned for the linear-accel baseline (still |la| near 0, variance ~0.001-0.005; slow gesture variance ~0.02+) but NOT device-tuned; a very slow/gentle gesture with variance <0.01 could still be suppressed. On devices where e.acceleration is null, position tracking is already inoperative (Kalman integrates e.acceleration -> 0), so |la| near 0 -> ZUPT always fires -> cube pinned at origin (safe degradation, not a regression). velTau=0.5 left unchanged to avoid altering two variables at once."
tdd_checkpoint: null

## Symptoms
<!-- Written during gathering, then immutable -->

expected: Phone held still (in hand or on a surface) should keep the rendered cube approximately stationary; intentional phone movements should move the cube predictably and proportionally.
actual: Cube drifts/translates continuously and unpredictably even when the phone is held still in-hand (not on a surface); intentional movements are hard to control because of this baseline drift. On a flat surface, ZUPT correctly resets position to still.
errors: None — behavioral/numerical issue, no exceptions or console errors.
reproduction: (1) Rest phone flat on a table — ZUPT fires, cube settles/resets correctly. (2) Hold phone still in hand (not resting on anything) — cube keeps translating/drifting with no sensible relation to actual (near-zero) motion. (3) Also occurs during intentional tilting/movement — motion is described as "without sense," harder to control than the pre-existing drift baseline.
started: Always been this way since dead-reckoning position tracking was added — never really worked.

## Eliminated
<!-- APPEND only - prevents re-investigating after /clear -->

- hypothesis: rotateDeviceToWorld() applies the conjugate of primaryQuat instead of primaryQuat directly, and this wrong rotation direction is the root cause of position drift.
  evidence: Verified the quaternion math by hand (conjugate vs. direct rotation, confirmed via three.js DeviceOrientationControls precedent that eulerToQuat's output is device→world and should be applied directly). Applied the "corrected" direct-rotation fix (commits ba3e172, 672c608) and tested on real device — control got WORSE, not better ("moving without sense... more difficult to move intentionally than with drift"). Root cause: scene.ts's hand-tuned axis negation (set(-rdx,-rdz,rdy), from prior quick task 260710-w83 "Fix inverted position axes") was empirically calibrated against the OLD conjugate rotation's output; changing the rotation direction invalidated that calibration. Reverted in commit 3703a0c. Rotation direction (in isolation) is very unlikely to be the actual root cause of "huge drift" since rotating a noisy vector by q vs q⁻¹ changes its direction, not its magnitude — it cannot by itself eliminate or explain unbounded drift growth.
  timestamp: 2026-07-11T00:00:00Z

## Evidence
<!-- APPEND only - facts discovered during investigation -->

- timestamp: 2026-07-11T00:00:00Z
  checked: User's real-device reproduction, comparing phone resting on a flat surface vs. held still in-hand
  found: On a flat surface, ZUPT correctly detects stillness and resets — cube settles fine. Held still in-hand (unavoidable natural hand tremor present), the cube keeps drifting/translating.
  implication: Strongly points at ZUPT's stillness threshold being too tight for real in-hand holding conditions (tremor variance never drops below adaptiveThreshold), leaving velocity un-reset and letting Kalman1D double-integrate persistent low-amplitude tremor noise into unbounded position drift. This is a distinct, more plausible root cause than the (already-eliminated) rotation-direction bug.

- timestamp: 2026-07-11T00:00:00Z
  checked: client/src/sensor/kalman.ts Kalman1D implementation
  found: predict() does vel += accel*dt; pos += vel*dt with no leak/decay term. resetVelocity() (called on ZUPT) zeroes velocity and shrinks P, but never resets `pos` itself — position only stops changing once velocity is zero, it is never pulled back toward a reference value.
  implication: If ZUPT rarely/never fires (e.g. in-hand tremor case), there is nothing else in the model to bound position growth (aside from the very loose 100m POSITION_MAX clamp) — a pure random-walk accumulation of whatever velocity noise built up before the last successful ZUPT.

- timestamp: 2026-07-11T00:00:00Z
  checked: client/phone.html calibration view copy (view-calibrating, lines 247-253)
  found: SMOKING GUN. The 3-second hold-still calibration instructs the user "Hold your phone still / Place it flat on a surface." So the calibration variance is measured on a table, not in-hand.
  implication: computeCalibration (encode.ts:143-156) computes threshold = max(variance*2, 0.001). A phone flat on a surface has accelerationIncludingGravity magnitude variance ≈ 0, so threshold collapses to the 0.001 floor. This threshold is then applied to in-hand runtime where tremor variance is far higher — ZUPT can never fire. Confirms the calibration-environment mismatch as root cause and explains the exact table-vs-hand difference: on a table variance≈0 < 0.001 (fires every tick); in-hand variance >> 0.001 (never fires).

- timestamp: 2026-07-11T00:00:00Z
  checked: Full data path — which fields the desktop cube actually renders (scene.ts) vs what the phone sends (phone.ts)
  found: scene.ts default positionMode is 'gesture' (line 98), which renders state.dx/dy/dz (lines 193-207), NOT the absolute px/py/pz. On the phone, dx/dy/dz = rawKalmanPos − gestureOrigin, and gestureOrigin is re-anchored (and dx/dy/dz zeroed) ONLY when ZUPT fires (phone.ts:929-935). scene.ts has a 0.002 dead-zone but that only masks sub-2mm noise, not accumulated drift.
  implication: The visible drift is dx/dy/dz growth, which is 100% gated on ZUPT firing to re-anchor the origin. With ZUPT dead in-hand, dx grows without bound. This makes ZUPT firing the single point of failure for the whole gesture pipeline, confirming the fix must (a) make ZUPT fire in-hand and (b) bound the integrator so a single missed ZUPT window cannot run away.

- timestamp: 2026-07-11T02:30:00Z
  checked: On-device human-verify of the prior fix (calibration in-hand copy + threshold x3/floor 0.01 + Kalman velTau=0.5 velocity leak). User's exact report.
  found: "It seems more stable, but drift a lot. Seems that all axes of movement are inverted again. And ZUPT fires very often. If I try to move the cube, it remains almost still, maybe is filtered too much, and continues drifting." Three distinct new/residual symptoms: (1) ZUPT overfires; (2) intentional movement suppressed / cube "remains almost still"; (3) axes feel inverted; plus residual "drifts a lot."
  implication: Prior fix is a PARTIAL fix + regression source, NOT a resolution. The threshold widening overcorrected. The over-firing, suppression, and inversion are consistent with ZUPT firing DURING gestures (not just during stillness), which zeroes velocity mid-gesture and re-anchors the origin mid-gesture. Re-open investigation.

- timestamp: 2026-07-11T02:30:00Z
  checked: Coordinator claim (3) — is "all axes inverted again" a literal sign regression? Re-read the three changed files (phone.html copy, encode.ts thresholds, kalman.ts velTau) and scene.ts axis mapping (set(-rdx,-rdz,rdy), line 207).
  found: None of the prior-fix changes touch any sign. rotateDeviceToWorld (phone.ts:777-787) is still the conjugate form (the direct-rotation experiment was reverted in 3703a0c). scene.ts mapping unchanged. So there is NO literal sign flip introduced.
  implication: "Inverted" is a PERCEIVED effect, not a code sign bug — consistent with the mid-gesture-re-anchor mechanism: ZUPT fires at the gesture velocity peak, re-anchors gestureOrigin to the mid-gesture (forward) position, and the deceleration half then drives displacement negative relative to that new origin -> the net visible motion looks reversed. Falsifies the literal-sign-bug reading; supports the origin-reset-artifact reading.

- timestamp: 2026-07-11T02:30:00Z
  checked: Coordinator claim (1)/(2) mechanism — WHY does ZUPT fire during gestures? Traced the ZUPT signal. phone.ts:900-901 (pre-fix) computes mag = hypot(accelerationIncludingGravity), a ~9.8-baseline signal, while the Kalman integrates the DIFFERENT signal e.acceleration (linear, phone.ts:895-897).
  found: |accelerationIncludingGravity| is a weak translation detector: it sits at ~9.8 and, at a hand gesture's velocity peak, the linear accel crosses zero so the magnitude is momentarily near-constant 9.8 -> the 300ms window variance dips. Widened threshold (x3, floor 0.01) makes that dip cross below-threshold often -> ZUPT fires MID-GESTURE. In contrast |linear acceleration| is ~0 at rest and stays elevated across BOTH the accel and decel halves of a gesture (the 300ms window spans both), so its window variance never collapses mid-gesture.
  implication: The ZUPT signal choice is the shared root of all three regression symptoms. Fix: switch ZUPT (runtime + calibration) to |linear acceleration| — the same vector the Kalman integrates — so ZUPT fires only during genuine sustained stillness and never mid-gesture. This removes the mid-gesture resetVelocity (suppression) and mid-gesture re-anchor (inversion), and restores reliable re-anchor during true stillness (residual drift).

- timestamp: 2026-07-11T02:30:00Z
  checked: Numeric simulation (scratchpad) of a symmetric accelerate->decelerate gesture (accel +1 m/s^2 for 0.5s then -1 for 0.5s) through Kalman1D velTau=0.5, WITH vs WITHOUT a mid-gesture resetVelocity+origin-reanchor at the velocity peak.
  found: WITHOUT mid-gesture reset, net displacement is POSITIVE (~+0.1 m, correct forward direction) and settles back toward 0 as velocity leaks — no inversion. WITH a resetVelocity+origin-reanchor injected at the peak, the post-peak displacement relative to the new origin goes NEGATIVE — the cube's net visible motion is reversed.
  implication: Directly confirms the mechanism: the inversion is caused by the mid-gesture origin re-anchor, not by the velocity leak's phase response and not by any sign error. Falsification branch (leaky-integrator phase inversion) is ruled out for velTau=0.5 at realistic gesture durations.

## Resolution
<!-- OVERWRITE as understanding evolves -->

root_cause: |
  (Evolved over two investigation passes.)

  PASS 1 (partial): ZUPT is the ONLY mechanism that bounds the phone's dead-reckoning position
  drift (it re-anchors gestureOrigin and zeroes the dx/dy/dz the desktop cube renders in gesture
  mode). Pass 1 attributed the in-hand drift to a calibration-environment mismatch (calibrating
  on-surface floored the threshold at 0.001, so ZUPT never fired in-hand). Fixing the copy +
  widening the threshold + adding a velocity leak reduced drift but did NOT resolve it and
  introduced two regressions (perceived inversion + suppressed movement).

  PASS 2 (deeper root): The real defect is the ZUPT SIGNAL CHOICE. ZUPT (and the calibration that
  sets its threshold) keyed on the magnitude of accelerationIncludingGravity — a ~9.8-baseline
  signal that is a poor translation detector: during a hand gesture its 300 ms-window variance
  DROPS (at the velocity peak the linear component crosses zero, so |a| is momentarily near-constant
  9.8). Numerically the AG-magnitude variance during a gesture (~5e-5) is LOWER than at rest
  (~6e-4) — an INVERTED ordering — so ZUPT fired MID-GESTURE, and the prior threshold WIDENING made
  it fire even more. Each mid-gesture fire (a) zeroed Kalman velocity, killing gesture momentum
  ("remains almost still / filtered too much"), and (b) re-anchored gestureOrigin to the mid-gesture
  position, so the deceleration half drove dx/dy/dz NEGATIVE ("all axes inverted" — an origin-reset
  artifact, NOT a literal sign bug; the changed files touch no signs). Residual stillness drift
  persisted because ZUPT flickered and the velocity leak only bounds (not zeroes) drift between fires.
fix: |
  PASS 2 fix — switch the ZUPT stillness signal to |LINEAR acceleration| (the SAME vector the Kalman
  integrates), everywhere:
  (1) phone.ts sensor tick: ZUPT `mag` now = hypot(ax,ay,az) from e.acceleration, NOT
      hypot(accelerationIncludingGravity). |linear accel| is ~0 at rest and stays elevated across
      BOTH the accel and decel halves of a gesture (the 300 ms window spans both), so its window
      variance never collapses mid-gesture → ZUPT fires only on sustained genuine stillness. This
      structurally removes the mid-gesture resetVelocity (suppression) and re-anchor (inversion),
      and restores reliable re-anchor during true stillness (residual drift). Magnitude is
      rotation-invariant so device-frame |la| == world-frame |la|.
  (2) encode.ts runCalibration: sample |e.acceleration| (linear) instead of
      |accelerationIncludingGravity|, so the derived threshold is measured on the same signal ZUPT
      uses at runtime.
  (3) encode.ts computeCalibration: re-tune for the low-baseline linear signal — multiplier 3→2 and
      floor 0.01→0.004 (the ×3/0.01 were sized for the old ~9.8 baseline and over-suppressed gentle
      gestures once the signal changed; 0.004 sits above steady-hand tremor variance ~0.001-0.003 and
      below gentle-gesture variance ~0.008+). The Kalman velocity leak (velTau=0.5) is the secondary
      drift bound, so ZUPT can safely err toward NOT firing during motion.

  PASS 1 changes RETAINED (still correct / complementary): phone.html "Hold it steady in your hand"
  copy; Kalman1D velTau=0.5 velocity leak. velTau left UNCHANGED this pass (avoid altering two
  variables at once).

  Devices with null e.acceleration: |la|=0 → ZUPT always fires → cube pins at origin. Safe
  degradation — those devices cannot dead-reckon position anyway (Kalman integrates e.acceleration→0).
verification: |
  Self-verification (numeric/unit — no physical phone in this environment):
  - Typecheck: `tsc --noEmit` exits 0. Vite build succeeds.
  - Full test suite: 99/99 pass across 7 files (was 96; +3 new ZUPT signal-choice tests).
  - Numeric simulation (scratchpad, replica of Kalman1D leaky integrator) of a symmetric
    accelerate→decelerate gesture (+1 then −1 m/s² for 0.5 s each, velTau=0.5):
      · WITHOUT mid-gesture re-anchor: net displacement +0.10 m (correct forward), settles to
        +0.0018 m as velocity leaks — NO inversion.
      · WITH a mid-gesture resetVelocity+origin-reanchor at the velocity peak: displacement ends
        −0.096 m (then −0.25 m during hold) — INVERTED. Directly confirms the inversion is caused
        by the mid-gesture re-anchor, ruling out the leaky-integrator-phase and sign-error branches.
  - Numeric simulation of window variances confirms the signal fix:
      · |linear accel| variance — still 0.00018, gesture 0.00806 (correct ordering; a threshold
        separates them).
      · |accelIncludingGravity| variance — still 0.00059, gesture 0.00006 (INVERTED ordering — the
        gesture reads "stiller" than rest → mid-gesture fire). This is the mechanism, and why the
        signal switch is the fix.
  - New/updated tests: encode.test.ts (computeCalibration floor 0.004 / ×2; linear-accel
    still-vs-gesture separation regression) and zupt.test.ts (linear-accel gesture window does NOT
    fire; still window DOES fire; and a documentation test showing the OLD accelIncludingGravity
    signal WOULD fire mid-gesture). All numeric expectations verified against hand-computed values.
  PENDING: On-device confirmation by the user (Device Motion cannot be exercised here) that
  (1) an in-hand-held phone keeps the cube approximately stationary, (2) intentional gestures move
  the cube in the CORRECT direction (no inversion) and proportionally, and (3) ZUPT no longer fires
  mid-gesture / over-suppresses movement. Threshold values are reasoned, not device-tuned — feel may
  still need a knob adjustment.
files_changed:
  - client/phone.ts                   # ZUPT stillness signal: |accelerationIncludingGravity| → |linear acceleration| (hypot(ax,ay,az))
  - client/src/sensor/encode.ts       # runCalibration samples |e.acceleration| (linear); computeCalibration multiplier 3→2, floor 0.01→0.004
  - client/phone.html                 # (Pass 1, retained) calibration copy "Hold it steady in your hand"
  - client/src/sensor/kalman.ts       # (Pass 1, retained) Kalman1D.predict velocity leak (velTau, default 0.5 s)
  - client/tests/encode.test.ts       # computeCalibration expectations (0.004 floor, ×2) + linear-accel still-vs-gesture separation test
  - client/tests/zupt.test.ts         # new "linear-accel signal fires on stillness, not mid-gesture" suite (3 tests)
  - client/tests/kalman.test.ts       # (Pass 1, retained) velocity-leak drift-bound suite
