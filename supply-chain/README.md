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

| Component | Branch | Ecosystem | Declared where | Lockfile SBOM | CRACI recorded being fetched |
| --- | --- | --- | --- | --- | --- |
| Backend | `main` | PyPI | Arguments to `uv_pip_install()` **in the Python source** | 0 components | 65 packages |
| Glasses UI | `glasses-ui` | npm | `package-lock.json` | 79 components | 28 packages |
| Companion app | `mobile-app` | npm | `package-lock.json` | 26 components | 26 packages |

The last column is from the SBOMs CRACI recorded for run #4 of the
workflow, downloaded from its API into `mobile-app/supply-chain/craci/`.
A manifest-based SBOM is wrong in both directions here. It finds nothing
for the backend, where CRACI recorded 65 packages, exactly the 65 in the
pinned list below. And it lists 79 for the glasses UI, where only 28 were
downloaded: the other 51 are builds of the bundler, the TypeScript
compiler and the CSS tool for other operating systems and processors, and
their helpers, which `npm ci` never fetches on a Linux x64 runner. For the
companion app the two agree, package for package.

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

That hook downloads two browser builds from `storage.googleapis.com`:
Chrome for Testing and `chrome-headless-shell`, both at 157.0.8103.50. On
Linux the two archives come to about 330 MB (204 MB and 128 MB). There are
27 packages in that lockfile and neither browser is one of them, so the
generated SBOM lists 26 components, says `puppeteer`, and stops. The
largest things entering the build are invisible to it.

The workflow demonstrates this with two jobs that differ only in policy:

- `undeclared-fetch-blocked` allows the `npm` and `github` presets only.
  The browser downloads match no rule, so the connections are blocked.
- `undeclared-fetch-reviewed` names `storage.googleapis.com` explicitly in a
  `connections` rule, with a comment recording why it is acceptable.

**Blocking the download does not fail the install, and that is the second
half of the finding.** puppeteer's hook catches the failed download, prints
a warning and exits 0, so `npm ci` reports `added 27 packages` and succeeds
with no browser on disk. In the first three runs the install step was green
under both policies; the only visible difference was that it took 1–2
seconds under the strict policy and 11–16 seconds where the download is
allowed. The exit code, the lockfile and a lockfile SBOM are identical
whether 330 MB of executable code arrived or not.

So neither job relies on the install step's result. Each ends by asking
puppeteer where its browser should be and checking whether the file
exists: the strict job passes only if the browser is absent, the reviewed
job only if it is present. Both jobs are expected to pass.

The record of what happened is CRACI's network trace of each job, not the
build's exit status. For run #4 the three jobs that install the companion
app show this for `storage.googleapis.com`:

| Job | Policy | What CRACI's trace recorded |
| --- | --- | --- |
| Companion app | Everything allowed | Two `GET`s, both `200`: `chrome-linux64.zip`, 203,527,334 bytes, and `chrome-headless-shell-linux64.zip`, 128,166,087 bytes, each with its SHA-256 |
| Strict policy | npm and GitHub only | The same two `GET`s, both denied with `403`: *"request does not match an allowed proxy policy rule"* |
| Reviewed policy | npm, GitHub and the named host | Two connections allowed by the rule `passthrough-tls-storage.googleapis.com`, carrying 203.8 MB and 128.4 MB |

Those observations are copied unchanged into
[`chrome-download-trace.json`](chrome-download-trace.json), with the job
IDs they came from. Two things in them are worth knowing:

- The browsers are not in CRACI's SBOM either. The companion app job's
  SBOM lists the same 26 npm packages as the lockfile. The 330 MB shows up
  in the network trace, with a URL and a hash, and nowhere else.
- Allowing a host with a `tls` connection rule is a pass-through. CRACI
  then sees how many bytes moved but not which files, so the reviewed job
  records less about the download than the job with no policy at all.
  CRACI's documentation says as much about exempted destinations
  ([Debug network problems in jobs](https://docs.craci.com/guides/network-troubleshooting/)).

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
- **Which of them are ticked** comes from CRACI's own record of the build.
  CRACI keeps one CycloneDX SBOM per job and serves it from its API.
  `mobile-app/scripts/fetch-craci-sboms.mjs` downloads the SBOM of every
  CRACI job in a run into `mobile-app/supply-chain/craci/`, with the run
  ID, commit, job IDs and hashes in `run.json`. A component is ticked only
  if CRACI recorded it, at the locked version.

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

The record committed on `mobile-app` is from run #4. All 14 components the
panel lists are in it at the locked versions, so all 14 are ticked, and
the seven server packages are shown at the exact version CRACI saw
installed. The panel's other figures are worked out from the same files:
when the run started, how many CRACI jobs succeeded (5 of 5), and
"packages checked", which is the number of components summed over the five
jobs (183). That sum is how CRACI's dashboard counts: for run #1 the
dashboard showed 181, and that run's five SBOMs hold 30 + 28 + 67 + 28 + 28.

CRACI stamps a new serial number and timestamp on every download of an
SBOM, so a plain hash of the file never repeats. `run.json` therefore
carries a second hash, `contentSha256`, that leaves those two fields out;
it is the one to compare against a fresh download.

One figure is still read off the dashboard by hand: the run's known
vulnerability total. CRACI's API does not expose it, and its SBOMs carry
no `vulnerabilities` section. For run #4 the dashboard shows 0. The panel
data records which run that figure was read for, and
`build-trust-panel.mjs --strict` fails while that is not the run the SBOMs
came from.

Without the downloaded record the script falls back to the lockfile list
and ticks every component on the strength of the dashboard totals alone.
The output says which basis was used in its `evidence` field, and
`--strict` refuses the fallback.

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
