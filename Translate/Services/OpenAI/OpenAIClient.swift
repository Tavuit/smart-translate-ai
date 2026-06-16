import Foundation

struct OpenAIConfiguration: Equatable {
    static let apiKeyInfoKey = "OPENAI_API_KEY"
    static let defaultModel = "gpt-4o"
    static let defaultTranscriptionModel = "gpt-4o-transcribe"
    static let defaultRealtimeTranscriptionModel = "gpt-4o-transcribe"

    let apiKey: String
    let model: String

    init(apiKey: String, model: String = Self.defaultModel) {
        self.apiKey = apiKey
        self.model = model
    }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) throws -> OpenAIConfiguration {
        if let apiKey = sanitizedAPIKey(environment[apiKeyInfoKey]) {
            return OpenAIConfiguration(apiKey: apiKey)
        }

        let bundleValue = bundle.object(forInfoDictionaryKey: apiKeyInfoKey) as? String
        if let apiKey = sanitizedAPIKey(bundleValue) {
            return OpenAIConfiguration(apiKey: apiKey)
        }

        throw OpenAIClientError.missingAPIKey
    }

    static func sanitizedAPIKey(_ value: String?) -> String? {
        guard let value else { return nil }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }

        return trimmed
    }
}

struct GoogleCloudSpeechConfiguration: Equatable {
    static let accessTokenInfoKey = "GOOGLE_CLOUD_ACCESS_TOKEN"
    static let projectIDInfoKey = "GOOGLE_CLOUD_PROJECT_ID"
    static let locationInfoKey = "GOOGLE_CLOUD_SPEECH_LOCATION"
    static let recognizerInfoKey = "GOOGLE_CLOUD_SPEECH_RECOGNIZER"
    static let modelInfoKey = "GOOGLE_CLOUD_SPEECH_MODEL"
    static let defaultLocation = "asia-southeast1"
    static let defaultRecognizer = "_"
    static let defaultModel = "chirp_3"

    let accessToken: String
    let projectID: String
    let location: String
    let recognizer: String
    let model: String

    init(
        accessToken: String,
        projectID: String,
        location: String = Self.defaultLocation,
        recognizer: String = Self.defaultRecognizer,
        model: String = Self.defaultModel
    ) {
        self.accessToken = accessToken
        self.projectID = projectID
        self.location = location
        self.recognizer = recognizer
        self.model = model
    }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) throws -> GoogleCloudSpeechConfiguration {
        guard let accessToken = sanitizedValue(environment[accessTokenInfoKey])
            ?? sanitizedValue(bundle.object(forInfoDictionaryKey: accessTokenInfoKey) as? String)
        else {
            throw GoogleCloudSpeechClientError.missingAccessToken
        }

        guard let projectID = sanitizedValue(environment[projectIDInfoKey])
            ?? sanitizedValue(bundle.object(forInfoDictionaryKey: projectIDInfoKey) as? String)
        else {
            throw GoogleCloudSpeechClientError.missingProjectID
        }

        return GoogleCloudSpeechConfiguration(
            accessToken: accessToken,
            projectID: projectID,
            location: sanitizedValue(environment[locationInfoKey])
                ?? sanitizedValue(bundle.object(forInfoDictionaryKey: locationInfoKey) as? String)
                ?? defaultLocation,
            recognizer: sanitizedValue(environment[recognizerInfoKey])
                ?? sanitizedValue(bundle.object(forInfoDictionaryKey: recognizerInfoKey) as? String)
                ?? defaultRecognizer,
            model: sanitizedValue(environment[modelInfoKey])
                ?? sanitizedValue(bundle.object(forInfoDictionaryKey: modelInfoKey) as? String)
                ?? defaultModel
        )
    }

    static func sanitizedValue(_ value: String?) -> String? {
        guard let value else { return nil }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }

        return trimmed
    }
}

struct OpenAIReply: Equatable {
    let id: String
    let text: String
}

