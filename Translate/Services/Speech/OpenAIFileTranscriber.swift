@preconcurrency import AVFoundation
import Foundation
import os

@MainActor
final class OpenAIFileTranscriber: ObservableObject {
    private static let log = Logger(subsystem: "Translate", category: "OpenAIFileTranscriber")

    nonisolated static let recordingFileExtension = "m4a"
    nonisolated static let recordingMimeType = "audio/m4a"
    nonisolated static let recordingSampleRate = 48_000.0
    nonisolated static let recordingChannelCount = 1
    nonisolated static let recordingBitRate = 96_000
    nonisolated static let openAITranscriptionChunkDurationSeconds = 25.0
    nonisolated static let realtimeAudioTapBufferSize: AVAudioFrameCount = 2048
    nonisolated static let realtimeStopGraceMilliseconds = 1_500
    nonisolated static let defaultLiveTranscriptionEnabled = true
    nonisolated static let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: recordingSampleRate,
        AVNumberOfChannelsKey: recordingChannelCount,
        AVEncoderBitRateKey: recordingBitRate,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var audioLevel = 0.0
    @Published private(set) var statusMessage: String?
    @Published private(set) var recordingPreviewURL: URL?
    @Published private(set) var isLiveTranscriptionEnabled: Bool

    let model = OpenAIConfiguration.defaultTranscriptionModel

    private let openAIConfigurationProvider: () throws -> OpenAIConfiguration
    private let googleCloudConfigurationProvider: () throws -> GoogleCloudSpeechConfiguration
    private var speechRecognitionFramework: SpeechRecognitionFramework
    private var recordingFramework: RecordingFramework
    private var prompt: String
    private var languageCode: String
    private var audioEngine: AVAudioEngine?
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordingID: UUID?
    private var transcriptionID: UUID?
    private var realtimeStream: OpenAIRealtimeTranscriptionStream?
    private var realtimeFinalSegments: [String] = []
    private var realtimePartialTranscript = ""
    private var meteringTask: Task<Void, Never>?

    init(
        prompt: String = "The audio is Vietnamese speech.",
        languageCode: String = "vi-VN",
        speechRecognitionFramework: SpeechRecognitionFramework = .defaultFramework,
        recordingFramework: RecordingFramework = .defaultFramework,
        isLiveTranscriptionEnabled: Bool = OpenAIFileTranscriber.defaultLiveTranscriptionEnabled,
        openAIConfigurationProvider: @escaping () throws -> OpenAIConfiguration = { try OpenAIConfiguration.fromEnvironment() },
        googleCloudConfigurationProvider: @escaping () throws -> GoogleCloudSpeechConfiguration = { try GoogleCloudSpeechConfiguration.fromEnvironment() }
    ) {
        self.prompt = prompt
        self.languageCode = languageCode
        self.speechRecognitionFramework = speechRecognitionFramework
        self.recordingFramework = recordingFramework
        self.isLiveTranscriptionEnabled = isLiveTranscriptionEnabled
        self.openAIConfigurationProvider = openAIConfigurationProvider
        self.googleCloudConfigurationProvider = googleCloudConfigurationProvider
    }

    convenience init(
        prompt: String = "The audio is Vietnamese speech.",
        recordingFramework: RecordingFramework = .defaultFramework,
        configurationProvider: @escaping () throws -> OpenAIConfiguration = { try OpenAIConfiguration.fromEnvironment() }
    ) {
        self.init(
            prompt: prompt,
            languageCode: "vi-VN",
            speechRecognitionFramework: .openAI,
            recordingFramework: recordingFramework,
            openAIConfigurationProvider: configurationProvider
        )
    }

    func updateLanguage(prompt: String, languageCode: String) {
        cancelRecording()
        self.prompt = prompt
        self.languageCode = languageCode
    }

    func updateSpeechRecognitionFramework(_ speechRecognitionFramework: SpeechRecognitionFramework) {
        cancelRecording()
        self.speechRecognitionFramework = speechRecognitionFramework
    }

    func updateRecordingFramework(_ recordingFramework: RecordingFramework) {
        cancelRecording()
        self.recordingFramework = recordingFramework
    }

    func updateLiveTranscriptionEnabled(_ isEnabled: Bool) {
        cancelRecording()
        isLiveTranscriptionEnabled = isEnabled
    }

    func resetTranscript() {
        transcript = ""
        statusMessage = nil
    }

