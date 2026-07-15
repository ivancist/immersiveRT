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

    private let session: ARSession
    private let tracker: ARPoseTracker

    /// Dedicated, non-main queue for `ARSessionDelegate` delivery. Serial
    /// (a plain `DispatchQueue` is serial by default) so pose samples are
    /// handled in arrival order without needing additional synchronization
    /// — see the delegate-queue decision documented above.
    private let sessionQueue = DispatchQueue(label: "com.immersiveRT.ARPoseSource.sessionQueue")

    init(session: ARSession = ARSession(), tracker: ARPoseTracker = ARPoseTracker()) {
        self.session = session
        self.tracker = tracker
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
    /// full session restart (RESEARCH.md Pattern 2) — fully wired to a
    /// user-facing action in Plan 05 (D-10/D-11); this stub only performs
    /// the underlying ARKit call.
    func recenter() {
        session.setWorldOrigin(relativeTransform: matrix_identity_float4x4)
    }

    // MARK: - ARSessionDelegate

    /// Fires once per ARKit frame (headless — no rendering surface
    /// involved). Feeds ONLY `frame.camera.transform` and
    /// `frame.camera.trackingState` into `tracker`, then invokes `onPose`
    /// with the tracker's current wire-ready pose. D-14: never reads
    /// `frame.capturedImage`/`frame.capturedDepthData` or any other raw
    /// buffer from `frame`.
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        tracker.ingest(transform: frame.camera.transform, trackingState: frame.camera.trackingState)
        onPose?(tracker.currentPose())
    }
}