enum OpenAIClientError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case missingAPIKey
    case emptyOutput
    case apiError(String)
    case requestFailed(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The OpenAI endpoint URL is invalid."
        case .invalidResponse:
            "OpenAI returned an invalid response."
        case .missingAPIKey:
            "Missing OpenAI API key. Set OPENAI_API_KEY in the scheme environment or build settings."
        case .emptyOutput:
            "OpenAI returned an empty response."
        case .apiError(let message):
            message
        case .requestFailed(let statusCode, let message):
            "OpenAI request failed with status \(statusCode): \(message)"
        }
    }
}

enum GoogleCloudSpeechClientError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case missingAccessToken
    case missingProjectID
    case emptyOutput
    case requestFailed(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The Google Cloud Speech endpoint URL is invalid."
        case .invalidResponse:
            "Google Cloud Speech returned an invalid response."
        case .missingAccessToken:
            "Missing Google Cloud access token. Set GOOGLE_CLOUD_ACCESS_TOKEN in the scheme environment or build settings."
        case .missingProjectID:
            "Missing Google Cloud project ID. Set GOOGLE_CLOUD_PROJECT_ID in the scheme environment or build settings."
        case .emptyOutput:
            "Google Cloud Speech returned an empty transcript."
        case .requestFailed(let statusCode, let message):
            "Google Cloud Speech request failed with status \(statusCode): \(message)"
        }
    }
}

actor OpenAIClient {
    private let configuration: OpenAIConfiguration
    private let session: URLSession
    private let endpoint: URL

    init(
        configuration: OpenAIConfiguration,
        session: URLSession = .shared,
        endpoint: URL? = URL(string: "https://api.openai.com/v1/responses")
    ) throws {
        guard let endpoint else { throw OpenAIClientError.invalidURL }

        self.configuration = configuration
        self.session = session
        self.endpoint = endpoint
    }

    func generateReply(
        to input: String,
        instructions: String = "You are a concise translation assistant.",
        previousResponseID: String? = nil
    ) async throws -> OpenAIReply {
        let payload = ResponseRequest(
            model: configuration.model,
            input: input,
            instructions: instructions,
            previousResponseID: previousResponseID
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenAIClientError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: apiErrorMessage(from: data)
            )
        }

        let decoded = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        if let message = decoded.error?.message {
            throw OpenAIClientError.apiError(message)
        }

        let text = decoded.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpenAIClientError.emptyOutput }

        return OpenAIReply(id: decoded.id, text: text)
    }

    private func apiErrorMessage(from data: Data) -> String {
        guard
            let decoded = try? JSONDecoder().decode(ResponseEnvelope.self, from: data),
            let message = decoded.error?.message
        else {
            return String(data: data, encoding: .utf8) ?? "Unknown error"
        }

        return message
    }
}

private struct ResponseRequest: Encodable {
    let model: String
    let input: String
    let instructions: String
    let previousResponseID: String?

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case instructions
        case previousResponseID = "previous_response_id"
    }
}

private struct ResponseEnvelope: Decodable {
    let id: String
    let output: [ResponseOutputItem]?
    let error: ResponseError?

    var outputText: String {
        output?
            .compactMap(\.content)
            .flatMap { $0 }
            .compactMap(\.text)
            .joined(separator: "\n") ?? ""
    }
}

private struct ResponseOutputItem: Decodable {
    let content: [ResponseContent]?
}

private struct ResponseContent: Decodable {
    let text: String?
}

private struct ResponseError: Decodable {
    let message: String
}

struct OpenAITranscriptionResult: Equatable {
    let text: String
}

enum OpenAIRealtimeTranscriptionEvent: Equatable, Sendable {
    case delta(String)
    case completed(String)
    case status(String)
    case error(String)
}

private struct OpenAITranscriptionResponse: Decodable {
    let text: String
}

struct GoogleCloudSpeechTranscriptionResult: Equatable {
    let text: String
}

