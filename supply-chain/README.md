# Supply chain evidence

This project is a fall-detection system for Meta smart glasses: the glasses
capture a burst of frames, a Modal-hosted server judges whether a fall
happened, and a companion app alerts the wearer's emergency contacts.

That makes it a consumer safety device, and the question a safety device has
to be able to answer is not only "does it work" but "can you prove what is
inside it". This directory is the answer to the second question.

Builds run on [CRACI](https://craci.com) runners, which record an SBOM from
the build itself rather than from a manifest file. The workflow is
[`.github/workflows/supply-chain.yml`](../.github/workflows/supply-chain.yml).

## Why this product is in scope

The EU Cyber Resilience Act applies to products with digital elements placed
on the EU market. It reaches this project on three counts:

- The glasses UI and companion app are software with a data connection.
- The Modal backend is a *remote data processing solution* under Article 3:
  the product cannot perform its function without it, because the fall is
  only confirmed server-side.
- We integrate third-party components we did not write — Meta's Wearables
  DAT SDK, Anthropic's API, OpenCV, FastAPI — and Article 13 requires a
  manufacturer to exercise due diligence on exactly those.

The obligation that matters here is Annex I, Part II, point (1): identify and
document vulnerabilities and components, *"including by drawing up a software
bill of materials in a commonly used and machine-readable format covering at
the very least the top-level dependencies"*.

Two things about that are commonly overstated and worth stating correctly.
The legal floor is top-level dependencies, not the full transitive tree. And
the SBOM is not published to users: it lives in the technical documentation
and goes to a market surveillance authority on reasoned request, under
Article 31 and Annex VII point 8.

On timing, Annex I applies from **11 December 2027**. The Article 14
reporting duties — 24 hours for an early warning, 72 hours for the main
notification — have already applied since **11 September 2026**. A product
being designed now is being designed into the regime, not before it.

## The three supply chains

| Component | Branch | Ecosystem | Declared where | Lockfile SBOM |
| --- | --- | --- | --- | --- |
| Backend | `main` | PyPI | Arguments to `uv_pip_install()` **in the Python source** | 0 components |
| Glasses UI | `glasses-ui` | npm | `package-lock.json` | 79 components |
| Companion app | `mobile-app` | npm | `package-lock.json` | 26 components |

The backend row is the interesting one. Modal builds its container image
from a call inside the application file:

```python
modal.Image.debian_slim(python_version="3.12").uv_pip_install(
    "fastapi[standard]", "python-multipart", "opencv-python-headless<5",
    "numpy", "pydantic", "httpx", "anthropic",
)
```

There is no `requirements.txt` and no lockfile. A tool that reads manifests
finds **zero** dependencies for the component that handles photographs of
people who have fallen. A recording made during the build finds all seven
plus their transitive tree, which is the whole argument for build-time
SBOMs rather than manifest parsing.

### Pinning what the code declares

Seven names in a function call are not a record of what ships. Resolved for
Python 3.12 on Linux, which is what both the Modal image and the CRACI
runner use, those seven declarations become **65 packages**. Three files
in this directory hold that down:

| File | What it is |
| --- | --- |
| `backend-requirements.in` | The seven declarations, copied out of `fall_server.py` |
| `backend-requirements.txt` | All 65 packages they resolve to, each pinned to one version with the hashes of its files |
| `check_backend_pins.py` | Reads the declarations back out of `fall_server.py` and fails if either file has drifted from the code |

The backend job checks out `main` at its current commit, runs the check,
and then installs from the pinned file with `--require-hashes`, so pip
refuses any file whose hash is not in the lock and any package the lock
does not name. If someone adds a library to the server, the job fails
until the pins are regenerated; the copy cannot quietly become fiction.
Nothing is pushed to `main`, so the Modal deploy is never triggered.

To regenerate after the server's dependencies change:

```
uv pip compile supply-chain/backend-requirements.in \
  --python-version 3.12 --python-platform x86_64-unknown-linux-gnu \
  --generate-hashes -o supply-chain/backend-requirements.txt
```

What this does **not** do: it does not change what Modal installs. The
deployed image is still built from the unpinned call in `fall_server.py`,
so it gets whatever versions are newest on the day it is built, and those
can differ from the pins here. The pins make the CRACI record reproducible
and reviewable; closing the gap fully means having `fall_server.py` install
from this file, which is a change to the product and belongs on `main`.

## What we found

`mobile-app` depends on `puppeteer@25.17.0`, which declares:

```json
"scripts": { "postinstall": "node install.mjs" }
```

That hook downloads a Chrome binary — roughly 150 MB of executable code —
from `storage.googleapis.com`. There are 27 packages in that lockfile and the
binary is none of them, so the generated SBOM lists 26 components, says
`puppeteer`, and stops. The largest single artifact entering the build is
invisible to it.

The workflow demonstrates this with two jobs that differ only in policy:

- `undeclared-fetch-blocked` allows the `npm` and `github` presets only. The
  Chrome download matches no rule, the job fails closed, and CRACI reports
  the violation. **This job is expected to fail; the failure is the result.**
- `undeclared-fetch-reviewed` names `storage.googleapis.com` explicitly in a
  `connections` rule, with a comment recording why it is acceptable, and
  passes.

The second job is what a reviewed dependency should look like: a named host
in version control with a reason attached, rather than a fetch nobody saw.

## Where the SBOM goes next: the companion app's Trust panel

The CRA does not require publishing the SBOM to users, and most teams
don't. For a device a vulnerable person wears all day, we think the
opposite is the more interesting move: take the ingredient list CRACI
records and show it to the person wearing the device, and to their family.

The companion app's `Trust` tab (`mobile-app` branch; `node shoot.mjs`
there regenerates screenshots) translates the CycloneDX SBOM into five human-worded
groups — "Sees and understands what happens", "Keeps your face private",
"Alerts your family", "Receives signals from the glasses", "Shows text on
your glasses" — with the real package names one tap away, each with a
"Verified" tick. A small translation script
(`mobile-app/scripts/build-trust-panel.mjs`) builds the panel's data and
refuses to emit placeholders; if the record is missing the panel says so.

