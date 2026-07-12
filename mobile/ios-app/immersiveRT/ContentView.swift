import SwiftUI

struct ContentView: View {
    @State private var isShowingScanner = false
    // Token extracted from a valid scanned QR code
    @State private var verifiedToken: String?
    @State private var isShowingInvalidTokenToast = false

    var body: some View {
        ZStack(alignment: .top) {
            if let token = verifiedToken {
                TokenDetailsView(token: token) {
                    self.verifiedToken = nil
                }
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
        if let token = QRTokenParser.token(from: payload) {
            verifiedToken = token
        } else {
            isShowingInvalidTokenToast = true
        }
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
