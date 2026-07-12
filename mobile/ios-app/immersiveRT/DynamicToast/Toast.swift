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
}
