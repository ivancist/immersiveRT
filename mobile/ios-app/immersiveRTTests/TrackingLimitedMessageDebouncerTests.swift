import XCTest
@testable import immersiveRT

/// Pure-function tests for `TrackingLimitedMessageDebouncer` (D-08 anti-
/// flicker fix, 06.3-06 Task 3 on-device follow-up). No `ARSession` or real
/// clock is ever involved — every candidate and `nowMs` is synthetic,
/// matching `HoldStillDetectorTests`'s fixture-driven approach.
final class TrackingLimitedMessageDebouncerTests: XCTestCase {

    // MARK: - Rapid oscillation within the dwell window -> no report

    /// Alternating between two different candidate messages faster than the
    /// dwell threshold must never produce a report — this is exactly the
    /// on-device bug: real ARKit flicker between `.limited(reason:)`
    /// sub-reasons should not each re-trigger a toast.
    func test_rapidOscillationBetweenReasons_withinDwellWindow_producesNoReport() {
        let debouncer = TrackingLimitedMessageDebouncer(dwellDurationMs: 400)

        var nowMs: Double = 0
        let messages = ["excessiveMotion", "insufficientFeatures"]
        for i in 0..<10 {
            let candidate = messages[i % messages.count]
            let result = debouncer.ingest(candidate: candidate, nowMs: nowMs)
            XCTAssertEqual(result, .noChange, "oscillation at \(nowMs)ms must not report (candidate: \(candidate))")
            nowMs += 50 // faster than the 400ms dwell threshold
        }
    }

    /// The same oscillation scenario, but expressed as flickering back and
    /// forth to/from a single already-reported value — the "same type
    /// re-triggers" half of the user's on-device report ("also of the same
    /// type").
    func test_rapidOscillation_backToAlreadyReportedValue_producesNoReport() {
        let debouncer = TrackingLimitedMessageDebouncer(dwellDurationMs: 400)

        // Get "excessiveMotion" reported once (stable for the full dwell).
        XCTAssertEqual(debouncer.ingest(candidate: "excessiveMotion", nowMs: 0), .noChange)
        XCTAssertEqual(debouncer.ingest(candidate: "excessiveMotion", nowMs: 400), .report("excessiveMotion"))

        // Now flicker rapidly: briefly to a different reason and back to the
        // already-reported "excessiveMotion", faster than the dwell window
        // each time. None of this should produce a second report of
        // "excessiveMotion", nor any report of "insufficientFeatures".
        var nowMs: Double = 450
        for _ in 0..<6 {
            XCTAssertEqual(debouncer.ingest(candidate: "insufficientFeatures", nowMs: nowMs), .noChange)
            nowMs += 50
            XCTAssertEqual(debouncer.ingest(candidate: "excessiveMotion", nowMs: nowMs), .noChange, "flickering back to the already-reported value must not re-report it")
            nowMs += 50
        }
    }

    // MARK: - Stable message beyond the dwell window -> exactly one report

    /// A candidate that is the continuous per-frame value for at least the
    /// dwell duration produces exactly one `.report`, not on the exact frame
    /// it stabilizes and never again on subsequent stable frames.
    func test_stableMessage_beyondDwellWindow_producesExactlyOneReport() {
        let debouncer = TrackingLimitedMessageDebouncer(dwellDurationMs: 400)

        XCTAssertEqual(debouncer.ingest(candidate: "excessiveMotion", nowMs: 0), .noChange)
        XCTAssertEqual(debouncer.ingest(candidate: "excessiveMotion", nowMs: 100), .noChange, "not yet stable for the full 400ms")
        XCTAssertEqual(debouncer.ingest(candidate: "excessiveMotion", nowMs: 300), .noChange, "not yet stable for the full 400ms")

        // Crossing the 400ms threshold (elapsed since the pending window
        // started at nowMs=0).
        XCTAssertEqual(debouncer.ingest(candidate: "excessiveMotion", nowMs: 400), .report("excessiveMotion"))

        // Continuing to observe the SAME stable value afterward must not
        // re-fire — this is precisely the "toasts accumulate ... also of
        // the same type" bug.
        XCTAssertEqual(debouncer.ingest(candidate: "excessiveMotion", nowMs: 450), .noChange)
        XCTAssertEqual(debouncer.ingest(candidate: "excessiveMotion", nowMs: 10_000), .noChange)
    }

