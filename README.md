# Fall detection with Meta glasses

One repository for the iPhone application and its Modal backend.

| Folder | Contents |
| --- | --- |
| [`app/`](app/README.md) | Native iPhone app, local deterministic detector, camera capture, Modal transport and tests |
| [`app/ios/`](app/ios/) | Xcode project and the actual SwiftUI application |
| [`backend/`](backend/README.md) | Modal/FastAPI server and model evaluation tool |
| [`ios/`](ios/README.md) | Standalone Swift backend-client and optional voice-flow examples |

The app connects glasses, monitors motion locally and captures one second at
requested 7 fps after a fall alert. It sends up to seven ordered JPEGs together
to `/analyze`; no MP4 is created. The backend selects usable/best frames,
restores their chronological order and sends them in one Claude request.

Start with [app setup](app/README.md) and [backend setup](backend/README.md).
Personal signing settings, credentials, recordings and runtime artifacts are
excluded from Git. The default development workflow now uses `main`.

## Checks

```sh
python3 app/tools/verify_model.py
swift test --package-path app/packages/DetectionEngine
```

## Backend development and deployment

```sh
modal serve backend/fall_server.py
modal deploy backend/fall_server.py
```

The GitHub deployment workflow uses `backend/fall_server.py`. Configure
`MODAL_TOKEN_ID` and `MODAL_TOKEN_SECRET` as repository secrets to enable automatic
Modal deployments on backend changes to `main`; otherwise deployment is explicitly
skipped. Set optional `MODAL_URL` for its health check.

A negative visual verdict ends that event while motion monitoring continues.
An enabled positive-result flow asks ElevenLabs questions through the glasses,
analyzes full replies, asks for email consent, and separately offers an iPhone
call handoff. Two healthy unanswered listening windows send an email automatically.
See [spoken check-in setup](app/contracts/CHECK_IN.md) and
[the integration contract](app/contracts/INTEGRATION.md). Configured-service and
physical end-to-end validation remain required.
