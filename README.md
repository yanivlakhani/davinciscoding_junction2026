# Safy — AI Safety Glasses

> **Junction 2026 · Meta AI Glasses Track · CRACI · ElevenLabs · Modal · Codex Side Tracks**
>
> *Want to see it live? Ask us for an in-person demo, we'd love to show you!!!*

Every year, millions of elderly individuals suffer severe, life-threatening falls. The tech industry's answer so far has been a smartwatch or a plastic panic button on a lanyard around the neck. Both are failing.

**The stigma problem.** People forget or refuse to wear medical lanyards. They sit in a drawer.

**The physics problem.** The wrist is not your body's centre of gravity. Drop your phone off the couch and an Apple Watch might call an ambulance. But if you hit your head and your arm absorbs the impact, it registers nothing. The current market is plagued by false positives that waste emergency resources and false negatives that cost lives.

**The context problem.** Every existing detector — Apple Watch, Abeye smart glasses, wearable pendants — can only tell you *that* something happened. Not *what*. A family member gets a notification that says "a fall was detected" and has no idea whether their parent tripped on a rug or collapsed from a stroke.

The head is where we balance. The head is where we see. **Safy** moves safety from the wrist to the eyes.

We are **DaVinci's Coding**, and this is our project for **Junction 2026**.

### Moving the Centre of Gravity

The Junction 2026 theme is *"Moving the Centre of Gravity."* Ours does it in not one, not two, but THREE distinct ways:

1. **Literally.** The glasses detect a sudden shift in the wearer's centre of gravity — the biomechanical event that defines a fall.
2. **Physically.** We move the sensor from the wrist to the head, where balance is controlled and where a camera can actually see what happened.
3. **Systemically.** We move the centre of gravity of emergency response — from reactive to informed, from a generic alarm to a first-person AI summary, from opaque software to a transparent supply chain anyone can verify.

---

## How it works

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Meta Glasses │────▶│  iPhone App  │────▶│ Modal Server │────▶│ Safy Web App │
│  IMU + Camera │     │  Fall Detect │     │ Claude Vision│     │ Family Alert │
└──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
       │                                         │
       ▼                                         ▼
