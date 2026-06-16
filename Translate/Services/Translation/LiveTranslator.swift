import Foundation

@MainActor
final class LiveTranslator: ObservableObject {
    static let stableTranscriptDelay: Duration = .seconds(1)

    @Published private(set) var translation = ""
    @Published private(set) var translatedSourceText = ""
    @Published private(set) var statusMessage: String?
    @Published private(set) var isTranslating = false

    private let configurationProvider: () throws -> OpenAIConfiguration
    private var translationTask: Task<Void, Never>?
    private var lastTranslatedSource = ""

    init(configurationProvider: @escaping () throws -> OpenAIConfiguration = { try OpenAIConfiguration.fromEnvironment() }) {
        self.configurationProvider = configurationProvider
    }

    func scheduleTranslation(
        sourceText: String,
        sourceLanguage: ChatLanguage,
        targetLanguage: ChatLanguage,
        delay: Duration
    ) {
        translationTask?.cancel()

        let trimmedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            reset()
            return
        }

        guard trimmedSource != lastTranslatedSource else { return }

        translation = ""
        translatedSourceText = ""
        statusMessage = nil
        translationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                await self?.translate(
                    sourceText: trimmedSource,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage
                )
            } catch {
                return
            }
        }
    }

    func reset() {
        translationTask?.cancel()
        translationTask = nil
        translation = ""
        translatedSourceText = ""
        statusMessage = nil
        isTranslating = false
        lastTranslatedSource = ""
    }

    private func translate(sourceText: String, sourceLanguage: ChatLanguage, targetLanguage: ChatLanguage) async {
        isTranslating = true
        statusMessage = nil

        do {
            let configuration = try configurationProvider()
            let client = try OpenAIClient(configuration: configuration)
            let reply = try await client.generateReply(
                to: sourceText,
                instructions: translationInstructions(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
            )
            translation = reply.text
            translatedSourceText = sourceText
            lastTranslatedSource = sourceText
        } catch {
            statusMessage = error.localizedDescription
        }

        isTranslating = false
    }

    private func translationInstructions(sourceLanguage: ChatLanguage, targetLanguage: ChatLanguage) -> String {
        """
        Translate from \(sourceLanguage.title) to \(targetLanguage.title).
        Return only the translated text.
        Preserve the meaning and natural conversational tone.
        """
    }
}
