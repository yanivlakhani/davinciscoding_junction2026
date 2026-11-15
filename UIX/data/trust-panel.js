// GENERATED FILE. Do not edit by hand.
// Regenerate with: node scripts/build-trust-panel.mjs
// Component list: supply-chain/*.cyclonedx.json and supply-chain/backend-declared.txt
// Ticks: supply-chain/craci/*.cdx.json (downloaded from CRACI)
window.TRUST_DATA = {
  "run": {
    "verified": "2026-11-15T00:33:39Z",
    "durationSeconds": 49,
    "jobsTotal": 5,
    "jobsSucceeded": 5,
    "packagesChecked": 183,
    "knownVulnerabilities": 0,
    "runner": "CRACI (Helsinki)"
  },
  "evidence": {
    "source": "craci",
    "basis": "Each tick means CRACI recorded this component being fetched during the build, and the run reported no known vulnerabilities.",
    "run": {
      "id": "43658777059",
      "url": "https://github.com/yanivlakhani/davinciscoding_junction2026/actions/runs/43658777059",
      "commit": "e61b995b5ac297cf57120331eaa125a0e08a25d2",
      "startedAt": "2026-11-15T00:33:39Z",
      "fetchedAt": "2026-11-15T00:51:08.312Z"
    },
    "componentsRecorded": {
      "backend": 69,
      "glasses-ui": 30,
      "mobile-app": 28,
      "policy-strict": 28,
      "policy-reviewed": 28
    },
    "vulnerabilities": {
      "known": 0,
      "source": "CRACI dashboard, read by hand; CRACI's API does not expose this figure",
      "readForRunStartedAt": "2026-11-15T00:33:39Z"
    },
    "verified": 14,
    "of": 14
  },
  "runtimeTotal": 14,
  "developerToolsTotal": 98,
  "groups": [
    {
      "id": "vision",
      "title": "Sees and understands what happens",
      "blurb": "Looks at a short burst of pictures from the glasses and decides whether you really fell.",
      "components": [
        {
          "name": "anthropic",
          "version": "2.8.0",
          "source": "PyPI",
          "where": "server",
          "verified": true
        },
        {
          "name": "numpy",
          "version": "2.5.4",
          "source": "PyPI",
          "where": "server",
          "verified": true
        }
      ],
      "count": 2
    },
    {
      "id": "privacy",
      "title": "Keeps your face private",
      "blurb": "Finds faces in the pictures and blurs them before anything leaves the server.",
      "components": [
        {
          "name": "opencv-python-headless",
          "version": "4.14.0.94",
          "source": "PyPI",
          "where": "server",
          "verified": true
        }
      ],
      "count": 1
    },
    {
      "id": "alert",
      "title": "Alerts your family",
      "blurb": "Sends the alert to the contacts you chose if a fall is confirmed.",
      "components": [
        {
          "name": "httpx",
          "version": "0.28.1",
          "source": "PyPI",
          "where": "server",
          "verified": true
        }
      ],
      "count": 1
    },
    {
      "id": "server",
      "title": "Receives signals from the glasses",
      "blurb": "The small server the glasses talk to over the internet.",
      "components": [
        {
          "name": "fastapi",
          "version": "0.163.0",
          "source": "PyPI",
          "where": "server",
          "verified": true
        },
        {
          "name": "pydantic",
          "version": "2.14.3",
          "source": "PyPI",
          "where": "server",
          "verified": true
        },
        {
          "name": "python-multipart",
          "version": "0.0.33",
          "source": "PyPI",
          "where": "server",
          "verified": true
        }
      ],
      "count": 3
    },
    {
      "id": "display",
      "title": "Shows text on your glasses",
      "blurb": "Draws the words and symbols you see in the right lens.",
      "components": [
        {
          "name": "@wearables-ui-toolkit/androidx-shapes",
          "version": "130.33.0",
          "source": "npm",
          "where": "glasses",
          "verified": true
        },
        {
          "name": "@wearables-ui-toolkit/foundation",
          "version": "130.33.0",
          "source": "npm",
          "where": "glasses",
          "verified": true
        },
        {
          "name": "@wearables-ui-toolkit/icons",
          "version": "130.33.0",
          "source": "npm",
          "where": "glasses",
          "verified": true
        },
        {
          "name": "@wearables-ui-toolkit/mrbd",
          "version": "130.33.0",
          "source": "npm",
          "where": "glasses",
          "verified": true
        },
        {
          "name": "react",
          "version": "19.3.1",
          "source": "npm",
          "where": "glasses",
          "verified": true
        },
        {
          "name": "react-dom",
          "version": "19.3.1",
          "source": "npm",
          "where": "glasses",
          "verified": true
        },
        {
          "name": "scheduler",
          "version": "0.28.0",
          "source": "npm",
          "where": "glasses",
          "verified": true
        }
      ],
      "count": 7
    }
  ],
  "raw": {
    "server": [
      {
        "name": "anthropic",
        "version": "2.8.0",
        "source": "PyPI",
        "verified": true
      },
      {
        "name": "opencv-python-headless",
        "version": "4.14.0.94",
        "source": "PyPI",
        "verified": true
      },
      {
        "name": "numpy",
        "version": "2.5.4",
        "source": "PyPI",
        "verified": true
      },
      {
        "name": "httpx",
        "version": "0.28.1",
        "source": "PyPI",
        "verified": true
      },
      {
        "name": "fastapi",
        "version": "0.163.0",
        "source": "PyPI",
        "verified": true
      },
      {
        "name": "python-multipart",
        "version": "0.0.33",
        "source": "PyPI",
        "verified": true
      },
      {
        "name": "pydantic",
        "version": "2.14.3",
        "source": "PyPI",
        "verified": true
      }
    ],
    "glasses": [
      {
        "name": "@wearables-ui-toolkit/androidx-shapes",
        "version": "130.33.0",
        "source": "npm",
        "verified": true
      },
      {
        "name": "@wearables-ui-toolkit/foundation",
        "version": "130.33.0",
        "source": "npm",
        "verified": true
      },
      {
        "name": "@wearables-ui-toolkit/icons",
        "version": "130.33.0",
        "source": "npm",
        "verified": true
      },
      {
        "name": "@wearables-ui-toolkit/mrbd",
        "version": "130.33.0",
        "source": "npm",
        "verified": true
      },
      {
        "name": "react",
        "version": "19.3.1",
        "source": "npm",
        "verified": true
      },
      {
        "name": "react-dom",
        "version": "19.3.1",
        "source": "npm",
        "verified": true
      },
      {
        "name": "scheduler",
        "version": "0.28.0",
        "source": "npm",
        "verified": true
      }
    ],
    "developerToolsCount": 98
  },
  "generatedAt": "2026-11-15T01:02:24.347Z"
};