┌──────────────┐                          ┌──────────────┐
│ Glasses Lens │                          │ ElevenLabs   │
│  Display UI  │                          │ Voice Check  │
└──────────────┘                          └──────────────┘
```

### Escalation pipeline

| Stage | What happens | Where |
|-------|-------------|-------|
| **1. Detection** | Accelerometer + gyroscope on the glasses flag a likely fall. A local deterministic detector on the iPhone filters false positives before anything leaves the phone. | iPhone app |
| **2. Verbal check-in** | The glasses ask *"Are you okay?"* out loud (ElevenLabs TTS) and show it on the right-lens display. The wearer can respond by voice or tap. A clear "I'm fine" cancels the event. | Glasses + server |
| **3. Situation understanding** | A one-second JPEG burst (up to 7 frames) is sent to Claude, which classifies the incident (accidental fall, assault, collapse) with a confidence score. Faces are blurred before transmission. | Modal server |
| **4. Alert** | The companion web app shows the family member what happened: AI summary, key frames, severity and GPS location from the Meta Ray-Bans. Location is shared only during an active emergency, never in the background. Email alerts are sent automatically if configured. | Safy web app |

### Privacy by design

- Recording starts only *after* escalation, never continuously.
- GPS location is transmitted only during an active emergency — never tracked in the background.
- Bystander faces are blurred with OpenCV before any frame reaches Claude.
- No data leaves the phone until the wearer fails to cancel.
- The companion app runs entirely in the browser — no account, no server-side storage.

---

## Architecture

| Component | Branch | Stack | Description |
|-----------|--------|-------|-------------|
| **iPhone app** | [`main`](.) | Swift 6 · SwiftUI · Meta DAT SDK 1.0.1 | Connects glasses, runs the local fall detector, captures JPEG bursts, sends to Modal. |
| **Backend server** | [`main`](.) | Python 3.12 · Modal · FastAPI · Claude · ElevenLabs | Receives frames, blurs faces, runs Claude vision analysis, manages the spoken check-in pipeline, sends email alerts. |
| **Glasses lens display** | [`glasses-ui`](../../tree/glasses-ui) | React 19 · Vite · Meta Ray-Ban Display Toolkit | Five-state UI rendered on the right lens: Idle → Checking In → Escalated → Alert Sent → Cancelled. |
| **Companion web app (Safy)** | [`mobile-app`](../../tree/mobile-app) | Vanilla HTML/CSS/JS · Puppeteer tests | Family-facing alert screen with emergency contacts, fall preview, location sharing and the Trust panel. |
| **Supply chain evidence** | [`craci`](../../tree/craci) | CRACI runners · CycloneDX 1.7 · GitHub Actions | SBOM generation, network trace analysis and backend dependency pinning for the CRACI side track. |

---

## The five screens on the glasses

The lens display mirrors the backend state machine. On a 600×600 additive-light display, pure black is transparent and only the UI glows.

| State | What the wearer sees |
|-------|---------------------|
| **Idle** | Faint shield icon — safety mode is armed |
| **Checking In** | "Are you okay?" with a 15-second countdown ring |
| **Escalated** | Red hazard triangle · "Getting help · Recording · Analysing" |
| **Alert Sent** | Green tick · "Help is coming" · contacts named |
| **Cancelled** | Shield-check · "Glad you're okay" — re-arms automatically |

---

## CRACI Side Track — Supply Chain Transparency

> **Junction 2026 CRACI Side Track submission**

A safety device has to answer two questions: *does it work?* and *can you prove what is inside it?* The second one is what the EU Cyber Resilience Act (CRA) requires, and it is what this side track delivers.

### Why Safy is in scope

The CRA applies to products with digital elements on the EU market. Safy qualifies on three counts:

1. The glasses UI and companion app are software with a data connection.
2. The Modal backend is a *remote data processing solution* — the product cannot function without it.
3. We integrate third-party components (Meta DAT SDK, Anthropic API, OpenCV, FastAPI) and Article 13 requires due diligence on each.

### What we built

7 CI jobs run on [CRACI](https://craci.com) runners on every push. CRACI records a CycloneDX 1.7 SBOM from each build — not from a manifest file, but from what the runner actually downloads and installs.

| CRACI job | What it does |
|-----------|-------------|
| `backend` | Installs all 65 pinned Python packages with hash verification. Manifest scanners find 0 components — CRACI finds all 65. |
| `glasses-ui` | Builds the lens UI. Lockfile lists 79 packages; CRACI records 28 actually fetched (51 are other-platform binaries). |
| `mobile-app` | Installs the companion app. Puppeteer's postinstall downloads ~330 MB of Chrome binaries — invisible to any lockfile. |
| `policy-strict` | Same app under `default: deny`. CRACI blocks the Chrome download. Puppeteer exits 0 anyway — the binary is absent on disk. |
| `policy-reviewed` | Same app with `storage.googleapis.com` explicitly allowed. Chrome arrives as expected. |
| **`vuln-autofix`** | **AI auto-fixer.** Pulls every SBOM from the CRACI API, queries OSV for CVEs, checks network traces, and asks Claude to generate a fix. Opens a GitHub issue with the remediation plan. |
| `trust-panel` | Verifies the companion app's Trust panel matches the CRACI evidence. |

The backend's pinned dependency list is checked by CI against what `fall_server.py` actually declares. If someone adds a library, the workflow fails until the pins are regenerated.

### The Trust panel — a nutrition label for a safety device

The companion app includes a user-facing **Trust panel** that translates raw CycloneDX SBOMs into plain language:

- **5 purpose groups** a non-technical person can understand: "Sees and understands what happens", "Keeps your face private", "Alerts your family", "Receives signals from the glasses", "Shows text on your glasses".
- Every component carries a **Verified** tick backed by CRACI's per-job SBOM artifacts.
- A live dashboard shows packages checked (183), CRACI jobs verified (5/5) and known safety issues (0).

The CRA does not require publishing an SBOM to users. We did it anyway, because a safety device worn on someone's face should be able to explain itself to the person wearing it.

### AI auto-fixer — software that defends itself

After every build, the `vuln-autofix` job pulls every SBOM from the CRACI API, extracts every package purl, and batch-queries [OSV](https://osv.dev) for known vulnerabilities. If it finds one with a known fix, it sends the exact build data to Claude, which generates a remediation plan grounded in what CRACI actually saw installed — not a lockfile, not a guess. The fix is posted as a GitHub issue automatically.

If an attacker exploits a new CVE within a day, the next push to `craci` catches it and generates a fix before anyone wakes up.

### Verification

- **18 unit tests** validate strict SBOM verification, stale-file detection and purl normalization.
- **100+ headless integration assertions** test the full Trust panel and raw SBOM screen.
- CI workflow: [`.github/workflows/supply-chain.yml`](../../tree/craci/.github/workflows/supply-chain.yml)
- Full write-up: [`supply-chain/README.md`](../../tree/craci/supply-chain/README.md)

---

## ElevenLabs Side Track — The Voice That Checks In

> **Junction 2026 ElevenLabs Side Track submission**

When the glasses detect a fall, the first thing the wearer hears is a voice. Not a beep, not a siren, but a calm spoken question: *"Are you okay? Tell me how you feel."*

That voice is ElevenLabs. The backend calls the ElevenLabs TTS API (`eleven_flash_v2_5` model) to generate each spoken prompt, and the audio is streamed through the glasses' open-ear speakers.

### Seven spoken states

ElevenLabs generates a distinct prompt for each stage of the conversation, in English and Italian:

| Stage | What the glasses say |
|-------|---------------------|
| **Check-in** | *"Are you okay? Tell me how you feel."* |
| **Contact** | *"Would you like me to email your emergency contact?"* |
| **Decline** | *"Are you sure you do not want me to email your emergency contact?"* |
| **Call** | *"Would you like to call your emergency contact?"* |
| **Email sent** | *"Your email alert has been submitted."* |
| **Email failed** | *"I could not confirm that your email alert was sent."* |
| **Call handoff** | *"Confirm the call on your iPhone."* |

The voice is not decoration — it is the primary interface for someone who may be on the ground, disoriented, unable to look at a screen. The wearer's spoken response is transcribed, classified (fine / not fine / no response), and drives the next step. Two unanswered prompts trigger an automatic email alert.

Audio is generated once per voice+model+language combination and cached in server RAM, so subsequent falls get instant playback with no API latency. Credentials stay on Modal and never reach the phone.

---

## Modal Side Track — Serverless Fall Analysis

> **Junction 2026 Modal Side Track submission**

The entire backend runs on [Modal](https://modal.com) as a single serverless application (`fall-detection-backend`). Modal is not just hosting — it is what makes a 48-hour hackathon backend production-capable.

### What Modal provides

- **`modal.Image`** builds a reproducible container with Python 3.12, OpenCV, FastAPI, Anthropic and all dependencies — one declaration, no Dockerfile.
- **`modal.asgi_app`** serves the FastAPI application with `@modal.concurrent(max_inputs=20)`, handling multiple simultaneous fall events without managing servers.
- **`modal.Dict`** provides two persistent distributed dictionaries:
  - `fall-events`: stores event state across the entire escalation pipeline (detection → check-in → consent → alert)
  - `fall-email-deliveries`: atomic email claim tracking that prevents duplicate SMTP sends after ambiguous acknowledgements
- **`modal.Secret`** manages three secret groups (`fall-secrets`, `email-sending`, `elevenlabs-voice`) — API keys never appear in code or environment files.
- **GitHub Actions auto-deploy**: every push to `main` that touches `backend/**` triggers `modal deploy`, with a post-deploy health check against the live endpoint.

### The request flow

1. iPhone sends up to 7 JPEGs as multipart form data to `POST /analyze`
2. Modal decodes frames, measures quality (brightness, sharpness, contrast), blurs faces with OpenCV
3. All decodable frames go to Claude in one multi-image request — chronological order preserved
4. Claude returns a structured verdict (fall yes/no, confidence 0–1, reason in ≤12 words)
5. If positive, ElevenLabs voice check-in begins through `GET /check-in/prompt`
6. Spoken responses come back via `POST /event/{id}/check-in` with transcript and consent tracking
7. Email alerts go through Gmail SMTP with atomic delivery claims

Modal's serverless model means the backend scales to zero when nobody is falling and spins up in seconds when they are. For a safety application, that cold-start time is acceptable because the local detector and camera capture run on the phone — the server is only called after evidence is collected.

---

## Codex Side Track — AI-Assisted Development

> **Junction 2026 Codex Side Track submission**

All four team members used Codex throughout the 48-hour build. It was not a nice-to-have — it was how a team of four shipped a multi-platform system in two days.

### How we used it

- **Idea filtering**: we started with 10+ concepts and used Codex to rapidly evaluate feasibility, market size, existing solutions, and technical risk for each. It helped us converge on fall detection within the first hour.
- **Market justification**: Codex helped us research fall statistics, existing products (Apple Watch, Abeye), their failure modes, and the regulatory landscape (EU Cyber Resilience Act timelines) — grounding our pitch in real data.
- **Architecture design**: we described the system we wanted and iterated on the escalation pipeline design, API contracts, and state machine before writing code.
- **Debugging and integration**: when the iOS app, the Modal backend, the glasses UI and the companion app needed to talk to each other, Codex helped debug cross-platform issues in real time — Swift ↔ Python ↔ React ↔ vanilla JS.
- **Supply chain tooling**: the entire CRACI integration — SBOM fetching scripts, trust panel builder, backend pin checker, vulnerability auto-fixer — was built with Codex, turning CycloneDX specs and API docs into working code.
- **Test generation**: the 18 unit tests and 100+ Puppeteer integration assertions were written with Codex, catching real regressions (like a teammate's contact-editor refactor breaking the trust panel tests).

Codex was the force multiplier that let four people build what would normally take a team of eight a week.

---

## Folder structure (this branch)

```
app/
├── ios/                  Xcode project and SwiftUI application
├── packages/
│   └── DetectionEngine/  Local fall detector, camera capture, Modal transport, tests
├── contracts/            Phone ↔ server integration contract
└── tools/                Model verification, credential provisioning, log tools
backend/
├── fall_server.py        Modal/FastAPI server (detection, vision, check-in, alerts)
├── eval_images.py        Claude model comparison tool
└── tests/                Backend unit tests
ios/                      Standalone Swift backend-client examples
```

---

## Quick start

### Backend

```sh
pip install modal
modal setup
modal serve backend/fall_server.py        # dev (hot reload)
modal deploy backend/fall_server.py       # production
```

Configure `fall-secrets` in Modal with `ANTHROPIC_API_KEY` and `API_KEY`. Optional: `email-sending` secret for Gmail alerts, `elevenlabs-voice` for spoken check-ins.

### iPhone app

```sh
cp app/ios/Configuration/Signing.example.xcconfig app/ios/Configuration/Signing.local.xcconfig
cp app/ios/Configuration/Modal.example.xcconfig   app/ios/Configuration/Modal.local.xcconfig
open app/ios/FallApp.xcodeproj
```

Requires Xcode with Swift 6, an iPhone on iOS 17.2+, and Meta DAT SDK 1.0.1 with paired glasses.

### Glasses display

```sh
cd glasses-ui && npm install && npm run dev
```

Open `http://localhost:5173/?mode=glasses` with the [Meta Ray-Ban Display Simulator](https://chromewebstore.google.com/detail/meta-ray-ban-display-simu/jpjlmmodokemlepklkdbimceggpbjcll) Chrome extension.

### Companion app (Safy)

The companion app on the [`mobile-app`](../../tree/mobile-app) branch is a static HTML file. Open `index.html` in any browser or serve it locally.

---

## CI / CD

| Workflow | Branch | What it does |
|----------|--------|-------------|
| **Deploy server to Modal** | `main` | Auto-deploys `backend/fall_server.py` on push. Requires `MODAL_TOKEN_ID` and `MODAL_TOKEN_SECRET` secrets. |
| **Supply chain evidence** | `craci` | Runs 7 jobs: 5 CRACI SBOM builds, AI vulnerability auto-fixer, and trust-panel verification. |

---

## Team

**DaVinci's Coding** — built at **Junction 2026** in Espoo, Finland. 48 hours, four people, one mission: move the centre of gravity from *detecting* falls to *understanding* them.

| Name | Focus |
|------|-------|
| **Lorenzo** | iOS app, glasses integration, backend pipeline, spoken check-in flow |
| **Eddicpp** | Backend server, Claude vision, frame selection, Safy UI |
| **Sergio** | Glasses lens display, Meta DAT toolkit |
| **Yaniv** | Supply chain (CRACI), glasses display UI, Trust panel & UI, companion app, evaluation |

---

## License

Junction 2026 hackathon project.
