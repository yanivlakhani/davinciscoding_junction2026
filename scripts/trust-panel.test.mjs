// Tests for the Trust panel data pipeline.
//   node --test scripts/trust-panel.test.mjs
//
// build-trust-panel.mjs decides which components get a "Verified" tick, and
// fetch-craci-sboms.mjs downloads the record those ticks rest on. Both are
// run here as real processes against a throwaway copy of the project, so
// nothing in the working tree is touched and no network is used: GitHub and
// CRACI are replaced by a local server that answers the way their published
// API descriptions say they do.
//
// The fixtures write component names more ways than CRACI does. Its real
// SBOMs (see supply-chain/craci/) give every component a package URL, such
// as pkg:pypi/fastapi@0.163.0?file_name=... or pkg:npm/%40scope/name@1.2.3,
// and the first test below runs the build against those real files.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync, spawn } from "node:child_process";
import { createServer } from "node:http";
import { cpSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const project = join(here, "..");

// A private copy of everything the scripts read, so tests can add or break
// inputs freely.
function sandbox() {
  const dir = mkdtempSync(join(tmpdir(), "trust-panel-"));
  cpSync(join(project, "scripts"), join(dir, "scripts"), { recursive: true });
  mkdirSync(join(dir, "supply-chain"));
  for (const f of ["glasses-ui.cyclonedx.json", "mobile-app.cyclonedx.json", "backend-declared.txt"]) {
    cpSync(join(project, "supply-chain", f), join(dir, "supply-chain", f));
  }
  mkdirSync(join(dir, "data"));
  cpSync(join(project, "data", "trust-panel.js"), join(dir, "data", "trust-panel.js"));
  return dir;
}

const build = (dir, ...args) =>
  spawnSync(process.execPath, [join(dir, "scripts", "build-trust-panel.mjs"), ...args], { encoding: "utf8" });

function readData(dir) {
  const text = readFileSync(join(dir, "data", "trust-panel.js"), "utf8");
  const prefix = "window.TRUST_DATA = ";
  return JSON.parse(text.slice(text.indexOf(prefix) + prefix.length).replace(/;\s*$/, ""));
}

const rows = (data) => data.groups.flatMap((g) => g.components);

// The components the panel lists as shipping to the glasses, straight from
// the lockfile SBOM, so the fixtures cannot drift from the real input.
const lockedGlasses = JSON.parse(readFileSync(join(project, "supply-chain", "glasses-ui.cyclonedx.json"), "utf8"))
  .components.filter((c) => ["react", "react-dom", "scheduler"].includes(c.name) || c.name.startsWith("@wearables-ui-toolkit/"));

const BACKEND = ["anthropic", "opencv-python-headless", "numpy", "httpx", "fastapi", "python-multipart", "pydantic"];

// The run the hand-read dashboard figure belongs to, taken from the script
// so these tests keep working when that figure is re-read for a newer run.
const DASHBOARD_RUN_STARTED = readFileSync(join(project, "scripts", "build-trust-panel.mjs"), "utf8")
  .match(/readForRunStartedAt:\s*"([^"]+)"/)[1];
const minutesAfterDashboardRun = (m) => new Date(Date.parse(DASHBOARD_RUN_STARTED) + m * 60000).toISOString();

