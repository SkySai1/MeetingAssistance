import Foundation

struct MeetingSession {
    let options: Options
    let selected: [AudioSource: AudioDevice]

    func run() async throws {
        let sources: [AudioSource] = options.remoteOnly ? [.remote] : AudioSource.allCases
        let timeline = TranscriptTimeline(sources: sources) { event in
            let data: Data
            if options.json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                data = try encoder.encode(event) + Data([10])
            } else { data = Data((event.terminalLine + "\n").utf8) }
            try FileHandle.standardOutput.write(contentsOf: data)
        }
        let stop = StopSignal()
        var transcribers: [AudioSource: WhisperTranscriber] = [:]
        var pipelines: [AudioSource: StreamPipeline] = [:]
        if !options.captureOnly {
            let paths = try ModelPaths(model: options.modelPath, tokenizer: options.tokenizerPath)
            Log.info("\nLoading WhisperKit locally...\nModel: \(paths.model.path)\nTokenizer: \(paths.tokenizer.path)\nLanguage: ru")
            for source in sources {
                transcribers[source] = try await WhisperTranscriber(source: source, paths: paths, debugDirectory: options.debugAudioDirectory)
                if stop.requested { return }
                pipelines[source] = StreamPipeline(source: source, thresholdDB: options.thresholdDB, timeline: timeline)
            }
        }
        let captures = try sources.map { source -> AudioCapture in
            guard let device = selected[source] else { throw MeetingError("No selected device for \(source.rawValue)") }
            return try AudioCapture(source: source, device: device)
        }
        let clock = MeetingClock()
        defer { captures.forEach { $0.stop() } }
        Log.info("\nStarting audio capture...")
        for capture in captures { try capture.start(); Log.info("\(capture.source.rawValue) stream ready") }
        Log.info(options.captureOnly ? "Capturing independent PCM. Ctrl-C to stop." : "Transcription started. Finalized events on stdout; diagnostics on stderr. Ctrl-C stops capture and drains ASR.")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for capture in captures {
                let pipeline = pipelines[capture.source]
                group.addTask { try await captureLoop(capture, pipeline: pipeline, clock: clock, stop: stop) }
                if let pipeline, let transcriber = transcribers[capture.source] {
                    group.addTask {
                        while true {
                            try Task.checkCancellation()
                            if let chunk = await pipeline.next() {
                                let began = clock.now
                                let events = try await transcriber.transcribe(chunk)
                                let elapsed = clock.now - began
                                let lag = max(0, clock.now - chunk.end)
                                try await pipeline.complete(events, lag: lag)
                                Log.info(String(format: "ASR %@ | audio %.2fs | decode %.2fs | lag %.2fs | events %d",
                                    capture.source.rawValue, chunk.end - chunk.start, elapsed, lag, events.count))
                                if lag > 15 { Log.info("WARNING: \(capture.source.rawValue) transcription is more than 15 seconds behind capture") }
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

    private func captureLoop(_ capture: AudioCapture, pipeline: StreamPipeline?, clock: MeetingClock, stop: StopSignal) async throws {
        let resampler = try pipeline.map { _ in try AudioResampler(device: capture.device) }
        var lastReport = 0.0
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
            for sample in packet.samples { sum += Double(sample * sample) }
            count += packet.samples.count
            if let pipeline, let resampler {
                let converted = try resampler.convert(packet, time: time)
                try await pipeline.ingest(converted.samples, start: converted.start)
            }
        }

        while !stop.requested && clock.now < (options.duration ?? .infinity) {
            try Task.checkCancellation()
            while let packet = try capture.ring.pop() { try await consume(packet) }
            if clock.now - lastPacket > 3 { throw MeetingError("\(capture.source.rawValue): no audio callbacks for 3 seconds") }
            if clock.now - lastReport >= (options.captureOnly ? 1 : 5) {
                let db = 10 * log10(max(sum / Double(max(count, 1)), 1e-12))
                let backlog = await pipeline?.backlogSeconds ?? 0
                Log.info(String(format: "[%07.3f] %@ level: %6.1f dBFS | captured %.2fs | ASR queue %.2fs | RSS %.0f MB",
                    clock.now, capture.source.rawValue, db, Double(totalFrames) / capture.device.sampleRate, backlog, residentMemoryMB()))
                sum = 0; count = 0; lastReport = clock.now
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        capture.stop()
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
