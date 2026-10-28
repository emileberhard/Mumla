import Foundation
import Synchronization

// Transport experiment only: no microphone capture, retries, or transcript logging.
struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

struct MultipartBody: Sendable {
    let prefix: Data
    let audio: Data
    let suffix: Data

    var complete: Data { prefix + audio + suffix }
}

struct ProbeResponse: Sendable {
    let data: Data
    let status: Int
    let elapsedMilliseconds: Double
    let sourceFinishedMilliseconds: Double?
    let firstUploadProgressMilliseconds: Double?
    let bytesSentBeforeSourceFinished: Int64
    let networkProtocol: String?
}

// URLSession invokes delegates on its queue; every mutable field is mutex-protected.
final class UploadProbe: NSObject, URLSessionDataDelegate, Sendable {
    struct State {
        var continuation: CheckedContinuation<ProbeResponse, any Error>?
        var data = Data()
        var sourceFinishedMilliseconds: Double?
        var firstUploadProgressMilliseconds: Double?
        var bytesSentBeforeSourceFinished: Int64 = 0
        var networkProtocol: String?
        var suppliedStream = false
        var writer: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let start = ContinuousClock.now
    private let body: MultipartBody
    private let pacingSeconds: Double

    init(body: MultipartBody, pacingSeconds: Double) {
        self.body = body
        self.pacingSeconds = pacingSeconds
    }

    private var elapsedMilliseconds: Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }

    func run(_ request: URLRequest) async throws -> ProbeResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = max(40, pacingSeconds + 25)
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.continuation = continuation }
                let task = pacingSeconds > 0
                    ? session.uploadTask(withStreamedRequest: request)
                    : session.uploadTask(with: request, from: body.complete)
                task.resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void
    ) {
        let alreadySupplied = state.withLock { state in
            let previous = state.suppliedStream
            state.suppliedStream = true
            return previous
        }
        guard !alreadySupplied else {
            completionHandler(nil)
            task.cancel()
            return
        }
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 16_384, inputStream: &input, outputStream: &output)
        guard let input, let output else {
            completionHandler(nil)
            task.cancel()
            return
        }
        let writer = StreamWriter(output: output)
        completionHandler(input)
        let worker = Task {
            do {
                try await writer.send(body: body, duration: pacingSeconds)
                state.withLock { $0.sourceFinishedMilliseconds = elapsedMilliseconds }
            } catch {
                task.cancel()
            }
        }
        state.withLock { $0.writer = worker }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLarge = state.withLock { state in
            state.data.append(data)
            return state.data.count > 1_048_576
        }
        if tooLarge { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        state.withLock { state in
            if state.firstUploadProgressMilliseconds == nil {
                state.firstUploadProgressMilliseconds = elapsedMilliseconds
            }
            if state.sourceFinishedMilliseconds == nil, pacingSeconds > 0 {
                state.bytesSentBeforeSourceFinished = totalBytesSent
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        state.withLock { $0.networkProtocol = metrics.transactionMetrics.last?.networkProtocolName }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let result = state.withLock { state -> (CheckedContinuation<ProbeResponse, any Error>?, ProbeResponse) in
            state.writer?.cancel()
            let continuation = state.continuation
            state.continuation = nil
            return (continuation, ProbeResponse(
                data: state.data,
                status: (task.response as? HTTPURLResponse)?.statusCode ?? 0,
                elapsedMilliseconds: elapsedMilliseconds,
                sourceFinishedMilliseconds: state.sourceFinishedMilliseconds,
                firstUploadProgressMilliseconds: state.firstUploadProgressMilliseconds,
                bytesSentBeforeSourceFinished: state.bytesSentBeforeSourceFinished,
                networkProtocol: state.networkProtocol
            ))
        }
        if let error {
            result.0?.resume(throwing: error)
        } else {
            result.0?.resume(returning: result.1)
        }
    }
}

// The output stream is transferred once to send(), and is never accessed elsewhere.
final class StreamWriter: @unchecked Sendable {
    private let output: OutputStream

    init(output: OutputStream) { self.output = output }

    @concurrent
    func send(body: MultipartBody, duration: Double) async throws {
        output.open()
        defer { output.close() }
        try await write(body.prefix)
        let start = ContinuousClock.now
        let chunkSize = max(1, Int(Double(body.audio.count) / duration / 10))
        for offset in stride(from: 0, to: body.audio.count, by: chunkSize) {
            let end = min(offset + chunkSize, body.audio.count)
            let availableAt = start.advanced(by: .seconds(duration * Double(end) / Double(body.audio.count)))
            try await Task.sleep(until: availableAt, clock: .continuous)
            try await write(body.audio.subdata(in: offset..<end))
        }
        try await write(body.suffix)
    }

    private func write(_ data: Data) async throws {
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            guard output.streamStatus != .error, output.streamStatus != .closed else {
                throw ProbeFailure(description: "Upload output stream closed")
            }
            guard output.hasSpaceAvailable else {
                try await Task.sleep(for: .milliseconds(5))
                continue
            }
            let written = data.withUnsafeBytes { bytes in
                output.write(bytes.bindMemory(to: UInt8.self).baseAddress! + offset, maxLength: min(4_096, data.count - offset))
            }
            guard written > 0 else { throw ProbeFailure(description: "Upload output stream write failed") }
            offset += written
        }
    }
}

