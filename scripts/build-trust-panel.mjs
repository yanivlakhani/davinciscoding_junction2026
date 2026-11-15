#!/usr/bin/env node
// Builds data/trust-panel.js, the data behind the companion app's Trust panel.
//
//   node scripts/build-trust-panel.mjs            write data/trust-panel.js
//   node scripts/build-trust-panel.mjs --check    fail if the committed file is stale
//   node scripts/build-trust-panel.mjs --strict   fail unless every tick is backed
//                                                 by CRACI's own record
//
// Two kinds of input, and the difference matters:
//
//   supply-chain/*.cyclonedx.json   What the lockfiles say will be installed.
//                                   Decides WHICH components the panel lists.
//   supply-chain/craci/*.cdx.json   What CRACI recorded being fetched during
//                                   the build. Decides which of them get a
//                                   "Verified" tick.
//
// The second set is downloaded from CRACI by scripts/fetch-craci-sboms.mjs.
// When it is present a component is ticked only if CRACI recorded it. When
// it is absent the script falls back to the lockfile list plus the run
// totals, and says so in the output (evidence.source === "lockfile").
//
// The UI should never ship with figures that do not trace back to a real
// run; if that trace is broken the script fails rather than falling back to
// placeholders.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");

const flags = new Set(process.argv.slice(2));
const CHECK = flags.has("--check");
const STRICT = flags.has("--strict");
for (const f of flags) {
  if (f !== "--check" && f !== "--strict") {
    console.error(`Unknown option: ${f}`);
    process.exit(2);
  }
}

// ---------------------------------------------------------------------------
// The one figure CRACI's API does not expose is the run's known
// vulnerability total (its SBOMs carry no `vulnerabilities` section and
// there is no endpoint for it). It is read off the CRACI dashboard by hand,
// and this records which run it was read for. When the downloaded record
// is from a different run the build says so, and --strict fails, until
// someone looks at the dashboard for that run and updates this.
// ---------------------------------------------------------------------------
const DASHBOARD = {
  readForRunStartedAt: "2026-11-14T21:02:06Z",
  knownVulnerabilities: 0,
};

// The rest of that run's dashboard totals. Used only while CRACI's record
// has not been downloaded; once it has, the same figures are worked out
// from the record instead (see runFromRecord below). "verified" is the UTC
// time the run started, which the UI shows as "last checked".
const DASHBOARD_RUN = {
  verified: DASHBOARD.readForRunStartedAt,
  durationSeconds: 42,
  jobsTotal: 5,
  jobsSucceeded: 5,
  packagesChecked: 181,
  knownVulnerabilities: DASHBOARD.knownVulnerabilities,
  runner: "CRACI (Helsinki)",
};

// ---------------------------------------------------------------------------
// What the backend actually runs. The names are declared as arguments to
// uv_pip_install() inside backend/fall_server.py and are in no lockfile,
// which is the whole point of the exercise.
//
// supply-chain/backend-declared.txt is the list of those declarations. The
// supply-chain workflow on the `craci` branch checks it against
// fall_server.py on main, so it cannot drift unnoticed. This map adds the
// one thing a machine cannot know: what each package is FOR, in the words
// the panel uses. A declared package with no purpose here, or a purpose
// for a package that is no longer declared, stops the build.
// ---------------------------------------------------------------------------
const BACKEND_PURPOSE = {
  "anthropic":              "vision",
  "opencv-python-headless": "privacy",
  "numpy":                  "vision",
  "httpx":                  "alert",
  "fastapi":                "server",
  "python-multipart":       "server",
  "pydantic":               "server",
};

// PEP 503: PyPI treats runs of "-", "_" and "." as the same character and
// ignores case, so "Python_Multipart" and "python-multipart" are one package.
const pypiName = (name) => name.toLowerCase().replace(/[-_.]+/g, "-");

