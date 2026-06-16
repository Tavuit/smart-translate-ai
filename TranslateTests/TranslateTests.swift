import AVFoundation
import XCTest
@testable import Translate

final class TranslateTests: XCTestCase {
    func testChatLanguagesExposeExpectedTitles() {
        XCTAssertEqual(ChatLanguage.allCases.map(\.title), ["English", "Vietnamese"])
    }

    func testChatLanguagesMapToSpeechLocales() {
        XCTAssertEqual(ChatLanguage.english.localeIdentifier, "en-US")
        XCTAssertEqual(ChatLanguage.vietnamese.localeIdentifier, "vi-VN")
    }

    func testChatLanguageButtonsUseFixedWidth() {
        XCTAssertEqual(ChatLanguage.english.buttonWidth, 120)
        XCTAssertEqual(ChatLanguage.vietnamese.buttonWidth, 120)
    }

    func testTranslationSpeakerUsesTargetLanguageVoice() {
        XCTAssertEqual(TranslationSpeaker.preferredVoiceLanguage(for: .english), "en-US")
        XCTAssertEqual(TranslationSpeaker.preferredVoiceLanguage(for: .vietnamese), "vi-VN")
    }

    func testTranslationSpeakerDefaultSpeedControls() {
        XCTAssertEqual(TranslationSpeaker.defaultSpeechSpeed, 1.0)
        XCTAssertEqual(TranslationSpeaker.speechSpeedStep, 0.05)
        XCTAssertEqual(TranslationSpeaker.clampedSpeechSpeed(0.25), TranslationSpeaker.minimumSpeechSpeed)
        XCTAssertEqual(TranslationSpeaker.clampedSpeechSpeed(1.75), TranslationSpeaker.maximumSpeechSpeed)
    }

    func testDefaultSpeechRecognitionFrameworkIsOpenAI() {
        XCTAssertEqual(SpeechRecognitionFramework.defaultFramework, .openAI)
    }

    func testSpeechRecognitionFrameworkOptionsExposeExpectedTitles() {
        XCTAssertEqual(
            SpeechRecognitionFramework.allCases.map(\.menuTitle),
            ["Google Cloud Speech-to-Text V2", "OpenAI gpt-4o-transcribe"]
        )
    }

    func testDefaultRecordingFrameworkIsAVAudioEngine() {
        XCTAssertEqual(RecordingFramework.defaultFramework, .avAudioEngine)
    }

    func testRecordingFrameworkOptionsExposeExpectedTitles() {
        XCTAssertEqual(
            RecordingFramework.allCases.map(\.menuTitle),
            ["AVAudioEngine + AVAudioSession", "WebRTC Audio Processing"]
        )
    }

    func testOpenAIDefaultModelIsGPT4O() {
        XCTAssertEqual(OpenAIConfiguration.defaultModel, "gpt-4o")
    }

    func testOpenAITranscriptionModelIsGPT4OTranscribe() {
        XCTAssertEqual(OpenAIConfiguration.defaultTranscriptionModel, "gpt-4o-transcribe")
    }

    func testOpenAIRealtimeTranscriptionModelSupportsTurnDetection() {
        XCTAssertEqual(OpenAIConfiguration.defaultRealtimeTranscriptionModel, "gpt-4o-transcribe")
    }

    func testOpenAITranscriptionUsesShortChunkDuration() {
        XCTAssertEqual(OpenAIFileTranscriber.openAITranscriptionChunkDurationSeconds, 25)
    }

    func testOpenAIRealtimeTranscriptionUsesExpectedAudioFormat() {
        XCTAssertEqual(OpenAIRealtimeTranscriptionStream.audioSampleRate, 24_000)
        XCTAssertEqual(OpenAIFileTranscriber.realtimeAudioTapBufferSize, 2048)
        XCTAssertEqual(OpenAIFileTranscriber.realtimeStopGraceMilliseconds, 1_500)
        XCTAssertTrue(OpenAIFileTranscriber.defaultLiveTranscriptionEnabled)
        XCTAssertEqual(OpenAIRealtimeTranscriptionStream.endpoint, "wss://api.openai.com/v1/realtime?intent=transcription")
        XCTAssertEqual(OpenAIRealtimeTranscriptionStream.serverVADThreshold, 0.5)
        XCTAssertEqual(OpenAIRealtimeTranscriptionStream.serverVADPrefixPaddingMilliseconds, 300)
        XCTAssertEqual(OpenAIRealtimeTranscriptionStream.serverVADSilenceDurationMilliseconds, 650)
    }