@main
struct AzureSpeechProbe {
    static func main() async {
        do {
            try await run()
        } catch {
            let nsError = error as NSError
            let message = error as? ProbeFailure
            print("{\"failure\":\"\(message?.description ?? "Transport failed")\",\"errorCode\":\(nsError.code)}")
            exit(1)
        }
    }

    static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 4,
              ["buffered", "paced"].contains(arguments[0]),
              let duration = Double(arguments[3]), duration > 0, duration <= 60 else {
            throw ProbeFailure(description: "Usage: azure-speech-probe buffered|paced AUDIO MODEL|standard DURATION_SECONDS")
        }
        guard let origin = ProcessInfo.processInfo.environment["LLM_ROUTER_ORIGIN"], origin.hasPrefix("https://"), let baseURL = URL(string: origin + "/vendors/azure-speech") else {
            throw ProbeFailure(description: "Set LLM_ROUTER_ORIGIN to the router's HTTPS origin")
        }
        let routerKeyPath = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/llm-router/key").path
        let routerKey = (try? String(contentsOfFile: routerKeyPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !routerKey.isEmpty else {
            throw ProbeFailure(description: "Install this device's llm-router key at \(routerKeyPath)")
        }
        let audioURL = URL(fileURLWithPath: arguments[1])
        let audio = try Data(contentsOf: audioURL)
        guard !audio.isEmpty, audio.count <= 10_000_000 else {
            throw ProbeFailure(description: "Probe requires nonempty audio smaller than 10 MB")
        }
        let fileExtension = audioURL.pathExtension.lowercased()
        guard ["wav", "mp3", "flac"].contains(fileExtension) else {
            throw ProbeFailure(description: "Probe supports WAV, MP3, or FLAC")
        }
        let definition: [String: Any] = arguments[2] == "standard" ? [:] : [
            "enhancedMode": ["enabled": true, "model": arguments[2]],
        ]
        let definitionData = try JSONSerialization.data(withJSONObject: definition, options: [.sortedKeys])
        let boundary = UUID().uuidString
        var prefix = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"definition\"\r\nContent-Type: application/json\r\n\r\n".utf8)
        prefix.append(definitionData)
        prefix.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"probe.\(fileExtension)\"\r\nContent-Type: \(fileExtension == "mp3" ? "audio/mpeg" : "audio/\(fileExtension)")\r\n\r\n".utf8))
        let body = MultipartBody(prefix: prefix, audio: audio, suffix: Data("\r\n--\(boundary)--\r\n".utf8))
        var components = URLComponents(url: baseURL.appending(path: "speechtotext/transcriptions:transcribe"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "api-version", value: "2025-10-15")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(routerKey)", forHTTPHeaderField: "Authorization")
        let response = try await UploadProbe(body: body, pacingSeconds: arguments[0] == "paced" ? duration : 0).run(request)
        let decoded = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        let phrases = decoded?["combinedPhrases"] as? [[String: Any]] ?? []
        var summary: [String: Any] = [
            "mode": arguments[0], "modelRequested": arguments[2],
            "fileExtension": fileExtension, "audioBytes": audio.count,
            "httpStatus": response.status, "elapsedMilliseconds": response.elapsedMilliseconds,
            "phraseCount": phrases.count,
            "transcriptCharacters": phrases.compactMap { $0["text"] as? String }.joined().count,
            "bytesSentBeforeSourceFinished": response.bytesSentBeforeSourceFinished,
        ]
        summary["durationMilliseconds"] = decoded?["durationMilliseconds"]
        summary["networkProtocol"] = response.networkProtocol
        summary["firstUploadProgressMilliseconds"] = response.firstUploadProgressMilliseconds
        summary["sourceFinishedMilliseconds"] = response.sourceFinishedMilliseconds
        if let finished = response.sourceFinishedMilliseconds {
            summary["finishToResponseMilliseconds"] = response.elapsedMilliseconds - finished
        }
        if !(200..<300).contains(response.status) {
            let error = decoded?["error"] as? [String: Any] ?? decoded
            summary["errorCode"] = error?["code"]
        }
        let output = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print(String(decoding: output, as: UTF8.self))
        if !(200..<300).contains(response.status) { exit(2) }
    }
}
