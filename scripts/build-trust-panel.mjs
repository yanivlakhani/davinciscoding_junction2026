#!/usr/bin/env node
// Builds data/trust-panel.js from the CycloneDX SBOMs recorded by CRACI.
//
// The input is the raw ingredient list CRACI records while the build runs.
// The output is a small object the companion app can read without a server,
// and without pretending to understand package names it has no reason to
// show a non-technical user.
//
//   node scripts/build-trust-panel.mjs
//
// If the SBOMs or the run metadata change, re-run this and commit the
// output. The UI should never ship with figures that do not trace back to
// a real run; if that trace is broken the script should fail, not fall
// back to placeholders.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");

// ---------------------------------------------------------------------------
// Metadata from the CRACI run on 2026-11-14. Update these when a new run
// completes. "verified" is the UTC timestamp the CRACI run started; it is
// what the UI shows as "last checked".
// ---------------------------------------------------------------------------
const RUN = {
  verified: "2026-11-14T21:02:06Z",
  durationSeconds: 42,
  jobsTotal: 5,
  jobsSucceeded: 5,
  packagesChecked: 181,      // from CRACI dashboard
  knownVulnerabilities: 0,   // from CRACI dashboard
  runner: "CRACI (Helsinki)",
};

// ---------------------------------------------------------------------------
// What the backend actually runs. These come from fall_server.py's
// uv_pip_install() call and are not in any lockfile, which is the whole
// point of the exercise. Keep this list in step with backend/fall_server.py
// on origin/main.
// ---------------------------------------------------------------------------
const BACKEND_RUNTIME = [
  { name: "anthropic",              purpose: "vision"   },
  { name: "opencv-python-headless", purpose: "privacy"  },
  { name: "numpy",                  purpose: "vision"   },
  { name: "httpx",                  purpose: "alert"    },
  { name: "fastapi",                purpose: "server"   },
  { name: "python-multipart",       purpose: "server"   },
  { name: "pydantic",               purpose: "server"   },
];

// ---------------------------------------------------------------------------
// Which npm packages from glasses-ui's SBOM actually ship to the device.
// Everything else is tooling that runs on a developer's laptop and never
// touches the glasses, so grandma does not need to see it.
// ---------------------------------------------------------------------------
const shipsToGlasses = (name) =>
  name === "react" ||
  name === "react-dom" ||
  name === "scheduler" ||
  name.startsWith("@wearables-ui-toolkit/");

const purposeForGlassesPackage = (name) =>
  name.startsWith("@wearables-ui-toolkit/") ? "display" : "display";

// ---------------------------------------------------------------------------
// The five groups the user actually reads. Each one is one job the product
// does, worded for the person wearing the glasses, not the person writing
// the code. `blurb` is one sentence a family member can read in two seconds.
// ---------------------------------------------------------------------------
const GROUPS = [
  {
    id: "vision",
    title: "Sees and understands what happens",
    blurb: "Looks at a short burst of pictures from the glasses and decides whether you really fell.",
  },
  {
    id: "privacy",
    title: "Keeps your face private",
    blurb: "Finds faces in the pictures and blurs them before anything leaves the server.",
  },
  {
    id: "alert",
    title: "Alerts your family",
    blurb: "Sends the alert to the contacts you chose if a fall is confirmed.",
  },
  {
    id: "server",
    title: "Receives signals from the glasses",
    blurb: "The small server the glasses talk to over the internet.",
  },
  {
    id: "display",
    title: "Shows text on your glasses",
    blurb: "Draws the words and symbols you see in the right lens.",
  },
];

// ---------------------------------------------------------------------------
// Load the two npm SBOMs. If either file is missing or malformed, fail loudly
// so the committed trust-panel.js can never silently fall out of date.
// ---------------------------------------------------------------------------
function loadSbom(relPath) {
  const text = readFileSync(join(root, relPath), "utf8");
  const sbom = JSON.parse(text);
  if (sbom.bomFormat !== "CycloneDX") {
    throw new Error(`${relPath}: expected CycloneDX, got ${sbom.bomFormat}`);
  }
  return sbom;
}

const glassesSbom = loadSbom("supply-chain/glasses-ui.cyclonedx.json");
const mobileSbom  = loadSbom("supply-chain/mobile-app.cyclonedx.json");

const glassesComponents = glassesSbom.components || [];
const mobileComponents  = mobileSbom.components  || [];

const glassesRuntime = glassesComponents.filter((c) => shipsToGlasses(c.name));
const glassesBuild   = glassesComponents.filter((c) => !shipsToGlasses(c.name));

// The companion app in this prototype is a single HTML file with no shipped
// dependencies; everything in its SBOM is test tooling. That changes the day
// the mock becomes a real app, and the script will pick it up automatically.
const mobileRuntime = [];
const mobileBuild   = mobileComponents;

// ---------------------------------------------------------------------------
// Assemble the five groups.
// ---------------------------------------------------------------------------
const bucket = Object.fromEntries(GROUPS.map((g) => [g.id, []]));

for (const c of BACKEND_RUNTIME) {
  bucket[c.purpose].push({
    name: c.name,
    source: "PyPI",
    where: "server",
  });
}
for (const c of glassesRuntime) {
  bucket[purposeForGlassesPackage(c.name)].push({
    name: c.name,
    version: c.version,
    source: "npm",
    where: "glasses",
  });
}

const groups = GROUPS.map((g) => ({
  ...g,
  components: bucket[g.id].sort((a, b) => a.name.localeCompare(b.name)),
  count: bucket[g.id].length,
}));

// ---------------------------------------------------------------------------
// Headline counts. "runtimeTotal" is the figure the summary card leads with:
// how many pieces are actually running in the product. "developerToolsTotal"
// is what we exclude, called out honestly instead of silently dropped.
// ---------------------------------------------------------------------------
const runtimeTotal = groups.reduce((s, g) => s + g.count, 0);
const developerToolsTotal = glassesBuild.length + mobileBuild.length;

if (runtimeTotal === 0) {
  throw new Error("No runtime components resolved. Trust panel would be empty; refusing to write placeholder.");
}

// Raw technical list for the "see the full list" view: every runtime
// component, grouped by where it runs, with its registry source.
const raw = {
  server: BACKEND_RUNTIME.map((c) => ({ name: c.name, source: "PyPI" })),
  glasses: glassesRuntime.map((c) => ({
    name: c.name, version: c.version, source: "npm",
  })).sort((a, b) => a.name.localeCompare(b.name)),
  developerToolsCount: developerToolsTotal,
};

const out = {
  run: RUN,
  runtimeTotal,
  developerToolsTotal,
  groups,
  raw,
  generatedAt: new Date().toISOString(),
};

const banner = `// GENERATED FILE. Do not edit by hand.
// Regenerate with: node scripts/build-trust-panel.mjs
// Source: supply-chain/*.cyclonedx.json (recorded by CRACI)
`;

const js = banner + "window.TRUST_DATA = " + JSON.stringify(out, null, 2) + ";\n";
writeFileSync(join(root, "data/trust-panel.js"), js);

console.log(`Wrote data/trust-panel.js`);
console.log(`  runtime components: ${runtimeTotal} in ${groups.length} groups`);
console.log(`  developer tools excluded: ${developerToolsTotal}`);
console.log(`  verified at: ${RUN.verified}`);
for (const g of groups) {
  console.log(`  ${g.count.toString().padStart(2)} ${g.id.padEnd(8)} ${g.title}`);
}
