import SwiftUI

struct ContentView: View {
    // Owns (or receives from `immersiveRTApp`, Task 3's scenePhase wiring)
    // the `TransportManager`-backed view-model that drives `ActiveSessionView`.
    // Defaulting the parameter keeps this initializer source-compatible with
    // `ContentView()` (the #Preview below) while letting `immersiveRTApp`
    // inject a shared, app-owned instance once scenePhase observation needs
    // it (Task 3).
    @ObservedObject private var sessionViewModel: SessionViewModel
    @State private var isShowingScanner = false
    // Set once a scanned QR code's token+host successfully kick off a
    // connect — routes ContentView to ActiveSessionView (replacing the
    // TokenDetailsView placeholder).
    @State private var hasStartedSession = false

    /// Presented via `dynamicIslandToast` (D-15) for the invalid-QR-code
    /// message AND the D-09 camera-permission gate below (`currentToast`'s
    /// value is only meaningful while `isShowingToast` is `true`, mirrors
    /// `SessionViewModel`'s equivalent pair on `ActiveSessionView`).
    @State private var currentToast: Toast = .invalidQRCode
    @State private var isShowingToast = false

    // `SessionViewModel()` is intentionally NOT a default-parameter-value
    // expression (`= SessionViewModel()`) — default argument expressions
    // are type-checked in a nonisolated context regardless of the module's
    // `-default-isolation=MainActor` build setting, so calling a MainActor
    // initializer there is a hard compiler error. Constructing it inside
    // the (MainActor-isolated-by-default) init body instead sidesteps that.
    init(sessionViewModel: SessionViewModel? = nil) {
        _sessionViewModel = ObservedObject(wrappedValue: sessionViewModel ?? SessionViewModel())
    }

    var body: some View {
        ZStack(alignment: .top) {
            if hasStartedSession {
                ActiveSessionView(viewModel: sessionViewModel)
            } else {
                HomeView(onScanTapped: presentScannerIfCameraAvailable)
            }
        }
        .dynamicIslandToast(isPresented: $isShowingToast, duration: 2, value: currentToast)
        .sheet(isPresented: $isShowingScanner) {
            QRScannerView { scannedPayload in
                isShowingScanner = false
                self.handleScannedPayload(scannedPayload)
            }
            .edgesIgnoringSafeArea(.all)
        }
    }

    /// D-09 gate reached through the ACTUAL first user-facing camera use:
    /// tapping "Scan QR". `QRScannerView`'s `ScannerViewController` has no
    /// permission handling of its own — with camera access denied, it
    /// silently shows a black screen with zero frames delivered (no error,
    /// no callback), discovered via on-device verification. Reuses
    /// `ARPoseSource.checkARStartupPreconditions()` (the same D-09 check
    /// `SessionViewModel.start(token:host:)` runs before ARKit tracking
    /// begins) rather than duplicating the permission-check logic — the QR
    /// flow needs the same camera access the later ARKit flow needs, so
    /// gating it here too makes the D-09 block reachable in the real user
    /// flow, not just at the ARKit-session-start point the user never
    /// otherwise reaches with camera access denied.
    private func presentScannerIfCameraAvailable() {
        Task {
            if let error = await ARPoseSource.checkARStartupPreconditions() {
                presentStartupErrorToast(error)
                return
            }
            isShowingScanner = true
        }
    }

    /// Maps a D-09 precondition failure to the matching Toast — mirrors
    /// `SessionViewModel.presentStartupError(_:)`'s toast selection exactly
    /// (kept separate since this call site has no `SessionState` to
    /// transition; it simply must not present the scanner sheet).
    private func presentStartupErrorToast(_ error: ARStartupError) {
        switch error {
        case .deviceUnsupported:
            currentToast = .arUnavailable
        case .cameraDenied, .cameraRestricted:
            currentToast = .cameraPermissionDenied
        }
        isShowingToast = true
    }

    private func handleScannedPayload(_ payload: String) {
        guard let token = QRTokenParser.token(from: payload),
              let host = QRTokenParser.host(from: payload) else {
            currentToast = .invalidQRCode
            isShowingToast = true
            return
        }
        hasStartedSession = true
        sessionViewModel.start(token: token, host: host)
    }
}

// MARK: - Subviews

struct HomeView: View {
    /// D-09: routed through `ContentView.presentScannerIfCameraAvailable()`
    /// rather than flipping a `isShowingScanner` binding directly — the tap
    /// must run the camera-permission precondition check FIRST, since
    /// `QRScannerView` has no permission handling of its own.
    var onScanTapped: () -> Void

    var body: some View {
        VStack {
            Spacer()

            Text("ImmersiveRT")
                .font(.largeTitle)
                .fontWeight(.bold)

            Spacer()

            Button(action: onScanTapped) {
                HStack(spacing: 12) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.title2)
                    Text("Scan QR")
                        .font(.headline)
                }
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue)
                .cornerRadius(12)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
