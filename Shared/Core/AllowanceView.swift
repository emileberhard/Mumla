import CloudKit
import SwiftUI

struct AllowanceView: View {
    let access: MumlaAccess

    var body: some View {
        switch access.state {
        case .checking:
            AllowanceMeter(allowance: .placeholder)
                .redacted(reason: .placeholder)
        case .available(let allowance):
            AllowanceMeter(allowance: allowance)
        case .iCloudUnavailable(let status):
            ICloudUnavailableView(status: status, access: access)
        case .serviceUnavailable:
            AccessIssueRow(systemImage: "wifi.exclamationmark", title: "Can't Reach Mumla") {
                Button("Try Again") { Task { await access.refresh() } }
            }
        }
    }
}

extension MumlaAccess.State {
    var isWorthNoticing: Bool {
        switch self {
        case .iCloudUnavailable: true
        case .available(let allowance): allowance.available == .zero || allowance.isRunningLow
        case .checking, .serviceUnavailable: false
        }
    }
}

extension MumlaAccess.Allowance {
    var isRunningLow: Bool {
        remaining <= .seconds(600)
    }

    static let placeholder = MumlaAccess.Allowance(limit: .seconds(3600), used: .zero, reserved: .zero, resetsAt: .now)
}

extension Duration {
    var wholeMinutes: Int {
        Int(components.seconds / 60)
    }
}

private struct AllowanceMeter: View {
    let allowance: MumlaAccess.Allowance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        dynamicTypeSize.allowanceRowLayout {
            Gauge(value: fractionLeft) {
                Text("Minutes left")
            } currentValueLabel: {
                Text(allowance.remaining.wholeMinutes, format: .number)
                    .contentTransition(.numericText(countsDown: true))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.headline)
                Text(resets)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.smooth, value: allowance)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headline)
        .accessibilityValue(resets)
    }

    private var fractionLeft: Double {
        guard allowance.limit > .zero else { return 0 }
        return allowance.remaining / allowance.limit
    }

    private var headline: LocalizedStringKey {
        if allowance.isExhausted {
            "No minutes left"
        } else if allowance.available == .zero {
            "In use on another device"
        } else if allowance.remaining < .seconds(60) {
            "Less than a minute left"
        } else {
            "\(allowance.remaining.wholeMinutes) of \(allowance.limit.wholeMinutes) min left"
        }
    }

    private var resets: LocalizedStringKey {
        "Resets \(allowance.resetsAt, format: .dateTime.month(.wide).day())"
    }

    private var tint: Color {
        if allowance.isExhausted {
            .secondary
        } else if allowance.isRunningLow {
            .orange
        } else {
            .accentColor
        }
    }
}

private struct ICloudUnavailableView: View {
    let status: CKAccountStatus
    let access: MumlaAccess

    var body: some View {
        switch status {
        case .noAccount:
            AccessIssueRow(systemImage: "icloud.slash", title: "Sign In to iCloud") {
                ICloudSignInHint()
            }
        case .restricted:
            AccessIssueRow(systemImage: "lock.icloud", title: "iCloud Is Restricted") {
                Text("Screen Time or device management blocks it.")
                    .foregroundStyle(.secondary)
            }
        default:
            AccessIssueRow(systemImage: "exclamationmark.icloud", title: "iCloud Isn't Responding") {
                Button("Try Again") { Task { await access.refresh() } }
            }
        }
    }
}

struct ICloudSignInHint: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        #if os(macOS)
        Button("Open System Settings") {
            openURL(URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!)
        }
        #else
        Text("Open Settings and sign in at the top.")
            .foregroundStyle(.secondary)
        #endif
    }
}

private struct AccessIssueRow<Detail: View>: View {
    let systemImage: String
    let title: LocalizedStringKey
    @ViewBuilder let detail: Detail
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        dynamicTypeSize.allowanceRowLayout {
            Image(systemName: systemImage)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
                .frame(minWidth: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                detail
                    .font(.subheadline)
            }
        }
    }
}

private extension DynamicTypeSize {
    var allowanceRowLayout: AnyLayout {
        isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 14))
    }
}