    func toggleRecording() async {
        guard !isTranscribing else { return }

        if isRecording {
            await stopRecordingAndTranscribe()
        } else {
            await startRecording()
        }
    }

    func startRecording() async {
        Self.log.debug("startRecording called isRecording=\(self.isRecording) isTranscribing=\(self.isTranscribing)")
        guard !isRecording, !isTranscribing else {
            Self.log.debug("startRecording aborted by guard")
            return
        }

        do {
            try await requestMicrophonePermission()
            switch speechRecognitionFramework {
            case .openAI:
                if isLiveTranscriptionEnabled {
                    try await startRealtimeAudioRecording()
                } else {
                    try startAudioRecording()
                }
            case .googleCloud:
                try startAudioRecording()
            }
        } catch {
            Self.log.error("startRecording failed: \(error.localizedDescription, privacy: .public)")
            statusMessage = error.localizedDescription
            cancelRecording()
        }
    }

    func stopRecordingAndTranscribe() async {
        Self.log.debug("stopRecordingAndTranscribe called")
        if realtimeStream != nil {
            await stopRealtimeAudioRecording()
            return
        }

        guard let recordingURL, recordingID != nil else {
            Self.log.debug("stopRecordingAndTranscribe no active recording, cancelling")
            cancelRecording()
            return
        }

        let durationSecs = audioRecorder?.currentTime ?? 0
        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        stopMetering()
        self.recordingID = nil
        Self.log.debug("recorder stopped duration=\(durationSecs)s url=\(recordingURL.lastPathComponent, privacy: .public)")
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        if self.recordingURL == recordingURL {
            self.recordingURL = nil
        }

        replaceRecordingPreview(with: recordingURL)

        let transcriptionID = UUID()
        self.transcriptionID = transcriptionID
        isTranscribing = true
        statusMessage = "Transcribing with \(speechRecognitionFramework.title)..."

        do {
            let text = try await transcribeAudio(at: recordingURL)
            if self.transcriptionID == transcriptionID, self.recordingID == nil {
                transcript = text
                statusMessage = nil
            }
        } catch {
            if self.transcriptionID == transcriptionID {
                statusMessage = error.localizedDescription
            }
        }

        if self.transcriptionID == transcriptionID {
            self.transcriptionID = nil
            isTranscribing = false
        }
    }

