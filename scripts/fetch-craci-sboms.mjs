#!/usr/bin/env node
// Downloads the SBOMs CRACI recorded for a supply-chain workflow run, so the
// Trust panel's ticks rest on CRACI's own record instead of on our lockfiles.
//
//   CRACI_API_TOKEN=... node scripts/fetch-craci-sboms.mjs
//   CRACI_API_TOKEN=... node scripts/fetch-craci-sboms.mjs --run 1234567890
//
// Then:  node scripts/build-trust-panel.mjs --strict
//
// The token comes from CRACI: Settings -> API tokens (organisation admins
// only, shown once, expires after 90 days). It is read from the environment
// and is never written to disk or printed. Do not commit it.
//
// How it works. CRACI keeps one SBOM per job and identifies a job by its
// GitHub job ID (GET /v1preview1/sbom, see https://api.craci.com/openapi.json).
// So this asks GitHub which jobs the run had, then asks CRACI for each one.
// Without --run it takes the most recent completed run of the workflow on
// the `craci` branch.
//
// Optional environment:
//   GITHUB_TOKEN   only needed if the repository is private or the
//                  unauthenticated GitHub rate limit has been used up
//   CRACI_REPO     OWNER/REPOSITORY, if not the default below

import { mkdirSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const outDir = join(here, "..", "supply-chain", "craci");

const REPO = process.env.CRACI_REPO || "yanivlakhani/davinciscoding_junction2026";
const WORKFLOW = "supply-chain.yml";
const BRANCH = "craci";
// Overridable so the tests can point at a local stand-in for both services.
const GITHUB_API = process.env.GITHUB_API_URL || "https://api.github.com";
const CRACI_API = process.env.CRACI_API_URL || "https://api.craci.com";

// The jobs to download, by the name they have in
// .github/workflows/supply-chain.yml on the `craci` branch.
//
// The first three are the installs that make up the product, and are what
// the Trust panel's ticks are checked against. The two policy jobs install
// the same things as the companion app job and decide no ticks. They are
// downloaded because the "packages checked" total on CRACI's dashboard is
// the sum over every CRACI job in the run, and keeping all of them here
// lets the build add that total up from the files rather than have it
// typed in by hand.
const JOBS = [
  { key: "backend",         name: "Backend (PyPI)",      file: "backend.cdx.json",    required: true  },
  { key: "glasses-ui",      name: "Glasses UI (npm)",    file: "glasses-ui.cdx.json", required: true  },
  { key: "mobile-app",      name: "Companion app (npm)", file: "mobile-app.cdx.json", required: false },
  { key: "policy-strict",   name: "Strict policy (expected to block Chrome download)",  file: "policy-strict.cdx.json",   required: false },
  { key: "policy-reviewed", name: "Reviewed policy (Chrome download named explicitly)", file: "policy-reviewed.cdx.json", required: false },
];

// A job ran on CRACI if its `runs-on` label says so. Jobs on GitHub-hosted
// runners (the workflow has one, which only compares files) leave no
// record at CRACI and are not counted as CRACI jobs.
const RUNNER_LABEL = "craci";

// CRACI builds the SBOM document when it is requested, and stamps each
// download with a new serial number and the time of the request. Everything
// else is the same from one download to the next, so this is the hash to
// compare when checking a file here against a fresh download.
function contentHash(sbom) {
  const { serialNumber, metadata, ...rest } = sbom;
  const { timestamp, ...stableMetadata } = metadata || {};
  return createHash("sha256").update(JSON.stringify({ ...rest, metadata: stableMetadata })).digest("hex");
}

function fail(message) {
  console.error(`fetch-craci-sboms: ${message}`);
  process.exit(1);
}

const args = process.argv.slice(2);
let runId = null;
for (let i = 0; i < args.length; i += 1) {
  if (args[i] === "--run" && /^\d+$/.test(args[i + 1] || "")) { runId = args[i + 1]; i += 1; }
  else fail(`unknown argument "${args[i]}". Usage: fetch-craci-sboms.mjs [--run <github run id>]`);
}

const token = process.env.CRACI_API_TOKEN;
if (!token) {
  fail(
    "CRACI_API_TOKEN is not set.\n" +
    "  Create a token in CRACI under Settings -> API tokens, then run:\n" +
    "  CRACI_API_TOKEN=<token> node scripts/fetch-craci-sboms.mjs"
  );
}

async function github(path) {
  const headers = { Accept: "application/vnd.github+json", "User-Agent": "fetch-craci-sboms" };
  const ghToken = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  if (ghToken) headers.Authorization = `Bearer ${ghToken}`;
  const res = await fetch(`${GITHUB_API}${path}`, { headers });
  if (res.status === 404) fail(`GitHub returned 404 for ${path}. If ${REPO} is private, set GITHUB_TOKEN.`);
  if (res.status === 403 || res.status === 429) fail(`GitHub refused the request (${res.status}), probably the rate limit. Set GITHUB_TOKEN and retry.`);
  if (!res.ok) fail(`GitHub returned ${res.status} for ${path}.`);
  return res.json();
}

async function craciSbom(jobId) {
  const query = new URLSearchParams({ provider: "github", repo: REPO, job_id: String(jobId) });
  const res = await fetch(`${CRACI_API}/v1preview1/sbom?${query}`, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.cyclonedx+json" },
  });
  if (res.status === 401) fail("CRACI rejected the token (401). It may be mistyped, revoked, or past its 90 days.");
  if (res.status === 404) fail(`CRACI has no record of job ${jobId} in ${REPO} (404). Was that job run on a CRACI runner?`);
  if (res.status === 409) fail(`CRACI says job ${jobId} has not finished (409). Wait for the run to complete and retry.`);
  if (!res.ok) fail(`CRACI returned ${res.status} for job ${jobId}.`);
  return res.text();
}

