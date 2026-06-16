import SwiftUI

struct ConversationView: View {
    @StateObject private var fileTranscriber = OpenAIFileTranscriber(speechRecognitionFramework: .defaultFramework)
    @StateObject private var liveTranslator = LiveTranslator()
    @StateObject private var translationSpeaker = TranslationSpeaker()
    @State private var selectedFramework = SpeechRecognitionFramework.defaultFramework
    @State private var selectedRecordingFramework = RecordingFramework.defaultFramework
    @State private var isLiveTranscriptionEnabled = OpenAIFileTranscriber.defaultLiveTranscriptionEnabled
    @State private var sourceLanguage = ChatLanguage.vietnamese
    @State private var targetLanguage = ChatLanguage.english
    @State private var isTranslationSpeechMuted = false
    @State private var translationSpeechSpeed = TranslationSpeaker.defaultSpeechSpeed

    var body: some View {
        ZStack {
            ChatStyle.pageBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ChatTopBar(
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    onSwapLanguages: swapLanguages
                )
                    .frame(height: 113)

                ChatMainContent(
                    transcript: activeTranscript,
                    translation: liveTranslator.translation,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    isRecording: activeIsRecording,
                    audioLevel: activeAudioLevel,
                    isTranscribing: activeIsBusy,
                    isTranslating: liveTranslator.isTranslating,
                    statusMessage: activeStatusMessage,
                    showsTranslation: true,
                    isTranslationSpeechMuted: isTranslationSpeechMuted,
                    translationSpeechSpeed: translationSpeechSpeed,
                    onToggleTranslationSpeechMute: toggleTranslationSpeechMute,
                    onDecreaseTranslationSpeechSpeed: decreaseTranslationSpeechSpeed,
                    onIncreaseTranslationSpeechSpeed: increaseTranslationSpeechSpeed
                )
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)

                ChatBottomControls(
                    isRecording: activeIsRecording,
                    isBusy: activeIsBusy,
                    audioLevel: activeAudioLevel,
                    selectedFramework: $selectedFramework,
                    selectedRecordingFramework: $selectedRecordingFramework,
                    isLiveTranscriptionEnabled: $isLiveTranscriptionEnabled,
                    isTranslationSpeechMuted: $isTranslationSpeechMuted,
                    onMicTap: {
                        Task {
                            await toggleActiveRecorder()
                        }
                    }
                )
                    .frame(height: 166.5)
            }
            .frame(maxWidth: 390, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .onChange(of: selectedFramework) {
            rebuildTranscriberForSpeechFramework()
        }
        .onChange(of: selectedRecordingFramework) {
            rebuildTranscriberForRecordingFramework()
        }
        .onChange(of: isLiveTranscriptionEnabled) {
            rebuildTranscriberForLiveTranscriptionMode()
        }
        .onChange(of: sourceLanguage) {
            rebuildTranscriberForSourceLanguage()
        }
        .onChange(of: targetLanguage) {
            translationSpeaker.reset()
            liveTranslator.reset()
            scheduleTranslationIfReady(delay: .zero)
        }
        .onChange(of: activeTranscript) {
            translationSpeaker.reset()
            scheduleTranslationIfReady(delay: .zero)
        }
        .onChange(of: activeIsRecording) {
            if !activeIsRecording, !activeIsBusy {
                scheduleTranslationIfReady(delay: .zero)
                speakTranslationIfReady()
            }
        }
        .onChange(of: activeIsBusy) {
            if !activeIsRecording, !activeIsBusy {
                scheduleTranslationIfReady(delay: .zero)
                speakTranslationIfReady()
            }
        }
        .onChange(of: liveTranslator.translation) {
            speakTranslationIfReady()
        }
        .onChange(of: liveTranslator.isTranslating) {
            if !liveTranslator.isTranslating {
                speakTranslationIfReady()
            }
        }
        .onChange(of: isTranslationSpeechMuted) {
            if isTranslationSpeechMuted {
                translationSpeaker.reset()
            } else {
                speakTranslationIfReady()
            }
        }
        .onChange(of: translationSpeechSpeed) {
            translationSpeaker.updateSpeed(translationSpeechSpeed)
        }
    }

    private var activeTranscript: String {
        fileTranscriber.transcript
    }

    private var activeStatusMessage: String? {
        if let translationStatus = liveTranslator.statusMessage {
            return translationStatus
        }

        return fileTranscriber.statusMessage
    }

    private var activeIsRecording: Bool {
        fileTranscriber.isRecording
    }