actor OpenAITranscriptionClient {
    private let configuration: OpenAIConfiguration
    private let session: URLSession
    private let endpoint: URL

    init(
        configuration: OpenAIConfiguration,
        session: URLSession = .shared,
        endpoint: URL? = URL(string: "https://api.openai.com/v1/audio/transcriptions")
    ) throws {
        guard let endpoint else { throw OpenAIClientError.invalidURL }

        self.configuration = configuration
        self.session = session
        self.endpoint = endpoint
    }

    func transcribeAudio(
        fileURL: URL,
        mimeType: String? = nil,
        prompt: String = "The audio is Vietnamese speech.",
        language: String? = nil,
        model: String = OpenAIConfiguration.defaultTranscriptionModel
    ) async throws -> OpenAITranscriptionResult {
        let boundary = "Boundary-\(UUID().uuidString)"
        let fileData = try Data(contentsOf: fileURL)
        let uploadMimeType = mimeType ?? Self.mimeType(for: fileURL)

        var formData = MultipartFormData(boundary: boundary)
            .appendingField(name: "model", value: model)
            .appendingField(name: "response_format", value: "json")
            .appendingField(name: "prompt", value: prompt)

        if let language {
            formData = formData.appendingField(name: "language", value: language)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData
            .appendingFile(
                name: "file",
                filename: fileURL.lastPathComponent,
                mimeType: uploadMimeType,
                data: fileData
            )
            .finalizedData()

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenAIClientError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: apiErrorMessage(from: data)
            )
        }

        let decoded = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpenAIClientError.emptyOutput }

        return OpenAITranscriptionResult(text: text)
    }

    private func apiErrorMessage(from data: Data) -> String {
        guard
            let decoded = try? JSONDecoder().decode(OpenAITranscriptionErrorEnvelope.self, from: data),
            let message = decoded.error?.message
        else {
            return String(data: data, encoding: .utf8) ?? "Unknown error"
        }

        return message
    }

    nonisolated static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "flac":
            "audio/flac"
        case "mp3":
            "audio/mpeg"
        case "mp4":
            "audio/mp4"
        case "mpeg", "mpga":
            "audio/mpeg"
        case "m4a":
            "audio/m4a"
        case "ogg":
            "audio/ogg"
        case "wav":
            "audio/wav"
        case "webm":
            "audio/webm"
        default:
            "application/octet-stream"
        }
    }
}

