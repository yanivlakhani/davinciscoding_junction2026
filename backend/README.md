# Modal fall-detection backend

The server receives a one-second JPEG burst from the iPhone app, prepares usable
images and sends one multi-image request to Claude. It is deployed as the same
Modal app (`fall-detection-backend`) and function (`fastapi_app`); moving this
source file does not rename those resources or require a phone endpoint change.

Run these commands from the repository root:

```sh
pip install modal
modal setup
modal serve backend/fall_server.py
```

For a stable deployment:

```sh
modal deploy backend/fall_server.py
```

Configure the existing Modal secret `fall-secrets` with `ANTHROPIC_API_KEY` and
`API_KEY`; optional `NOTIFY_WEBHOOK_URL` is used by explicit alarm/answer routes.
For the Gmail POC, create the separate `email-sending` Modal secret, select
`NOTIFY_CHANNEL=email` and configure the sender,
Google app password and one recipient as described in [Email alerts](EMAIL_ALERTS.md).
These values stay in Modal secrets. Email submission is not proof of inbox delivery.
Keep credential values outside the repository. The Docker image declares the
runtime dependencies, including FastAPI, multipart, OpenCV and Anthropic.

GitHub Actions watches `backend/**` on `main` and deploys this same file when
repository secrets `MODAL_TOKEN_ID` and `MODAL_TOKEN_SECRET` are configured.
Without both secrets, it checks Python syntax and explicitly skips deployment.
Optional repository variable `MODAL_URL` enables a post-deploy health check.

The iPhone multipart contract and current response/retry limitations are in
[`app/contracts/INTEGRATION.md`](../app/contracts/INTEGRATION.md). `/classify` is
stateless for evaluation; `/analyze` stores a production event. Neither HTTP 200
nor upload receipt alone certifies a usable prediction; inspect `vision_error`
and `vision.caduta`.

## Frame selection for `/analyze`

Send 1-7 JPEG frames in chronological order. Every decodable frame reaches Claude
in one request, including dark, blurred or low-contrast frames. Image-quality
measurements are diagnostic only; no sharpness ranking or quality rejection applies
to `/analyze`. Faces are still blurred before forwarding.

The legacy `best_n` field remains accepted (1-7) for compatibility and does not
reduce the batch. `frame_policy=all_decodable`, `selected_frame_indices` and
`selected_frame_times_s` report the actual forwarded frames and chronological times.
Invalid image bytes cannot be forwarded. Provider failures or no decodable images
produce an unknown verdict rather than a negative fall result.

## Confrontare modelli di visione

`eval_images.py` permette di confrontare i modelli Claude configurati nel backend.
Esegui il comando sullo stesso dataset etichettato, selezionando un modello alla volta:

```bash
python3 backend/eval_images.py /percorso/al/dataset --model claude-sonnet-5-5
python3 backend/eval_images.py /percorso/al/dataset --model claude-haiku-5-5
python3 backend/eval_images.py /percorso/al/dataset --model claude-opus-5-5
```

Le chiamate vengono aggiunte a `evaluation_history.jsonl`. Lo script aggiorna
`model_comparison.json` e `model_comparison.md` nella cartella del dataset; la
tabella Markdown confronta accuratezza, precisione, recall, specificità, F1,
ROC-AUC e latenza mediana/p95 tra i soli modelli Claude. Le metriche di qualità
sono calcolate solo per le immagini con etichetta ground truth.

## Spoken check-in

The authenticated `/check-in/prompt` and `/event/{eid}/check-in` routes support
staged questions, complete-reply analysis, email consent and a separate call request.
Add `ELEVENLABS_API_KEY` and `ELEVENLABS_VOICE_ID` to the separate `elevenlabs-voice`
Modal secret, preserving `fall-secrets` API/Anthropic credentials. See
[the check-in contract](../app/contracts/CHECK_IN.md). Two healthy unanswered
questions send an email; audio errors are not silence. The server records call
requests but never claims to place or connect a cellular call.

```sh
pip install -r backend/requirements-test.txt
python -m unittest discover -s backend/tests -v
```

These tests stub image/provider/Modal dependencies and do not contact a model,
create production events or notify contacts. Missing `API_KEY` now fails closed.

## Analysis latency and retries

`/analyze` deduplicates by `event_id` under the same per-event lock as check-ins.
Repeating an accepted event returns its stored result rather than rerunning Claude
or overwriting a conversation. The current deployment uses one container for these
locks; scaling beyond one requires a distributed claim.

Responses and safe `analysis_timing` logs report queue/lookup, preprocessing, model,
store and total handler milliseconds plus `prompt_version`. The store and total
handler measurements are response/log-only because they are measured after the
event write; recovered stored events retain preprocessing/model measurements.
Handler timings exclude multipart reception/parsing before handler entry.
The vision schema/model and seven-frame input remain the same; v4 shortens the
prompt and requests a reason of at most twelve words while retaining conservative
fall decisions. Validate sensitivity against labeled clips before interpreting
prompt changes as an accuracy improvement.

## Exact spoken replies

`/event/{event_id}/check-in` applies the versioned `EXACT_REPLIES` allowlist to
complete utterances before using Claude. The current question/stage determines
the meaning. Simple exact replies skip model inference; unlisted, qualified or
ambiguous replies retain the full Claude path. Negatively framed decline questions
accept plain yes/no or explicit certainty; polite/ambiguous replies still use Claude.

Responses and `check_in_timing` logs expose `interpretation_source`,
`matcher_version` and `matched_rule`. Authentication, event confirmation, stage
ordering, deduplicated sending and silence handling continue to use the same state
machine. `/health` advertises `reply_matching_version`. The phone does not need
a new build for this backend-only feature. See `../app/contracts/CHECK_IN.md`.