    /// A candidate value change that occurs before the dwell threshold
    /// elapses restarts the pending window entirely — the elapsed time
    /// against the OLD candidate is discarded, not carried over to the new
    /// one.
    func test_candidateChangeBeforeDwellElapses_restartsWindowForNewCandidate() {
        let debouncer = TrackingLimitedMessageDebouncer(dwellDurationMs: 400)

        XCTAssertEqual(debouncer.ingest(candidate: "excessiveMotion", nowMs: 0), .noChange)
        XCTAssertEqual(debouncer.ingest(candidate: "excessiveMotion", nowMs: 300), .noChange)

        // Switches to a different reason at 300ms, well before "excessiveMotion"
        // would have dwelled long enough (400ms).
        XCTAssertEqual(debouncer.ingest(candidate: "insufficientFeatures", nowMs: 300), .noChange)

        // Only 300ms after the NEW candidate started (600ms) — must still
        // be pending, not reported, since its own window restarted at 300ms.
        XCTAssertEqual(debouncer.ingest(candidate: "insufficientFeatures", nowMs: 600), .noChange)

        // 400ms after the new candidate's own window start (300ms -> 700ms)
        // it finally reports.
        XCTAssertEqual(debouncer.ingest(candidate: "insufficientFeatures", nowMs: 700), .report("insufficientFeatures"))
    }

    // MARK: - nil (recovered) case is debounced symmetrically

    /// The `nil`/recovered transition goes through the identical dwell gate
    /// as any non-nil reason: a brief flicker back to `.limited` before nil
    /// has dwelled long enough must not report `nil` (dismiss the toast)
    /// only to immediately re-report the limited reason.
    func test_recoveredNilCandidate_isDebouncedSymmetrically() {
        let debouncer = TrackingLimitedMessageDebouncer(dwellDurationMs: 400)

        // Get "excessiveMotion" reported first (tracking is currently
        // limited and the toast is showing).
        XCTAssertEqual(debouncer.ingest(candidate: "excessiveMotion", nowMs: 0), .noChange)
        XCTAssertEqual(debouncer.ingest(candidate: "excessiveMotion", nowMs: 400), .report("excessiveMotion"))

        // Tracking briefly reports .normal (candidate nil), then flickers
        // back to the SAME already-reported "excessiveMotion" before nil's
        // own dwell window would have elapsed — must not report nil (no
        // dismiss-then-reappear flash).
        XCTAssertEqual(debouncer.ingest(candidate: nil, nowMs: 450), .noChange)
        XCTAssertEqual(debouncer.ingest(candidate: "excessiveMotion", nowMs: 500), .noChange, "flicker back to the already-reported reason must not re-report it")

        // Now tracking genuinely recovers and STAYS nil for the full dwell
        // window — this must report nil exactly once (dismiss the toast).
        XCTAssertEqual(debouncer.ingest(candidate: nil, nowMs: 550), .noChange)
        XCTAssertEqual(debouncer.ingest(candidate: nil, nowMs: 950), .report(nil))

        // And continuing to observe the recovered (nil) state afterward
        // must not re-fire.
        XCTAssertEqual(debouncer.ingest(candidate: nil, nowMs: 5_000), .noChange)
    }

    /// The very first-ever call with a `nil` candidate must not produce a
    /// report — the debouncer's initial "last reported" state is already
    /// nil (matching the original dedup field's initial value), so this is
    /// "no change from the implicit initial state", not a genuine recovery.
    func test_firstCallWithNilCandidate_producesNoReport() {
        let debouncer = TrackingLimitedMessageDebouncer(dwellDurationMs: 400)
        XCTAssertEqual(debouncer.ingest(candidate: nil, nowMs: 0), .noChange)
        XCTAssertEqual(debouncer.ingest(candidate: nil, nowMs: 1_000), .noChange)
    }

    // MARK: - Deterministic via injected nowMs

    /// Two debouncers fed the exact same (candidate, nowMs) sequence produce
    /// identical results every time — no dependency on the real wall clock.
    func test_deterministicResultsGivenIdenticalInjectedTimestamps() {
        let samples: [(nowMs: Double, candidate: String?)] = [
            (0, "initializing"),
            (200, "initializing"),
            (400, "initializing"),
            (450, nil),
            (900, nil),
        ]

        func run() -> [TrackingLimitedMessageDebouncer.Result] {
            let debouncer = TrackingLimitedMessageDebouncer(dwellDurationMs: 400)
            return samples.map { sample in
                debouncer.ingest(candidate: sample.candidate, nowMs: sample.nowMs)
            }
        }

        let resultsA = run()
        let resultsB = run()

        XCTAssertEqual(resultsA, resultsB)
        XCTAssertEqual(resultsA, [
            .noChange,
            .noChange,
            .report("initializing"),
            .noChange,
            .report(nil),
        ])
    }
}
