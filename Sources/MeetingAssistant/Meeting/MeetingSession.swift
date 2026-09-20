import Foundation
import Synchronization

/// A single meeting run, shared by CLI and GUI. Create a new instance to restart.
/// requestStop drains captured audio and final ASR; task cancellation aborts work.
public final class MeetingSession: Sendable {
    private let configuration: MeetingConfiguration
    private let callbacks: MeetingCallbacks
    private let started = Atomic<Bool>(false)
    private let stopRequested = Atomic<Bool>(false)
    private let stoppingPublished = Atomic<Bool>(false)
    private let analysis: ContextEngine?
    private let debugLog: MeetingDebugLog?
    public var debugLogURL: URL? { debugLog?.fileURL }

    public init(configuration: MeetingConfiguration, callbacks: MeetingCallbacks = MeetingCallbacks()) {
        self.configuration = configuration
        self.callbacks = callbacks
        debugLog = configuration.debugEnabled ? MeetingDebugLog(directory: configuration.debugLogDirectory, reportError: callbacks.diagnostic) : nil
        analysis = configuration.captureOnly ? nil : configuration.ai.map { ContextEngine(configuration: $0, output: callbacks.analysis) }
    }

    public func requestStop() { debugLog?.record(.info, "Stop requested"); stopRequested.store(true, ordering: .releasing) }
    public func cancelAnalysis() { debugLog?.record(.warning, "AI cancellation requested"); if let analysis { Task { await analysis.cancel() } } }
    public func retryAnalysis() { debugLog?.record(.info, "AI retry requested"); if let analysis { Task { await analysis.retry() } } }
    public func continueWaitingForAnalysis() { debugLog?.record(.info, "Continue waiting for AI requested"); if let analysis { Task { await analysis.continueWaiting() } } }
    public func addContextMessage(_ text: String, time: Double) async throws {
        guard let analysis, !stopRequested.load(ordering: .acquiring) else { throw MeetingError("AI не включён или встреча уже завершается.") }
        try await analysis.addMessage(text, time: time)
        debugLog?.record(.info, "USER_NOTE accepted at \(time)s, characters=\(text.count)")
    }

    public func run() async throws {
        guard !started.exchange(true, ordering: .acquiringAndReleasing) else {
            throw MeetingError("A MeetingSession can only run once; create a new session")
        }
        if let debugLog, debugLog.start() { callbacks.diagnostic("Debug-журнал: \(debugLog.fileURL.path)") }
        do {
            try await Log.$file.withValue(debugLog) {
                try await runWithDiagnostics()
            }
            await debugLog?.close()
        } catch {
            await debugLog?.close()
            throw error
        }
    }

    private func publishPhase(_ phase: MeetingPhase) {
        debugLog?.record(.info, "Meeting phase: \(phase)")
        callbacks.phase(phase)
    }

    private func runWithDiagnostics() async throws {
        try await Log.$sink.withValue(callbacks.diagnostic) {
            do {
                publishPhase(.preparing)
                Log.debug("Configuration: captureOnly=\(configuration.captureOnly), remoteOnly=\(configuration.remoteOnly), thresholdDB=\(configuration.thresholdDB), AI=\(configuration.ai != nil), diarization=\(configuration.diarization.model.rawValue), remoteDiarization=\(configuration.diarization.remoteEnabled), microphoneDiarization=\(configuration.diarization.microphoneEnabled)")
                for source in configuration.sources {
                    if let device = configuration.selected[source] {
                        Log.debug("Device \(source.rawValue): \(device.name) [\(device.id)], \(device.sampleRate) Hz, \(device.inputChannels) channels")
                    }
                }
                try configuration.validate()
                if !stopRequested.load(ordering: .acquiring) {
                    let analysisTask = analysis.map { engine in Task { await engine.run() } }
                    try await withTaskCancellationHandler {
                        do {
                            try await runSession()
                        } catch {
                            analysis?.journal.close()
                            await analysisTask?.value
                            throw error
                        }
                        analysis?.journal.close()
                        if analysisTask != nil { publishPhase(.finishingAnalysis) }
                        await analysisTask?.value
                    } onCancel: { self.cancelAnalysis() }
                }
                publishPhase(.stopped)
            } catch {
                Log.error("Meeting failed: \(error)")
                publishPhase(.failed(String(describing: error)))
                throw error
            }
        }
    }

