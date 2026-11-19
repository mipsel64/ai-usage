import SwiftUI

struct PreferencesSymbol: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.title2)
            .foregroundStyle(.tint)
            .frame(width: 36, height: 36)
            .background(.tint.opacity(0.12), in: .rect(cornerRadius: 10))
    }
}
