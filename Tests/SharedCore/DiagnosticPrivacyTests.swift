import AppKit
import Foundation
import OSLog
import Sentry
import SpeechKit
import Testing
import zlib

@Suite(.serialized)
struct DiagnosticPrivacyTests {
    @Test func providerPayloadDoesNotEnterDiagnosticEvent() throws {
        let sentinel = "synthetic-private-transcript-and-dictionary"
        let errors: [any Error] = [
            SpeechKitError.httpFailure(statusCode: 429, body: sentinel),
            SpeechKitError.providerFailure(sentinel),
            SpeechKitError.webSocketClosed(code: 1008, reason: sentinel),
            NSError(domain: sentinel, code: 51, userInfo: [
                NSLocalizedDescriptionKey: sentinel,
                NSLocalizedFailureReasonErrorKey: sentinel,
                NSUnderlyingErrorKey: NSError(domain: sentinel, code: 2),
                "response_body": sentinel,
            ]),
            SyntheticPrivateError(value: sentinel),
        ]
        for error in errors {
            let event = DiagnosticEvent(message: "Transcription failed", metadata: ["provider": "synthetic"], error: error)
            let captured = try #require(event.error)
            let emitted = event.message + event.metadata.description + captured.description + captured.localizedDescription
            #expect(!emitted.contains(sentinel))
            #expect(captured.userInfo.isEmpty)
            #expect(event.metadata["provider"] == "synthetic")
        }
        let throttled = DiagnosticEvent(message: "Transcription failed", metadata: [:], error: errors[0])
        #expect(throttled.error?.code == 429)
        #expect(throttled.metadata["error_kind"] == "http_failure")
        let closed = DiagnosticEvent(message: "Transcription failed", metadata: [:], error: errors[2])
        #expect(closed.error?.code == 1008)
    }