    private func publishStopping() {
        if !stoppingPublished.exchange(true, ordering: .acquiringAndReleasing) {
            publishPhase(.stopping)
        }
    }

    private func runSession() async throws {
        let sources = configuration.sources
        let diarizers = Dictionary(uniqueKeysWithValues: sources.filter { !configuration.captureOnly && configuration.diarization.enabled(for: $0) }
            .map { ($0, SourceDiarizer(source: $0, model: configuration.diarization.model,
                modelURL: configuration.diarization.resolvedModelURL, output: callbacks.diarization)) })
        let timeline = TranscriptTimeline(sources: sources) { [callbacks, analysis] event in
            try callbacks.transcript(event)
            analysis?.journal.append(event)
            Log.debug("Final transcript id=\(event.id) source=\(event.source.rawValue) speaker=\(event.speakerLabel) start=\(event.startTime) end=\(event.endTime): \(event.text)")
        }
        var transcribers: [AudioSource: WhisperTranscriber] = [:]
        var pipelines: [AudioSource: StreamPipeline] = [:]
        if !configuration.captureOnly {
            publishPhase(.loadingModels)
            let paths = try ModelPaths(model: configuration.modelPath, tokenizer: configuration.tokenizerPath)
            Log.info("\nLoading WhisperKit locally...\nModel: \(paths.model.path)\nTokenizer: \(paths.tokenizer.path)\nLanguage: ru")
            for source in sources {
                transcribers[source] = try await WhisperTranscriber(source: source, paths: paths, debugDirectory: configuration.debugAudioDirectory)
                try Task.checkCancellation()
                if stopRequested.load(ordering: .acquiring) { return }
                pipelines[source] = StreamPipeline(source: source, thresholdDB: configuration.thresholdDB, timeline: timeline)
            }
        }
        try Task.checkCancellation()
        if stopRequested.load(ordering: .acquiring) { return }
        // Recheck IDs and names after model loading; never fall back to a default.
        let available = try AudioDeviceManager.devices()
        let captures = try sources.map { source -> AudioCapture in
            guard let selected = configuration.selected[source],
                  let device = available.first(where: { $0.id == selected.id && $0.name == selected.name && $0.inputChannels > 0 }) else {
                throw MeetingError("\(source.rawValue): selected audio device is no longer available. Reconnect it and refresh audio devices.")
            }
            return try AudioCapture(source: source, device: device)
        }
        let clock = MeetingClock()
        defer { captures.forEach { $0.stop() } }
        Log.info("\nStarting audio capture...")
        for capture in captures { try capture.start(); Log.info("\(capture.source.rawValue) stream ready") }
        publishPhase(.running)
        Log.info(configuration.captureOnly ? "Capturing independent PCM." : "Transcription started.")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for diarizer in diarizers.values { group.addTask { await diarizer.run() } }
            for capture in captures {
                let pipeline = pipelines[capture.source]
                let diarizer = diarizers[capture.source]
                group.addTask { try await self.captureLoop(capture, pipeline: pipeline, diarizer: diarizer, clock: clock) }
                if let pipeline, let transcriber = transcribers[capture.source] {
                    group.addTask {
                        while true {
                            try Task.checkCancellation()
                            if let chunk = await pipeline.next() {
                                Log.debug("ASR \(capture.source.rawValue) window start=\(chunk.start) end=\(chunk.end) final=\(chunk.isFinal)")
                                let began = clock.now
                                var events = try await transcriber.transcribe(chunk)
                                if let diarizer { events = await diarizer.annotate(events) }
                                let elapsed = clock.now - began
                                let lag = max(0, clock.now - chunk.end)
                                try await pipeline.complete(events, lag: lag)
                                Log.info(String(format: "ASR %@ | audio %.2fs | decode %.2fs | lag %.2fs | events %d",
                                    capture.source.rawValue, chunk.end - chunk.start, elapsed, lag, events.count))
                                if lag > 15 { Log.warning("\(capture.source.rawValue) transcription is more than 15 seconds behind capture") }
                            } else if await pipeline.isDrained { break }
                            else { try await Task.sleep(for: .milliseconds(50)) }
                        }
                    }
                }
            }
            // Throw on the first error, cancelling every other capture/decoder task.
            for try await _ in group {}
        }
        for source in sources {
            if let pipeline = pipelines[source] {
                Log.info(String(format: "%@ finished: %d decode windows, maximum completion lag %.2fs", source.rawValue,
                               await pipeline.decodedChunks, await pipeline.maxLag))
            }
        }
        Log.info("Meeting stopped. Finalized events: \(await timeline.emittedCount).")
    }

    private func captureLoop(_ capture: AudioCapture, pipeline: StreamPipeline?, diarizer: SourceDiarizer?, clock: MeetingClock) async throws {
        defer { diarizer?.inlet.close() }
        let resampler = try pipeline.map { _ in try AudioResampler(device: capture.device) }
        var lastReport = 0.0
        var lastMeter = 0.0
        var meterSum = 0.0
        var meterCount = 0
        var sum: Double = 0
        var count = 0
        var totalFrames = 0
        var expectedSample: Double?
        var lastPacket = clock.now
        var maxCaptureLag = 0.0

        func consume(_ packet: CapturedAudio) async throws {
            if let expectedSample, abs(packet.sampleTime - expectedSample) > 1 {
                throw MeetingError("\(capture.source.rawValue): discontinuous capture timestamps (\(packet.sampleTime - expectedSample) frames)")
            }
            expectedSample = packet.sampleTime + Double(packet.frames)
            totalFrames += packet.frames
            lastPacket = clock.now
            let time = clock.seconds(at: packet.hostTime)
            maxCaptureLag = max(maxCaptureLag, clock.now - time)
            for sample in packet.samples {
                let energy = Double(sample * sample)
                sum += energy; meterSum += energy
            }
            meterCount += packet.samples.count
            count += packet.samples.count
            if let pipeline, let resampler {
                let converted = try resampler.convert(packet, time: time)
                diarizer?.inlet.append(converted.samples, start: converted.start)
                try await pipeline.ingest(converted.samples, start: converted.start)
            }
        }

        while !stopRequested.load(ordering: .acquiring) && clock.now < (configuration.duration ?? .infinity) {
            try Task.checkCancellation()
            while let packet = try capture.ring.pop() { try await consume(packet) }
            if clock.now - lastPacket > 3 { throw MeetingError("\(capture.source.rawValue): no audio callbacks for 3 seconds") }
            if clock.now - lastMeter >= 0.2 {
                callbacks.metrics(AudioMetrics(source: capture.source, elapsed: clock.now,
                    levelDB: 10 * log10(max(meterSum / Double(max(meterCount, 1)), 1e-12)),
                    backlogSeconds: await pipeline?.backlogSeconds ?? 0))
                meterSum = 0; meterCount = 0; lastMeter = clock.now
            }
            if clock.now - lastReport >= (configuration.captureOnly ? 1 : 5) {
                let db = 10 * log10(max(sum / Double(max(count, 1)), 1e-12))
                let backlog = await pipeline?.backlogSeconds ?? 0
                Log.info(String(format: "[%07.3f] %@ level: %6.1f dBFS | captured %.2fs | ASR queue %.2fs | RSS %.0f MB",
                    clock.now, capture.source.rawValue, db, Double(totalFrames) / capture.device.sampleRate, backlog, residentMemoryMB()))
                sum = 0; count = 0; lastReport = clock.now
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        capture.stop()
        publishStopping()
        while let packet = try capture.ring.pop() { try await consume(packet) }
        try await pipeline?.finish()
        Log.info(String(format: "%@ capture stopped: %.2fs, maximum callback-consumer lag %.3fs", capture.source.rawValue,
                       Double(totalFrames) / capture.device.sampleRate, maxCaptureLag))
    }
}

private func residentMemoryMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1048576 : 0
}
