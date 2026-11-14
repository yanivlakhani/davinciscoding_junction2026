# Phone to Modal integration

The API implementation is in `backend/fall_server.py` on `main`; the seven-frame
contract was introduced in commit `81ecb96`. Configure your
Modal URL locally; the existing workspace deployment is
`https://lorejob--fall-detection-backend-fastapi-app.us-east.modal.run`.
Authentication is the `x-api-key` header, read from iPhone Keychain.

## Capture and request

A local deterministic fall event receives a stable event ID and durable outbox
entry. Camera readiness may start before the fall alert. Collection targets a
one-second media window at 7 fps, with at most seven frames and up to 0.25 seconds
of available decodable pre-roll. Actual frame count can be lower; no duplicate
frames are invented. HEVC is decoded in memory and every collected frame is JPEG
encoded. No MP4 is created. JPEG order follows presentation timestamps.

`POST /analyze`, multipart/form-data:

| Field | Client value |
| --- | --- |
| `frames` | Repeated JPEG file parts, up to seven, in chronological order |
| `event_id` | Stable local ID, reused across retries |
| `duration_s` | `1` for new captures |
| `imu_level` | `1`; no invented sensor-to-severity mapping |
| `best_n` | Omitted; backend default is `7` |

No location is collected/sent. An `Idempotency-Key` header carries the event ID;
the current backend does not enforce atomic idempotency from that header.

The backend accepts 1–7 images, filters unusable imagery, selects up to `best_n`
by sharpness, restores selected frames to input order and includes them in one
interactive Claude Messages request. This is not the asynchronous Batch API.
Default `best_n=7` forwards every usable image if all seven are usable.

## Response and recovery

Current response fields include nullable `fall_detected`, `event_id`, `n_frames`, `best_n`,
`selected_frame_indices`, `selected_frame_times_s`, `vision`, `vision_error`,
`status` and `processing_ms`. `vision.caduta` is `SI`, `NO`, or null when there is
no prediction. A null result or provider error must never be interpreted as NO.
Alarm `level` is fused with IMU state and is not a visual true/false result.

The phone checks public `/health` and an authenticated random nonexistent event
lookup. Expected results are HTTP 200/`ok=true` and HTTP 404/`unknown event`.
Before upload it looks up `/event/{event_id}` to recover an already accepted
request. A successful response is saved under `server-responses/`; the event then
moves from `outbox/` to `delivered/`. Existing UI reports this receipt status,
and separately displays the parsed visual-model verdict. Negative results finish
the event; positive results can start the explicitly enabled spoken check-in.

Incomplete captures stay local. Network, TLS, authorization and server failures
retain images/events; retryable failures back off for 30 seconds while the app
runs. Captures with more than seven archived frames remain local rather than
being silently truncated or posted above the server limit. Credentials are never
forwarded across redirects. No `/answer` or `/alarm` call is issued by this app.

## Remaining integration work

- Visual result parsing now distinguishes true, false and unavailable even if
  HTTP 200 contains `vision_error`. See [the spoken check-in contract](CHECK_IN.md)
  for ElevenLabs setup, staged reply analysis, email consent, silence alerts and call handoff.
- Implement atomic server-side request idempotency before relying on retries
  under concurrent/ambiguous requests.
- Carry actual frame offsets instead of backend-inferred evenly spaced times.
- Validate real seven-frame capture, selection, model result and latency on
  physical glasses; test background/lock paths independently.

Phone artifacts live under `Documents/FallApp/`: sessions, camera timelines,
capture JPEG/JSON, outbox/delivered events, server responses and network timing.
No recordings or runtime artifacts are part of this repository addition.
