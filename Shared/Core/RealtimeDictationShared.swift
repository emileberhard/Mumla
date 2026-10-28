import Foundation
import SpeechKit

struct RealtimeDictationResult: Sendable {
    let diagnosticsSessionID: String
    let text: String?
    let originalAudio: Result<URL, any Error>?
    let fallbackReason: String?
    let failure: (any Error)?
}

nonisolated struct RealtimeDictationNotStarted: Error {}

struct RealtimeDictationCompletion {
    let text: String?
    let fallbackReason: String?
    let error: (any Error)?

    static func finish(_ dictation: RealtimeDictation) async -> Self {
        do {
            let text = RealtimeDictationText.pasteable(try await dictation.finish())
            return Self(text: text, fallbackReason: text == nil ? "missing_realtime_text" : nil, error: nil)
        } catch {
            return Self(text: nil, fallbackReason: RealtimeDictationFailure.reason(for: error), error: error)
        }
    }
}

struct RealtimeDictationProviderConfiguration: Sendable {
    let grant: Task<AccessGrant, any Error>
    let customVocabulary: [String]
    let languageHints: [String]
    let onAudioLimitReached: @Sendable () -> Void

    func makeSession() -> any RealtimeTranscriptionSession {
        GrantedRealtimeTranscriptionSession(
            grant: grant,
            request: .init(languageHints: languageHints, customVocabulary: customVocabulary),
            onAudioLimitReached: onAudioLimitReached
        )
    }

    var diagnosticsMetadata: [String: String] {
        [
            "provider": "azure-speech",
            "model": "MAI-Transcribe-2",
            "transport": "progressive-http-upload",
            "custom_vocabulary_count": String(customVocabulary.count),
            "language_hints": languageHints.joined(separator: ","),
        ]
    }
}

enum RealtimeDictationText {
    static func pasteable(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        return text.last.map { ".?!".contains($0) } == true ? text + " " : text
    }
}

enum RealtimeDictationFailure {
    static func reason(for error: Error) -> String {
        guard let error = error as? RealtimeDictationError else {
            return error is CancellationError ? "realtime_canceled" : "realtime_failed"
        }
        return switch error {
        case .connectionFailed: "realtime_connection_failed"
        case .streamFailed: "realtime_stream_failed"
        case .commitFailed: "realtime_commit_failed"
        case .streamEnded: "realtime_stream_ended"
        case .finalizationTimedOut: "realtime_finalization_timed_out"
        case .audioBufferOverflow: "realtime_audio_buffer_overflow"
        }
    }
}

nonisolated struct RealtimeCaptureTailSnapshot: Sendable {
    let deliveredBufferCount: Int
    let level: Double
}

/// Keeps iOS capture open only long enough for CoreAudio to deliver the buffer
/// already in flight when the user taps stop. If that buffer still contains
/// speech, capture continues until the first quiet buffer, with a hard cap for
/// sustained speech or noisy environments.
nonisolated enum RealtimeCaptureTailPolicy {
    static let pollInterval: Duration = .milliseconds(10)
    static let firstBufferTimeout: Duration = .milliseconds(150)
    static let maximumDuration: Duration = .milliseconds(500)
    static let silenceLevelThreshold = 0.04

    static func shouldFinish(
        initialBufferCount: Int,
        currentSnapshot: RealtimeCaptureTailSnapshot,
        elapsed: Duration
    ) -> Bool {
        if elapsed >= maximumDuration {
            return true
        }
        guard currentSnapshot.deliveredBufferCount > initialBufferCount else {
            return elapsed >= firstBufferTimeout
        }
        return currentSnapshot.level <= silenceLevelThreshold
    }
}

enum RealtimePCM16WAVFile {
    nonisolated static func data(pcmData: Data, sampleRate: Int) throws -> Data {
        guard sampleRate > 0 else {
            throw RealtimePCM16WAVFileWriterError.invalidSampleRate
        }
        guard !pcmData.isEmpty else {
            throw RealtimePCM16WAVFileWriterError.emptyAudio
        }

        var data = header(sampleRate: sampleRate, dataByteCount: pcmData.count)
        data.append(pcmData)
        return data
    }

    nonisolated static func write(pcmData: Data, sampleRate: Int, to outputURL: URL) throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)
        let data = try data(pcmData: pcmData, sampleRate: sampleRate)
        try data.write(to: outputURL, options: [.atomic])
    }

    private nonisolated static func header(sampleRate: Int, dataByteCount: Int) -> Data {
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(UInt32(36 + dataByteCount))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * MemoryLayout<Int16>.size))
        data.appendLittleEndian(UInt16(MemoryLayout<Int16>.size))
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(UInt32(dataByteCount))
        return data
    }
}

enum RealtimePCM16WAVFileWriterError: Error {
    case invalidSampleRate
    case emptyAudio
}

enum PCM16AudioLevel {
    nonisolated static func rms(from data: Data) -> Float {
        guard data.count >= MemoryLayout<Int16>.size else { return 0 }

        var sum: Float = 0
        var sampleCount = 0
        data.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: bytes.count - 1, by: MemoryLayout<Int16>.size) {
                let value = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                let sample = Float(value) / Float(Int16.max)
                sum += sample * sample
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return 0 }
        return sqrt(sum / Float(sampleCount))
    }
}

private extension Data {
    nonisolated mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
