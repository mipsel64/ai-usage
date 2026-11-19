import SwiftUI

struct SignInRequiredDot: View {
    var body: some View {
        Circle()
            .fill(.orange)
            .frame(width: 7, height: 7)
            .accessibilityLabel("Sign-in required")
    }
}