    private var activeIsBusy: Bool {
        fileTranscriber.isTranscribing
    }

    private var activeAudioLevel: Double {
        fileTranscriber.audioLevel
    }

    private func toggleActiveRecorder() async {
        guard !activeIsBusy else { return }

        if !activeIsRecording {
            translationSpeaker.reset()
            liveTranslator.reset()
        }

        await fileTranscriber.toggleRecording()
    }

    private func stopRecordersForFrameworkChange() {
        fileTranscriber.cancelRecording()
        fileTranscriber.resetTranscript()
        translationSpeaker.reset()
        liveTranslator.reset()
    }

    private func swapLanguages() {
        stopRecordersForFrameworkChange()
        swap(&sourceLanguage, &targetLanguage)
    }

    private func rebuildTranscriberForSourceLanguage() {
        fileTranscriber.updateLanguage(
            prompt: sourceLanguage.speechPrompt,
            languageCode: sourceLanguage.localeIdentifier
        )
        fileTranscriber.resetTranscript()
        translationSpeaker.reset()
        liveTranslator.reset()
    }

    private func rebuildTranscriberForSpeechFramework() {
        fileTranscriber.updateSpeechRecognitionFramework(selectedFramework)
        translationSpeaker.reset()
        liveTranslator.reset()
    }

    private func rebuildTranscriberForRecordingFramework() {
        fileTranscriber.updateRecordingFramework(selectedRecordingFramework)
        translationSpeaker.reset()
        liveTranslator.reset()
    }

    private func rebuildTranscriberForLiveTranscriptionMode() {
        fileTranscriber.updateLiveTranscriptionEnabled(isLiveTranscriptionEnabled)
        fileTranscriber.resetTranscript()
        translationSpeaker.reset()
        liveTranslator.reset()
    }

    private func scheduleLiveTranslation(delay: Duration? = nil) {
        liveTranslator.scheduleTranslation(
            sourceText: activeTranscript,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            delay: delay ?? .seconds(1)
        )
    }

    private func scheduleTranslationIfReady(delay: Duration? = nil) {
        guard !activeIsRecording else { return }
        guard !activeIsBusy else { return }
        guard !activeTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        scheduleLiveTranslation(delay: delay)
    }

    private func speakTranslationIfReady() {
        let sourceText = activeTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return }
        guard !isTranslationSpeechMuted else { return }
        guard !activeIsRecording else { return }
        guard !liveTranslator.isTranslating else { return }
        guard liveTranslator.translatedSourceText == sourceText else { return }

        translationSpeaker.speak(
            liveTranslator.translation,
            language: targetLanguage,
            speed: translationSpeechSpeed
        )
    }

    private func toggleTranslationSpeechMute() {
        isTranslationSpeechMuted.toggle()
    }

    private func decreaseTranslationSpeechSpeed() {
        updateTranslationSpeechSpeed(by: -TranslationSpeaker.speechSpeedStep)
    }

    private func increaseTranslationSpeechSpeed() {
        updateTranslationSpeechSpeed(by: TranslationSpeaker.speechSpeedStep)
    }

    private func updateTranslationSpeechSpeed(by delta: Double) {
        let nextSpeed = translationSpeechSpeed + delta
        translationSpeechSpeed = TranslationSpeaker.clampedSpeechSpeed(nextSpeed)
    }

}

enum ChatLanguage: String, CaseIterable, Identifiable {
    case english = "English"
    case vietnamese = "Vietnamese"

    var id: String { rawValue }
    var title: String { rawValue }

    var locale: Locale {
        Locale(identifier: localeIdentifier)
    }

    var localeIdentifier: String {
        switch self {
        case .english:
            "en-US"
        case .vietnamese:
            "vi-VN"
        }
    }

    var speechPrompt: String {
        switch self {
        case .english:
            "The audio is English speech."
        case .vietnamese:
            "The audio is Vietnamese speech."
        }
    }

    var buttonWidth: CGFloat {
        120
    }
}

enum ChatStyle {
    static let pageBackground = Color(red: 19 / 255, green: 19 / 255, blue: 19 / 255)
    static let controlFill = Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)
    static let controlBorder = Color(red: 42 / 255, green: 42 / 255, blue: 42 / 255)
    static let primaryButton = Color(red: 168 / 255, green: 199 / 255, blue: 250 / 255)
    static let primaryInk = Color(red: 18 / 255, green: 49 / 255, blue: 116 / 255)
    static let recordingButton = Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255)
    static let mutedText = Color(red: 209 / 255, green: 213 / 255, blue: 219 / 255)
    static let promptText = Color(red: 163 / 255, green: 163 / 255, blue: 163 / 255)
}

