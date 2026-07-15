import XCTest
@testable import immersiveRT

/// Pure-function tests for `HoldStillDetector` (D-10). No `ARSession` or
/// real clock is ever involved — every sample's position and `nowMs` are
/// synthetic, matching `ARPoseConversionTests`'s fixture-driven approach.
final class HoldStillDetectorTests: XCTestCase {

    // MARK: - Sustained still -> true after required duration

    /// Feeding position samples whose frame-to-frame displacement stays
    /// below the threshold for at least `requiredStillDurationMs` reports
    /// `isStill == true` once that duration has elapsed since the window
    /// started; it must NOT report true before then.
    func test_sustainedStill_reportsTrueOnlyAfterRequiredDurationElapses() {
        let detector = HoldStillDetector(
            displacementThresholdMeters: 0.005,
            requiredStillDurationMs: 500
        )

        // First sample seeds the still-window; never true on the very first
        // ingest (nothing to diff against yet).
        var elapsedMs: Double = 0
        XCTAssertFalse(detector.ingest(px: 0, py: 0, pz: 0, nowMs: elapsedMs))

        // Sub-threshold jitter (0.1mm) every 100ms, well under the 500ms
        // requirement each time.
        for _ in 0..<4 {
            elapsedMs += 100
            let stillSoFar = detector.ingest(px: 0.0001, py: 0, pz: 0, nowMs: elapsedMs)
            XCTAssertFalse(stillSoFar, "should not report still before \(500)ms have elapsed (at \(elapsedMs)ms)")
        }

        // Crossing the 500ms threshold (elapsed since window start = 600ms).
        elapsedMs += 200
        XCTAssertTrue(detector.ingest(px: 0.0001, py: 0, pz: 0, nowMs: elapsedMs))
    }

    // MARK: - Jump resets the still-accumulation window

    /// A single frame-to-frame displacement exceeding the threshold resets
    /// the accumulator: `isStill` immediately reports `false`, and stays
    /// `false` until a fresh still-window re-accumulates for the full
    /// required duration.
    func test_largeJump_resetsStillAccumulationWindow() {
        let detector = HoldStillDetector(
            displacementThresholdMeters: 0.005,
            requiredStillDurationMs: 500
        )

        _ = detector.ingest(px: 0, py: 0, pz: 0, nowMs: 0)
        XCTAssertTrue(detector.ingest(px: 0, py: 0, pz: 0, nowMs: 600), "should be still after 600ms of no motion")

        // A 1-meter jump is far above the 5mm threshold.
        let immediatelyAfterJump = detector.ingest(px: 1.0, py: 0, pz: 0, nowMs: 610)
        XCTAssertFalse(immediatelyAfterJump, "a large jump must reset the still-accumulation window")

        // Even a moment later (well under the required duration since the
        // reset), it must still report false — the window has not
        // re-accumulated yet.
        let shortlyAfterJump = detector.ingest(px: 1.0, py: 0, pz: 0, nowMs: 620)
        XCTAssertFalse(shortlyAfterJump, "still-window must re-accumulate fully after a reset")

        // Once the full required duration has elapsed since the reset
        // (window restarted at nowMs=610), it reports still again.
        let reaccumulated = detector.ingest(px: 1.0, py: 0, pz: 0, nowMs: 1200)
        XCTAssertTrue(reaccumulated, "should report still again once the window re-accumulates post-reset")
    }

    // MARK: - Deterministic via injected nowMs

    /// Two detectors fed the exact same (position, nowMs) sequence produce
    /// identical results every time — no dependency on the real wall clock.
    func test_deterministicResultsGivenIdenticalInjectedTimestamps() {
        let samples: [(nowMs: Double, px: Double, py: Double, pz: Double)] = [
            (0, 0, 0, 0),
            (100, 0.0001, 0, 0),
            (600, 0.0001, 0, 0),
        ]

        func run() -> [Bool] {
            let detector = HoldStillDetector(
                displacementThresholdMeters: 0.005,
                requiredStillDurationMs: 500
            )
            return samples.map { sample in
                detector.ingest(px: sample.px, py: sample.py, pz: sample.pz, nowMs: sample.nowMs)
            }
        }

        let resultsA = run()
        let resultsB = run()

        XCTAssertEqual(resultsA, resultsB)
        XCTAssertEqual(resultsA, [false, false, true])
    }
}