    func testOpenAITranscriptionMapsLocalesToLanguageCodes() {
        XCTAssertEqual(OpenAIFileTranscriber.openAILanguageCode(from: "vi-VN"), "vi")
        XCTAssertEqual(OpenAIFileTranscriber.openAILanguageCode(from: "en-US"), "en")
    }

    func testSpeechTranscriberUsesLargerAudioBuffer() {
        XCTAssertEqual(SpeechTranscriber.audioTapBufferSize, 2048)
    }

    func testOpenAIRecorderUsesCompressedM4AForLongerRecordings() {
        XCTAssertEqual(OpenAIFileTranscriber.recordingFileExtension, "m4a")
        XCTAssertEqual(OpenAIFileTranscriber.recordingMimeType, "audio/m4a")
        XCTAssertEqual(OpenAIFileTranscriber.recordingSettings[AVFormatIDKey] as? Int, Int(kAudioFormatMPEG4AAC))
        XCTAssertEqual(OpenAIFileTranscriber.recordingSettings[AVSampleRateKey] as? Double, 48_000)
        XCTAssertEqual(OpenAIFileTranscriber.recordingSettings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(OpenAIFileTranscriber.recordingSettings[AVEncoderBitRateKey] as? Int, 96_000)
    }

    func testOpenAITranscriptionClientInfersSupportedAudioMimeTypes() {
        XCTAssertEqual(
            OpenAITranscriptionClient.mimeType(for: URL(fileURLWithPath: "/tmp/voice.m4a")),
            "audio/m4a"
        )
        XCTAssertEqual(
            OpenAITranscriptionClient.mimeType(for: URL(fileURLWithPath: "/tmp/voice.wav")),
            "audio/wav"
        )
    }

    @MainActor
    func testLiveTranslatorWaitsForStableTranscript() {
        XCTAssertEqual(LiveTranslator.stableTranscriptDelay, .seconds(1))
    }

    func testOpenAIConfigurationIgnoresPlaceholderAPIKey() {
        XCTAssertNil(OpenAIConfiguration.sanitizedAPIKey("$(OPENAI_API_KEY)"))
    }

    func testGoogleCloudSpeechConfigurationUsesExpectedDefaults() throws {
        let configuration = try GoogleCloudSpeechConfiguration.fromEnvironment([
            "GOOGLE_CLOUD_ACCESS_TOKEN": "token",
            "GOOGLE_CLOUD_PROJECT_ID": "translate-project"
        ])

        XCTAssertEqual(configuration.accessToken, "token")
        XCTAssertEqual(configuration.projectID, "translate-project")
        XCTAssertEqual(configuration.location, "asia-southeast1")
        XCTAssertEqual(configuration.recognizer, "_")
        XCTAssertEqual(configuration.model, "chirp_3")
    }

    @MainActor
    func testSpeechTranscriberStartsIdle() {
        let transcriber = SpeechTranscriber()

        XCTAssertFalse(transcriber.isRecording)
        XCTAssertFalse(transcriber.isPreparing)
        XCTAssertFalse(transcriber.isFinishing)
        XCTAssertEqual(transcriber.audioLevel, 0)
        XCTAssertEqual(transcriber.transcript, "")
    }

    @MainActor
    func testSpeechTranscriberDefaultsToVietnamese() {
        let transcriber = SpeechTranscriber()

        XCTAssertEqual(transcriber.localeIdentifier, "vi-VN")
    }

    @MainActor
    func testOpenAIFileTranscriberStartsIdle() {
        let transcriber = OpenAIFileTranscriber(speechRecognitionFramework: .defaultFramework)

        XCTAssertFalse(transcriber.isRecording)
        XCTAssertFalse(transcriber.isTranscribing)
        XCTAssertEqual(transcriber.audioLevel, 0)
        XCTAssertEqual(transcriber.transcript, "")
        XCTAssertNil(transcriber.recordingPreviewURL)
        XCTAssertTrue(transcriber.isLiveTranscriptionEnabled)
    }

    @MainActor
    func testOpenAIFileTranscriberCanDisableLiveTranscription() {
        let transcriber = OpenAIFileTranscriber(speechRecognitionFramework: .defaultFramework)

        transcriber.updateLiveTranscriptionEnabled(false)

        XCTAssertFalse(transcriber.isLiveTranscriptionEnabled)
    }
}
