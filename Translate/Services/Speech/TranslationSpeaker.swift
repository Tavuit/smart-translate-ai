import AVFoundation
import Foundation
import os

@MainActor
final class TranslationSpeaker: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    private static let log = Logger(subsystem: "Translate", category: "TranslationSpeaker")

    @Published private(set) var lastSpokenText = ""

    private let synthesizer = AVSpeechSynthesizer()
    private var currentText = ""
    private var currentLanguage: ChatLanguage?
    private var currentSpeed = defaultSpeechSpeed
    private var currentCharacterIndex = 0

    nonisolated static let defaultSpeechSpeed = 1.0
    nonisolated static let speechSpeedStep = 0.05
    nonisolated static let minimumSpeechSpeed = 0.5
    nonisolated static let maximumSpeechSpeed = 1.5

    nonisolated static func preferredVoiceLanguage(for language: ChatLanguage) -> String {
        language.localeIdentifier
    }

    nonisolated static func clampedSpeechSpeed(_ speed: Double) -> Double {
        min(max(speed, minimumSpeechSpeed), maximumSpeechSpeed)
    }

    nonisolated static func utteranceRate(for speed: Double) -> Float {
        let clampedSpeed = clampedSpeechSpeed(speed)
        let rate = Float(clampedSpeed) * AVSpeechUtteranceDefaultSpeechRate
        return min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: ChatLanguage, speed: Double = TranslationSpeaker.defaultSpeechSpeed) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, trimmedText != lastSpokenText else { return }

        Self.log.debug("speak language=\(language.localeIdentifier, privacy: .public) speed=\(speed) len=\(trimmedText.count)")
        stop()
        lastSpokenText = trimmedText
        speakSegment(trimmedText, language: language, speed: speed)
    }

    func updateSpeed(_ speed: Double) {
        currentSpeed = Self.clampedSpeechSpeed(speed)
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
        guard let currentLanguage else { return }

        let remainingText = remainingSpeechText()
        guard !remainingText.isEmpty else { return }

        Self.log.debug("update speech speed=\(self.currentSpeed) remainingLen=\(remainingText.count)")
        synthesizer.stopSpeaking(at: .immediate)
        speakSegment(remainingText, language: currentLanguage, speed: currentSpeed)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        currentCharacterIndex = min(max(characterRange.location, 0), (currentText as NSString).length)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        currentCharacterIndex = (currentText as NSString).length
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func speakSegment(_ text: String, language: ChatLanguage, speed: Double) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: trimmedText)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.preferredVoiceLanguage(for: language))
        utterance.rate = Self.utteranceRate(for: speed)
        utterance.pitchMultiplier = 1
        utterance.volume = 1

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)

        currentText = trimmedText
        currentLanguage = language
        currentSpeed = Self.clampedSpeechSpeed(speed)
        currentCharacterIndex = 0
        synthesizer.speak(utterance)
    }

    private func remainingSpeechText() -> String {
        let nsText = currentText as NSString
        let startIndex = min(max(currentCharacterIndex, 0), nsText.length)
        return nsText
            .substring(from: startIndex)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func reset() {
        stop()
        lastSpokenText = ""
        currentText = ""
        currentLanguage = nil
        currentCharacterIndex = 0
    }

    func stop() {
        guard synthesizer.isSpeaking || synthesizer.isPaused else {
            Self.log.debug("stop no-op (synth idle)")
            return
        }
        Self.log.debug("stop synth speaking, deactivating session")
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