// A stand-in for what CRACI records. Names are deliberately written the
// different ways a recorder might write them.
function craciRecord(dir, { dropBackend = [], dropGlasses = [], glassesVersion = (c) => c.version, startedAt = minutesAfterDashboardRun(-1), craciJobsTotal = 2 } = {}) {
  const out = join(dir, "supply-chain", "craci");
  mkdirSync(out, { recursive: true });

  const backend = BACKEND.filter((n) => !dropBackend.includes(n)).map((name, i) => {
    // PyPI names: underscores and capitals are the same package (PEP 503).
    const written = i % 2 ? name.replace(/-/g, "_") : name.toUpperCase();
    return { type: "library", name: written, version: `1.${i}.0`, purl: `pkg:pypi/${written}@1.${i}.0` };
  });
  backend.push({ type: "library", name: "starlette", version: "0.40.0", purl: "pkg:pypi/starlette@0.40.0" });

  const glasses = lockedGlasses.filter((c) => !dropGlasses.includes(c.name)).map((c, i) => {
    const version = glassesVersion(c);
    if (c.name.startsWith("@")) {
      const [scope, bare] = c.name.split("/");
      // Scoped names appear percent-encoded in a purl, unencoded in sloppy
      // ones, and split into group + name when there is no purl at all.
      if (i % 3 === 0) return { type: "library", name: c.name, version, purl: `pkg:npm/%40${scope.slice(1)}/${bare}@${version}` };
      if (i % 3 === 1) return { type: "library", name: bare, group: scope, version, purl: `pkg:npm/${scope}/${bare}@${version}?vcs_url=x` };
      return { type: "library", group: scope, name: bare, version };
    }
    return { type: "library", name: c.name, version, purl: `pkg:npm/${c.name}@${version}` };
  });
  // Nested components must be found too.
  const nested = glasses.pop();
  glasses.push({ type: "application", name: "glasses-ui", version: "0.0.0", components: [nested] });

  const bom = (components) => JSON.stringify({ bomFormat: "CycloneDX", specVersion: "1.7", components });
  writeFileSync(join(out, "backend.cdx.json"), bom(backend));
  writeFileSync(join(out, "glasses-ui.cdx.json"), bom(glasses));
  writeFileSync(join(out, "run.json"), JSON.stringify({
    runId: "111", runUrl: "https://example.test/run/111", commit: "abc1234",
    startedAt, completedAt: new Date(Date.parse(startedAt) + 37000).toISOString(),
    craciJobsTotal, craciJobsSucceeded: craciJobsTotal,
    sboms: [{ key: "backend", file: "backend.cdx.json" }, { key: "glasses-ui", file: "glasses-ui.cdx.json" }],
    fetchedAt: "2026-11-15T00:00:00Z",
  }));
  // Top-level components in each file, which is what the build counts.
  return { backend: backend.length, glasses: glasses.length };
}

test("the committed data file matches what its inputs produce", () => {
  const r = spawnSync(process.execPath, [join(project, "scripts", "build-trust-panel.mjs"), "--check"], { encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
});

test("without CRACI's record: every component listed, evidence marked as lockfile, strict refuses", () => {
  const dir = sandbox();
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  const data = readData(dir);
  assert.equal(data.evidence.source, "lockfile");
  assert.equal(data.runtimeTotal, 14);
  assert.equal(rows(data).length, 14);
  assert.equal(build(dir, "--strict").status, 1, "strict must not pass on lockfile evidence alone");
  rmSync(dir, { recursive: true });
});

test("with CRACI's record: every tick is backed by it, however the names are written", () => {
  const dir = sandbox();
  craciRecord(dir);
  const r = build(dir, "--strict");
  assert.equal(r.status, 0, r.stdout + r.stderr);
  const data = readData(dir);
  assert.equal(data.evidence.source, "craci");
  assert.equal(data.evidence.run.id, "111");
  assert.deepEqual([data.evidence.verified, data.evidence.of], [14, 14]);
  assert.ok(rows(data).every((c) => c.verified === true));
  // PyPI packages are declared without versions; the one shown is CRACI's.
  assert.equal(data.raw.server.find((c) => c.name === "anthropic").version, "1.0.0");
  // npm versions stay the lockfile's, which CRACI confirmed.
  const react = lockedGlasses.find((c) => c.name === "react");
  assert.equal(data.raw.glasses.find((c) => c.name === "react").version, react.version);
  rmSync(dir, { recursive: true });
});

test("with CRACI's record: the run's figures are worked out from it, not typed in", () => {
  const dir = sandbox();
  const startedAt = minutesAfterDashboardRun(2);
  const counted = craciRecord(dir, { startedAt });
  assert.equal(build(dir, "--strict").status, 0);
  const data = readData(dir);
  assert.equal(data.run.verified, startedAt);
  assert.equal(data.run.durationSeconds, 37);
  assert.deepEqual([data.run.jobsSucceeded, data.run.jobsTotal], [2, 2]);
  assert.equal(data.run.packagesChecked, counted.backend + counted.glasses);
  assert.deepEqual(data.evidence.componentsRecorded, { backend: counted.backend, "glasses-ui": counted.glasses });
  // The one figure that is still typed in says where it came from.
  assert.equal(data.evidence.vulnerabilities.readForRunStartedAt, DASHBOARD_RUN_STARTED);
  rmSync(dir, { recursive: true });
});

test("a packages total that leaves out a CRACI job is flagged", () => {
  const dir = sandbox();
  craciRecord(dir, { craciJobsTotal: 5 });
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /added up from 2 downloaded SBOMs, but the run had 5 CRACI jobs/);
  assert.equal(build(dir, "--strict").status, 1);
  rmSync(dir, { recursive: true });
});

test("a component CRACI did not record loses its tick, and only that one", () => {
  const dir = sandbox();
  craciRecord(dir, { dropBackend: ["httpx"], dropGlasses: ["scheduler"] });
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /httpx: not in CRACI's record/);
  const unverified = rows(readData(dir)).filter((c) => !c.verified).map((c) => c.name).sort();
  assert.deepEqual(unverified, ["httpx", "scheduler"]);
  assert.equal(readData(dir).evidence.verified, 12);
  assert.equal(build(dir, "--strict").status, 1);
  rmSync(dir, { recursive: true });
});

test("an npm package CRACI saw at a different version is not ticked", () => {
  const dir = sandbox();
  craciRecord(dir, { glassesVersion: (c) => (c.name === "react" ? "0.0.1-other" : c.version) });
  const r = build(dir);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /react: lockfile says .* CRACI recorded 0\.0\.1-other/);
  const react = rows(readData(dir)).find((c) => c.name === "react");
  assert.equal(react.verified, false);
  rmSync(dir, { recursive: true });
});

