import SwiftUI

struct TokenDetailsView: View {
    let token: String
    var onDismiss: () -> Void // Callback block to handle backward state mutation

    var body: some View {
        VStack(spacing: 24) {
            // Contextual Header replacing NavigationBar layout
            /*HStack {
                Button(action: onDismiss) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.body)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16) */

            Spacer()

            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)
            
            Text("Token Detected Successfully")
                .font(.title2)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("TOKEN PAYLOAD:")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.gray)
                
                Text(token)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 20)
            
            Spacer()
        }
    }
}
