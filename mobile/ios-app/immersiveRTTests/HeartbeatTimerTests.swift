import XCTest
@testable import immersiveRT

/// Deterministic test double for `HeartbeatScheduler` — records every
/// `schedule(interval:fire:)` call and lets tests invoke the latest fire
/// closure manually, so `HeartbeatTimerTests` never waits on a real 5s
/// `Timer`.
final class FakeHeartbeatScheduler: HeartbeatScheduler {

    final class FakeToken: HeartbeatCancelable {
        private(set) var isCancelled = false
        func cancel() { isCancelled = true }
    }

    private(set) var scheduledIntervals: [TimeInterval] = []
    private(set) var tokens: [FakeToken] = []
    private var fireClosures: [() -> Void] = []

    func schedule(interval: TimeInterval, fire: @escaping () -> Void) -> HeartbeatCancelable {
        scheduledIntervals.append(interval)
        fireClosures.append(fire)
        let token = FakeToken()
        tokens.append(token)
        return token
    }

    /// Invokes the most recently scheduled `fire` closure — simulates one
    /// interval elapsing on whichever timer is currently active.
    func fireLatest() {
        fireClosures.last?()
    }
}

final class HeartbeatTimerTests: XCTestCase {

    func test_start_firesHeartbeatEveryInterval() {
        let scheduler = FakeHeartbeatScheduler()
        var sent: [SignalingEnvelope] = []
        let timer = HeartbeatTimer(interval: 5.0, scheduler: scheduler, myId: { "phone-1" }) {
            sent.append($0)
        }

        timer.start()
        scheduler.fireLatest()
        scheduler.fireLatest()
        scheduler.fireLatest()

        XCTAssertEqual(sent.count, 3, "exactly one heartbeat per elapsed interval")
        XCTAssertEqual(scheduler.scheduledIntervals, [5.0])
    }

    func test_startTwice_doesNotDoubleFireRate() {
        let scheduler = FakeHeartbeatScheduler()
        var sent: [SignalingEnvelope] = []
        let timer = HeartbeatTimer(scheduler: scheduler, myId: { "phone-1" }) {
            sent.append($0)
        }

        timer.start()
        timer.start() // idempotent restart — mirrors startHeartbeat()'s clear-before-start

        XCTAssertEqual(scheduler.tokens.count, 2, "second start() schedules a fresh timer")
        XCTAssertTrue(scheduler.tokens[0].isCancelled, "first timer must be cancelled before the second starts")

        scheduler.fireLatest()

        XCTAssertEqual(sent.count, 1, "only the latest (second) scheduled timer should fire — no double-fire rate")
    }

    func test_stop_haltsFurtherHeartbeats() {
        let scheduler = FakeHeartbeatScheduler()
        var sent: [SignalingEnvelope] = []
        let timer = HeartbeatTimer(scheduler: scheduler, myId: { "phone-1" }) {
            sent.append($0)
        }

        timer.start()
        scheduler.fireLatest()
        timer.stop()

        XCTAssertTrue(scheduler.tokens.last?.isCancelled == true, "stop() cancels the active timer")
        XCTAssertEqual(sent.count, 1, "no heartbeats after stop()")
    }

    func test_envelopeShape_isHeartbeatWithEmptyPayload() throws {
        let scheduler = FakeHeartbeatScheduler()
        var sent: [SignalingEnvelope] = []
        let timer = HeartbeatTimer(scheduler: scheduler, myId: { "phone-42" }) {
            sent.append($0)
        }

        timer.start()
        scheduler.fireLatest()

        let envelope = try XCTUnwrap(sent.first)
        XCTAssertEqual(envelope.type, SignalingEnvelope.SignalingType.heartbeat)
        XCTAssertEqual(envelope.from, "phone-42")
        XCTAssertEqual(envelope.to, "")
        XCTAssertTrue(envelope.payload.isEmpty)
    }
}