test("half a CRACI record is an error, not a partial pass", () => {
  const dir = sandbox();
  craciRecord(dir);
  rmSync(join(dir, "supply-chain", "craci", "glasses-ui.cdx.json"));
  const r = build(dir);
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /only part of a CRACI record/);
  rmSync(dir, { recursive: true });
});

test("SBOMs that do not say which run they came from are an error", () => {
  const dir = sandbox();
  craciRecord(dir);
  const runJson = join(dir, "supply-chain", "craci", "run.json");
  writeFileSync(runJson, JSON.stringify({ runId: "111", startedAt: minutesAfterDashboardRun(0) }));
  let r = build(dir);
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /does not describe the run/);
  rmSync(runJson);
  r = build(dir);
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /run\.json is missing/);
  rmSync(dir, { recursive: true });
});

test("a record from a different run than the dashboard reading fails strict", () => {
  const dir = sandbox();
  craciRecord(dir, { startedAt: minutesAfterDashboardRun(600) });
  assert.equal(build(dir).status, 0);
  const strict = build(dir, "--strict");
  assert.equal(strict.status, 1);
  assert.match(strict.stderr, /Read it off the dashboard for that run and update DASHBOARD/);
  rmSync(dir, { recursive: true });
});

test("a backend dependency with no stated purpose stops the build", () => {
  const dir = sandbox();
  const declared = join(dir, "supply-chain", "backend-declared.txt");
  writeFileSync(declared, readFileSync(declared, "utf8") + "requests>=2\n");
  const r = build(dir);
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /declared but not given a purpose: requests/);
  rmSync(dir, { recursive: true });
});

test("--check notices a data file that no longer matches its inputs", () => {
  const dir = sandbox();
  craciRecord(dir);            // inputs change, committed data does not
  const r = build(dir, "--check");
  assert.equal(r.status, 1);
  assert.match(r.stderr, /stale/);
  rmSync(dir, { recursive: true });
});

// ---------------------------------------------------------------------------
// fetch-craci-sboms.mjs, against a local stand-in for GitHub and CRACI.
// ---------------------------------------------------------------------------
const TOKEN = "test-token-do-not-leak";