// ---- 1. Which run ---------------------------------------------------------
let run;
if (runId) {
  run = await github(`/repos/${REPO}/actions/runs/${runId}`);
} else {
  const list = await github(
    `/repos/${REPO}/actions/workflows/${WORKFLOW}/runs?branch=${BRANCH}&status=completed&per_page=1`
  );
  run = (list.workflow_runs || [])[0];
  if (!run) fail(`no completed run of ${WORKFLOW} on the ${BRANCH} branch was found.`);
}
if (run.status !== "completed") fail(`run ${run.id} is still ${run.status}. Wait for it to complete and retry.`);

// ---- 2. Its jobs ----------------------------------------------------------
const jobList = await github(`/repos/${REPO}/actions/runs/${run.id}/jobs?per_page=100`);
const ghJobs = jobList.jobs || [];
if (ghJobs.length === 0) fail(`run ${run.id} has no jobs.`);

// ---- 3. One SBOM per job, fetched before anything is written --------------
// A failed download must not leave half a record on disk.
const fetched = [];
for (const want of JOBS) {
  const job = ghJobs.find((j) => j.name === want.name);
  if (!job) {
    if (want.required) fail(`run ${run.id} has no job named "${want.name}". Has the workflow been renamed?`);
    console.warn(`  skipped ${want.key}: no job named "${want.name}" in this run`);
    continue;
  }
  if (job.conclusion !== "success") {
    if (want.required) fail(`job "${want.name}" finished as ${job.conclusion}; refusing to record a failed build as evidence.`);
    console.warn(`  skipped ${want.key}: job finished as ${job.conclusion}`);
    continue;
  }
  const text = await craciSbom(job.id);
  let sbom;
  try { sbom = JSON.parse(text); } catch { fail(`CRACI's response for "${want.name}" is not JSON.`); }
  if (sbom.bomFormat !== "CycloneDX") fail(`CRACI's response for "${want.name}" is not CycloneDX (bomFormat: ${sbom.bomFormat}).`);
  fetched.push({
    ...want,
    text,
    jobId: String(job.id),
    conclusion: job.conclusion,
    specVersion: sbom.specVersion ?? null,
    components: Array.isArray(sbom.components) ? sbom.components.length : 0,
    sha256: createHash("sha256").update(text).digest("hex"),
    contentSha256: contentHash(sbom),
  });
}

// Every CRACI job in the run has to be one this script knows about, or the
// package total added up from the files would silently leave a job out.
const craciJobs = ghJobs.filter((j) => (j.labels || []).includes(RUNNER_LABEL));
const known = new Set(JOBS.map((j) => j.name));
const unknown = craciJobs.filter((j) => !known.has(j.name));
if (unknown.length) {
  fail(
    `run ${run.id} has CRACI jobs this script does not know: ${unknown.map((j) => `"${j.name}"`).join(", ")}.\n` +
    "  Add them to JOBS, or the packages-checked total would be short."
  );
}
const completedTimes = ghJobs.map((j) => Date.parse(j.completed_at)).filter(Number.isFinite);

// ---- 4. Write the record --------------------------------------------------
mkdirSync(outDir, { recursive: true });
for (const f of fetched) writeFileSync(join(outDir, f.file), f.text);

const record = {
  repository: REPO,
  workflow: WORKFLOW,
  branch: run.head_branch,
  runId: String(run.id),
  runNumber: run.run_number,
  runUrl: run.html_url,
  commit: run.head_sha,
  startedAt: run.run_started_at || run.created_at,
  completedAt: completedTimes.length ? new Date(Math.max(...completedTimes)).toISOString().replace(".000Z", "Z") : null,
  conclusion: run.conclusion,
  jobsTotal: ghJobs.length,
  jobsSucceeded: ghJobs.filter((j) => j.conclusion === "success").length,
  craciJobsTotal: craciJobs.length,
  craciJobsSucceeded: craciJobs.filter((j) => j.conclusion === "success").length,
  // sha256 is of the file as written here. contentSha256 leaves out the
  // serial number and timestamp CRACI stamps on each download, so anyone
  // holding a token can download the same job's SBOM, hash it the same
  // way, and confirm nothing else differs.
  sboms: fetched.map(({ key, name, file, jobId, conclusion, specVersion, components, sha256, contentSha256 }) =>
    ({ key, job: name, file, jobId, conclusion, specVersion, components, sha256, contentSha256 })),
  fetchedAt: new Date().toISOString(),
};
writeFileSync(join(outDir, "run.json"), JSON.stringify(record, null, 2) + "\n");

console.log(`CRACI record for run #${record.runNumber} (${record.runId}), commit ${String(record.commit).slice(0, 7)}`);
for (const f of fetched) console.log(`  ${f.file.padEnd(26)} ${String(f.components).padStart(4)} components`);
console.log(`  ${"total".padEnd(26)} ${String(fetched.reduce((s, f) => s + f.components, 0)).padStart(4)}`);
console.log(`  CRACI jobs: ${record.craciJobsSucceeded}/${record.craciJobsTotal} succeeded, started ${record.startedAt}`);
console.log("Next: node scripts/build-trust-panel.mjs --strict");
