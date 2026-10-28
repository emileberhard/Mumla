// Single-provider realtime transcription runner.
//
// Streams a PCM16 WAV to one provider over its realtime WebSocket API at
// real-time pace (100 ms chunks), sends the
// provider's "user tapped stop" flush message, and records every inbound
// wire event as timestamped JSONL. OpenAI, ElevenLabs, and Gemini session
// payloads mirror SpeechKit exactly so runs reproduce app behavior; the other
// providers follow their official streaming quickstarts.
//
//   swift Evaluations/RealtimeTranscription/scripts/stream_provider.swift \
//     --provider openai --model gpt-4o-mini-transcribe-2025-12-15 \
//     --vad semantic:auto \
//     --wav Evaluations/RealtimeTranscription/fixtures/en-developer-message.wav \
//     --rate 24000 --out /tmp/openai.jsonl
//
// Providers and their --model meaning:
//   openai       model ID (--vad semantic:low|server:0.5:500|off, --delay for whisper)
//   elevenlabs   fixed app config (16 kHz WAV required)
//   gemini       model ID (16 kHz WAV required; smart mode with manual VAD)
//   assemblyai   speech_model (empty = Universal-Streaming default; 16 kHz WAV)
//   deepgram     model ID, e.g. nova-3
//
// Every provider is reached through llm-router with this device's router key
// from ~/.config/llm-router/key.

import Foundation

// MARK: - Arguments

let usage = """
usage: stream_provider.swift --provider openai|elevenlabs|gemini|assemblyai|deepgram \
  --wav <pcm16 wav> --rate <hz> --out <jsonl> [--model <id>] [--vad <mode>] \
  [--language <code|auto>] [--delay <value>] [--tail-wait <seconds>] \
  [--previous-text <text>] [--commit-strategy <vad|manual>] [--keyterms <csv>]
"""

func failUsage(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n\n\(usage)\n".utf8))
    exit(2)
}

if CommandLine.arguments.contains("--help") {
    print(usage)
    exit(0)
}

let knownArguments: Set<String> = [
    "provider", "wav", "rate", "out", "model", "vad", "language", "delay", "tail-wait",
    "previous-text", "commit-strategy", "keyterms",
]
var args: [String: String] = [:]
let argv = Array(CommandLine.arguments.dropFirst())
guard argv.count.isMultiple(of: 2) else {
    failUsage("every option must have a value")
}
for index in stride(from: 0, to: argv.count, by: 2) {
    let option = argv[index]
    guard option.hasPrefix("--") else {
        failUsage("unexpected argument: \(option)")
    }
    let name = String(option.dropFirst(2))
    guard knownArguments.contains(name) else {
        failUsage("unknown option: --\(name)")
    }
    guard args.updateValue(argv[index + 1], forKey: name) == nil else {
        failUsage("duplicate option: --\(name)")
    }
}

guard
    let provider = args["provider"],
    let wavPath = args["wav"],
    let rateString = args["rate"], let sampleRate = Int(rateString),
    let outPath = args["out"]
else {
    failUsage("missing a required option")
}

let providers = ["openai", "elevenlabs", "gemini", "assemblyai", "deepgram"]
guard providers.contains(provider) else {
    failUsage("unknown provider: \(provider)")
}
guard sampleRate > 0 else {
    failUsage("--rate must be positive")
}

let model = args["model"] ?? ""
let vad = args["vad"] ?? "semantic:low"
let language = args["language"] ?? "en"
let previousText = args["previous-text"] ?? ""
let commitStrategy = args["commit-strategy"] ?? "vad"
let keyterms = (args["keyterms"] ?? "")
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }
guard let tailWaitSeconds = Double(args["tail-wait"] ?? "8"), tailWaitSeconds >= 0 else {
    failUsage("--tail-wait must be a non-negative number")
}
guard previousText.count <= 50 else {
    failUsage("--previous-text must contain at most 50 characters")
}
guard ["vad", "manual"].contains(commitStrategy) else {
    failUsage("--commit-strategy must be vad or manual")
}
guard keyterms.count <= 50, keyterms.allSatisfy({ $0.count <= 20 }) else {
    failUsage("--keyterms must contain at most 50 comma-separated terms of at most 20 characters")
}

