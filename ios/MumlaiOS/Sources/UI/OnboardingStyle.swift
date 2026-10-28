import SwiftUI

enum MumlaOnboardingStyle {
    static let controlSpacing: CGFloat = 14
    static let primaryActionVerticalPadding: CGFloat = 15
}

extension View {
    func mumlaOnboardingPrimaryActionStyle() -> some View {
        buttonStyle(.glassProminent)
            .controlSize(.large)
    }
}

struct OnboardingPrimaryButton: View {
    private let title: LocalizedStringKey
    private let action: () -> Void

    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .mumlaOnboardingPrimaryActionStyle()
            .padding(.vertical, MumlaOnboardingStyle.primaryActionVerticalPadding)
    }
}

struct OnboardingSecondaryButton: View {
    private let title: LocalizedStringKey
    private let action: () -> Void

    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct OnboardingTryItField: View {
    private let prompt: LocalizedStringKey
    @Binding private var text: String
    private let isFocused: FocusState<Bool>.Binding

    init(
        _ prompt: LocalizedStringKey,
        text: Binding<String>,
        isFocused: FocusState<Bool>.Binding
    ) {
        self.prompt = prompt
        _text = text
        self.isFocused = isFocused
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard.fill")
                .font(.body.weight(.medium))
                .foregroundStyle(isFocused.wrappedValue ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)

            TextField(prompt, text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(.body)
                .focused(isFocused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(minHeight: 56)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isFocused.wrappedValue
                        ? Color.accentColor.opacity(0.7)
                        : Color.secondary.opacity(0.14),
                    lineWidth: isFocused.wrappedValue ? 1.5 : 1
                )
        }
        .contentShape(.rect(cornerRadius: 16))
        .onTapGesture {
            isFocused.wrappedValue = true
        }
        .animation(.easeOut(duration: 0.18), value: isFocused.wrappedValue)
    }
}
