---
slug: fix-phone-disconnect-on-leave
date: 2026-07-10
status: complete
---

# Fix: Phone disconnect on desktop leave

**Problem:** `updateConnectingUI()` only updated `#chan-open` counter text. When
`openChannelCount` dropped to 0 (desktop clicked Leave Room), phone stayed on
`view-active` with no connected desktop.

**Fix:** Added 3-line guard in `updateConnectingUI()` — when `openChannelCount === 0
&& sensorPipelineRunning`, reset flag and call `showView('view-connecting')`.

**Why reset sensorPipelineRunning:** The flag guards re-calibration on temporary desktop
reconnects. On intentional leave (`peer-left` from `handle_leave`), resetting allows
fresh calibration for the next desktop that joins.

**Files modified:** `client/src/phone.ts`

**Verification:** `npm run typecheck && npm run build` both pass. Manual test required:
click Leave Room on desktop → phone should show view-connecting within ~1s.