actor OpenAIRealtimeTranscriptionStream {
    nonisolated static let audioSampleRate = 24_000.0
    nonisolated static let connectionTimeoutSeconds: UInt64 = 8
    nonisolated static let endpoint = "wss://api.openai.com/v1/realtime?intent=transcription"
    nonisolated static let serverVADThreshold = 0.5
    nonisolated static let serverVADPrefixPaddingMilliseconds = 300
    nonisolated static let serverVADSilenceDurationMilliseconds = 650

    private let configuration: OpenAIConfiguration
    private let session: URLSession
    private let webSocketDelegate: RealtimeWebSocketDelegate
    private let endpointURL: URL
    private let eventHandler: @Sendable (OpenAIRealtimeTranscriptionEvent) -> Void
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var isDisconnecting = false

    init(
        configuration: OpenAIConfiguration,
        session: URLSession? = nil,
        endpointURL: URL? = URL(string: OpenAIRealtimeTranscriptionStream.endpoint),
        eventHandler: @escaping @Sendable (OpenAIRealtimeTranscriptionEvent) -> Void
    ) throws {
        guard let endpointURL else { throw OpenAIClientError.invalidURL }

        let webSocketDelegate = RealtimeWebSocketDelegate()
        self.configuration = configuration
        self.webSocketDelegate = webSocketDelegate
        self.session = session ?? URLSession(
            configuration: .default,
            delegate: webSocketDelegate,
            delegateQueue: nil
        )
        self.endpointURL = endpointURL
        self.eventHandler = eventHandler
    }

    func connect(prompt: String, language: String) async throws {
        isDisconnecting = false
        var request = URLRequest(url: endpointURL)
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        try await webSocketDelegate.waitForOpen(timeoutSeconds: Self.connectionTimeoutSeconds)
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        try await sendJSON([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": Int(Self.audioSampleRate)
                        ],
                        "noise_reduction": [
                            "type": "near_field"
                        ],
                        "transcription": [
                            "model": OpenAIConfiguration.defaultRealtimeTranscriptionModel,
                            "language": language,
                            "prompt": prompt
                        ],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": Self.serverVADThreshold,
                            "prefix_padding_ms": Self.serverVADPrefixPaddingMilliseconds,
                            "silence_duration_ms": Self.serverVADSilenceDurationMilliseconds
                        ]
                    ]
                ]
            ]
        ])
    }

    func sendAudio(_ audioData: Data) async {
        guard !audioData.isEmpty else { return }

        do {
            try await sendJSON([
                "type": "input_audio_buffer.append",
                "audio": audioData.base64EncodedString()
            ])
        } catch {
            handleSendError(error)
        }
    }

    func commitAudioBuffer() async {
        do {
            try await sendJSON([
                "type": "input_audio_buffer.commit"
            ])
        } catch {
            handleSendError(error)
        }
    }

    func disconnect() {
        isDisconnecting = true
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let webSocketTask else { return }

            do {
                let message = try await webSocketTask.receive()
                handle(message)
            } catch {
                if !Task.isCancelled, !isDisconnecting, !Self.isSocketDisconnectedError(error) {
                    eventHandler(.error(error.localizedDescription))
                }
                return
            }
        }
    }

    private func handleSendError(_ error: Error) {
        guard !isDisconnecting, !Self.isSocketDisconnectedError(error) else { return }
        eventHandler(.error(error.localizedDescription))
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .data(let messageData):
            data = messageData
        case .string(let string):
            data = Data(string.utf8)
        @unknown default:
            data = nil
        }

        guard
            let data,
            let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = envelope["type"] as? String
        else {
            return
        }

        switch type {
        case "conversation.item.input_audio_transcription.delta":
            if let delta = envelope["delta"] as? String, !delta.isEmpty {
                eventHandler(.delta(delta))
            }
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = envelope["transcript"] as? String {
                eventHandler(.completed(transcript))
            }
        case "error":
            eventHandler(.error(Self.errorMessage(from: envelope)))
        case "transcription_session.updated", "session.created", "session.updated":
            eventHandler(.status("Live transcription is ready."))
        default:
            break
        }
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let webSocketTask else { throw OpenAIClientError.invalidResponse }

        let data = try JSONSerialization.data(withJSONObject: object)
        let string = String(decoding: data, as: UTF8.self)
        try await webSocketTask.send(.string(string))
    }

    private nonisolated static func isSocketDisconnectedError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("socket isn't connected")
            || message.contains("socket is not connected")
            || message.contains("cancelled")
    }

    private static func errorMessage(from envelope: [String: Any]) -> String {
        guard
            let error = envelope["error"] as? [String: Any],
            let message = error["message"] as? String
        else {
            return "OpenAI realtime transcription failed."
        }

        return message
    }
}

private final class RealtimeWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var openResult: Result<Void, Error>?

    func waitForOpen(timeoutSeconds: UInt64) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.waitForOpen()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw OpenAIClientError.apiError("Timed out connecting to OpenAI realtime transcription.")
            }

            try await group.next()
            group.cancelAll()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        finish(.success(()))
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let message = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "Socket closed before connecting."
        finish(.failure(OpenAIClientError.apiError(message)))
    }

    private func waitForOpen() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let openResult {
                lock.unlock()
                continuation.resume(with: openResult)
                return
            }

            openContinuation = continuation
            lock.unlock()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard openResult == nil else {
            lock.unlock()
            return
        }

        openResult = result
        let continuation = openContinuation
        openContinuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }
}

private struct OpenAITranscriptionErrorEnvelope: Decodable {
    let error: OpenAITranscriptionAPIError?
}

private struct OpenAITranscriptionAPIError: Decodable {
    let message: String
}

