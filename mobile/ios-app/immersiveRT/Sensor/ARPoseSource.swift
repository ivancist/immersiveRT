import ARKit
import Foundation
import simd

/// Headless-`ARSession` world-tracking pose source (D-01, D-14) — the
/// ARKit equivalent of `CoreMotionSource`, superseding it for BOTH
/// orientation AND position (unlike CoreMotion, which only ever produced
/// orientation).
///
/// Structural shape mirrors `CoreMotionSource.swift` exactly: a `final
/// class` wrapping the OS sensor API, a single public closure callback
/// (`onPose`), `start()`/`stop()` guarded by a device-capability check, and
/// a dedicated background delivery queue — never the main queue/actor for
/// the 60Hz pose stream itself (Pitfall 3 of RESEARCH.md: callers that need
/// UI-visible state must hop to `@MainActor` explicitly and at a throttled
/// rate, exactly like `CoreMotionSource`'s own doc comment instructs).
///
/// Delegate-queue decision (RESEARCH.md Pitfall 2): `ARSessionDelegate`
/// callbacks default to the MAIN queue unless `session.delegateQueue` is
/// explicitly set otherwise. This class explicitly assigns a dedicated
/// serial background `DispatchQueue` to `session.delegateQueue` — mirroring
/// `CoreMotionSource`'s off-main convention — so the 60Hz pose-conversion +
/// packet-encode work never contends with main-thread UI work, at the cost
/// of one documented queue hop (`ARSessionDelegate` background queue →
/// `@MainActor`, performed by `TransportManager.startSensorLoopIfNeeded()`).
/// This is a deliberate, explicit choice per Pitfall 2's instruction to not
/// silently assume either option — do not remove `delegateQueue` without
/// updating this comment.
///
/// D-14 (data minimization): only `frame.camera.transform` and
/// `frame.camera.trackingState` are ever read from an `ARFrame` here. Raw
/// camera pixel buffers (`frame.capturedImage`) and depth buffers
/// (`frame.capturedDepthData`) are never accessed, retained, logged, or
/// forwarded anywhere in this class. There is no rendering view of any kind
/// — this is a headless `ARSession` per RESEARCH.md Pattern 1.
final class ARPoseSource: NSObject, ARSessionDelegate {

    /// Invoked once per ARKit frame update, on the dedicated background
    /// `sessionQueue` below — NOT the main actor. Callers that need to
    /// surface UI-visible state must explicitly hop to `@MainActor`
    /// themselves, at a throttled rate, not once per callback (mirrors
    /// `CoreMotionSource.onOrientation`'s doc comment exactly).
    var onPose: ((ARPose) -> Void)?

    /// Fires with the current per-frame hold-still result (Task 1's
    /// `HoldStillDetector.ingest`) on every frame until auto-calibration
    /// completes — lets a future UI (Plan 06's DynamicToast wiring)
    /// indicate "hold still to calibrate…" progress. Called on the same
    /// background `sessionQueue` as `onPose`; callers needing UI-visible
    /// state must hop to `@MainActor` themselves, exactly like `onPose`.
    var onCalibrationProgress: ((Bool) -> Void)?

    /// Fires exactly once, the moment auto-calibration (D-10) completes:
    /// the device was held still for `HoldStillDetector`'s required
    /// duration and `recenter()` has just been called to lock the world
    /// origin. Called on `sessionQueue` — same hop-to-`@MainActor`
    /// convention as `onPose`.
    var onCalibrationComplete: (() -> Void)?

    /// `true` once the auto-calibration recenter (D-10) has fired for this
    /// session. Flips to `true` exactly once; read from `sessionQueue` only
    /// (mirrors every other piece of frame-driven state in this class).
    private(set) var isCalibrated = false

    private let session: ARSession
    private let tracker: ARPoseTracker

    /// Drives the D-10 auto-calibration gate purely from `ARCamera.transform`
    /// position deltas (never CoreMotion/accelerometer — see
    /// `HoldStillDetector`'s own doc comment). Reset per `ARPoseSource`
    /// instance, i.e. once per app-launch session.
    private let holdStillDetector: HoldStillDetector

    /// Dedicated, non-main queue for `ARSessionDelegate` delivery. Serial
    /// (a plain `DispatchQueue` is serial by default) so pose samples are
    /// handled in arrival order without needing additional synchronization
    /// — see the delegate-queue decision documented above.
    private let sessionQueue = DispatchQueue(label: "com.immersiveRT.ARPoseSource.sessionQueue")

    init(
        session: ARSession = ARSession(),
        tracker: ARPoseTracker = ARPoseTracker(),
        holdStillDetector: HoldStillDetector = HoldStillDetector()
    ) {
        self.session = session
        self.tracker = tracker
        self.holdStillDetector = holdStillDetector
        super.init()
    }

    /// Starts headless world tracking. No-op (no crash, no callback) if
    /// `ARWorldTrackingConfiguration.isSupported` is false — mirrors
    /// `CoreMotionSource.start()`'s `isDeviceMotionAvailable` capability
    /// guard exactly.
    func start() {
        guard ARWorldTrackingConfiguration.isSupported else { return }
        let config = ARWorldTrackingConfiguration()
        // `config.worldAlignment` is left at its `.gravity` default per
        // RESEARCH.md Pattern 1 — do not override without a reason.
        session.delegateQueue = sessionQueue
        session.delegate = self
        session.run(config)
    }

    /// Stops world tracking.
    func stop() {
        session.pause()
    }

    /// Re-anchors the world origin to the device's CURRENT pose, WITHOUT a
    /// full session restart (RESEARCH.md Pattern 2 — never re-run the
    /// session with a tracking-reset option for a routine recenter, since
    /// that would cause a visible tracking blip). Invoked automatically
    /// once, after auto-calibration completes (D-10, see
    /// `session(_:didUpdate:)` below), and manually on demand via
    /// `TransportManager.recenter()` (D-11).
    func recenter() {
        session.setWorldOrigin(relativeTransform: matrix_identity_float4x4)
    }

    // MARK: - ARSessionDelegate

    /// Fires once per ARKit frame (headless — no rendering surface
    /// involved). Feeds ONLY `frame.camera.transform` and
    /// `frame.camera.trackingState` into `tracker`, drives the D-10
    /// auto-calibration gate from the resulting pose, then invokes `onPose`
    /// with the tracker's current wire-ready pose. D-14: never reads
    /// `frame.capturedImage`/`frame.capturedDepthData` or any other raw
    /// buffer from `frame`.
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        tracker.ingest(transform: frame.camera.transform, trackingState: frame.camera.trackingState)
        let pose = tracker.currentPose()
        updateAutoCalibration(with: pose)
        onPose?(pose)
    }

    /// D-10: drives `holdStillDetector` from the current pose's position
    /// only (never orientation/CoreMotion — see `HoldStillDetector`'s doc
    /// comment). Once the device has been held still for the required
    /// duration, calls `recenter()` exactly once to lock the world origin,
    /// marks the stream calibrated, and notifies `onCalibrationComplete`.
    /// A no-op after `isCalibrated` is already `true` — this is a one-time,
    /// session-start gate, not a repeating recenter.
    private func updateAutoCalibration(with pose: ARPose) {
        guard !isCalibrated else { return }

        let nowMs = Date().timeIntervalSince1970 * 1000
        let isStill = holdStillDetector.ingest(px: pose.px, py: pose.py, pz: pose.pz, nowMs: nowMs)
        onCalibrationProgress?(isStill)

        guard isStill else { return }

        isCalibrated = true
        recenter()
        onCalibrationComplete?()
    }
}