function fakeServices({ backendConclusion = "success", sbomStatus = 200, extraJobs = [] } = {}) {
  const seen = [];
  let served = 0;
  const server = createServer((req, res) => {
    const url = new URL(req.url, "http://localhost");
    seen.push({ path: url.pathname, query: Object.fromEntries(url.searchParams), auth: req.headers.authorization });
    const json = (body, status = 200) => { res.writeHead(status, { "content-type": "application/json" }); res.end(JSON.stringify(body)); };
    if (url.pathname.endsWith("/actions/workflows/supply-chain.yml/runs")) {
      return json({ workflow_runs: [{ id: 555, run_number: 2, status: "completed", conclusion: "success", head_branch: "craci", head_sha: "deadbeefcafe", html_url: "https://github.test/run/555", run_started_at: "2026-11-15T00:10:00Z" }] });
    }
    if (url.pathname.endsWith("/actions/runs/555/jobs")) {
      return json({ jobs: [
        { id: 9001, name: "Backend (PyPI)", conclusion: backendConclusion, labels: ["craci"], completed_at: "2026-11-15T00:10:49Z" },
        { id: 9002, name: "Glasses UI (npm)", conclusion: "success", labels: ["craci"], completed_at: "2026-11-15T00:10:12Z" },
        { id: 9003, name: "Companion app (npm)", conclusion: "success", labels: ["craci"], completed_at: "2026-11-15T00:10:27Z" },
        { id: 9004, name: "Strict policy (expected to block Chrome download)", conclusion: "success", labels: ["craci"], completed_at: "2026-11-15T00:10:24Z" },
        { id: 9005, name: "Reviewed policy (Chrome download named explicitly)", conclusion: "success", labels: ["craci"], completed_at: "2026-11-15T00:10:22Z" },
        // Runs on a GitHub-hosted runner, so CRACI has no record of it.
        { id: 9006, name: "Trust panel matches the evidence", conclusion: "success", labels: ["ubuntu-latest"], completed_at: "2026-11-15T00:10:10Z" },
        ...extraJobs,
      ] });
    }
    if (url.pathname === "/v1preview1/sbom") {
      if (sbomStatus !== 200) return json({ title: "nope" }, sbomStatus);
      if (url.searchParams.get("job_id") === "9006") return json({ title: "no such job" }, 404);
      // Like CRACI, stamp every download with a new serial number and time.
      served += 1;
      return json({
        bomFormat: "CycloneDX", specVersion: "1.7", serialNumber: `urn:uuid:download-${served}`,
        metadata: { timestamp: `2026-11-15T00:20:${String(served).padStart(2, "0")}Z`, component: { name: "job" } },
        components: [{ name: `job-${url.searchParams.get("job_id")}` }],
      });
    }
    json({ message: "not found" }, 404);
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve({ server, seen, base: `http://127.0.0.1:${server.address().port}` })));
}

// The server lives in this process, so the script has to run without
// blocking it: spawnSync would deadlock.
function runFetch(dir, base, env = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [join(dir, "scripts", "fetch-craci-sboms.mjs")], {
      env: { PATH: process.env.PATH, GITHUB_API_URL: base, CRACI_API_URL: base, ...env },
    });
    let stdout = "", stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("close", (status) => resolve({ status, stdout, stderr }));
  });
}

test("fetch: refuses to run without a token and says how to get one", async () => {
  const dir = sandbox();
  const r = await runFetch(dir, "http://127.0.0.1:9");
  assert.equal(r.status, 1);
  assert.match(r.stderr, /CRACI_API_TOKEN is not set/);
  rmSync(dir, { recursive: true });
});

