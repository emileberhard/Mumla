import DictationLibrary
import AudioToolbox
import AVFAudio
import Foundation
import os

nonisolated enum AudioArchiveFileType: String, Codable, Sendable {
    case wav
    case caf
}

nonisolated enum OriginalAudioError: LocalizedError {
    case encoder(OSStatus)
    case conversionFailed
    case empty
    case alreadyFinished

    var errorDescription: String? {
        switch self {
        case .encoder(let status): "The original audio could not be encoded (\(status))."
        case .conversionFailed: "The original audio could not be converted."
        case .empty: "No original audio was captured."
        case .alreadyFinished: "The original audio was already finished."
        }
    }
}

nonisolated struct CapturedDictationAudio: Sendable {
    let providerWAV: Data
    let original: Task<Result<URL, any Error>, Never>

    init(providerWAV: Data, original: Result<URL, any Error>) {
        self.providerWAV = providerWAV
        self.original = Task { original }
    }

    init(providerWAV: Data, originalAudio: OriginalAudioWriter) {
        self.providerWAV = providerWAV
        original = Task(priority: .utility) {
            do { return .success(try await originalAudio.finishArchived()) }
            catch { return .failure(error) }
        }
    }
}

nonisolated enum OriginalAudio {
    static let batchProviderSampleRate = 16_000

    static func pcm16Format(sampleRate: Int) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true)
    }

    @concurrent
    static func providerWAV(from url: URL, fileType: AudioArchiveFileType) async throws -> Data {
        switch fileType {
        case .wav:
            return try Data(contentsOf: url)
        case .caf:
            let file = try AVAudioFile(forReading: url)
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  let format = pcm16Format(sampleRate: batchProviderSampleRate)
            else { throw OriginalAudioError.conversionFailed }
            try file.read(into: input)
            guard let pcm = StreamingAudioConverter(outputFormat: format).convert(input, endOfStream: true)?.pcm16MonoData
            else { throw OriginalAudioError.conversionFailed }
            return try RealtimePCM16WAVFile.data(pcmData: pcm, sampleRate: batchProviderSampleRate)
        }
    }
}

nonisolated final class StreamingAudioConverter {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func supports(_ inputFormat: AVAudioFormat) -> Bool {
        inputFormat == outputFormat || converter(for: inputFormat) != nil
    }

    func convert(_ buffer: AVAudioPCMBuffer, endOfStream: Bool = false) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        if buffer.format == outputFormat { return buffer }
        guard let converter = converter(for: buffer.format) else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        nonisolated(unsafe) let input = buffer
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    func flush() -> AVAudioPCMBuffer? {
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8_192) else { return nil }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    private func converter(for inputFormat: AVAudioFormat) -> AVAudioConverter? {
        if converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }
        return converter
    }
}

nonisolated extension AVAudioPCMBuffer {
    var pcm16MonoData: Data? {
        guard format.commonFormat == .pcmFormatInt16, format.channelCount == 1, let channel = int16ChannelData else {
            return nil
        }
        return Data(bytes: channel[0], count: Int(frameLength) * MemoryLayout<Int16>.size)
    }
}

