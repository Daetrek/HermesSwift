# HermesSwift

HermesSwift is a native SwiftUI iOS client for [Hermes Agent](https://hermes-agent.nousresearch.com/). It provides a mobile-first chat, voice, attachments, session organization, and black/phosphor-green terminal UI for a self-hosted Hermes API server.

> This is a client app only. It does not include or host a Hermes backend.

## Features

- Native SwiftUI chat UI
- True-black / phosphor-green terminal theme
- Hermes API session list, new chat, message send, and streaming fallback
- Attachment upload flow for images and files when the server supports it
- Markdown/code rendering with copy affordances
- Voice push-to-talk and text-to-speech integration through an optional OpenAI-compatible voice endpoint
- Local session organization: rename, pin, archive, search
- Command palette actions for summarize, extract tasks, debug latest error, copy/speak last answer, and screenshot analysis
- API token stored in Keychain

## Requirements

- macOS with full Xcode installed
- iOS 17+
- XcodeGen (`brew install xcodegen`)
- A running Hermes Agent API server
- A Hermes API token

## Configure Hermes

Start or configure your Hermes API server following the official docs:

https://hermes-agent.nousresearch.com/docs

The app does not ship with a public default API URL. On first launch, enter your own API server URL, for example:

```text
http://192.168.1.20:8642
https://your-host.example.com
```

Then paste your Hermes API token. The token is saved to the iOS Keychain.

## Optional voice endpoint

Voice features expect an OpenAI-style audio API compatible with:

```text
GET  /v1/audio/voices
POST /v1/audio/transcriptions
POST /v1/audio/speech
```

Leave the voice URL blank if you only want text chat.

## Build

```bash
brew install xcodegen
xcodegen generate
open HermesSwift.xcodeproj
```

In Xcode:

1. Select the `HermesSwift` target.
2. Set your own Apple Development Team.
3. Change the bundle identifier if needed.
4. Build and run on your iPhone.

CLI project generation:

```bash
xcodegen generate
xcodebuild -project HermesSwift.xcodeproj -scheme HermesSwift -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

## Security notes

- API tokens are stored in Keychain, not source or UserDefaults.
- Do not commit your API URL or token if it reveals private infrastructure.
- The app is a client. All server-side permissions and safety controls must be enforced by your Hermes deployment.

## License

MIT