struct ChatTopBar: View {
    let sourceLanguage: ChatLanguage
    let targetLanguage: ChatLanguage
    let onSwapLanguages: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ChatLanguageButton(language: sourceLanguage)

            Button(action: onSwapLanguages) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ChatStyle.mutedText)
                    .frame(width: 36, height: 36)
            }
            .padding(.horizontal, 8)
            .accessibilityLabel("Swap languages")

            ChatLanguageButton(language: targetLanguage)
        }
        .padding(.horizontal, 20)
        .padding(.top, 48)
        .padding(.bottom, 20)
    }
}

struct ChatLanguageButton: View {
    let language: ChatLanguage

    var body: some View {
        Text(language.title)
            .font(.system(size: 15, weight: .medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .tracking(0.375)
            .lineLimit(1)
            .frame(width: language.buttonWidth, height: 45)
            .background(ChatStyle.controlFill, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(ChatStyle.controlBorder))
    }
}

struct ChatMainContent: View {
    let transcript: String
    let translation: String
    let sourceLanguage: ChatLanguage
    let targetLanguage: ChatLanguage
    let isRecording: Bool
    let audioLevel: Double
    let isTranscribing: Bool
    let isTranslating: Bool
    let statusMessage: String?
    let showsTranslation: Bool
    let isTranslationSpeechMuted: Bool
    let translationSpeechSpeed: Double
    let onToggleTranslationSpeechMute: () -> Void
    let onDecreaseTranslationSpeechSpeed: () -> Void
    let onIncreaseTranslationSpeechSpeed: () -> Void

    var body: some View {
        ZStack {
            ChatStyle.pageBackground

            if shouldShowTranscriptBody {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if isRecording {
                            RecordingStatusPill(audioLevel: audioLevel)
                        }

                        TranslationBlock(
                            title: sourceLanguage.title,
                            text: transcriptDisplayText,
                            foregroundColor: transcript.isEmpty ? ChatStyle.promptText : .white.opacity(0.9)
                        )

                        if showsTranslation, !isRecording {
                            TranslationOutputBlock(
                                title: targetLanguage.title,
                                text: translation,
                                statusMessage: statusMessage,
                                isTranslating: isTranslating,
                                isMuted: isTranslationSpeechMuted,
                                speechSpeed: translationSpeechSpeed,
                                onToggleMute: onToggleTranslationSpeechMute,
                                onDecreaseSpeed: onDecreaseTranslationSpeechSpeed,
                                onIncreaseSpeed: onIncreaseTranslationSpeechSpeed
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 28)
                }
                .scrollIndicators(.visible)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                if isTranscribing {
                    TranscriptionLoadingState()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 32)
                } else {
                    Text(displayText)
                        .font(.system(size: 24, weight: .regular))
                        .tracking(0)
                        .foregroundStyle(ChatStyle.promptText)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 32)
                }
            }
        }
        .clipShape(
            UnevenRoundedRectangle(
                bottomLeadingRadius: 40,
                bottomTrailingRadius: 40
            )
        )
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }

    private var displayText: String {
        if let statusMessage {
            statusMessage
        } else {
            "Tap on the mic button to start"
        }
    }

    private var shouldShowTranscriptBody: Bool {
        isRecording || !transcript.isEmpty
    }

    private var transcriptDisplayText: String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTranscript.isEmpty {
            return transcript
        }

        if let statusMessage, isRecording {
            return statusMessage
        }

        return "Listening..."
    }

}

struct TranscriptionLoadingState: View {
    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(ChatStyle.primaryButton.opacity(0.12))
                    .frame(width: 116, height: 116)

                Circle()
                    .stroke(ChatStyle.primaryButton.opacity(0.3), lineWidth: 1)
                    .frame(width: 116, height: 116)

                ProgressView()
                    .controlSize(.large)
                    .tint(ChatStyle.primaryButton)
            }

            VStack(spacing: 14) {
                Text("Transcribing")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .tracking(0)

                VStack(spacing: 7) {
                    loadingLine(width: 184)
                    loadingLine(width: 228)
                    loadingLine(width: 152)
                }
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Transcribing")
    }

    private func loadingLine(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(ChatStyle.mutedText.opacity(0.16))
            .frame(width: width, height: 8)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(ChatStyle.primaryButton.opacity(0.34))
                    .frame(width: width * 0.45, height: 8)
            }
            .redacted(reason: .placeholder)
    }
}

struct RecordingListeningState: View {
    let audioLevel: Double