guard let routerOrigin = ProcessInfo.processInfo.environment["LLM_ROUTER_ORIGIN"], routerOrigin.hasPrefix("https://") else {
    failUsage("Set LLM_ROUTER_ORIGIN to the router's HTTPS origin")
}
let routerKeyPath = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".config/llm-router/key").path
let routerKey = (try? String(contentsOfFile: routerKeyPath, encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
guard !routerKey.isEmpty else {
    failUsage("Install this device's llm-router key at \(routerKeyPath)")
}

func routed(_ vendor: String, _ path: String) -> URLComponents {
    URLComponents(string: routerOrigin.replacingOccurrences(of: "https://", with: "wss://") + "/vendors/\(vendor)" + path)!
}

// MARK: - WAV loading

func loadPCM(path: String) -> Data {
    guard let file = FileManager.default.contents(atPath: path) else {
        fatalError("cannot read \(path)")
    }
    guard file.count >= 12, String(decoding: file[0 ..< 4], as: UTF8.self) == "RIFF" else {
        fatalError("not a RIFF WAV file: \(path)")
    }
    var offset = 12
    while offset + 8 <= file.count {
        let id = String(decoding: file[offset ..< offset + 4], as: UTF8.self)
        let size = file[offset + 4 ..< offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        if id == "data" {
            let start = offset + 8
            let end = min(start + Int(size), file.count)
            return Data(file[start ..< end])
        }
        offset += 8 + Int(size) + (Int(size) % 2)
    }
    fatalError("no data chunk in \(path)")
}

let pcm = loadPCM(path: wavPath)
let audioSeconds = Double(pcm.count) / Double(sampleRate * 2)

// MARK: - Event log

let startedAt = ContinuousClock.now
var logLines: [String] = []
var sentAudioSeconds = 0.0

@MainActor
func logEvent(direction: String, payload: String) {
    let t = Double((startedAt.duration(to: .now)) / .seconds(1))
    let payloadData = Data(payload.utf8)
    let event = (try? JSONSerialization.jsonObject(with: payloadData, options: [.fragmentsAllowed])) ?? payload
    let entry: [String: Any] = [
        "t": t,
        "audio_sent_s": sentAudioSeconds,
        "dir": direction,
        "event": event,
    ]
    let data = try! JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
    logLines.append(String(decoding: data, as: UTF8.self))
}

func jsonString(_ object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Provider wiring

// Whether audio chunks go as binary WebSocket frames (raw PCM16) or as the
// provider's JSON + base64 text message.
let sendsBinaryAudio = ["assemblyai", "deepgram"].contains(provider)

func makeRequest() -> URLRequest {
    switch provider {
    case "openai":
        var components = routed("openai", "/v1/realtime")
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        var request = URLRequest(url: components.url!)
        request.addValue("Bearer \(routerKey)", forHTTPHeaderField: "Authorization")
        return request
    case "elevenlabs":
        var components = routed("elevenlabs", "/v1/speech-to-text/realtime")
        var queryItems = [
            URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "include_timestamps", value: "true"),
            URLQueryItem(name: "include_language_detection", value: "true"),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: commitStrategy),
            URLQueryItem(name: "vad_silence_threshold_secs", value: "3.0"),
            URLQueryItem(name: "vad_threshold", value: "0.4"),
            URLQueryItem(name: "min_speech_duration_ms", value: "100"),
            URLQueryItem(name: "min_silence_duration_ms", value: "100"),
            URLQueryItem(name: "enable_logging", value: "true"),
        ]
        if language != "auto" {
            queryItems.append(URLQueryItem(name: "language_code", value: language))
        }
        queryItems.append(contentsOf: keyterms.map {
            URLQueryItem(name: "keyterms", value: $0)
        })
        components.queryItems = queryItems
        var request = URLRequest(url: components.url!)
        request.addValue(routerKey, forHTTPHeaderField: "xi-api-key")
        return request
    case "gemini":
        let components = routed("google", "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")
        var request = URLRequest(url: components.url!)
        request.addValue(routerKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    case "assemblyai":
        var components = routed("assemblyai-streaming", "/v3/ws")
        var queryItems = [
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "format_turns", value: "true"),
        ]
        if !model.isEmpty {
            queryItems.append(URLQueryItem(name: "speech_model", value: model))
        }
        // Language steering is a JSON-array string, Universal-3.5 Pro
        // Streaming only; the other streaming models reject it.
        if model == "universal-3-5-pro" {
            let codes = language.split(separator: ",").map { "\"\($0)\"" }.joined(separator: ",")
            queryItems.append(URLQueryItem(name: "language_codes", value: "[\(codes)]"))
        }
        components.queryItems = queryItems
        var request = URLRequest(url: components.url!)
        request.addValue(routerKey, forHTTPHeaderField: "Authorization")
        return request
    case "deepgram":
        var components = routed("deepgram", "/v1/listen")
        components.queryItems = [
            URLQueryItem(name: "model", value: model.isEmpty ? "nova-3" : model),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "language", value: language),
        ]
        var request = URLRequest(url: components.url!)
        request.addValue("Token \(routerKey)", forHTTPHeaderField: "Authorization")
        return request
    default:
        fatalError("unknown provider \(provider)")
    }
}

func turnDetectionJSON() -> Any {
    if vad == "off" { return NSNull() }
    if vad.hasPrefix("semantic") {
        let eagerness = vad.split(separator: ":").count > 1 ? String(vad.split(separator: ":")[1]) : "auto"
        return ["type": "semantic_vad", "eagerness": eagerness]
    }
    if vad.hasPrefix("server") {
        let parts = vad.split(separator: ":").map(String.init)
        let threshold = parts.count > 1 ? Double(parts[1]) ?? 0.5 : 0.5
        let silence = parts.count > 2 ? Int(parts[2]) ?? 500 : 500
        return ["type": "server_vad", "threshold": threshold, "prefix_padding_ms": 300, "silence_duration_ms": silence] as [String: Any]
    }
    fatalError("unknown vad \(vad)")
}

// Message sent right after connecting, before audio.
@MainActor
func startMessage() -> String? {
    switch provider {
    case "openai":
        var transcription: [String: Any] = [
            "model": model.isEmpty ? "gpt-4o-mini-transcribe-2025-12-15" : model,
            "language": language,
        ]
        if let delay = args["delay"] {
            transcription["delay"] = delay
        }
        return jsonString([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": sampleRate],
                        "noise_reduction": ["type": "near_field"],
                        "transcription": transcription,
                        "turn_detection": turnDetectionJSON(),
                    ],
                ],
            ] as [String: Any],
        ])
    case "gemini":
        let languageCodes = [
            "en": "en-US",
            "sv": "sv-SE",
        ]
        return jsonString([
            "setup": [
                "model": "models/\(model.isEmpty ? "gemini-3.5-transcribe-live" : model)",
                "generationConfig": ["responseModalities": ["TEXT"]],
                "realtimeInputConfig": [
                    "automaticActivityDetection": ["disabled": true],
                ],
                "inputAudioTranscription": [
                    "languageCodes": languageCodes[language].map { [$0] } ?? [],
                    "customVocabulary": keyterms,
                    "mode": "SMART",
                ],
            ] as [String: Any],
        ])
    default:
        return nil
    }
}