    func cancelRecording() {
        Self.log.debug("cancelRecording called isRecording=\(self.isRecording)")
        if isRecording {
            audioRecorder?.stop()
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        if let realtimeStream {
            Task {
                await realtimeStream.disconnect()
            }
        }

        audioEngine = nil
        audioRecorder = nil
        realtimeStream = nil
        isRecording = false
        isTranscribing = false
        audioLevel = 0
        recordingID = nil
        transcriptionID = nil
        realtimeFinalSegments = []
        realtimePartialTranscript = ""
        stopMetering()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Self.log.debug("audio session deactivated by cancelRecording")

        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        clearRecordingPreview()
    }

    private func requestMicrophonePermission() async throws {
        let isGranted = await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { isGranted in
                    continuation.resume(returning: isGranted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
        }

        guard isGranted else { throw SpeechTranscriberError.microphoneDenied }
    }

    private func startRealtimeAudioRecording() async throws {
        let configuration = try openAIConfigurationProvider()
        let language = Self.openAILanguageCode(from: languageCode)
        let stream = try OpenAIRealtimeTranscriptionStream(
            configuration: configuration,
            eventHandler: { [weak self] event in
                Task { @MainActor in
                    self?.handleRealtimeTranscriptionEvent(event)
                }
            }
        )

        try await stream.connect(prompt: prompt, language: language)
        try startRealtimeAudioCapture(stream: stream)

        transcript = ""
        statusMessage = "Live transcription is ready."
        realtimeStream = stream
        realtimeFinalSegments = []
        realtimePartialTranscript = ""
        recordingID = UUID()
        audioLevel = 0
        isRecording = true
        Self.log.debug("realtime recording started")
    }

    private func startRealtimeAudioCapture(stream: OpenAIRealtimeTranscriptionStream) throws {
        let audioSession = AVAudioSession.sharedInstance()
        try configureAudioSession(audioSession)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(
            onBus: 0,
            bufferSize: Self.realtimeAudioTapBufferSize,
            format: inputFormat
        ) { buffer, _ in
            let level = Self.normalizedPowerLevel(fromAudioBuffer: buffer)
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.audioLevel = max(level, self.audioLevel * 0.65)
            }

            guard let audioData = Self.pcm24kMonoData(from: buffer, inputFormat: inputFormat) else { return }
            Task {
                await stream.sendAudio(audioData)
            }
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    private func stopRealtimeAudioRecording() async {
        guard let stream = realtimeStream else {
            cancelRecording()
            return
        }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false
        audioLevel = 0
        recordingID = nil
        isTranscribing = true
        statusMessage = "Finalizing live transcript..."

        await stream.commitAudioBuffer()
        try? await Task.sleep(for: .milliseconds(Self.realtimeStopGraceMilliseconds))
        await stream.disconnect()
        realtimeStream = nil
        isTranscribing = false
        statusMessage = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No speech detected." : nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Self.log.debug("realtime recording stopped")
    }

    private func startAudioRecording() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try configureAudioSession(audioSession)
        Self.log.debug("audio session configured category=\(audioSession.category.rawValue, privacy: .public) sampleRate=\(audioSession.sampleRate) inputs=\(audioSession.currentRoute.inputs.map { $0.portName }.joined(separator: ","), privacy: .public)")
        clearRecordingPreview()

        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openai-transcription-\(UUID().uuidString)")
            .appendingPathExtension(Self.recordingFileExtension)

        let recorder = try AVAudioRecorder(url: recordingURL, settings: Self.recordingSettings)
        recorder.isMeteringEnabled = true
        let prepared = recorder.prepareToRecord()
        let started = recorder.record()
        Self.log.debug("recorder prepared=\(prepared) started=\(started) url=\(recordingURL.lastPathComponent, privacy: .public)")
        guard started else {
            Self.log.error("recorder.record() returned false")
            throw SpeechTranscriberError.recognizerUnavailable
        }

        transcript = ""
        statusMessage = nil
        audioRecorder = recorder
        self.recordingURL = recordingURL
        recordingID = UUID()
        audioLevel = 0
        isRecording = true
        startMetering()
        Self.log.debug("recording started")
    }

    private func transcribeAudio(at recordingURL: URL) async throws -> String {
        switch speechRecognitionFramework {
        case .googleCloud:
            let configuration = try googleCloudConfigurationProvider()
            let client = try GoogleCloudSpeechClient(configuration: configuration)
            let result = try await client.transcribeAudio(fileURL: recordingURL, languageCode: languageCode)
            return result.text
        case .openAI:
            let configuration = try openAIConfigurationProvider()
            let client = try OpenAITranscriptionClient(configuration: configuration)
            let chunks = try await openAITranscriptionChunks(for: recordingURL)
            defer {
                for chunkURL in chunks where chunkURL != recordingURL {
                    try? FileManager.default.removeItem(at: chunkURL)
                }
            }

            let language = Self.openAILanguageCode(from: languageCode)
            var transcribedChunks: [String] = []
            for (index, chunkURL) in chunks.enumerated() {
                if chunks.count > 1 {
                    statusMessage = "Transcribing part \(index + 1) of \(chunks.count) with \(speechRecognitionFramework.title)..."
                }

                let result = try await client.transcribeAudio(
                    fileURL: chunkURL,
                    mimeType: Self.recordingMimeType,
                    prompt: prompt,
                    language: language
                )
                transcribedChunks.append(result.text)
            }

            return transcribedChunks
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func openAITranscriptionChunks(for recordingURL: URL) async throws -> [URL] {
        let asset = AVURLAsset(url: recordingURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > Self.openAITranscriptionChunkDurationSeconds else {
            return [recordingURL]
        }

        let chunkCount = Int(ceil(durationSeconds / Self.openAITranscriptionChunkDurationSeconds))
        var chunkURLs: [URL] = []
        for index in 0..<chunkCount {
            let startSeconds = Double(index) * Self.openAITranscriptionChunkDurationSeconds
            let remainingSeconds = max(durationSeconds - startSeconds, 0)
            let chunkDurationSeconds = min(Self.openAITranscriptionChunkDurationSeconds, remainingSeconds)
            guard chunkDurationSeconds > 0 else { continue }

            let chunkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("openai-transcription-\(UUID().uuidString)-part-\(index + 1)")
                .appendingPathExtension(Self.recordingFileExtension)
            let startTime = CMTime(seconds: startSeconds, preferredTimescale: duration.timescale)
            let chunkDuration = CMTime(seconds: chunkDurationSeconds, preferredTimescale: duration.timescale)

            try await exportAudioChunk(
                asset: asset,
                timeRange: CMTimeRange(start: startTime, duration: chunkDuration),
                outputURL: chunkURL
            )
            chunkURLs.append(chunkURL)
        }

        return chunkURLs.isEmpty ? [recordingURL] : chunkURLs
    }

    private func exportAudioChunk(asset: AVAsset, timeRange: CMTimeRange, outputURL: URL) async throws {
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw SpeechTranscriberError.recognizerUnavailable
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = timeRange
        try? FileManager.default.removeItem(at: outputURL)

        let exportBox = ExportSessionBox(exportSession)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                switch exportBox.session.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: exportBox.session.error ?? SpeechTranscriberError.recognizerUnavailable)
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: SpeechTranscriberError.recognizerUnavailable)
                }
            }
        }
    }

