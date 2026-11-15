# Supply Chain Evidence — Safy (Junction 2026 CRACI Side Track)

Safy is a fall-detection system for Meta smart glasses. A consumer safety device has to answer two questions: *does it work?* and *can you prove what is inside it?* This directory answers the second one — and defends it automatically.

Builds run on [CRACI](https://craci.com) runners. The workflow is [`.github/workflows/supply-chain.yml`](../.github/workflows/supply-chain.yml).

## What we built

**7 CI jobs** run on every push to `craci`:

| Job | What it does |
|-----|-------------|
| `backend` | Installs all 65 pinned Python packages with `--require-hashes`. Fails if `fall_server.py` declarations drift from the pins. |
| `glasses-ui` | `npm ci` + build of the right-lens React app. CRACI records the 28 packages actually fetched (lockfile lists 79 — the other 51 are other-platform binaries never downloaded). |
| `mobile-app` | `npm ci` for the companion app. |
| `policy-strict` | Same companion app under `default: deny` — only npm and GitHub allowed. CRACI blocks Puppeteer's 330 MB Chrome download with HTTP 403. |
| `policy-reviewed` | Same app with `storage.googleapis.com` explicitly allowed. Chrome arrives. |
| **`vuln-autofix`** | **AI auto-fixer.** Pulls every CRACI SBOM from this run via the API, queries OSV for known vulnerabilities, checks network traces for policy violations, and — if anything is found — asks Claude to generate a remediation plan and opens a GitHub issue with the fix. |
| `trust-panel` | Verifies the companion app's user-facing Trust panel matches the CRACI evidence. |

### The pipeline

```
CRACI runner builds the project
        ↓
CRACI records a CycloneDX 1.7 SBOM per job (from what was actually fetched)
        ↓
vuln-autofix pulls every SBOM via the CRACI API
        ↓
OSV batch query: are any of these packages vulnerable?
        ↓
   YES → Claude reads the SBOM + vulnerability data → generates fix → opens GitHub issue
   NO  → "All clear — supply chain is clean for this build"
        ↓
Trust panel shows the result to the person wearing the glasses
```

## What we found

### 1. The invisible 330 MB download

`puppeteer@25.17.0` has a postinstall hook that downloads Chrome binaries from `storage.googleapis.com`. Neither binary appears in the lockfile, the SBOM, or any manifest. The only record is CRACI's network trace.

Under strict policy, CRACI blocks the download — but `npm ci` still exits 0. The install looks green whether 330 MB of executable code arrived or not. Each job verifies the binary's presence on disk rather than trusting the exit code.

### 2. Zero-component backend

The backend declares its dependencies as Python function arguments (`uv_pip_install(...)`) — no `requirements.txt`, no lockfile. A manifest scanner finds **0 components**. CRACI recorded all **65 packages** with exact hashes.

### 3. Platform ghost packages

The glasses UI lockfile lists 79 packages. CRACI recorded 28 actually being downloaded — the other 51 are binaries for other operating systems that `npm ci` never fetches on Linux x64.

## AI auto-fixer

The `vuln-autofix` job (`supply-chain/vuln-autofix.mjs`) runs after every build:

1. **Fetches SBOMs** from the CRACI API for every CRACI job in the run
2. **Extracts purls** from every component CRACI recorded
3. **Batch-queries OSV** for known vulnerabilities across all packages
4. **Checks network traces** for policy violations
5. **Calls Claude** with the exact vulnerable packages, their versions, and available fixes
6. **Opens a GitHub issue** with a structured remediation plan

The AI fix is grounded in the actual build data — not a lockfile, not a guess. Claude sees exactly what CRACI saw installed, and generates fixes against that reality.

If no vulnerabilities are found, the job reports a clean bill of health. If ANTHROPIC_API_KEY is not configured, it still scans and reports — just without the AI fix.

## Trust panel — a nutrition label for a safety device

The companion app translates CycloneDX SBOMs into plain language for the person wearing the glasses:

- **5 purpose groups**: "Sees and understands what happens", "Keeps your face private", "Alerts your family", "Receives signals from the glasses", "Shows text on your glasses"
- Every component carries a **Verified** tick backed by CRACI's per-job SBOM
- Dashboard: 183 packages checked, 5/5 CRACI jobs, 0 known safety issues

The CRA doesn't require publishing an SBOM to users. We did it anyway — a safety device worn on someone's face should be able to explain itself.

### How ticks work

A component is ticked only if CRACI's SBOM for that job contains it at the locked version. The data is built by `fetch-craci-sboms.mjs` (downloads SBOMs via CRACI API) → `build-trust-panel.mjs --strict` (refuses to emit anything without full CRACI backing). 18 unit tests and 100+ headless integration assertions verify the panel.

## Backend dependency pinning

| File | Purpose |
|------|---------|
| `backend-requirements.in` | The 7 declarations copied from `fall_server.py` |
| `backend-requirements.txt` | All 65 resolved packages, pinned with hashes |
| `check_backend_pins.py` | Fails if the pins drift from the code |

The backend CI job installs with `--require-hashes` — pip refuses any file not in the lock. Adding a library to the server fails CI until pins are regenerated:

```sh
uv pip compile supply-chain/backend-requirements.in \
  --python-version 3.12 --python-platform x86_64-unknown-linux-gnu \
  --generate-hashes -o supply-chain/backend-requirements.txt
```

## Reproducing the lockfile-only view

`./supply-chain/baseline-sbom.sh` generates SBOMs from lockfiles alone — the conventional approach. Compare its output against what CRACI records. The delta is the point.

## Roadmap

- **iOS client**: depends on Meta DAT SDK 1.0.1 via Swift Package Manager. Joins the pipeline once CRACI ships macOS runners.
- **Deploy from pins**: point `fall_server.py` at the pinned lockfile so the deployed image matches the CRACI record exactly.
