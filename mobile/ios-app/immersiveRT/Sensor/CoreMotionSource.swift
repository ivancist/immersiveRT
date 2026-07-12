import CoreMotion
import Foundation

/// OS-fused orientation source (PHONE-04, D-09).
///
/// Wraps `CMMotionManager` and streams `CMDeviceMotion.attitude.quaternion`
/// at ~60Hz on a dedicated background `OperationQueue` — never the main
/// queue/actor (Pitfall 3). CoreMotion has already fused gyro+accelerometer
/// internally; this class runs NO secondary fusion pass on top of that
/// output, mirroring the same convention the web client already follows
/// for `DeviceOrientationEvent` (CLAUDE.md IMU Sensor Fusion section,
/// RESEARCH.md Anti-Patterns: "Running a secondary orientation-fusion pass
/// on top of CoreMotion's `attitude`").
///
/// Emits ORIENTATION ONLY. Position, gesture displacement, and
/// driftConfidence are NOT produced here — they stay zero-stubbed in the
/// encoder (Plan 02) per D-01/D-09; no dead-reckoning/ZUPT/Kalman port
/// happens in this phase (SENS-01..05 out of scope for 06.2).
final class CoreMotionSource {

    /// A quaternion in packet-field order, matching the D-14 wire schema's
    /// `(qw, qx, qy, qz)` layout.
    struct Quaternion {
        let qw: Double
        let qx: Double
        let qy: Double
        let qz: Double
    }

    /// Invoked once per attitude sample, on the dedicated sensor
    /// background queue below — NOT the main actor. Callers that need to
    /// surface UI-visible state (e.g. "sensor active" indicator) must
    /// explicitly hop to `@MainActor` themselves, at a throttled rate, not
    /// once per callback (Pitfall 3: this project's
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` build setting makes
    /// touching `@Published`/SwiftUI state directly from here unsafe).
    var onOrientation: ((Quaternion) -> Void)?

    private let motionManager = CMMotionManager()

    /// Dedicated, non-main queue for CoreMotion delivery. Serial
    /// (`maxConcurrentOperationCount = 1`) so attitude samples are handled
    /// in arrival order without needing additional synchronization.
    private let sensorQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.immersiveRT.CoreMotionSource.sensorQueue"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Starts streaming device motion updates at ~60Hz (PHONE-04, targeting
    /// the max device rate; iOS is OS-controlled and may not always hit
    /// exactly 60Hz).
    ///
    /// Reference frame: `.xArbitraryZVertical` — device-relative, no
    /// compass correction. This is RESEARCH.md's reasoned starting point
    /// for parity with the web client's non-absolute `deviceorientation`
    /// behavior on iOS Safari (where `deviceorientationabsolute` never
    /// fires), NOT a verified-correct answer (Pitfall 1).
    ///
    /// ⚠️ UNVERIFIED (Pitfall 1): the direct
    /// `CMQuaternion(x,y,z,w) → packet (qw,qx,qy,qz)` mapping performed in
    /// the update handler below has NOT been confirmed correct against the
    /// desktop's expected rotation convention on a physical device. Its
    /// on-device correctness is gated by the axis-verification checkpoint
    /// in Plan 09 — treat this mapping as a starting point, not a settled
    /// answer, until that checkpoint passes.
    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: sensorQueue
        ) { [weak self] motion, _ in
            guard let self, let attitude = motion?.attitude else { return }
            let q = attitude.quaternion // CMQuaternion { x, y, z, w } — note field order
            // ⚠️ Pitfall 1: this mapping is UNVERIFIED on-device — see
            // Plan 09's on-device axis-verification checkpoint before
            // trusting it. No secondary fusion pass runs on top of `q`
            // (CoreMotion already fused gyro+accelerometer internally).
            self.onOrientation?(Quaternion(qw: q.w, qx: q.x, qy: q.y, qz: q.z))
        }
    }

    /// Stops streaming device motion updates.
    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
}