    @Test @MainActor func diagnosticSinksExcludeProviderAndNSErrorPayloads() throws {
        let sentinel = "synthetic-private-provider-payload-at-sentry-boundary"
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let logs = OSAllocatedUnfairLock(initialState: [String]())
        let breadcrumbs = OSAllocatedUnfairLock(initialState: [String]())
        SentrySDK.start { options in
            options.dsn = "https://public@localhost/1"
            options.enableCrashHandler = false
            options.enableAutoSessionTracking = false
            options.enableAppHangTracking = false
            options.enableSwizzling = false
            options.enableLogs = true
            options.beforeSend = { @Sendable event in
                let text = String(describing: event.serialize())
                events.withLock { $0.append(text) }
                return nil
            }
            options.beforeSendLog = { @Sendable log in
                let text = log.body + log.attributes.mapValues(\.value).description
                logs.withLock { $0.append(text) }
                return nil
            }
            options.beforeBreadcrumb = { @Sendable breadcrumb in
                let text = String(describing: breadcrumb.serialize())
                breadcrumbs.withLock { $0.append(text) }
                return nil
            }
        }
        defer { SentrySDK.close() }
        AppDiagnostics.error(
            "Synthetic transcription failure", category: "privacy_test",
            error: SpeechKitError.httpFailure(statusCode: 429, body: sentinel)
        )
        CrashReporting.capture(
            message: "Synthetic transcription failure", context: "privacy_test",
            error: NSError(domain: sentinel, code: 52, userInfo: [
                NSLocalizedDescriptionKey: sentinel, "response_body": sentinel,
                NSUnderlyingErrorKey: NSError(domain: sentinel, code: 53),
            ])
        )
        CrashReporting.breadcrumb("Synthetic lifecycle event", category: "privacy_test")
        let capturedEvents = events.withLock { $0 }
        let capturedLogs = logs.withLock { $0 }
        let capturedBreadcrumbs = breadcrumbs.withLock { $0 }
        #expect(capturedEvents.count >= 2)
        #expect(capturedLogs.count >= 2)
        #expect(capturedBreadcrumbs.count >= 2)
        for payload in capturedEvents + capturedLogs + capturedBreadcrumbs {
            #expect(!payload.contains(sentinel))
        }
        #expect(capturedEvents.contains { $0.contains("429") })
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func outgoingEnvelopesDoNotLinkInstallations() async throws {
        let installation = "synthetic-persistent-installation"
        let deviceHash = "synthetic-persistent-device-hash"
        let unlinked = try await captureEnvelopes(installation: installation, deviceHash: deviceHash, applyPrivacy: true)
        let control = try await captureEnvelopes(installation: installation, deviceHash: deviceHash, applyPrivacy: false)
        #expect(!unlinked.contains { $0.contains(installation) || $0.contains(deviceHash) || $0.contains("synthetic-persistent-account-hash") })
        #expect(!control.contains { $0.contains("synthetic-persistent-account-hash") })
        #expect(control.contains { $0.contains("synthetic-objc-path") && $0.contains("file.path") })
        #expect(control.contains { $0.contains(installation) })
        #expect(control.contains { $0.contains(deviceHash) })
        for type in ["event", "transaction", "log"] {
            #expect(unlinked.contains { $0.contains("\"type\":\"\(type)\"") })
        }
        #expect(control.contains { $0.contains("\"type\":\"session\"") && $0.contains(installation) })
        #expect(!unlinked.contains { $0.contains("\"type\":\"session\"") })
        #expect(unlinked.contains { $0.contains("SyntheticCrash") })
        #expect(unlinked.contains { $0.contains("HTTPClientError") })
        #expect(unlinked.contains { $0.contains("429") })
        #expect(unlinked.contains { $0.contains("synthetic_model") })
        #expect(unlinked.contains { $0.contains("synthetic_policy_tag") })
    }

    @MainActor private func captureEnvelopes(
        installation: String, deviceHash: String, applyPrivacy: Bool
    ) async throws -> [String] {
        let root = URL.temporaryDirectory.appending(path: "DiagnosticPrivacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticEnvelopeProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let options = Options()
        options.dsn = "http://public@localhost/1"
        options.releaseName = "synthetic@1.0.0"
        options.enableCrashHandler = false
        options.enableAppHangTracking = false
        options.enableSwizzling = true
        options.enableLogs = true
        options.tracesSampleRate = 1
        options.urlSession = session
        options.cacheDirectoryPath = root.path
        if applyPrivacy { DiagnosticPrivacy.configure(options, tags: ["policy": "synthetic_policy_tag"]) }
        let cache = URL(filePath: options.cacheDirectoryPath)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try installation.write(to: cache.appending(path: "INSTALLATION"), atomically: true, encoding: .utf8)
        DiagnosticEnvelopeProtocol.envelopes.withLock { $0.removeAll() }
        let (arrivals, arrival) = AsyncStream.makeStream(of: Data.self)
        DiagnosticEnvelopeProtocol.arrival.withLock { $0 = arrival }
        defer {
            DiagnosticEnvelopeProtocol.arrival.withLock { $0 = nil }
            arrival.finish()
        }
        SentrySDK.start(options: options)
        defer { SentrySDK.close() }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        SentrySDK.configureScope { scope in
            scope.setContext(value: ["device_app_hash": deviceHash, "app_version": "1.0.0"], key: "app")
            scope.setTag(value: "synthetic_model", key: "model")
        }
        AppDiagnostics.error("Synthetic provider failure", category: "privacy_test", error: SpeechKitError.httpFailure(statusCode: 429, body: "synthetic-body"))
        for (level, type) in [(SentryLevel.fatal, "SyntheticCrash"), (.error, "HTTPClientError")] {
            let event = Event(level: level)
            event.exceptions = [Exception(value: "Synthetic failure", type: type)]
            SentrySDK.capture(event: event)
        }
        let transaction = SentrySDK.startTransaction(name: "Synthetic timing", operation: "test", bindToScope: true)
        let account = root.appending(path: "Accounts/synthetic-persistent-account-hash")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        let file = account.appending(path: "synthetic.json")
        let bytes = Data("synthetic".utf8)
        try bytes.write(to: file)
        #expect(try Data(contentsOf: file) == bytes)
        let objcFile = root.appending(path: "synthetic-objc-path")
        try bytes.write(to: objcFile)
        #expect(try NSData(contentsOf: objcFile, options: .uncached) as Data == bytes)
        transaction.startChild(operation: "test.work").finish()
        transaction.finish()
        CrashReporting.breadcrumb("Synthetic state transition", category: "privacy_test", metadata: ["count": "3"])
        for await envelope in arrivals {
            if try Self.decodeEnvelope(envelope).contains("\"type\":\"transaction\"") { break }
        }
        await Task.detached { SentrySDK.flush(timeout: 2) }.value
        SentrySDK.close()
        if applyPrivacy {
            #expect(cache.lastPathComponent == "MumlaUnlinkedDiagnostics")
            #expect(FileManager.default.fileExists(atPath: cache.appending(path: "INSTALLATION").path))
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "INSTALLATION").path))
            let sdkPaths = try FileManager.default.contentsOfDirectory(
                at: cache.appending(path: "io.sentry"), includingPropertiesForKeys: nil
            )
            #expect(sdkPaths.contains { FileManager.default.fileExists(atPath: $0.appending(path: "envelopes").path) })
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "io.sentry").path))
        }
        return try DiagnosticEnvelopeProtocol.envelopes.withLock { $0 }.map(Self.decodeEnvelope)
    }

    private nonisolated static func decodeEnvelope(_ data: Data) throws -> String {
        var stream = z_stream()
        guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: 1_048_576)
        let result = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = buffer.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = uInt(buffer.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END else { throw CocoaError(.fileReadCorruptFile) }
        return String(decoding: output.prefix(Int(stream.total_out)), as: UTF8.self)
    }

    @Test func platformErrorKeepsSafeDomainAndCode() {
        let event = DiagnosticEvent(
            message: "Request failed", metadata: [:],
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://synthetic.invalid/private")!])
        )
        #expect(event.error?.domain == NSURLErrorDomain)
        #expect(event.error?.code == NSURLErrorTimedOut)
        #expect(event.error?.userInfo.isEmpty == true)
    }
}

private struct SyntheticPrivateError: Error, LocalizedError, CustomStringConvertible {
    let value: String
    var description: String { value }
    var errorDescription: String? { value }
}

private nonisolated final class DiagnosticEnvelopeProtocol: URLProtocol, @unchecked Sendable {
    static let envelopes = OSAllocatedUnfairLock(initialState: [Data]())
    static let arrival = OSAllocatedUnfairLock<AsyncStream<Data>.Continuation?>(initialState: nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count == 0 { break }
                guard count > 0, body.count + count <= 1_048_576 else {
                    client?.urlProtocol(self, didFailWithError: URLError(.dataLengthExceedsMaximum))
                    return
                }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let capturedBody = body
        Self.envelopes.withLock { $0.append(capturedBody) }
        Self.arrival.withLock { _ = $0?.yield(capturedBody) }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