    var body: some View {
        VStack(spacing: 26) {
            ZStack {
                Circle()
                    .fill(ChatStyle.recordingButton.opacity(0.16))
                    .frame(width: pulseSize, height: pulseSize)
                    .animation(.easeOut(duration: 0.16), value: audioLevel)

                Circle()
                    .stroke(ChatStyle.recordingButton.opacity(0.36), lineWidth: 1)
                    .frame(width: 118, height: 118)

                Circle()
                    .fill(ChatStyle.recordingButton)
                    .frame(width: 82, height: 82)

                Image(systemName: "mic.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 12) {
                Text("Listening...")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .tracking(0)

                VoiceLevelMeter(level: audioLevel, isActive: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Listening")
    }

    private var pulseSize: CGFloat {
        126 + CGFloat(audioLevel) * 68
    }
}

struct RecordingStatusPill: View {
    let audioLevel: Double

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ChatStyle.recordingButton)
                .frame(width: 9, height: 9)

            Text("Listening")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))

            MiniVoiceLevelMeter(level: audioLevel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ChatStyle.controlFill, in: Capsule())
        .overlay(Capsule().stroke(ChatStyle.controlBorder))
        .accessibilityLabel("Listening")
    }
}

struct MiniVoiceLevelMeter: View {
    let level: Double

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5) { index in
                Capsule()
                    .fill(level >= Double(index + 1) / 6 ? ChatStyle.primaryButton : ChatStyle.mutedText.opacity(0.35))
                    .frame(width: 3, height: barHeight(for: index))
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
        .frame(height: 15)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let centerDistance = abs(index - 2)
        return 5 + CGFloat(level) * CGFloat(13 - centerDistance * 3)
    }
}

struct TranslationBlock: View {
    let title: String
    let text: String
    let foregroundColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ChatStyle.mutedText.opacity(0.7))

            Text(text)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(foregroundColor)
                .lineSpacing(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TranslationOutputBlock: View {
    let title: String
    let text: String
    let statusMessage: String?
    let isTranslating: Bool
    let isMuted: Bool
    let speechSpeed: Double
    let onToggleMute: () -> Void
    let onDecreaseSpeed: () -> Void
    let onIncreaseSpeed: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ChatStyle.mutedText.opacity(0.7))

            TranslationPlaybackControls(
                isMuted: isMuted,
                speed: speechSpeed,
                onToggleMute: onToggleMute,
                onDecreaseSpeed: onDecreaseSpeed,
                onIncreaseSpeed: onIncreaseSpeed
            )

            if isTranslating {
                TranslationLoadingState()
            } else {
                Text(displayText)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(text.isEmpty ? ChatStyle.promptText : ChatStyle.primaryButton)
                    .lineSpacing(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var displayText: String {
        if !text.isEmpty {
            text
        } else if let statusMessage {
            statusMessage
        } else {
            "Waiting for a complete phrase..."
        }
    }
}

struct TranslationPlaybackControls: View {
    let isMuted: Bool
    let speed: Double
    let onToggleMute: () -> Void
    let onDecreaseSpeed: () -> Void
    let onIncreaseSpeed: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleMute) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isMuted ? ChatStyle.recordingButton : ChatStyle.primaryButton)
                    .frame(width: 34, height: 34)
                    .background(ChatStyle.controlFill, in: Circle())
                    .overlay(Circle().stroke(ChatStyle.controlBorder))
            }
            .accessibilityLabel(isMuted ? "Unmute translated voice" : "Mute translated voice")

            HStack(spacing: 6) {
                Button(action: onDecreaseSpeed) {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(canDecreaseSpeed ? ChatStyle.primaryButton : ChatStyle.mutedText.opacity(0.42))
                        .frame(width: 30, height: 30)
                }
                .disabled(!canDecreaseSpeed)
                .accessibilityLabel("Decrease voice speed")

                Text("\(speed, specifier: "%.2f")x")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .monospacedDigit()
                    .frame(width: 54, height: 30)

                Button(action: onIncreaseSpeed) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(canIncreaseSpeed ? ChatStyle.primaryButton : ChatStyle.mutedText.opacity(0.42))
                        .frame(width: 30, height: 30)
                }
                .disabled(!canIncreaseSpeed)
                .accessibilityLabel("Increase voice speed")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ChatStyle.controlFill, in: Capsule())
            .overlay(Capsule().stroke(ChatStyle.controlBorder))

            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
    }

    private var canDecreaseSpeed: Bool {
        speed > TranslationSpeaker.minimumSpeechSpeed
    }

    private var canIncreaseSpeed: Bool {
        speed < TranslationSpeaker.maximumSpeechSpeed
    }
}

