# Swift reference clients

These standalone examples demonstrate the backend request and optional spoken
answer workflow. They are not compiled into the native application.

- `FallBackendClient.swift`: multipart `/analyze` client and event-answer request.
- `FallVoiceManager.swift`: optional speech/audio interaction example.

The actual app lives in [`app/ios/`](../app/ios/). Its optional spoken check-in
uses ElevenLabs, full-reply transcription and staged consent endpoints;
vibration remains off. These examples are legacy references; their alarm flow
must not be copied into the new check-in workflow.
