import SwiftUI

struct Toast {
    private(set) var id: String = UUID().uuidString
    var symbol: String
    var symbolFont: Font
    var symbolForegroundStyle: (Color,Color)
    
    var title: String
    var message: String
    
    static var example1: Toast {
        Toast(symbol: "checkmark.seal.fill",
              symbolFont: .system(size: 35),
              symbolForegroundStyle: (.white, .green),
              title: "Scan Success!",
              message: "Your QR Code is valid")
    }
    
    static var invalidQRCode: Toast {
        Toast(symbol: "macbook.slash",
              symbolFont: .system(size: 28),
              symbolForegroundStyle: (.white, .red),
              title: "Scan Failed!",
              message: "Your QR Code is not valid")
    }

    /// D-09: `ARWorldTrackingConfiguration.isSupported == false` — a hard
    /// block, never a silent CoreMotion-only degrade. Presented once, before
    /// any `ARSession` is ever run (`ARPoseSource.checkARStartupPreconditions()`).
    static var arUnavailable: Toast {
        Toast(symbol: "arkit",
              symbolFont: .system(size: 28),
              symbolForegroundStyle: (.white, .red),
              title: "AR Not Supported",
              message: "This device does not support ARKit world tracking")
    }

    /// D-09: camera permission denied/restricted — also a hard block, never
    /// a silent degrade. Camera access is required because ARKit's world
    /// tracking is camera-driven (D-14: the camera feed itself is never
    /// displayed, stored, or transmitted — only the resulting pose is).
    static var cameraPermissionDenied: Toast {
        Toast(symbol: "video.slash.fill",
              symbolFont: .system(size: 28),
              symbolForegroundStyle: (.white, .red),
              title: "Camera Access Needed",
              message: "Camera access is required for motion tracking")
    }

    /// D-08: local-only feedback for the current `ARCamera.TrackingState`
    /// `.limited(reason:)` sub-reason — `message` comes from
    /// `trackingLimitedReasonMessage(_:)` (`ARPoseConversion.swift`). Never
    /// changes the wire `driftConfidence`, which stays a flat 0.5 for any
    /// `.limited` reason (D-07/D-08) — this toast is purely local UX.
    /// Informational (not red/error) styling, since limited tracking is a
    /// transient, recoverable state rather than a hard failure.
    static func trackingLimited(_ message: String) -> Toast {
        Toast(symbol: "arkit",
              symbolFont: .system(size: 26),
              symbolForegroundStyle: (.white, .orange),
              title: "Tracking Limited",
              message: message)
    }

    /// D-11: brief confirmation shown after the Plan 08 overlay-menu
    /// Recenter button re-zeros this player's ARKit world origin — purely
    /// local feedback, no wire effect (mirrors `trackingLimited`'s
    /// informational, non-error styling).
    static var recentered: Toast {
        Toast(symbol: "location.viewfinder",
              symbolFont: .system(size: 26),
              symbolForegroundStyle: (.white, .blue),
              title: "Recentered",
              message: "Your position has been re-zeroed")
    }
}
