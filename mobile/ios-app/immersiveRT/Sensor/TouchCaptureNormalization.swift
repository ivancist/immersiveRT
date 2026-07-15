import CoreGraphics

/// Pure touch-coordinate normalization against the app's explicit
/// landscape-locked interface bounds (D-05) — the native-parity counterpart
/// to `client/src/phone.ts`'s `clamp01(t.clientX / window.innerWidth)` touch
/// normalization (SENS-06).
///
/// This is deliberately a free function taking an explicit `bounds: CGRect`
/// parameter rather than reading `UIScreen.main.bounds` or any other
/// ambient/global geometry source — the caller (`ActiveSessionView`, Task 2)
/// is responsible for supplying the current landscape-locked geometry (e.g.
/// from a `GeometryReader` proxy), never raw/possibly-portrait device
/// bounds. Keeping this pure and dependency-free makes it directly
/// Simulator-testable with no gesture runtime, view hierarchy, or device
/// orientation involved.
///
/// Maps `location` into `[0,1] x [0,1]` relative to `bounds`, where
/// `bounds.origin` (top-left) is `(0,0)` and `bounds.origin + bounds.size`
/// (bottom-right) is `(1,1)`. Locations outside `bounds` are clamped to
/// `[0,1]` on each axis independently (mirrors `SensorPacketEncoder`'s
/// wire-level `clamp01` — this is the first-line clamp, applied before the
/// encoder's own defense-in-depth clamp01 + `safeFloat()`, per T-06.3-04).
func normalizedTouch(location: CGPoint, in bounds: CGRect) -> (x: Double, y: Double) {
    guard bounds.width > 0, bounds.height > 0 else {
        return (0, 0)
    }

    let rawX = (location.x - bounds.minX) / bounds.width
    let rawY = (location.y - bounds.minY) / bounds.height

    let clampedX = min(1, max(0, Double(rawX)))
    let clampedY = min(1, max(0, Double(rawY)))

    return (x: clampedX, y: clampedY)
}
