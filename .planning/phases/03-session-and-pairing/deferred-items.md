# Phase 03 Deferred Items

Items discovered during Phase 03 execution that are out-of-scope per the executor
scope boundary (pre-existing issues in files not modified by the current task).

---

## D-001: `TurnCredentials` missing `#[derive(Debug)]` — main.rs binary test fails

**Discovered during:** Plan 03-01, Task 2
**File:** `server/src/turn_creds.rs` (struct `TurnCredentials`)
**Symptom:** `cargo test -p immersive-rt-server` fails with:
```
error[E0277]: `TurnCredentials` doesn't implement `std::fmt::Debug`
   --> server/src/main.rs:167:26
     let err = result.expect_err("handler should fail with wrong token");
```
**Root cause:** `expect_err()` requires the `Ok` type (`Json<TurnCredentials>`) to implement
`Debug`. This became a hard compile-time requirement in Rust 1.93.1. The test was added in
commit `d75a55d` (Phase 02 CR-01).
**Fix:** Add `#[derive(Debug)]` to `struct TurnCredentials` in `server/src/turn_creds.rs`.
**Workaround used:** `cargo test --lib` (library-only target) skips the binary test compilation,
allowing Phase 03 tests to run correctly.
**Impact:** Binary target tests cannot run until fixed. Library tests unaffected.
**Priority:** Medium — fix before next phase that compiles the binary test target.