actor GoogleCloudSpeechClient {
    private let configuration: GoogleCloudSpeechConfiguration
    private let session: URLSession
    private let endpointBaseURL: URL

    init(
        configuration: GoogleCloudSpeechConfiguration,
        session: URLSession = .shared,
        endpointBaseURL: URL? = URL(string: "https://speech.googleapis.com")
    ) throws {
        guard let endpointBaseURL else { throw GoogleCloudSpeechClientError.invalidURL }

        self.configuration = configuration
        self.session = session
        self.endpointBaseURL = endpointBaseURL
    }

    func transcribeAudio(fileURL: URL, languageCode: String) async throws -> GoogleCloudSpeechTranscriptionResult {
        let fileData = try Data(contentsOf: fileURL)
        let payload = GoogleCloudSpeechRecognizeRequest(
            config: GoogleCloudSpeechRecognitionConfig(
                model: configuration.model,
                languageCodes: [languageCode],
                features: GoogleCloudSpeechRecognitionFeatures(enableAutomaticPunctuation: true),
                autoDecodingConfig: [:]
            ),
            content: fileData.base64EncodedString()
        )

        let endpointBaseString = endpointBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let endpoint = URL(
            string: "\(endpointBaseString)/v2/projects/\(configuration.projectID)/locations/\(configuration.location)/recognizers/\(configuration.recognizer):recognize"
        ) else {
            throw GoogleCloudSpeechClientError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleCloudSpeechClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GoogleCloudSpeechClientError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: googleAPIErrorMessage(from: data)
            )
        }

        let decoded = try JSONDecoder().decode(GoogleCloudSpeechRecognizeResponse.self, from: data)
        let text = decoded.results
            .compactMap { $0.alternatives.first?.transcript }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GoogleCloudSpeechClientError.emptyOutput }

        return GoogleCloudSpeechTranscriptionResult(text: text)
    }

    private func googleAPIErrorMessage(from data: Data) -> String {
        guard
            let decoded = try? JSONDecoder().decode(GoogleCloudSpeechErrorEnvelope.self, from: data),
            let message = decoded.error?.message
        else {
            return String(data: data, encoding: .utf8) ?? "Unknown error"
        }

        return message
    }
}

private struct GoogleCloudSpeechRecognizeRequest: Encodable {
    let config: GoogleCloudSpeechRecognitionConfig
    let content: String
}

private struct GoogleCloudSpeechRecognitionConfig: Encodable {
    let model: String
    let languageCodes: [String]
    let features: GoogleCloudSpeechRecognitionFeatures
    let autoDecodingConfig: [String: String]
}

private struct GoogleCloudSpeechRecognitionFeatures: Encodable {
    let enableAutomaticPunctuation: Bool
}

private struct GoogleCloudSpeechRecognizeResponse: Decodable {
    let results: [GoogleCloudSpeechRecognitionResult]
}

private struct GoogleCloudSpeechRecognitionResult: Decodable {
    let alternatives: [GoogleCloudSpeechRecognitionAlternative]
}

private struct GoogleCloudSpeechRecognitionAlternative: Decodable {
    let transcript: String
}

private struct GoogleCloudSpeechErrorEnvelope: Decodable {
    let error: GoogleCloudSpeechAPIError?
}

private struct GoogleCloudSpeechAPIError: Decodable {
    let message: String
}

struct MultipartFormData {
    private let boundary: String
    private var data = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    func appendingField(name: String, value: String) -> MultipartFormData {
        var copy = self
        copy.data.appendString("--\(boundary)\r\n")
        copy.data.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        copy.data.appendString("\(value)\r\n")
        return copy
    }

    func appendingFile(name: String, filename: String, mimeType: String, data fileData: Data) -> MultipartFormData {
        var copy = self
        copy.data.appendString("--\(boundary)\r\n")
        copy.data.appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        copy.data.appendString("Content-Type: \(mimeType)\r\n\r\n")
        copy.data.append(fileData)
        copy.data.appendString("\r\n")
        return copy
    }

    func finalizedData() -> Data {
        var copy = data
        copy.appendString("--\(boundary)--\r\n")
        return copy
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
