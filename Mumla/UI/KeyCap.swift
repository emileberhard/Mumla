import SwiftUI

struct KeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(.callout, design: .rounded).weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.quaternary, in: .rect(cornerRadius: 5))
    }
}

struct KeyGesture: View {
    let action: LocalizedStringKey
    let key: String

    var body: some View {
        HStack(spacing: 6) {
            Text(action)
            KeyCap(key: key)
        }
        .accessibilityElement(children: .combine)
    }
}
