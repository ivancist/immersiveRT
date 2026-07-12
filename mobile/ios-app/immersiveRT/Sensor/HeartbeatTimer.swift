import Foundation

/// A cancellable handle to a scheduled repeating fire — returned by
/// `HeartbeatScheduler.schedule(interval:fire:)`.
protocol HeartbeatCancelable: AnyObject {
    func cancel()
}

/// Abstraction over "repeat this closure every `interval` seconds."
///
/// Exists so `HeartbeatTimer` never talks to `Foundation.Timer` directly —
/// tests inject a fake scheduler that fires deterministically (no real 5s
/// waits), while production code uses `TimerHeartbeatScheduler` below.
protocol HeartbeatScheduler {
    func schedule(interval: TimeInterval, fire: @escaping () -> Void) -> HeartbeatCancelable
}

/// Production `HeartbeatScheduler` backed by `Foundation.Timer`.
final class TimerHeartbeatScheduler: HeartbeatScheduler {

    private final class TimerToken: HeartbeatCancelable {
        private let timer: Timer
        init(timer: Timer) { self.timer = timer }
        func cancel() { timer.invalidate() }
    }

    func schedule(interval: TimeInterval, fire: @escaping () -> Void) -> HeartbeatCancelable {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            fire()
        }
        return TimerToken(timer: timer)
    }
}

/// Sends a `heartbeat` envelope on a fixed interval to keep the paired slot
/// alive (PHONE-06), porting `client/src/phone.ts`'s `startHeartbeat()`.
///
/// The heartbeat is dispatched through an injected `send` closure — never a
/// hardcoded transport — so it rides whichever `SignalingTransport`
/// conformance (WebTransport or WebSocket fallback) is currently active
/// (D-04, Shared Pattern: envelope dispatch).
final class HeartbeatTimer {

    private let interval: TimeInterval
    private let scheduler: HeartbeatScheduler
    private let myId: () -> String
    private let send: (SignalingEnvelope) -> Void
    private var currentToken: HeartbeatCancelable?

    init(
        interval: TimeInterval = 5.0,
        scheduler: HeartbeatScheduler = TimerHeartbeatScheduler(),
        myId: @escaping () -> String,
        send: @escaping (SignalingEnvelope) -> Void
    ) {
        self.interval = interval
        self.scheduler = scheduler
        self.myId = myId
        self.send = send
    }

    /// Starts firing heartbeats every `interval` seconds (default 5s,
    /// PHONE-06).
    ///
    /// Idempotent: clears any existing timer before starting a new one —
    /// mirrors `startHeartbeat()`'s
    /// `if (heartbeatInterval !== null) { clearInterval(heartbeatInterval); }`
    /// guard, so calling `start()` again (e.g. at initial pair success and
    /// again after every successful reconnect) never double-fires.
    func start() {
        currentToken?.cancel()
        currentToken = scheduler.schedule(interval: interval) { [weak self] in
            guard let self else { return }
            self.send(
                SignalingEnvelope(
                    type: SignalingEnvelope.SignalingType.heartbeat,
                    from: self.myId(),
                    to: "",
                    payload: [:]
                )
            )
        }
    }

    /// Halts further heartbeats.
    func stop() {
        currentToken?.cancel()
        currentToken = nil
    }
}
