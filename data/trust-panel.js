// GENERATED FILE. Do not edit by hand.
// Regenerate with: node scripts/build-trust-panel.mjs
// Source: supply-chain/*.cyclonedx.json (recorded by CRACI)
window.TRUST_DATA = {
  "run": {
    "verified": "2026-11-14T21:02:06Z",
    "durationSeconds": 42,
    "jobsTotal": 5,
    "jobsSucceeded": 5,
    "packagesChecked": 181,
    "knownVulnerabilities": 0,
    "runner": "CRACI (Helsinki)"
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
          "source": "PyPI",
          "where": "server"
        },
        {
          "name": "numpy",
          "source": "PyPI",
          "where": "server"
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
          "source": "PyPI",
          "where": "server"
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
          "source": "PyPI",
          "where": "server"
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
          "source": "PyPI",
          "where": "server"
        },
        {
          "name": "pydantic",
          "source": "PyPI",
          "where": "server"
        },
        {
          "name": "python-multipart",
          "source": "PyPI",
          "where": "server"
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
          "where": "glasses"
        },
        {
          "name": "@wearables-ui-toolkit/foundation",
          "version": "130.33.0",
          "source": "npm",
          "where": "glasses"
        },
        {
          "name": "@wearables-ui-toolkit/icons",
          "version": "130.33.0",
          "source": "npm",
          "where": "glasses"
        },
        {
          "name": "@wearables-ui-toolkit/mrbd",
          "version": "130.33.0",
          "source": "npm",
          "where": "glasses"
        },
        {
          "name": "react",
          "version": "19.3.1",
          "source": "npm",
          "where": "glasses"
        },
        {
          "name": "react-dom",
          "version": "19.3.1",
          "source": "npm",
          "where": "glasses"
        },
        {
          "name": "scheduler",
          "version": "0.28.0",
          "source": "npm",
          "where": "glasses"
        }
      ],
      "count": 7
    }
  ],
  "raw": {
    "server": [
      {
        "name": "anthropic",
        "source": "PyPI"
      },
      {
        "name": "opencv-python-headless",
        "source": "PyPI"
      },
      {
        "name": "numpy",
        "source": "PyPI"
      },
      {
        "name": "httpx",
        "source": "PyPI"
      },
      {
        "name": "fastapi",
        "source": "PyPI"
      },
      {
        "name": "python-multipart",
        "source": "PyPI"
      },
      {
        "name": "pydantic",
        "source": "PyPI"
      }
    ],
    "glasses": [
      {
        "name": "@wearables-ui-toolkit/androidx-shapes",
        "version": "130.33.0",
        "source": "npm"
      },
      {
        "name": "@wearables-ui-toolkit/foundation",
        "version": "130.33.0",
        "source": "npm"
      },
      {
        "name": "@wearables-ui-toolkit/icons",
        "version": "130.33.0",
        "source": "npm"
      },
      {
        "name": "@wearables-ui-toolkit/mrbd",
        "version": "130.33.0",
        "source": "npm"
      },
      {
        "name": "react",
        "version": "19.3.1",
        "source": "npm"
      },
      {
        "name": "react-dom",
        "version": "19.3.1",
        "source": "npm"
      },
      {
        "name": "scheduler",
        "version": "0.28.0",
        "source": "npm"
      }
    ],
    "developerToolsCount": 98
  },
  "generatedAt": "2026-11-14T21:59:11.887Z"
};