test("fetch: downloads one SBOM per CRACI job and records where it came from", async () => {
  const dir = sandbox();
  const { server, seen, base } = await fakeServices();
  const r = await runFetch(dir, base, { CRACI_API_TOKEN: TOKEN });
  server.close();
  assert.equal(r.status, 0, r.stderr);

  const out = join(dir, "supply-chain", "craci");
  for (const f of ["backend.cdx.json", "glasses-ui.cdx.json", "mobile-app.cdx.json", "policy-strict.cdx.json", "policy-reviewed.cdx.json", "run.json"]) {
    assert.ok(existsSync(join(out, f)), `${f} should have been written`);
  }
  const record = JSON.parse(readFileSync(join(out, "run.json"), "utf8"));
  assert.equal(record.runId, "555");
  assert.equal(record.commit, "deadbeefcafe");
  assert.deepEqual([record.jobsSucceeded, record.jobsTotal], [6, 6]);
  // The GitHub-hosted job is not a CRACI job and is never asked for.
  assert.deepEqual([record.craciJobsSucceeded, record.craciJobsTotal], [5, 5]);
  assert.deepEqual(record.sboms.map((s) => s.jobId), ["9001", "9002", "9003", "9004", "9005"]);
  assert.equal(record.completedAt, "2026-11-15T00:10:49Z");

  // CRACI is asked for the right jobs, with the token, in the documented form.
  const sbomCalls = seen.filter((c) => c.path === "/v1preview1/sbom");
  assert.deepEqual(sbomCalls.map((c) => c.query.job_id), ["9001", "9002", "9003", "9004", "9005"]);
  assert.ok(sbomCalls.every((c) => c.query.provider === "github" && c.auth === `Bearer ${TOKEN}`));
  // The CRACI token goes to CRACI only, and appears nowhere in the output.
  assert.ok(seen.filter((c) => c.path !== "/v1preview1/sbom").every((c) => c.auth === undefined));
  assert.ok(!(r.stdout + r.stderr + readFileSync(join(out, "run.json"), "utf8")).includes(TOKEN));

  // The panel builds from exactly what was downloaded.
  const built = build(dir);
  assert.equal(built.status, 0, built.stderr);
  const data = readData(dir);
  assert.equal(data.run.packagesChecked, 5);
  assert.deepEqual([data.run.jobsSucceeded, data.run.jobsTotal], [5, 5]);
  rmSync(dir, { recursive: true });
});

test("fetch: two downloads of the same job differ only in CRACI's stamp, and contentSha256 says so", async () => {
  const dir = sandbox();
  const { server, base } = await fakeServices();
  const out = join(dir, "supply-chain", "craci", "run.json");
  const first = await runFetch(dir, base, { CRACI_API_TOKEN: TOKEN });
  const a = JSON.parse(readFileSync(out, "utf8")).sboms;
  const second = await runFetch(dir, base, { CRACI_API_TOKEN: TOKEN });
  const b = JSON.parse(readFileSync(out, "utf8")).sboms;
  server.close();
  assert.deepEqual([first.status, second.status], [0, 0], first.stderr + second.stderr);
  assert.ok(a.every((s, i) => s.sha256 !== b[i].sha256), "the stand-in stamps each download, so file hashes differ");
  assert.deepEqual(a.map((s) => s.contentSha256), b.map((s) => s.contentSha256));
  assert.equal(new Set(a.map((s) => s.contentSha256)).size, a.length, "different jobs must not hash alike");
  rmSync(dir, { recursive: true });
});

test("fetch: a CRACI job the script does not know stops it, so the total cannot come up short", async () => {
  const dir = sandbox();
  const { server, base } = await fakeServices({ extraJobs: [{ id: 9007, name: "Something new", conclusion: "success", labels: ["craci"] }] });
  const r = await runFetch(dir, base, { CRACI_API_TOKEN: TOKEN });
  server.close();
  assert.equal(r.status, 1);
  assert.match(r.stderr, /does not know: "Something new"/);
  assert.ok(!existsSync(join(dir, "supply-chain", "craci")));
  rmSync(dir, { recursive: true });
});

test("fetch: a failed product job is not recorded as evidence, and nothing is written", async () => {
  const dir = sandbox();
  const { server, base } = await fakeServices({ backendConclusion: "failure" });
  const r = await runFetch(dir, base, { CRACI_API_TOKEN: TOKEN });
  server.close();
  assert.equal(r.status, 1);
  assert.match(r.stderr, /refusing to record a failed build/);
  assert.ok(!existsSync(join(dir, "supply-chain", "craci")));
  rmSync(dir, { recursive: true });
});

test("fetch: a rejected token is reported plainly, without echoing it", async () => {
  const dir = sandbox();
  const { server, base } = await fakeServices({ sbomStatus: 401 });
  const r = await runFetch(dir, base, { CRACI_API_TOKEN: TOKEN });
  server.close();
  assert.equal(r.status, 1);
  assert.match(r.stderr, /rejected the token/);
  assert.ok(!r.stderr.includes(TOKEN));
  assert.ok(!existsSync(join(dir, "supply-chain", "craci")));
  rmSync(dir, { recursive: true });
});
