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
    @State private var isShowingInvalidTokenToast = false

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
                HomeView(isShowingScanner: $isShowingScanner)
            }
        }
        .dynamicIslandToast(isPresented: $isShowingInvalidTokenToast, duration: 2, value: .invalidQRCode)
        .sheet(isPresented: $isShowingScanner) {
            QRScannerView { scannedPayload in
                isShowingScanner = false
                self.handleScannedPayload(scannedPayload)
            }
            .edgesIgnoringSafeArea(.all)
        }
    }

    private func handleScannedPayload(_ payload: String) {
        guard let token = QRTokenParser.token(from: payload),
              let host = QRTokenParser.host(from: payload) else {
            isShowingInvalidTokenToast = true
            return
        }
        hasStartedSession = true
        sessionViewModel.start(token: token, host: host)
    }
}

// MARK: - Subviews

struct HomeView: View {
    @Binding var isShowingScanner: Bool

    var body: some View {
        VStack {
            Spacer()

            Text("ImmersiveRT")
                .font(.largeTitle)
                .fontWeight(.bold)

            Spacer()

            Button(action: {
                isShowingScanner = true
            }) {
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
