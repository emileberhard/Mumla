import SwiftUI
import UIKit

enum DictationPillMetrics {
    static let width: CGFloat = 186
    static let height: CGFloat = 50
}

enum DictationPillPalette {
    static var control: Color { Color(uiColor: .secondarySystemFill) }
    static var recording: Color { Color(uiColor: .systemRed) }
    static var warning: Color { Color(uiColor: .systemOrange) }
}

/// The dictation pill shared by the keyboard bar and the main app screen so
/// the control looks and behaves the same on both surfaces.
struct DictationPillContent: View {
    let symbolName: String?
    let title: String?
    let foregroundColor: Color
    var symbolColor: Color?
    var showsProgress = false
    var showsCassette = false
    var recordingStartDate: Date?
    var recordingDeadline: Date?
    var fillsWidth = false
    var height: CGFloat = DictationPillMetrics.height

    var body: some View {
        Group {
            if showsCassette {
                // Fills the pill edge to edge so the wheels sit inside the
                // pill's own rounded ends.
                CassetteMotifView(color: foregroundColor, recordingStartDate: recordingStartDate, recordingDeadline: recordingDeadline)
            } else {
                HStack(spacing: 8) {
                    if showsProgress {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(foregroundColor)
                            .accessibilityHidden(true)
                    } else if let symbolName {
                        Image(systemName: symbolName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(symbolColor ?? foregroundColor)
                            .accessibilityHidden(true)
                    }

                    if let title {
                        Text(title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(foregroundColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .frame(width: fillsWidth ? nil : DictationPillMetrics.width, height: height)
        .frame(maxWidth: fillsWidth ? .infinity : nil)
    }
}

extension View {
    func dictationPillBackground(_ fill: Color, shadowOpacity: Double = 0.12) -> some View {
        background(Capsule(style: .continuous).fill(fill))
            .shadow(color: .black.opacity(shadowOpacity), radius: 5, y: 2)
    }
}