The panel draws on two different things, and it matters which is which:

- **Which components are listed** comes from the lockfiles and from the
  server's declarations (`backend-declared.txt` on `mobile-app`, held to
  `fall_server.py` by the same check as above).
- **Which of them are ticked** is meant to come from CRACI's own record of
  the build. CRACI keeps one CycloneDX SBOM per job and serves it from its
  API. `mobile-app/scripts/fetch-craci-sboms.mjs` downloads the three
  product jobs' SBOMs into `mobile-app/supply-chain/craci/`, with the run
  ID, commit and a SHA-256 of each file as served. Once they are there, a
  component is ticked only if CRACI recorded it, at the locked version.

```
supply-chain.yml on CRACI runners
        |  one SBOM per job, held by CRACI
        v
mobile-app/scripts/fetch-craci-sboms.mjs      (needs a CRACI API token)
        v
mobile-app/supply-chain/craci/*.cdx.json + run.json
        v
mobile-app/scripts/build-trust-panel.mjs      (--strict: every tick backed)
        v
mobile-app/data/trust-panel.js  ->  Trust panel in the companion app
```

Until that download has been done, the script falls back to the lockfile
list and ticks every component on the strength of the run totals from the
CRACI dashboard (all jobs succeeded, no known vulnerabilities). The output
records which basis was used in its `evidence` field, and
`build-trust-panel.mjs --strict` fails on anything less than CRACI's
record. The vulnerability total itself is read off the dashboard by hand,
because the API does not expose it.

The workflow's `trust-panel` job keeps the app honest between downloads: it
fails if the app's backend list differs from what the server declares, or
if the committed `data/trust-panel.js` is not exactly what its inputs
produce.

This is the first SBOM we've seen pointed at the person wearing the
device, rather than at an auditor. The CRA angle is still there — the
record is the same one that would go to a market surveillance authority
on reasoned request — but the first audience is the family member who
wants to know what their mother's glasses are actually running.

## Reproducing the lockfile-only view

`./supply-chain/baseline-sbom.sh` regenerates `baseline/*.cyclonedx.json`
from lockfiles alone, which is what conventional tooling produces, and
prints the install-hook finding. It needs no CRACI account:

```
ok    glasses-ui — 79 components
ok    mobile-app — 26 components
ok    backend    — 0 components from manifests, 7 declared in source

  27 packages in package-lock.json
  puppeteer runs an install script that downloads a browser binary
  that binary is not one of the 27 packages above
```

Compare that against what the CRACI run records. The delta is the point.

## Not covered

The iOS client (`app/`) depends on Meta's Wearables DAT SDK 1.0.1 via Swift
Package Manager, pinned in `Package.resolved`. CRACI currently offers Linux
runners, with macOS on the roadmap, so that supply chain is not recorded
here. It is the one remaining gap in coverage and we would rather name it
than imply the picture is complete.

Equally, an SBOM is evidence, not conformity. The risk assessment, the
conformity assessment route and the declaration of conformity remain the
manufacturer's work. This covers the component and vulnerability
documentation, which is the part that can be automated.
