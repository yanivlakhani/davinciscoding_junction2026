# Safy — AI Safety Glasses

> **Junction 2026 · Meta AI Glasses Track · CRACI Side Track**

Every year, millions of elderly individuals suffer severe, life-threatening falls. The tech industry's answer so far has been a smartwatch or a plastic panic button on a lanyard around the neck. Both are failing.

**The stigma problem.** People forget or refuse to wear medical lanyards. They sit in a drawer.

**The physics problem.** The wrist is not your body's centre of gravity. Drop your phone off the couch and an Apple Watch might call an ambulance. But if you hit your head and your arm absorbs the impact, it registers nothing. The current market is plagued by false positives that waste emergency resources and false negatives that cost lives.

**The context problem.** Every existing detector — Apple Watch, Abeye smart glasses, wearable pendants — can only tell you *that* something happened. Not *what*. A family member gets a notification that says "a fall was detected" and has no idea whether their parent tripped on a rug or collapsed from a stroke.

The head is where we balance. The head is where we see. **Safy** moves safety from the wrist to the eyes.

We are **DaVinci's Coding**, and this is our project for **Junction 2026**.

### Moving the Centre of Gravity

The Junction 2026 theme is *"Moving the Centre of Gravity."* Ours does it in three ways:

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

All CI jobs run on [CRACI](https://craci.com) runners, which record a CycloneDX 1.7 SBOM from each build — not from a manifest file, but from what the runner actually downloads and installs.

| CRACI job | What it records | Key finding |
|-----------|----------------|-------------|
| `backend` | All 65 Python packages installed for `fall_server.py` | Manifest scanners find 0 components (no `requirements.txt`). CRACI finds all 65 with exact hashes. |
| `glasses-ui` | 28 npm packages downloaded on Linux x64 | The lockfile lists 79, but 51 are platform-specific and never actually installed. |
| `mobile-app` | npm packages for the companion app | `puppeteer` downloads ~330 MB of Chrome binaries via a postinstall hook — invisible to any lockfile. |
| `policy-strict` | Same companion app under `default: deny` | CRACI blocks the Chrome download with HTTP 403. Puppeteer catches the error and exits 0, but the binary is absent on disk. |
| `policy-reviewed` | Same app with `storage.googleapis.com` allowed | The Chrome binary arrives as expected. |

The backend's pinned dependency list (`supply-chain/backend-requirements.txt`) is checked by CI against what `fall_server.py` actually declares. If someone adds a library, the workflow fails until the pins are regenerated.

### The Trust panel — a nutrition label for a safety device

The companion app includes a user-facing **Trust panel** that translates raw CycloneDX SBOMs into plain language:

- **5 purpose groups** a non-technical person can understand: "Sees and understands what happens", "Keeps your face private", "Alerts your family", "Receives signals from the glasses", "Shows text on your glasses".
- Every component carries a **Verified** tick backed by CRACI's per-job SBOM artifacts.
- A live dashboard shows packages checked (183), CRACI jobs verified (5/5) and known safety issues (0).

The CRA does not require publishing an SBOM to users. We did it anyway, because a safety device worn on someone's face should be able to explain itself to the person wearing it.

### Verification

- **18 unit tests** validate strict SBOM verification, stale-file detection and purl normalization.
- **100+ headless integration assertions** test the full Trust panel and raw SBOM screen.
- CI workflow: [`.github/workflows/supply-chain.yml`](../../tree/craci/.github/workflows/supply-chain.yml)
- Full write-up: [`supply-chain/README.md`](../../tree/craci/supply-chain/README.md)

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
| **Supply chain evidence** | `craci` | Runs 6 CRACI jobs: backend, glasses-ui, mobile-app, strict policy, reviewed policy and trust-panel verification. |

---

## Team

**DaVinci's Coding** — built at **Junction 2026** in Espoo, Finland. 48 hours, four people, one mission: move the centre of gravity from *detecting* falls to *understanding* them.

| Name | Focus |
|------|-------|
| **Lorenzo** | iOS app, glasses integration, backend pipeline, spoken check-in flow |
| **Eddicpp** | Backend server, Claude vision, frame selection, Safy UI |
| **Sergio** | Glasses lens display, Meta DAT toolkit |
| **Yaniv** | Supply chain (CRACI), Trust panel, companion app, evaluation |

---

## License

Junction 2026 hackathon project.
