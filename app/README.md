# FallApp for iPhone and Meta glasses

Native SwiftUI app with a local deterministic fall detector, Meta DAT glasses
connection, JPEG capture and authenticated integration with `../backend/fall_server.py`.
The selected detector is `deterministic-baseline-v1`; model code and configuration
are pinned by `model-lock.json`.

Connect glasses and accept the monitoring agreement. Sensor data then feeds the
local detector automatically. Early movement prepares the camera; a confirmed
local fall collects one second at requested **7 fps**, with up to seven frames.
The app stops non-continuous capture before JPEG processing/upload. No MP4 or
temporary movie is created. JPEGs and event metadata persist for upload retries.
The glasses capture LED stays active while the camera is streaming.

The phone sends one multipart `/analyze` request to Modal. The backend chooses
usable/best frames, restores their chronological order and sends them together
in one Claude request. No Claude key is stored on the phone.

## Layout

- `ios/`: Xcode project, UI, glasses SDK adapter and Keychain configuration.
- `packages/DetectionEngine/`: frozen detector, motion processing, JPEG export,
  camera recovery and Modal transport, with regression tests.
- `contracts/INTEGRATION.md`: request, response and retry behavior.
- `tools/`: project generation, model integrity, credential provisioning and
  read-only phone log tools.

## Build and configure

Requires macOS/Xcode with Swift 6 and an iPhone running iOS 17.2 or later. The
Meta DAT SDK is pinned to **1.0.1**. Physical glasses testing also requires the
matching Meta developer setup, Motion capability, paired glasses and Meta AI app.

From the repository root:

```sh
cp app/ios/Configuration/Signing.example.xcconfig app/ios/Configuration/Signing.local.xcconfig
cp app/ios/Configuration/Modal.example.xcconfig app/ios/Configuration/Modal.local.xcconfig
open app/ios/FallApp.xcodeproj
```

Set your bundle identifier, development team and Meta registration values in
`Signing.local.xcconfig`. Set the deployed Modal endpoint in
`Modal.local.xcconfig`, escaping the URL for Xcode, for example:

```text
MODAL_ENDPOINT_URL = https:/$()/your-workspace--fall-detection-backend-fastapi-app.modal.run
MODAL_AUTH_MODE = x-api-key
```

Build the `FallApp` scheme for your phone. Grant camera access through the app's
explicit permission flow. Enable Spoken fall check-in separately to allow microphone and speech recognition.
Voice plays only for a server-confirmed fall; vibration remains off.

The Modal API key lives in the phone's Keychain. For a **Debug** installation,
unlock the phone and bootstrap it from a private key file:

```sh
mkdir -p app/data
python3 app/tools/provision_iphone.py \
  --device "YOUR_DEVICE_ID" \
  --bundle-id "YOUR_BUNDLE_IDENTIFIER" \
  --key-file "/private/path/modal-api-key" \
  --result app/data/provision-result.json
```

The helper passes the key through a one-time launch environment and redacts its
output. Do not put keys in source, xcconfig, the app bundle or Git. Release builds
do not accept the debug bootstrap; a release credential enrollment flow remains
to be implemented. The default bundle ID is `org.local.fallapp.development`.

## Checks

```sh
python3 app/tools/verify_model.py
swift test --package-path app/packages/DetectionEngine
```

Two optional private-recording tests skip unless `FALL_BASELINE_WORKSPACE` points
to the original assessment workspace. The remaining tests cover motion ordering,
camera shutdown, seven-frame raw/HEVC export without movies, ordered multipart
upload, retry and notification gating. Recordings are intentionally not included.

If source membership changes, regenerate the project:

```sh
python3 app/tools/generate_project.py
```

## Phone diagnostics

```sh
xcrun devicectl list devices
python3 app/tools/watch_phone_logs.py --device "YOUR_DEVICE_ID" --bundle "YOUR_BUNDLE_IDENTIFIER"
python3 app/tools/pull_phone_logs.py --device "YOUR_DEVICE_ID" --bundle "YOUR_BUNDLE_IDENTIFIER"
```

These tools read app-written sensor/camera/network diagnostics. They do not
restart the app or attach a debugger. Exported logs go to ignored `app/data/`;
media is excluded. Mac file-copy failures while locked do not prove monitoring
stopped. Disconnect monitoring before a final consistent log export.

## Current limits

Background/locked-phone operation depends on the active Meta session and iOS.
Force-quit recovery is not promised. Optional silent disconnection notifications
require iOS permission and cannot be guaranteed after process termination.

The app displays the server visual verdict separately from upload receipt.
A negative result finishes the event while sensors keep monitoring. An enabled
positive-result check-in uses ElevenLabs and Apple speech recognition for staged
questions. Explicit email consent or two unanswered healthy listening windows
triggers a server-side email; calls require separate consent and iPhone confirmation.
The glasses can serve as Bluetooth call audio; DAT does not place a Meta AI call.
Phone location is optional and timestamped, never assumed to be a fresh fix while locked.
See [spoken check-in setup and API](contracts/CHECK_IN.md). Atomic email claims
prevent automatic repeat sends; vision-request idempotency and system-managed
background upload recovery remain pending.
Full seven-frame glasses-to-model validation still requires a physical capture.

Personal signing/configuration, credentials, recordings, session logs, historical
assessment reports and build output are excluded from this application folder.
