# Swift reference clients

These standalone examples demonstrate the backend request and optional spoken
answer workflow. They are not compiled into the native application.

- `FallBackendClient.swift`: multipart `/analyze` client and event-answer request.
- `FallVoiceManager.swift`: optional speech/audio interaction example.

The actual app lives in [`app/ios/`](../app/ios/) and deliberately keeps sound,
vibration and microphone use disabled. Use its transport rather than copying
these examples into the app without reviewing their behavior.