    nonisolated static func openAILanguageCode(from languageCode: String) -> String {
        languageCode
            .split(separator: "-")
            .first
            .map(String.init)?
            .lowercased() ?? languageCode.lowercased()
    }

    private func handleRealtimeTranscriptionEvent(_ event: OpenAIRealtimeTranscriptionEvent) {
        switch event {
        case .delta(let delta):
            realtimePartialTranscript += delta
            updateRealtimeTranscript()
            statusMessage = nil
        case .completed(let text):
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty, realtimeFinalSegments.last != trimmedText {
                realtimeFinalSegments.append(trimmedText)
            }
            realtimePartialTranscript = ""
            updateRealtimeTranscript()
            statusMessage = nil
        case .status(let message):
            if transcript.isEmpty {
                statusMessage = message
            }
        case .error(let message):
            statusMessage = message
        }
    }

    private func updateRealtimeTranscript() {
        let parts = realtimeFinalSegments + [realtimePartialTranscript]
        transcript = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func replaceRecordingPreview(with url: URL) {
        clearRecordingPreview()
        recordingPreviewURL = url
    }

    private func clearRecordingPreview() {
        if let recordingPreviewURL {
            try? FileManager.default.removeItem(at: recordingPreviewURL)
        }
        recordingPreviewURL = nil
    }

    private func startMetering() {
        meteringTask?.cancel()
        meteringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                self?.updateMetering()
            }
        }
    }

    private func stopMetering() {
        meteringTask?.cancel()
        meteringTask = nil
        audioLevel = 0
    }

    private func updateMetering() {
        guard isRecording, let audioRecorder else { return }

        audioRecorder.updateMeters()
        let avg = audioRecorder.averagePower(forChannel: 0)
        let level = Self.normalizedPowerLevel(fromAveragePower: avg)
        audioLevel = max(level, audioLevel * 0.65)
        Self.log.debug("meter avgPower=\(avg)dB normalized=\(level)")
    }

    private func configureAudioSession(_ audioSession: AVAudioSession) throws {
        switch recordingFramework {
        case .avAudioEngine:
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .allowBluetoothHFP, .defaultToSpeaker])
        case .webRTCAudioProcessing:
            try audioSession.setCategory(.playAndRecord, mode: .videoChat, options: [.duckOthers, .allowBluetoothHFP, .defaultToSpeaker])
        }

        try? audioSession.setPreferredInputNumberOfChannels(Self.recordingChannelCount)
        try? audioSession.setPreferredSampleRate(Self.recordingSampleRate)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    nonisolated static func normalizedPowerLevel(fromAveragePower averagePower: Float) -> Double {
        min(max((Double(averagePower) + 55) / 45, 0), 1)
    }

    nonisolated static func normalizedPowerLevel(fromAudioBuffer buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        var sumOfSquares = 0.0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = Double(samples[frame])
                sumOfSquares += sample * sample
            }
        }

        let sampleCount = max(channelCount * frameLength, 1)
        let rms = sqrt(sumOfSquares / Double(sampleCount))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(max((decibels + 55) / 45, 0), 1)
    }

    nonisolated static func pcm24kMonoData(from buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) -> Data? {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: OpenAIRealtimeTranscriptionStream.audioSampleRate,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }

        let sampleRateRatio = outputFormat.sampleRate / inputFormat.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRateRatio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            guard !didProvideInput else {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, conversionError == nil, outputBuffer.frameLength > 0 else {
            return nil
        }

        guard let audioBuffer = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
            return nil
        }

        return Data(
            bytes: audioBuffer,
            count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        )
    }
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}