nonisolated final class OriginalAudioWriter: Sendable {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    static let bitRate: UInt32 = 96_000

    let url: URL
    private let state: OSAllocatedUnfairLock<State>
    private let libraryCapture: DictationCaptureWriter?
    let dictationPlan: DictationPlan?

    private enum Phase { case open(ExtAudioFileRef), library, finished, discarded }

    private struct State {
        var phase: Phase
        let converter = StreamingAudioConverter(outputFormat: OriginalAudioWriter.format)
        var frameCount: Int64 = 0
        var failure: (any Error)?
        var libraryConfigured = false

        mutating func append(_ pcm: AVAudioPCMBuffer, to file: ExtAudioFileRef) throws {
            try OriginalAudioWriter.check(ExtAudioFileWrite(file, pcm.frameLength, pcm.audioBufferList))
            frameCount += Int64(pcm.frameLength)
        }

        func originalFormatBuffer(from buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
            guard let converted = converter.convert(buffer) else { throw OriginalAudioError.conversionFailed }
            return converted
        }
    }

    init(dictation: UnifiedDictationLibrary.PreparedCapture? = nil) throws {
        let libraryCapture = dictation?.writer
        self.libraryCapture = libraryCapture
        dictationPlan = dictation?.plan
        if let libraryCapture {
            url = libraryCapture.originalURL
            state = OSAllocatedUnfairLock(uncheckedState: State(phase: .library))
            return
        }
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mumla-original-\(UUID().uuidString).caf")
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: Self.format.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
            mChannelsPerFrame: Self.format.channelCount, mBitsPerChannel: 0, mReserved: 0
        )
        var created: ExtAudioFileRef?
        try Self.check(ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileCAFType, &fileFormat, nil, AudioFileFlags.eraseFile.rawValue, &created
        ))
        guard let file = created else { throw OriginalAudioError.encoder(kAudio_ParamError) }
        do {
            try Self.configure(file)
        } catch {
            ExtAudioFileDispose(file)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        state = OSAllocatedUnfairLock(uncheckedState: State(phase: .open(file)))
    }

    deinit {
        discard()
    }

    static func encode(contentsOf source: URL) throws -> URL {
        let file = try AVAudioFile(forReading: source)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw OriginalAudioError.conversionFailed
        }
        try file.read(into: buffer)
        let writer = try OriginalAudioWriter()
        writer.write(buffer)
        return try writer.finish()
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        state.withLockUnchecked { state in
            if case .library = state.phase, let libraryCapture {
                do {
                    if !state.libraryConfigured {
                        try libraryCapture.configure(format: buffer.format)
                        state.libraryConfigured = true
                    }
                    libraryCapture.append(buffer)
                } catch { state.failure = error }
                return
            }
            guard case .open(let file) = state.phase, state.failure == nil else { return }
            do {
                let pcm = try state.originalFormatBuffer(from: buffer)
                try state.append(pcm, to: file)
            } catch {
                state.failure = error
            }
        }
    }

    func finishArchived() async throws -> URL {
        if let libraryCapture {
            let failure = state.withLockUnchecked { state in
                state.phase = .finished
                return state.failure
            }
            _ = try await libraryCapture.finish()
            if let failure { throw failure }
            return url
        }
        return try finish()
    }

    func finish() throws -> URL {
        try state.withLockUnchecked { state in
            guard case .open(let file) = state.phase else { throw OriginalAudioError.alreadyFinished }
            if state.failure == nil, let tail = state.converter.flush() {
                do { try state.append(tail, to: file) } catch { state.failure = error }
            }
            state.phase = .finished
            let status = ExtAudioFileDispose(file)
            do {
                if let failure = state.failure { throw failure }
                try Self.check(status)
                guard state.frameCount > 0 else { throw OriginalAudioError.empty }
                return url
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
    }

    func discard() {
        state.withLockUnchecked { state in
            if case .library = state.phase, let libraryCapture {
                state.phase = .discarded
                Task { _ = try? await libraryCapture.finish() }
                return
            }
            guard case .open(let file) = state.phase else { return }
            state.phase = .discarded
            ExtAudioFileDispose(file)
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func configure(_ file: ExtAudioFileRef) throws {
        var audioFile: AudioFileID?
        var size = UInt32(MemoryLayout<AudioFileID?>.size)
        try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioFile, &size, &audioFile))
        guard let audioFile else { throw OriginalAudioError.encoder(kAudio_ParamError) }
        var packetTableReserve: Float64 = 0
        try check(AudioFileSetProperty(
            audioFile, kAudioFilePropertyReserveDuration, UInt32(MemoryLayout<Float64>.size), &packetTableReserve
        ))

        var clientFormat = format.streamDescription.pointee
        try check(ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat
        ))

        var converter: AudioConverterRef?
        size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter))
        guard let converter else { throw OriginalAudioError.encoder(kAudio_ParamError) }
        var bitRate = Self.bitRate
        try check(AudioConverterSetProperty(
            converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitRate
        ))
        var converterConfig: CFArray?
        try withUnsafePointer(to: &converterConfig) { pointer in
            try check(ExtAudioFileSetProperty(
                file, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<CFArray?>.size), pointer
            ))
        }
    }

    fileprivate static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw OriginalAudioError.encoder(status) }
    }
}
