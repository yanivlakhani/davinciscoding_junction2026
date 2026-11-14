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