// Marks the session ready for audio. Deepgram has no ready event; audio is
// accepted as soon as the socket is open.
func isReadyEvent(_ text: String) -> Bool {
    switch provider {
    case "openai":
        return text.contains("\"session.updated\"") || text.contains("\"transcription_session.updated\"")
    case "elevenlabs":
        return text.contains("\"session_started\"")
    case "gemini":
        return text.contains("\"setupComplete\"")
    case "assemblyai":
        return text.contains("\"Begin\"")
    default:
        return false
    }
}

// The app-equivalent of tapping stop: ask the provider to finalize what it
// has.
func stopMessage() -> String {
    switch provider {
    case "openai":
        return jsonString(["type": "input_audio_buffer.commit"])
    case "elevenlabs":
        return jsonString(["message_type": "input_audio_chunk", "audio_base_64": "", "commit": true, "sample_rate": sampleRate])
    case "gemini":
        return jsonString(["realtimeInput": ["activityEnd": [:]]])
    case "assemblyai":
        // Terminate, not ForceEndpoint: ForceEndpoint only closes the current
        // turn with audio processed so far and can leave trailing words in the
        // buffer until session end. Terminate processes all remaining audio and
        // sends the final turns before closing — the correct tap-stop flush.
        return jsonString(["type": "Terminate"])
    case "deepgram":
        return jsonString(["type": "Finalize"])
    default:
        fatalError("unknown provider \(provider)")
    }
}

// Sent after the tail wait, before closing, so sessions end cleanly (and
// billing stops) on providers with an explicit terminate.
func terminateMessage() -> String? {
    switch provider {
    case "deepgram":
        return jsonString(["type": "CloseStream"])
    default:
        return nil
    }
}

// MARK: - Run

let sessionConfiguration = URLSessionConfiguration.ephemeral
sessionConfiguration.waitsForConnectivity = true
sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
sessionConfiguration.timeoutIntervalForRequest = 30
sessionConfiguration.timeoutIntervalForResource = 60 * 60
let urlSession = URLSession(configuration: sessionConfiguration)
let socket = urlSession.webSocketTask(with: makeRequest())
socket.maximumMessageSize = 8 * 1024 * 1024
socket.resume()

