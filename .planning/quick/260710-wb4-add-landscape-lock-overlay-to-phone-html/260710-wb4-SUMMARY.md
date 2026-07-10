---
quick_id: 260710-wb4
status: complete
date: 2026-07-10
commit: 00eb30d
---

# Quick Task 260710-wb4: Prevent Screen Rotation — Summary

## What Changed

**client/phone.html:**
- Added `#landscape-overlay` CSS block: `display:none` in portrait, `display:flex` in landscape via `@media (orientation: landscape)`
- Added overlay div with "Rotate your phone / This controller works in portrait only." — shown automatically when phone rotates

**client/src/phone.ts:**
- Extracted `tryLockPortrait()` helper from the inline DOMContentLoaded block
- Added `tryLockPortrait()` call at top of `btn-grant-motion` click handler (user gesture context — required by Chrome Android)
- DOMContentLoaded still calls `tryLockPortrait()` for early best-effort attempt

## Coverage

| Browser | Mechanism |
|---------|-----------|
| iOS Safari | CSS overlay (lock API unsupported) |
| Android Chrome | `screen.orientation.lock()` in user gesture |
| Android Firefox | CSS overlay fallback |
| All others | CSS overlay fallback |