struct TranslationLoadingState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(ChatStyle.primaryButton)

                Text("Translating")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ChatStyle.primaryButton)
            }

            VStack(alignment: .leading, spacing: 7) {
                loadingLine(width: 220)
                loadingLine(width: 172)
                loadingLine(width: 128)
            }
            .accessibilityHidden(true)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Translating")
    }

    private func loadingLine(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(ChatStyle.primaryButton.opacity(0.2))
            .frame(width: width, height: 8)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(ChatStyle.primaryButton.opacity(0.42))
                    .frame(width: width * 0.42, height: 8)
            }
            .redacted(reason: .placeholder)
    }
}

struct ChatBottomControls: View {
    let isRecording: Bool
    let isBusy: Bool
    let audioLevel: Double
    @Binding var selectedFramework: SpeechRecognitionFramework
    @Binding var selectedRecordingFramework: RecordingFramework
    @Binding var isLiveTranscriptionEnabled: Bool
    @Binding var isTranslationSpeechMuted: Bool
    let onMicTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
//            Text(controlText)
//                .font(.system(size: 15, weight: .medium))
//                .foregroundStyle(ChatStyle.mutedText)
//                .frame(height: 23)
//                .padding(.bottom, 16)
//
//            VoiceLevelMeter(level: audioLevel, isActive: isRecording)
//                .padding(.bottom, 18)

            ZStack {
                Button(action: onMicTap) {
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(isRecording ? .white : ChatStyle.primaryInk)
                        .frame(width: 72, height: 72)
                        .background(isRecording ? ChatStyle.recordingButton : ChatStyle.primaryButton, in: Circle())
                        .shadow(color: .black.opacity(0.12), radius: 15, y: 10)
                }
                .disabled(isBusy)
                .opacity(isBusy ? 0.6 : 1)
                .accessibilityLabel(isRecording ? "Stop recording" : "Start microphone")

                HStack {
                    SettingsMenuButton(
                        selectedFramework: $selectedFramework,
                        selectedRecordingFramework: $selectedRecordingFramework,
                        isLiveTranscriptionEnabled: $isLiveTranscriptionEnabled
                    )

                    Spacer()
                }
            }
            .frame(width: 340, height: 72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 48)
    }

    private var controlText: String {
        if isBusy {
            "Transcribing..."
        } else if isRecording {
            "Listening..."
        } else {
            "Tap mic to start"
        }
    }
}

struct SettingsMenuButton: View {
    @Binding var selectedFramework: SpeechRecognitionFramework
    @Binding var selectedRecordingFramework: RecordingFramework
    @Binding var isLiveTranscriptionEnabled: Bool

    var body: some View {
        Menu {
            Section("Speech") {
                Picker("Speech framework", selection: $selectedFramework) {
                    ForEach(SpeechRecognitionFramework.allCases) { framework in
                        Text(framework.menuTitle)
                            .tag(framework)
                    }
                }

                Toggle("Live transcription", isOn: $isLiveTranscriptionEnabled)
            }

            Section("Recording") {
                Picker("Recording framework", selection: $selectedRecordingFramework) {
                    ForEach(RecordingFramework.allCases) { framework in
                        Text(framework.menuTitle)
                            .tag(framework)
                    }
                }
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(ChatStyle.mutedText)
                .frame(width: 56, height: 56)
                .background(ChatStyle.controlFill, in: Circle())
                .overlay(Circle().stroke(ChatStyle.controlBorder))
        }
        .accessibilityLabel("Settings")
    }
}

struct VoiceLevelMeter: View {
    let level: Double
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<9) { index in
                Capsule()
                    .fill(barColor(for: index))
                    .frame(width: 5, height: barHeight(for: index))
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
        .frame(height: 28)
        .opacity(isActive ? 1 : 0.28)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let centerDistance = abs(index - 4)
        let baseline = CGFloat(8 + (4 - centerDistance) * 2)
        let activeBoost = CGFloat(level) * CGFloat(28 - centerDistance * 3)
        return min(max(baseline + activeBoost, 6), 28)
    }

    private func barColor(for index: Int) -> Color {
        guard isActive else { return ChatStyle.mutedText.opacity(0.35) }
        let threshold = Double(index + 1) / 10
        return level >= threshold ? ChatStyle.primaryButton : ChatStyle.mutedText.opacity(0.35)
    }
}

#Preview {
    ConversationView()
}
