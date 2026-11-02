import Foundation
import MetricKit
import Sentry

nonisolated enum SystemDiagnostics {
    static func start() {
        guard #available(iOS 27, macOS 27, *) else { return }
        let manager = MetricManager()
        Task.detached(priority: .utility) {
            for await report in manager.diagnosticReports {
                capture(report)
            }
        }
    }

    @available(iOS 27, macOS 27, *)
    static func capture(_ report: DiagnosticReport) {
        guard let event = event(for: report) else { return }
        let scope = Scope()
        if let tree = report.result.callStackTree, let json = try? JSONEncoder().encode(tree) {
            scope.addAttachment(Attachment(data: json, filename: "call-stack-tree.json", contentType: "application/json"))
        }
        SentrySDK.capture(event: event, scope: scope)
    }

    @available(iOS 27, macOS 27, *)
    static func event(for report: DiagnosticReport) -> Event? {
        guard let summary = report.result.summary else { return nil }
        let environment = report.environment
        let event = Event(level: summary.terminated ? .fatal : .warning)
        event.timestamp = report.timeRange.start
        event.releaseName = "\(environment.bundleIdentifier)@\(environment.applicationVersion)+\(environment.applicationBuildVersion)"
        event.dist = environment.applicationBuildVersion
        #if os(iOS)
        event.tags = ["process": environment.bundleIdentifier == Bundle.main.bundleIdentifier ? "app" : "keyboard"]
        #endif
        event.context = [
            "app": [
                "app_identifier": environment.bundleIdentifier,
                "app_version": environment.applicationVersion,
                "app_build": environment.applicationBuildVersion,
            ],
            "os": [
                "name": environment.osVersion.platform,
                "version": environment.osVersion.number,
                "build": environment.osVersion.buildNumber,
            ],
            "device": ["model": environment.deviceType, "arch": environment.platformArchitecture],
            "metrickit": summary.context.merging([
                "testflight": environment.isTestFlightApp,
                "low_power_mode": environment.lowPowerModeEnabled,
            ]) { current, _ in current },
        ]

        let exception = Exception(value: summary.value, type: summary.type)
        let mechanism = Mechanism(type: "metrickit")
        mechanism.handled = NSNumber(value: !summary.terminated)
        exception.mechanism = mechanism
        event.exceptions = [exception]
        if let tree = report.result.callStackTree {
            let threads = tree.callStackThreads.enumerated().map { index, thread in
                let sentryThread = SentryThread(threadId: NSNumber(value: index))
                let frames = mostSampledStackOutermostFirst(thread.rootFrames).map { frame(for: $0, in: tree) }
                sentryThread.stacktrace = SentryStacktrace(frames: frames, registers: [:])
                sentryThread.crashed = NSNumber(value: summary.terminated && thread.threadAttributed == true)
                return sentryThread
            }
            let exceptionThread = threads.first { $0.crashed?.boolValue == true } ?? threads.first
            exception.stacktrace = exceptionThread?.stacktrace
            exception.threadId = exceptionThread?.threadId
            event.threads = threads
            event.debugMeta = debugImages(in: tree)
        }
        return event
    }

    @available(iOS 27, macOS 27, *)
    private static func mostSampledStackOutermostFirst(_ roots: ContiguousArray<CallStackFrame>) -> [CallStackFrame] {
        var best: (samples: Int, stack: [CallStackFrame])?
        func visit(_ frame: CallStackFrame, below stack: [CallStackFrame]) {
            let stack = stack + [frame]
            let endingHere = (frame.sampleCount ?? 0) - frame.subFrames.reduce(0) { $0 + ($1.sampleCount ?? 0) }
            if frame.subFrames.isEmpty || endingHere > 0, endingHere > best?.samples ?? -1 {
                best = (endingHere, stack)
            }
            for caller in frame.subFrames {
                visit(caller, below: stack)
            }
        }
        for root in roots {
            visit(root, below: [])
        }
        return best?.stack.reversed() ?? []
    }

    @available(iOS 27, macOS 27, *)
    private static func frame(for callStackFrame: CallStackFrame, in tree: CallStackTree) -> Frame {
        let frame = Frame()
        let binaryName = callStackFrame.binaryName(from: tree)
        frame.package = binaryName
        frame.inApp = binaryName.map { NSNumber(value: appExecutables.contains($0)) }
        if let address = callStackFrame.address {
            frame.instructionAddress = hexAddress(address)
            frame.imageAddress = imageAddress(of: callStackFrame).map(hexAddress)
        }
        return frame
    }

    @available(iOS 27, macOS 27, *)
    private static func debugImages(in tree: CallStackTree) -> [DebugMeta] {
        var loadAddresses: [UUID: UInt64] = [:]
        tree.forEachFrame { frame in
            if let uuid = frame.binaryUUID, let address = imageAddress(of: frame) {
                loadAddresses[uuid] = address
            }
        }
        return loadAddresses.sorted { $0.value < $1.value }.map { uuid, address in
            let image = DebugMeta()
            image.type = "macho"
            image.debugID = uuid.uuidString
            image.codeFile = tree.binaryInfo[uuid]?.name
            image.imageAddress = hexAddress(address)
            return image
        }
    }

    @available(iOS 27, macOS 27, *)
    private static func imageAddress(of frame: CallStackFrame) -> UInt64? {
        guard let address = frame.address, let offset = frame.offsetIntoBinaryTextSegment, offset <= address else { return nil }
        return address - offset
    }

    private static func hexAddress(_ address: UInt64) -> String {
        String(format: "0x%016llx", address)
    }

    private static let appExecutables: Set<String> = {
        let plugIns = Bundle.main.builtInPlugInsURL.flatMap {
            try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        } ?? []
        let bundles = [Bundle.main] + plugIns.compactMap(Bundle.init(url:))
        return Set(bundles.compactMap { $0.executableURL?.lastPathComponent })
    }()
}

