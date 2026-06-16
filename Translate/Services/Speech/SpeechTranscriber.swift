import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechTranscriber: ObservableObject {
    nonisolated static let audioTapBufferSize: AVAudioFrameCount = 2048

    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isFinishing = false
    @Published private(set) var audioLevel = 0.0
    @Published private(set) var statusMessage: String?

    private(set) var localeIdentifier: String

    private let audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recordingFramework: RecordingFramework
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInstalledTap = false
    private var activeSessionID: UUID?
    private var pendingStartID: UUID?

    init(locale: Locale = Locale(identifier: "vi-VN"), recordingFramework: RecordingFramework = .defaultFramework) {
        localeIdentifier = locale.identifier
        self.recordingFramework = recordingFramework
        speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    func updateLocale(_ locale: Locale) {
        cancelRecording()
        localeIdentifier = locale.identifier
        speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    func updateRecordingFramework(_ recordingFramework: RecordingFramework) {
        cancelRecording()
        self.recordingFramework = recordingFramework
    }

    func toggleRecording() async {
        guard !isPreparing, !isFinishing else { return }

        if isRecording {
            stopRecording()
        } else {
            await startRecording()
        }
    }

    func startRecording() async {
        guard !isRecording, !isPreparing, !isFinishing else { return }

        let startID = UUID()
        pendingStartID = startID
        isPreparing = true
        defer {
            if pendingStartID == startID {
                pendingStartID = nil
            }
            isPreparing = false
        }

        do {
            try await requestPermissions()
            guard pendingStartID == startID else { return }
            try startAudioRecognition(sessionID: startID)
        } catch {
            statusMessage = error.localizedDescription
            stopRecording()
        }
    }

    func stopRecording() {
        pendingStartID = nil
        finishAudioRecognition(deactivateAudioSession: true)
    }

    func cancelRecording() {
        pendingStartID = nil
        stopAudioRecognition(invalidateSession: true, deactivateAudioSession: true)
    }

    private func stopRecording(for sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        stopAudioRecognition(invalidateSession: true, deactivateAudioSession: true)
    }

    private func finishAudioRecognition(deactivateAudioSession: Bool) {
        guard activeSessionID != nil || isRecording || recognitionTask != nil else {
            isRecording = false
            isFinishing = false
            audioLevel = 0
            return
        }

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        isRecording = false
        isFinishing = recognitionTask != nil
        audioLevel = 0

        if deactivateAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func stopAudioRecognition(invalidateSession: Bool, deactivateAudioSession: Bool) {
        if invalidateSession {
            activeSessionID = nil
        }

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        isFinishing = false
        audioLevel = 0

        if deactivateAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func requestPermissions() async throws {
        let speechStatus = await requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            throw SpeechTranscriberError.speechRecognitionDenied
        }

        let microphoneGranted = await requestMicrophonePermission()
        guard microphoneGranted else {
            throw SpeechTranscriberError.microphoneDenied
        }
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
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
    }

    private func startAudioRecognition(sessionID: UUID) throws {
        guard let speechRecognizer else {
            throw SpeechTranscriberError.recognizerUnavailable
        }

        guard speechRecognizer.isAvailable else {
            throw SpeechTranscriberError.recognizerUnavailable
        }

        stopAudioRecognition(invalidateSession: true, deactivateAudioSession: false)
        activeSessionID = sessionID

        let audioSession = AVAudioSession.sharedInstance()
        try configureAudioSession(audioSession)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                guard self.activeSessionID == sessionID else { return }

                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }

                if error != nil || result?.isFinal == true {
                    self.completeRecognition(for: sessionID)
                }
            }
        }

        let inputNode = audioEngine.inputNode
        try? inputNode.setVoiceProcessingEnabled(usesVoiceProcessing)
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: Self.audioTapBufferSize, format: recordingFormat) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.normalizedPowerLevel(from: buffer)

            Task { @MainActor in
                guard let self else { return }
                self.handleAudioLevel(level, sessionID: sessionID)
            }
        }
        hasInstalledTap = true

        audioEngine.prepare()
        try audioEngine.start()

        statusMessage = nil
        transcript = ""
        audioLevel = 0
        isRecording = true
    }

    private func completeRecognition(for sessionID: UUID) {
        guard activeSessionID == sessionID else { return }

        activeSessionID = nil
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        isFinishing = false
        audioLevel = 0
    }

    private func handleAudioLevel(_ level: Double, sessionID: UUID) {
        guard activeSessionID == sessionID, isRecording else { return }

        audioLevel = max(level, audioLevel * 0.65)
    }

    private var usesVoiceProcessing: Bool {
        switch recordingFramework {
        case .avAudioEngine, .webRTCAudioProcessing:
            true
        }
    }

    private func configureAudioSession(_ audioSession: AVAudioSession) throws {
        switch recordingFramework {
        case .avAudioEngine:
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .allowBluetoothHFP, .defaultToSpeaker])
        case .webRTCAudioProcessing:
            try audioSession.setCategory(.playAndRecord, mode: .videoChat, options: [.duckOthers, .allowBluetoothHFP, .defaultToSpeaker])
        }

        try? audioSession.setPreferredInputNumberOfChannels(1)
        try? audioSession.setPreferredSampleRate(48_000)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    nonisolated static func normalizedPowerLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData else { return 0 }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return 0 }

        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame]
                sum += sample * sample
            }
        }

        let rms = sqrt(sum / Float(channelCount * frameLength))
        let decibels = 20 * log10(max(rms, 0.000_000_1))
        return min(max((Double(decibels) + 55) / 45, 0), 1)
    }
}

enum SpeechTranscriberError: LocalizedError {
    case microphoneDenied
    case speechRecognitionDenied
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone permission is required to record speech."
        case .speechRecognitionDenied:
            "Speech recognition permission is required to convert speech to text."
        case .recognizerUnavailable:
            "Speech recognition is not available right now."
        }
    }
}
