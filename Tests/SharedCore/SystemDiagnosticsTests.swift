import Foundation
import MetricKit
import Sentry
import Testing

struct SystemDiagnosticsTests {
    private static let appUUID = "70B89F27-1634-3580-A695-57CDB41D7743"
    private static let uiUUID = "77A62F2E-8212-30F3-84C1-E8497440ACF8"

    @Test @available(macOS 27, *) func keyboardWatchdogBecomesSymbolicatableFatalEvent() throws {
        let sentinel = "synthetic-private-exception-message"
        let event = try Self.event(diagnostic: """
            "crashDiagnostic": {
                "callStackTree": {
                    "callStackPerThread": true,
                    "binaryInfo": [{"uuid": "\(Self.appUUID)", "name": "MumlaKeyboard"}, {"uuid": "\(Self.uiUUID)", "name": "UIKitCore"}],
                    "callStackThreads": [
                        {"threadAttributed": false, "rootFrames": [\(Self.frame(Self.uiUUID, 0x1_9000_0500, 0x500))]},
                        {"threadAttributed": true, "rootFrames": [
                            \(Self.frame(Self.appUUID, 0x1_0000_1010, 0x1010, sub: Self.frame(Self.uiUUID, 0x1_9000_0200, 0x200, sub: Self.frame(Self.appUUID, 0x1_0000_0010, 0x10))))
                        ]}
                    ]
                },
                "terminationCategory": "watchdog",
                "terminationReason": "scene-update watchdog transgression",
                "exceptionType": 10, "exceptionCode": 2343432205, "signal": 9,
                "exceptionReason": {"composedMessage": "\(sentinel)", "formatString": "%@", "arguments": ["\(sentinel)"],
                                    "exceptionType": "NSException", "className": "SyntheticClass", "exceptionName": "SyntheticException"}
            }
            """)

        #expect(event.level == .fatal)
        #expect(event.releaseName == "emileberhard.WisprClone.ios.keyboard@1.0.2+42")
        let exception = try #require(event.exceptions?.first)
        #expect(exception.type == "MetricKitCrash")
        #expect(exception.value == "watchdog")
        #expect(exception.mechanism?.type == "metrickit")
        #expect(exception.mechanism?.handled == false)
        #expect(exception.threadId == 1)
        #expect(exception.stacktrace?.frames.map(\.instructionAddress) == ["0x0000000100000010", "0x0000000190000200", "0x0000000100001010"])
        #expect(event.threads?.map { $0.crashed?.boolValue } == [false, true])
        let images = try #require(event.debugMeta)
        #expect(images.map(\.debugID) == [Self.appUUID, Self.uiUUID])
        #expect(images.map(\.imageAddress) == ["0x0000000100000000", "0x0000000190000000"])
        #expect(images.map(\.codeFile) == ["MumlaKeyboard", "UIKitCore"])
        let context = try #require(event.context?["metrickit"])
        #expect(context["termination_reason"] as? String == "scene-update watchdog transgression")
        #expect(context["objc_exception_name"] as? String == "SyntheticException")
        #expect(context["exception_code"] as? String == "0x8badf00d")
        #expect(context["app_version"] as? String == "1.0.2")
        #expect(!String(describing: event.serialize()).contains(sentinel))
    }

    @Test @available(macOS 27, *) func hangReportsItsMostSampledStack() throws {
        let event = try Self.event(diagnostic: """
            "hangDiagnostic": {
                "callStackTree": {
                    "callStackPerThread": false,
                    "binaryInfo": [{"uuid": "\(Self.appUUID)", "name": "MumlaiOS"}, {"uuid": "\(Self.uiUUID)", "name": "UIKitCore"}],
                    "callStackThreads": [{"rootFrames": [
                        \(Self.frame(Self.uiUUID, 0x1_9000_0100, 0x100, samples: 3, sub: Self.frame(Self.appUUID, 0x1_0000_0100, 0x100, samples: 3))),
                        \(Self.frame(Self.uiUUID, 0x1_9000_0200, 0x200, samples: 7, sub: [
                            Self.frame(Self.appUUID, 0x1_0000_0200, 0x200, samples: 2),
                            Self.frame(Self.appUUID, 0x1_0000_0300, 0x300, samples: 5),
                        ].joined(separator: ",")))
                    ]}]
                },
                "hangDuration": {"value": 2.5, "unit": "s"}
            }
            """)

        #expect(event.level == .warning)
        let exception = try #require(event.exceptions?.first)
        #expect(exception.type == "MetricKitHang")
        #expect(exception.mechanism?.handled == true)
        #expect(exception.stacktrace?.frames.map(\.instructionAddress) == ["0x0000000100000300", "0x0000000190000200"])
        #expect(event.threads?.first?.crashed == false)
        #expect(event.context?["metrickit"]?["hang_seconds"] as? Double == 2.5)
    }

    @available(macOS 27, *)
    private static func event(diagnostic: String) throws -> Event {
        let json = """
            {
                \(diagnostic),
                "timeRange": {"begin": 800000000, "end": 800000000},
                "environment": {
                    "regionFormat": "SE", "deviceType": "iPhone18,1", "platformArchitecture": "arm64e",
                    "osVersion": {"platform": "iOS", "number": "27.1", "buildNumber": "25B1"},
                    "lowPowerModeEnabled": false, "isTestFlightApp": true,
                    "applicationVersion": "1.0.2", "applicationBuildVersion": "42", "pid": 123,
                    "bundleIdentifier": "emileberhard.WisprClone.ios.keyboard", "signpostData": [], "states": []
                }
            }
            """
        return SystemDiagnostics.event(for: try JSONDecoder().decode(DiagnosticReport.self, from: Data(json.utf8)))
    }

    private static func frame(_ uuid: String, _ address: UInt64, _ offset: UInt64, samples: Int = 1, sub: String = "") -> String {
        #"{"binaryUUID": "\#(uuid)", "address": \#(address), "offsetIntoBinaryTextSegment": \#(offset), "sampleCount": \#(samples), "subFrames": [\#(sub)]}"#
    }
}