@available(iOS 27, macOS 27, *)
nonisolated private struct DiagnosticSummary {
    let type: String
    let value: String
    let terminated: Bool
    let context: [String: Any]
}

@available(iOS 27, macOS 27, *)
nonisolated private extension DiagnosticResult {
    var summary: DiagnosticSummary? {
        switch self {
        case .crash(let crash):
            if let category = crash.terminationCategory, [.badAccess, .abnormal, .illegalInstruction].contains(category) {
                return nil
            }
            var context: [String: Any] = ["kind": "crash"]
            context["termination_category"] = crash.terminationCategory?.rawValue
            context["termination_reason"] = crash.terminationReason?.rawValue
            context["exception_type"] = crash.exceptionType
            context["exception_code"] = crash.exceptionCode.map { String(format: "0x%llx", $0) }
            context["signal"] = crash.signal
            context["objc_exception_name"] = crash.exceptionReason?.exceptionName
            context["objc_exception_class"] = crash.exceptionReason?.className
            return DiagnosticSummary(
                type: "MetricKitCrash",
                value: crash.terminationCategory?.rawValue ?? "uncategorized",
                terminated: true,
                context: context
            )
        case .hang(let hang):
            return DiagnosticSummary(
                type: "MetricKitHang", value: "main thread hang", terminated: false,
                context: ["kind": "hang", "hang_seconds": hang.hangDuration.converted(to: .seconds).value]
            )
        case .cpuException(let cpu):
            return DiagnosticSummary(
                type: "MetricKitCPUException", value: "cpu exception", terminated: false,
                context: [
                    "kind": "cpu_exception",
                    "cpu_seconds": cpu.totalCPUTime.converted(to: .seconds).value,
                    "sampled_seconds": cpu.totalSampledTime.converted(to: .seconds).value,
                ]
            )
        case .diskWriteException(let disk):
            return DiagnosticSummary(
                type: "MetricKitDiskWriteException", value: "disk write exception", terminated: false,
                context: ["kind": "disk_write_exception", "bytes_written": disk.totalBytesWritten.converted(to: .bytes).value]
            )
        case .appLaunch(let launch):
            return DiagnosticSummary(
                type: "MetricKitAppLaunch", value: "slow launch", terminated: false,
                context: ["kind": "app_launch", "launch_seconds": launch.launchDuration.converted(to: .seconds).value]
            )
        #if os(iOS)
        case .memoryException:
            return DiagnosticSummary(
                type: "MetricKitMemoryException", value: "memory limit", terminated: true,
                context: ["kind": "memory_exception"]
            )
        #endif
        @unknown default:
            return DiagnosticSummary(type: "MetricKitDiagnostic", value: "unknown", terminated: false, context: ["kind": "unknown"])
        }
    }

    var callStackTree: CallStackTree? {
        switch self {
        case .crash(let crash): crash.callStackTree
        case .hang(let hang): hang.callStackTree
        case .cpuException(let cpu): cpu.callStackTree
        case .diskWriteException(let disk): disk.callStackTree
        case .appLaunch(let launch): launch.callStackTree
        #if os(iOS)
        case .memoryException(let memory): memory.callStackTree
        #endif
        @unknown default: nil
        }
    }
}