var ready = provider == "deepgram"
var receiverDone = false

// Any session outliving the audio + tail by a wide margin is hung, not slow.
// Fail fast with a diagnostic .failed log instead of blocking the harness;
// the missing .jsonl lets a resume retry the run.
@MainActor
func abortRun(_ reason: String) -> Never {
    logEvent(direction: "marker", payload: "ABORT: \(reason)")
    try? logLines.joined(separator: "\n").appending("\n")
        .write(toFile: outPath + ".failed", atomically: true, encoding: .utf8)
    FileHandle.standardError.write(Data("ABORT: \(reason)\n".utf8))
    exit(1)
}

Task { @MainActor in
    try? await Task.sleep(for: .seconds(audioSeconds + tailWaitSeconds + 60))
    abortRun("watchdog timeout")
}

let receiver = Task { @MainActor in
    while !Task.isCancelled {
        do {
            let message = try await socket.receive()
            let text: String
            switch message {
            case .data(let data):
                text = String(decoding: data, as: UTF8.self)
            case .string(let string):
                text = string
            @unknown default:
                continue
            }
            logEvent(direction: "in", payload: text)
            if isReadyEvent(text) {
                ready = true
            }
        } catch {
            logEvent(direction: "marker", payload: "receive ended: \(error.localizedDescription)")
            break
        }
    }
    receiverDone = true
}

if let start = startMessage() {
    logEvent(direction: "out", payload: start)
    try await socket.send(.string(start))
}

while !ready {
    if receiverDone {
        abortRun("connection ended before session ready (rejected?)")
    }
    try await Task.sleep(for: .milliseconds(20))
}
logEvent(direction: "marker", payload: "session ready, streaming \(String(format: "%.1f", audioSeconds))s of audio")

// Stream at real-time pace: 100 ms chunks.
let chunkBytes = sampleRate / 10 * 2
var offset = 0
var chunkIndex = 0
let streamStart = ContinuousClock.now
while offset < pcm.count {
    let end = min(offset + chunkBytes, pcm.count)
    let chunk = pcm[offset ..< end]
    if sendsBinaryAudio {
        try await socket.send(.data(Data(chunk)))
    } else if provider == "openai" {
        try await socket.send(.string(jsonString(["type": "input_audio_buffer.append", "audio": chunk.base64EncodedString()])))
    } else if provider == "gemini" {
        if chunkIndex == 0 {
            let activityStart = jsonString(["realtimeInput": ["activityStart": [:]]])
            logEvent(direction: "out", payload: activityStart)
            try await socket.send(.string(activityStart))
        }
        try await socket.send(.string(jsonString([
            "realtimeInput": [
                "audio": [
                    "data": chunk.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=\(sampleRate)",
                ],
            ],
        ])))
    } else {
        var payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": chunk.base64EncodedString(),
            "commit": false,
            "sample_rate": sampleRate,
        ]
        if provider == "elevenlabs", chunkIndex == 0, !previousText.isEmpty {
            payload["previous_text"] = previousText
        }
        try await socket.send(.string(jsonString(payload)))
    }
    offset = end
    chunkIndex += 1
    sentAudioSeconds = Double(offset) / Double(sampleRate * 2)
    let target = streamStart.advanced(by: .milliseconds(100 * chunkIndex))
    let now = ContinuousClock.now
    if now < target {
        try await Task.sleep(until: target)
    }
}

// The user taps Finish.
let stop = stopMessage()
logEvent(direction: "out", payload: stop)
logEvent(direction: "marker", payload: "STOP: commit requested")
try await socket.send(.string(stop))

// Collect the tail, then close the session cleanly. Providers that close the
// socket after their stop flush (AssemblyAI Terminate) end the wait early.
let tailDeadline = ContinuousClock.now.advanced(by: .seconds(tailWaitSeconds))
while !receiverDone, ContinuousClock.now < tailDeadline {
    try await Task.sleep(for: .milliseconds(50))
}
if let terminate = terminateMessage(), !receiverDone {
    logEvent(direction: "out", payload: terminate)
    try? await socket.send(.string(terminate))
    try? await Task.sleep(for: .milliseconds(500))
}
receiver.cancel()
socket.cancel(with: .normalClosure, reason: nil)
while !receiverDone {
    try await Task.sleep(for: .milliseconds(20))
}

try logLines.joined(separator: "\n").appending("\n")
    .write(toFile: outPath, atomically: true, encoding: .utf8)
print("wrote \(outPath): \(logLines.count) events")
exit(0)
