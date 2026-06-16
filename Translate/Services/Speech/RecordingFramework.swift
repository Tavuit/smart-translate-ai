import Foundation

enum RecordingFramework: String, CaseIterable, Identifiable {
    case avAudioEngine
    case webRTCAudioProcessing

    static let defaultFramework: RecordingFramework = .avAudioEngine

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .avAudioEngine:
            "AVAudioEngine + AVAudioSession"
        case .webRTCAudioProcessing:
            "WebRTC Audio Processing"
        }
    }
}

enum SpeechRecognitionFramework: String, CaseIterable, Identifiable {
    case googleCloud
    case openAI

    static let defaultFramework: SpeechRecognitionFramework = .openAI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .googleCloud:
            "Google Cloud"
        case .openAI:
            "OpenAI gpt-4o"
        }
    }

    var menuTitle: String {
        switch self {
        case .googleCloud:
            "Google Cloud Speech-to-Text V2"
        case .openAI:
            "OpenAI gpt-4o-transcribe"
        }
    }
}
