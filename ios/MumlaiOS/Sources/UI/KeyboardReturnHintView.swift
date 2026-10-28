import SwiftUI

struct KeyboardReturnHintView: View {
    let dismiss: @MainActor () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    VStack(spacing: 4) {
                        Text("Swipe right")
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)

                        Text("Return to your app.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    SwipeBackGestureCue()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, max(proxy.safeAreaInsets.bottom - 8, 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .ignoresSafeArea()
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, dismiss)
    }
}

private enum SwipeCuePhase: CaseIterable {
    case start
    case end
}

private struct SwipeBackGestureCue: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Capsule()
                .fill(.secondary.opacity(0.08))

            Capsule()
                .fill(.secondary.opacity(0.22))
                .frame(width: 104, height: 4)

            if reduceMotion {
                contactPoint(for: .end)
            } else {
                PhaseAnimator(SwipeCuePhase.allCases) { phase in
                    contactPoint(for: phase)
                } animation: { phase in
                    switch phase {
                    case .start:
                        .linear(duration: 0.01).delay(0.4)
                    case .end:
                        .smooth(duration: 0.9)
                    }
                }
            }
        }
        .frame(width: 178, height: 40)
        .glassEffect(.regular, in: .capsule)
        .accessibilityHidden(true)
    }

    private func contactPoint(for phase: SwipeCuePhase) -> some View {
        Circle()
            .fill(.primary)
            .frame(width: 18, height: 18)
            .shadow(color: .black.opacity(0.14), radius: 4, y: 1)
            .offset(x: phase == .start ? -54 : 54)
            .opacity(phase == .start ? 0.55 : 0.95)
    }
}
