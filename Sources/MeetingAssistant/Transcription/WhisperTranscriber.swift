import ArgmaxCore
import Foundation
import AVFoundation
@preconcurrency import WhisperKit

struct ModelPaths: Sendable {
    let model: URL
    let tokenizer: URL

    init(model: String?, tokenizer: String?) throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let base = documents.appendingPathComponent("huggingface/models")
        self.model = model.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? base.appendingPathComponent("argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_626MB")
        self.tokenizer = tokenizer.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? base.appendingPathComponent("openai/whisper-large-v3")
        for file in ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"] {
            guard FileManager.default.fileExists(atPath: self.model.appendingPathComponent(file).path) else {
                throw MeetingError("Local model component missing: \(self.model.appendingPathComponent(file).path). Set --model-path.")
            }
        }
        for file in ["tokenizer.json", "tokenizer_config.json", "config.json"] {
            guard FileManager.default.fileExists(atPath: self.tokenizer.appendingPathComponent(file).path) else {
                throw MeetingError("Local tokenizer file missing: \(self.tokenizer.appendingPathComponent(file).path). Set --tokenizer-path.")
            }
        }
    }
}

// One instance belongs exclusively to one ASR worker. Two streams never share mutable
// WhisperKit decoding state. Capture/ingest tasks never access this object.
final class WhisperTranscriber: @unchecked Sendable {
    private let kit: WhisperKit
    private let source: AudioSource
    private var finalizer: TranscriptFinalizer
    private let debugDirectory: URL?

    init(source: AudioSource, paths: ModelPaths, debugDirectory: String? = nil) async throws {
        self.source = source
        finalizer = TranscriptFinalizer(source: source)
        self.debugDirectory = debugDirectory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        if let directory = self.debugDirectory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let tokenizer = try await LocalWhisperTokenizer(folder: paths.tokenizer)
        let config = WhisperKitConfig(modelFolder: paths.model.path, tokenizerFolder: paths.tokenizer,
            verbose: false, prewarm: false, load: false, download: false)
        kit = try await WhisperKit(config)
        kit.tokenizer = tokenizer
        try await kit.loadModels()
        guard let logits = kit.textDecoder.logitsSize, let embeddings = kit.audioEncoder.embedSize else {
            throw MeetingError("Loaded WhisperKit model has no decoder/encoder dimensions")
        }
        // A pre-injected tokenizer bypasses WhisperKit's variant detection. Set the
        // public decoder flag explicitly and derive diagnostics from actual shapes;
        // kit.modelVariant remains its upstream default and is not used here.
        // These are the large-v3 shapes verified in the installed model config and
        // upstream ModelUtilities (its variant helpers are internal in this revision).
        guard logits == 51866, embeddings == 1280 else { throw MeetingError("This milestone requires a Whisper large-v3 model; got logits=\(logits), embeddings=\(embeddings)") }
        kit.textDecoder.isModelMultilingual = true
        kit.textDecoder.logitsFilters = [InitialTimestampFilter(timeTokenBegin: tokenizer.specialTokens.timeTokenBegin, vocabularySize: logits)]
        Log.info("\(source.rawValue) WhisperKit ready: large-v3 (local tokenizer; downloads disabled)")
    }

    func transcribe(_ chunk: SpeechChunk) async throws -> [TranscriptEvent] {
        if let debugDirectory {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(chunk.samples.count)) else { throw MeetingError("Cannot allocate debug WAV buffer") }
            buffer.frameLength = UInt32(chunk.samples.count)
            chunk.samples.withUnsafeBufferPointer { pointer in
                buffer.floatChannelData![0].update(from: pointer.baseAddress!, count: pointer.count)
            }
            let url = debugDirectory.appendingPathComponent(String(format: "%@-%09.3f.wav", source.rawValue, chunk.start))
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        // Live windows can begin mid-word. The upstream first-token threshold can
        // stop decoding after that word, and its fallback resets alignment storage
        // even after the final attempt. Decode the full greedy hypothesis once;
        // apply no-speech/validity checks to its completed result below.
        let options = DecodingOptions(language: "ru", temperatureFallbackCount: 0,
            detectLanguage: false, skipSpecialTokens: true, wordTimestamps: true,
            windowClipTime: 0, suppressBlank: true, compressionRatioThreshold: nil,
            logProbThreshold: nil, firstTokenLogProbThreshold: nil, concurrentWorkerCount: 1)
        // AudioStreamTranscriber in e687e26 owns startRecordingLive and unbounded
        // confirmed history. Use the verified public array API for our bounded,
        // explicitly selected AUHAL streams. Only completed decode results are used.
        let results = try await kit.transcribe(audioArray: chunk.samples, decodeOptions: options)
        if let debugDirectory {
            let data = try JSONEncoder().encode(results.flatMap(\.segments))
            try data.write(to: debugDirectory.appendingPathComponent(String(format: "%@-%09.3f.json", source.rawValue, chunk.start)))
        }
        var hypotheses: [[RecognizedWord]] = []
        for segment in results.flatMap(\.segments).sorted(by: { $0.start < $1.start }) {
            // Match WhisperKit's joint no-speech rule. A compression ratio on its
            // own is not grounds for deleting Russian speech after fallback decoding.
            if segment.noSpeechProb > 0.6 && segment.avgLogprob < -1 {
                Log.info(String(format: "%@: rejected no-speech segment (logprob %.2f, no-speech %.2f)", source.rawValue, segment.avgLogprob, segment.noSpeechProb))
                continue
            }
            guard let words = segment.words else { throw MeetingError("WhisperKit returned no requested word timestamps") }
            hypotheses.append(words.map { RecognizedWord(text: $0.word, start: Double($0.start), end: Double($0.end)) })
        }
        return try finalizer.finalize(hypotheses, chunk: chunk)
    }
}
