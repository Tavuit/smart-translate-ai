# Translate

Base iOS project built with SwiftUI.

## Requirements

- Xcode 26.3 or newer
- iOS 17.0 or newer

## Run

Open `Translate.xcodeproj` in Xcode, select the `Translate` scheme, then run on an iPhone or iPad simulator.

From terminal:

```bash
xcodebuild -project Translate.xcodeproj -scheme Translate -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## OpenAI API key

The app includes an `OpenAIClient` for the Responses API. Do not hardcode API keys in Swift source.

For local development, set `OPENAI_API_KEY` in the Xcode scheme environment or pass it as a build setting:

```bash
OPENAI_API_KEY=your_key_here xcodebuild -project Translate.xcodeproj -scheme Translate -destination 'platform=iOS Simulator,name=iPhone 17' build
```

For production, use a backend proxy so the OpenAI API key is never shipped in the iOS app bundle.

## Google Cloud Speech-to-Text V2

Google Cloud Speech-to-Text V2 is the default speech recognition provider. For local development, set:

- `GOOGLE_CLOUD_ACCESS_TOKEN`: OAuth access token with Cloud Speech permissions.
- `GOOGLE_CLOUD_PROJECT_ID`: Google Cloud project ID.
- `GOOGLE_CLOUD_SPEECH_LOCATION`: optional, defaults to `asia-southeast1`.
- `GOOGLE_CLOUD_SPEECH_MODEL`: optional, defaults to `chirp_3`.
- `GOOGLE_CLOUD_SPEECH_RECOGNIZER`: optional, defaults to `_`.

For quick testing, generate a short-lived token with:

```bash
gcloud auth print-access-token
```

For production, use a backend proxy or a proper token exchange flow so Google Cloud credentials are never shipped in the iOS app bundle.