// "fastapi[standard]" -> "fastapi", "opencv-python-headless<5" -> the name.
const requirementName = (line) => pypiName(line.split(/[\[<>=!~;\s]/)[0]);

function loadBackendDeclared() {
  const rel = "supply-chain/backend-declared.txt";
  const names = readFileSync(join(root, rel), "utf8")
    .split("\n")
    .map((l) => l.replace(/#.*/, "").trim())
    .filter(Boolean)
    .map(requirementName);
  const declared = new Set(names);
  const mapped = new Set(Object.keys(BACKEND_PURPOSE).map(pypiName));
  const unmapped = [...declared].filter((n) => !mapped.has(n));
  const stale = [...mapped].filter((n) => !declared.has(n));
  if (unmapped.length || stale.length) {
    throw new Error(
      `${rel} and BACKEND_PURPOSE disagree.` +
      (unmapped.length ? `\n  declared but not given a purpose: ${unmapped.join(", ")}` : "") +
      (stale.length ? `\n  given a purpose but no longer declared: ${stale.join(", ")}` : "")
    );
  }
}
loadBackendDeclared();

const BACKEND_RUNTIME = Object.entries(BACKEND_PURPOSE).map(([name, purpose]) => ({ name, purpose }));

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

const purposeForGlassesPackage = () => "display";

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
const mobileBuild = mobileComponents;

// ---------------------------------------------------------------------------
// CRACI's own record of the build.
//
// scripts/fetch-craci-sboms.mjs downloads one CycloneDX file per job from
// CRACI's API, plus run.json describing the run they came from. Either the
// backend and glasses files are both there or neither is: half a record
// would tick some rows on evidence and others on trust, and nobody reading
// the panel could tell which.
// ---------------------------------------------------------------------------
const CRACI_DIR = "supply-chain/craci";
const CRACI_FILES = {
  backend: "backend.cdx.json",
  glasses: "glasses-ui.cdx.json",
  mobile: "mobile-app.cdx.json",
};

// Package URL -> { type, name, version }. A purl is the one identifier in a
// CycloneDX component that says which ecosystem a name belongs to, e.g.
// pkg:npm/%40wearables-ui-toolkit/mrbd@1.2.3 or pkg:pypi/fastapi@0.115.0.
function parsePurl(purl) {
  if (typeof purl !== "string" || !purl.startsWith("pkg:")) return null;
  const rest = purl.slice(4).split("#")[0].split("?")[0];
  const slash = rest.indexOf("/");
  if (slash < 1) return null;
  const type = rest.slice(0, slash).toLowerCase();
  let path = rest.slice(slash + 1);
  let version;
  const at = path.lastIndexOf("@");
  if (at > 0) {                       // at === 0 is an npm scope, not a version
    version = decodeURIComponent(path.slice(at + 1));
    path = path.slice(0, at);
  }
  const name = path.split("/").map(decodeURIComponent).join("/");
  return name ? { type, name, version } : null;
}

const recordKey = (type, name) =>
  type === "pypi" ? `pypi:${pypiName(name)}` : `${type}:${name.toLowerCase()}`;

// Index every component CRACI recorded, including nested ones, by ecosystem
// and name. The value is the set of versions seen.
function indexRecorded(sbom) {
  const index = new Map();
  const add = (key, version) => {
    if (!index.has(key)) index.set(key, new Set());
    if (version) index.get(key).add(String(version));
  };
  const walk = (components) => {
    for (const c of components || []) {
      const purl = parsePurl(c.purl);
      if (purl) {
        add(recordKey(purl.type, purl.name), purl.version || c.version);
      } else if (c.name) {
        // No purl, so the ecosystem is unknown. Index it under both, with
        // the group folded in the way npm scopes are written.
        const full = c.group ? `${c.group}/${c.name}` : c.name;
        add(recordKey("npm", full), c.version);
        add(recordKey("pypi", full), c.version);
      }
      walk(c.components);
    }
  };
  walk(sbom.components);
  return index;
}

function loadCraciEvidence() {
  const path = (f) => join(root, CRACI_DIR, f);
  const has = Object.fromEntries(Object.entries(CRACI_FILES).map(([k, f]) => [k, existsSync(path(f))]));
  if (!has.backend && !has.glasses) return null;
  const refetch = "Re-run scripts/fetch-craci-sboms.mjs, or remove the directory to fall back to the lockfile list.";
  if (!has.backend || !has.glasses) {
    throw new Error(
      `${CRACI_DIR} holds only part of a CRACI record ` +
      `(backend: ${has.backend ? "present" : "missing"}, glasses-ui: ${has.glasses ? "present" : "missing"}). ${refetch}`
    );
  }
  // run.json says which run the files came from and lists every job that
  // was downloaded. Without it the files are SBOMs of nothing in particular.
  if (!existsSync(path("run.json"))) {
    throw new Error(`${CRACI_DIR} holds only part of a CRACI record (run.json is missing). ${refetch}`);
  }
  const run = JSON.parse(readFileSync(path("run.json"), "utf8"));
  const usable =
    typeof run.startedAt === "string" && Number.isInteger(run.craciJobsTotal) &&
    Number.isInteger(run.craciJobsSucceeded) && Array.isArray(run.sboms) && run.sboms.length > 0;
  if (!usable) {
    throw new Error(`${CRACI_DIR}/run.json does not describe the run (written by an older fetch script?). ${refetch}`);
  }

  const load = (key) => {
    const sbom = loadSbom(`${CRACI_DIR}/${CRACI_FILES[key]}`);
    const index = indexRecorded(sbom);
    return { index, count: index.size, vulnerabilities: Array.isArray(sbom.vulnerabilities) ? sbom.vulnerabilities.length : null };
  };
  const evidence = { backend: load("backend"), glasses: load("glasses"), mobile: has.mobile ? load("mobile") : null, run };

  // How many components CRACI recorded in each downloaded job, counted from
  // the files themselves rather than taken from run.json's word for it.
  evidence.componentsPerJob = {};
  for (const s of run.sboms) {
    if (!existsSync(path(s.file))) {
      throw new Error(`${CRACI_DIR}/run.json lists ${s.file}, which is missing. ${refetch}`);
    }
    const sbom = loadSbom(`${CRACI_DIR}/${s.file}`);
    evidence.componentsPerJob[s.key] = Array.isArray(sbom.components) ? sbom.components.length : 0;
  }
  return evidence;
}

const craci = loadCraciEvidence();
const warnings = [];

// With the record present, the run's figures come from it: when the run
// started, how many of its CRACI jobs succeeded, and how many packages
// CRACI recorded across them. That last sum is the dashboard's "packages
// checked": for the first run the dashboard showed 181, and the five
// per-job SBOMs of that run hold 30 + 28 + 67 + 28 + 28 = 181 components.
function runFromRecord({ run, componentsPerJob }) {
  const seconds = (Date.parse(run.completedAt) - Date.parse(run.startedAt)) / 1000;
  return {
    verified: run.startedAt,
    ...(Number.isFinite(seconds) ? { durationSeconds: Math.round(seconds) } : {}),
    jobsTotal: run.craciJobsTotal,
    jobsSucceeded: run.craciJobsSucceeded,
    packagesChecked: Object.values(componentsPerJob).reduce((a, b) => a + b, 0),
    knownVulnerabilities: DASHBOARD.knownVulnerabilities,   // from CRACI dashboard
    runner: DASHBOARD_RUN.runner,
  };
}

const RUN = craci ? runFromRecord(craci) : DASHBOARD_RUN;

// A component is shown as verified only when the CRACI run succeeded and its
// vulnerability check came back clean. CRACI reports the vulnerability total
// for the run, not per package, so a non-zero total withdraws every tick
// rather than guessing which components are affected. The UI then says
// "Being checked" instead.
const runClean =
  RUN.jobsSucceeded === RUN.jobsTotal && RUN.knownVulnerabilities === 0;

// With CRACI's record present, a tick additionally requires that CRACI
// recorded this component. For npm the lockfile version must be the one
// CRACI saw. PyPI packages are declared without versions, so the version
// shown is whichever one CRACI recorded.
function verify(type, name, lockedVersion) {
  if (!craci) return { verified: runClean, version: lockedVersion };
  const record = type === "pypi" ? craci.backend : craci.glasses;
  const versions = record.index.get(recordKey(type, name));
  if (!versions) {
    warnings.push(`${name}: not in CRACI's record of the build`);
    return { verified: false, version: lockedVersion };
  }
  if (lockedVersion && versions.size > 0 && !versions.has(String(lockedVersion))) {
    warnings.push(`${name}: lockfile says ${lockedVersion}, CRACI recorded ${[...versions].join(", ")}`);
    return { verified: false, version: lockedVersion };
  }
  const recorded = lockedVersion || (versions.size === 1 ? [...versions][0] : undefined);
  return { verified: runClean, version: recorded };
}

// Plain code-unit order, so the output is identical on every machine.
const byName = (a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);

// Drop undefined versions so the row shape stays the same as before.
const row = (fields) => Object.fromEntries(Object.entries(fields).filter(([, v]) => v !== undefined));

// ---------------------------------------------------------------------------
// Assemble the five groups.
// ---------------------------------------------------------------------------
const bucket = Object.fromEntries(GROUPS.map((g) => [g.id, []]));

const backendRows = BACKEND_RUNTIME.map((c) => {
  const v = verify("pypi", c.name);
  return { purpose: c.purpose, name: c.name, version: v.version, verified: v.verified };
});
const glassesRows = glassesRuntime.map((c) => {
  const v = verify("npm", c.name, c.version);
  return { purpose: purposeForGlassesPackage(c.name), name: c.name, version: v.version, verified: v.verified };
});

for (const c of backendRows) {
  bucket[c.purpose].push(row({ name: c.name, version: c.version, source: "PyPI", where: "server", verified: c.verified }));
}
for (const c of glassesRows) {
  bucket[c.purpose].push(row({ name: c.name, version: c.version, source: "npm", where: "glasses", verified: c.verified }));
}

const groups = GROUPS.map((g) => ({
  ...g,
  components: bucket[g.id].sort(byName),
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
  server: backendRows.map((c) => row({ name: c.name, version: c.version, source: "PyPI", verified: c.verified })),
  glasses: glassesRows
    .map((c) => row({ name: c.name, version: c.version, source: "npm", verified: c.verified }))
    .sort(byName),
  developerToolsCount: developerToolsTotal,
};

// ---------------------------------------------------------------------------
// Where the ticks come from, recorded in the output so the claim can be
// audited from the data file alone.
// ---------------------------------------------------------------------------
const verifiedCount = [...backendRows, ...glassesRows].filter((c) => c.verified).length;

const evidence = craci
  ? {
      source: "craci",
      basis: "Each tick means CRACI recorded this component being fetched during the build, and the run reported no known vulnerabilities.",
      run: {
        id: craci.run.runId,
        url: craci.run.runUrl,
        commit: craci.run.commit,
        startedAt: craci.run.startedAt,
        fetchedAt: craci.run.fetchedAt,
      },
      // Per CRACI job; these add up to run.packagesChecked.
      componentsRecorded: craci.componentsPerJob,
      vulnerabilities: {
        known: DASHBOARD.knownVulnerabilities,
        source: "CRACI dashboard, read by hand; CRACI's API does not expose this figure",
        readForRunStartedAt: DASHBOARD.readForRunStartedAt,
      },
      verified: verifiedCount,
      of: runtimeTotal,
    }
  : {
      source: "lockfile",
      basis: "Component list from lockfiles and fall_server.py; ticks from the run totals on the CRACI dashboard. CRACI's per-job SBOMs have not been downloaded into supply-chain/craci/ yet.",
      verified: verifiedCount,
      of: runtimeTotal,
    };

if (craci) {
  // The vulnerability total is typed in by hand. If it was read for a
  // different run than the downloaded record, or disagrees with it, say so.
  // GitHub's run start and the dashboard's first job start are seconds
  // apart for the same run, so allow a few minutes before calling it a
  // different one.
  const SAME_RUN_MS = 10 * 60 * 1000;
  if (Math.abs(Date.parse(craci.run.startedAt) - Date.parse(DASHBOARD.readForRunStartedAt)) > SAME_RUN_MS) {
    warnings.push(
      `the vulnerability total (${DASHBOARD.knownVulnerabilities}) was read off the CRACI dashboard for the run started ${DASHBOARD.readForRunStartedAt}, ` +
      `but the downloaded record is from the run started ${craci.run.startedAt}. ` +
      `Read it off the dashboard for that run and update DASHBOARD.`
    );
  }
  if (craci.run.sboms.length !== craci.run.craciJobsTotal) {
    warnings.push(
      `packages checked is added up from ${craci.run.sboms.length} downloaded SBOMs, but the run had ${craci.run.craciJobsTotal} CRACI jobs.`
    );
  }
  const recordedVulns = [craci.backend, craci.glasses, craci.mobile]
    .filter(Boolean)
    .map((r) => r.vulnerabilities)
    .filter((n) => n !== null);
  if (recordedVulns.length && recordedVulns.reduce((a, b) => a + b, 0) !== RUN.knownVulnerabilities) {
    warnings.push(
      `CRACI's SBOMs list ${recordedVulns.reduce((a, b) => a + b, 0)} vulnerabilities but RUN.knownVulnerabilities is ${RUN.knownVulnerabilities}.`
    );
  }
}

const out = {
  run: RUN,
  evidence,
  runtimeTotal,
  developerToolsTotal,
  groups,
  raw,
  generatedAt: new Date().toISOString(),
};

const banner = `// GENERATED FILE. Do not edit by hand.
// Regenerate with: node scripts/build-trust-panel.mjs
// Component list: supply-chain/*.cyclonedx.json and supply-chain/backend-declared.txt
// Ticks: ${craci ? "supply-chain/craci/*.cdx.json (downloaded from CRACI)" : "CRACI dashboard run totals (per-job SBOMs not downloaded yet)"}
`;
const PREFIX = "window.TRUST_DATA = ";
const dataPath = join(root, "data/trust-panel.js");

// Everything except the timestamp, which changes on every run by design.
const comparable = (o) => JSON.stringify({ ...o, generatedAt: null });

function report() {
  console.log(`  evidence: ${evidence.source}${craci?.run?.id ? ` (run ${craci.run.id})` : ""}`);
  console.log(`  runtime components: ${runtimeTotal} in ${groups.length} groups, ${verifiedCount} verified`);
  console.log(`  developer tools excluded: ${developerToolsTotal}`);
  console.log(`  verified at: ${RUN.verified}`);
  for (const g of groups) {
    console.log(`  ${g.count.toString().padStart(2)} ${g.id.padEnd(8)} ${g.title}`);
  }
  for (const w of warnings) console.warn(`  WARNING: ${w}`);
  if (!craci) {
    console.warn("  NOTE: ticks rest on the dashboard totals. Run scripts/fetch-craci-sboms.mjs to back each one with CRACI's record.");
  }
}

if (STRICT) {
  const problems = [];
  if (!craci) problems.push("CRACI's per-job SBOMs are not in supply-chain/craci/");
  if (verifiedCount !== runtimeTotal) problems.push(`${runtimeTotal - verifiedCount} of ${runtimeTotal} components are not verified`);
  problems.push(...warnings);
  if (problems.length) {
    console.error("Strict mode failed:");
    for (const p of problems) console.error(`  - ${p}`);
    process.exit(1);
  }
}

if (CHECK) {
  let committed;
  try {
    const text = readFileSync(dataPath, "utf8");
    committed = JSON.parse(text.slice(text.indexOf(PREFIX) + PREFIX.length).replace(/;\s*$/, ""));
  } catch (e) {
    console.error(`data/trust-panel.js could not be read: ${e.message}`);
    process.exit(1);
  }
  if (comparable(committed) !== comparable(out)) {
    const changed = Object.keys({ ...committed, ...out })
      .filter((k) => k !== "generatedAt" && JSON.stringify(committed[k]) !== JSON.stringify(out[k]));
    console.error("data/trust-panel.js is stale: it does not match what the inputs produce.");
    console.error(`  differs in: ${changed.join(", ")}`);
    console.error("  Regenerate with: node scripts/build-trust-panel.mjs");
    process.exit(1);
  }
  console.log("data/trust-panel.js matches its inputs");
  report();
} else {
  writeFileSync(dataPath, banner + PREFIX + JSON.stringify(out, null, 2) + ";\n");
  console.log("Wrote data/trust-panel.js");
  report();
}
