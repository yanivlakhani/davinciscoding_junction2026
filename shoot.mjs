// Screenshots + click-through checks for the mobile mock.
//   node shoot.mjs
// Writes PNGs to shots/ and exits non-zero if any behaviour check fails.
import puppeteer from "puppeteer";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { mkdirSync } from "node:fs";

const here = dirname(fileURLToPath(import.meta.url));
const shotsDir = join(here, "shots");
mkdirSync(shotsDir, { recursive: true });

const url = (hash = "") => `file://${join(here, "index.html")}${hash}`;
const VIEWPORT = { width: 390, height: 844, deviceScaleFactor: 2 };
const RED = "rgb(238, 53, 46)";
const GREEN = "rgb(0, 147, 60)";
const settle = () => new Promise((r) => setTimeout(r, 400));

const shots = [
  ["01-home", ""],
  ["02-home-fall-off", "#/home?fall=off"],
  ["03-home-location-off", "#/home?loc=off"],
  ["04-confirm-fall", "#/home?confirm=fall"],
  ["05-confirm-location", "#/home?confirm=loc"],
  ["06-contacts", "#/contacts"],
  ["07-edit", "#/edit"],
  ["10-trust", "#/trust"],
  ["11-rawsbom", "#/rawsbom"],
];

let failures = 0;
function check(label, actual, expected) {
  const ok = actual === expected;
  if (!ok) failures += 1;
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}${ok ? "" : `\n        expected: ${expected}\n        actual:   ${actual}`}`);
}

// Everything the wearer can see about one setting, read from the live page.
const read = (page) =>
  page.evaluate(() => {
    const knob = (id) => {
      const el = document.getElementById(id);
      const s = getComputedStyle(el, "::after");
      return { off: el.classList.contains("is-off"), color: s.backgroundColor, onLeft: s.left === "3px" };
    };
    const text = (id) => document.getElementById(id).textContent.trim();
    return {
      fallKnob: knob("fall-sw"),
      locKnob: knob("loc-sw"),
      title: text("st-title"),
      hint: text("fall-hint"),
      disc: document.getElementById("st-disc").className,
      locVal: text("loc-val"),
      sensor: text("sp-sensor"),
      camera: text("sp-camera"),
      fallPressed: document.getElementById("fall-btn").getAttribute("aria-pressed"),
      locPressed: document.getElementById("loc-btn").getAttribute("aria-pressed"),
      sheetOpen: document.getElementById("scrim").classList.contains("on"),
      sheetTitle: text("sheet-title"),
      toastOn: document.getElementById("toast").classList.contains("on"),
      toast: text("toast-tag") + " | " + text("toast-text"),
    };
  });

const browser = await puppeteer.launch({ headless: "new" });
try {
  // ---- 1. Screenshots of every state -------------------------------------
  for (const [name, hash] of shots) {
    const page = await browser.newPage();
    await page.setViewport(VIEWPORT);
    await page.goto(url(hash), { waitUntil: "networkidle0" });
    await settle();
    await page.screenshot({ path: join(shotsDir, `${name}.png`) });
    await page.close();
    console.log(`wrote ${name}.png`);
  }

  // ---- 2. Click-through checks -------------------------------------------
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
  await page.setViewport(VIEWPORT);
  await page.goto(url(), { waitUntil: "networkidle0" });
  await settle();

  let s = await read(page);
  console.log("\nStarting state");
  check("fall slider is on (green, right)", `${s.fallKnob.off}/${s.fallKnob.color}`, `false/${GREEN}`);
  check("location slider is on (green, right)", `${s.locKnob.off}/${s.locKnob.color}`, `false/${GREEN}`);
  check("title", s.title, "Fall detection on");

  console.log("\nFall detection: tap, then 'Keep it on'");
  await page.click("#fall-btn"); await settle();
  s = await read(page);
  check("confirmation opens", s.sheetOpen, true);
  check("sheet asks about fall detection", s.sheetTitle, "Turn off fall detection?");
  await page.click("#sheet-keep"); await settle();
  s = await read(page);
  check("sheet closes", s.sheetOpen, false);
  check("still on", `${s.title}/${s.fallKnob.off}`, "Fall detection on/false");

  console.log("\nFall detection: tap, then 'Turn off'  (the reported bug)");
  await page.click("#fall-btn"); await settle();
  await page.click("#sheet-confirm"); await settle();
  s = await read(page);
  check("title says off", s.title, "Fall detection off");
  check("slider knob is red", s.fallKnob.color, RED);
  check("slider knob moved to the left", s.fallKnob.onLeft, true);
  check("icon disc is red", s.disc, "status-disc off");
  check("hint flips", s.hint, "Tap to turn on");
  check("aria-pressed", s.fallPressed, "false");
  check("sensor row", s.sensor, "Paused");
  check("camera row", s.camera, "Off");
  check("toast", `${s.toastOn} ${s.toast}`, "true Off | Fall detection off. Your contacts were told.");
  check("location untouched", s.locKnob.off, false);
  await page.screenshot({ path: join(shotsDir, "08-after-turning-fall-off.png") });

  console.log("\nFall detection: tap again turns it back on without asking");
  await page.click("#fall-btn"); await settle();
  s = await read(page);
  check("no confirmation", s.sheetOpen, false);
  check("title says on", s.title, "Fall detection on");
  check("slider knob is green", s.fallKnob.color, GREEN);
  check("slider knob back on the right", s.fallKnob.onLeft, false);
  check("icon disc is green", s.disc, "status-disc on");
  check("sensor row", s.sensor, "Receiving");
  check("toast", s.toast, "On | Fall detection on.");

  console.log("\nLocation sharing: tap, then 'Keep it on'");
  await page.click("#loc-btn"); await settle();
  s = await read(page);
  check("confirmation opens", s.sheetOpen, true);
  check("sheet asks about location", s.sheetTitle, "Turn off location sharing?");
  await page.click("#sheet-keep"); await settle();
  s = await read(page);
  check("still on", `${s.sheetOpen}/${s.locKnob.off}`, "false/false");

  console.log("\nLocation sharing: tap, then 'Turn off'");
  await page.click("#loc-btn"); await settle();
  await page.click("#sheet-confirm"); await settle();
  s = await read(page);
  check("slider knob is red", s.locKnob.color, RED);
  check("slider knob moved to the left", s.locKnob.onLeft, true);
  check("row text", s.locVal, "Off \u00b7 not sent with alerts");
  check("aria-pressed", s.locPressed, "false");
  check("toast", s.toast, "Off | Location sharing off. Your contacts were told.");
  check("fall detection untouched", `${s.title}/${s.fallKnob.off}`, "Fall detection on/false");
  await page.screenshot({ path: join(shotsDir, "09-after-turning-location-off.png") });

  console.log("\nLocation sharing: tap again turns it back on without asking");
  await page.click("#loc-btn"); await settle();
  s = await read(page);
  check("no confirmation", s.sheetOpen, false);
  check("slider knob is green", s.locKnob.color, GREEN);
  check("row text", s.locVal, "On \u00b7 sent with a fall alert");

  console.log("\nNavigation");
  await page.click('.tab[data-tab="contacts"]'); await settle();
  check("contacts tab opens contacts", await page.$eval("#screen-contacts", (e) => e.classList.contains("on")), true);
  await page.click("#screen-contacts .contact"); await settle();
  check("contact row opens edit form", await page.$eval("#screen-edit", (e) => e.classList.contains("on")), true);
  await page.click("#screen-edit .back"); await settle();
  check("back returns to contacts", await page.$eval("#screen-contacts", (e) => e.classList.contains("on")), true);
  await page.click('.tab[data-tab="home"]'); await settle();
  check("home tab returns home", await page.$eval("#screen-home", (e) => e.classList.contains("on")), true);

  console.log("\nTrust panel");
  await page.evaluate(() => go("trust")); await settle();
  // The trust panel must render from the committed SBOM data, not from
  // placeholders. If data/trust-panel.js is missing the screen would still
  // load but the headline would read "Record missing" and we'd catch it.
  const trust = await page.evaluate(() => {
    const t = (id) => document.getElementById(id).textContent.trim();
    const groups = Array.from(document.querySelectorAll("#trust-groups .group-row"));
    return {
      hasData: !!window.TRUST_DATA,
      runtimeTotal: window.TRUST_DATA?.runtimeTotal,
      headline: t("trust-headline"),
      runtimeN: t("trust-runtime-n"),
      vulnLine: t("trust-vuln-line"),
      ago: t("trust-ago"),
      when: t("trust-when"),
      groupCount: groups.length,
      firstGroupOpen: groups[0]?.classList.contains("is-open"),
      pkgs: t("trust-stat-pkgs"),
      vulns: t("trust-stat-vulns"),
      jobs: t("trust-stat-jobs"),
      tabActive: document.querySelector('.tab[data-tab="trust"]').classList.contains("is-active"),
    };
  });
  check("SBOM data loaded", trust.hasData, true);
  check("record traces to a real run", trust.headline, "Verified clean");
  check("runtime count is a real number", Number.isInteger(trust.runtimeTotal) && trust.runtimeTotal > 0, true);
  check("runtime count surfaced in copy", trust.runtimeN, String(trust.runtimeTotal));
  check("vulnerability line reflects 0 known", trust.vulnLine, "No known safety issues.");
  check("'checked' relative time is present", trust.ago.length > 0, true);
  check("'checked' absolute time is present", /UTC$/.test(trust.when), true);
  check("five purpose groups rendered", trust.groupCount, 5);
  check("groups start collapsed", trust.firstGroupOpen, false);
  check("packages-checked stat surfaces CRACI number", trust.pkgs, "181");
  check("known-issues stat matches 0 from dashboard", trust.vulns, "0");
  check("jobs stat matches 5/5 from dashboard", trust.jobs, "5/5");
  check("trust tab lights up", trust.tabActive, true);

  // Tapping a group should reveal the real component names, not generic text.
  await page.click("#trust-groups .group-row"); await settle();
  const firstGroup = await page.evaluate(() => {
    const row = document.querySelector("#trust-groups .group-row");
    return {
      open: row.classList.contains("is-open"),
      aria: row.getAttribute("aria-expanded"),
      chips: Array.from(row.querySelectorAll(".comp-chip")).map((c) => c.firstChild.textContent.trim()),
    };
  });
  check("tap opens the first group", firstGroup.open, true);
  check("aria-expanded flips", firstGroup.aria, "true");
  check("component chips show real package names", firstGroup.chips.includes("anthropic"), true);
  await page.screenshot({ path: join(shotsDir, "12-trust-group-open.png") });

  // One more framing of the trust screen scrolled to the CRACI credits.
  // Dismiss any lingering toast from earlier steps so the credit panel is
  // unobstructed in the screenshot used for the pitch.
  await page.evaluate(() => {
    document.getElementById("toast").classList.remove("on");
    document.getElementById("screen-trust").scrollTo(0, 99999);
  });
  await settle();
  await page.screenshot({ path: join(shotsDir, "13-trust-bottom.png") });
  await page.evaluate(() => document.getElementById("screen-trust").scrollTo(0, 0));
  await settle();

  console.log("\nRaw technical list");
  // The link sits at the bottom of a scrollable screen, past the viewport.
  // Click it programmatically rather than fighting the scroll container.
  await page.evaluate(() => document.getElementById("raw-link").click());
  await settle();
  const raw = await page.evaluate(() => {
    const t = (id) => document.getElementById(id).textContent.trim();
    const rows = (sel) => Array.from(document.querySelectorAll(sel + " .raw-item span:first-child"))
      .map((e) => e.textContent.trim());
    return {
      onScreen: document.getElementById("screen-rawsbom").classList.contains("on"),
      tabStillTrust: document.querySelector('.tab[data-tab="trust"]').classList.contains("is-active"),
      serverRows: rows("#raw-server"),
      glassesRows: rows("#raw-glasses"),
      devN: t("raw-dev-n"),
    };
  });
  check("raw screen opens", raw.onScreen, true);
  check("trust tab stays lit on sub-screen", raw.tabStillTrust, true);
  check("server list includes anthropic", raw.serverRows.some((r) => r.startsWith("anthropic")), true);
  check("server list includes opencv-python-headless", raw.serverRows.some((r) => r.startsWith("opencv-python-headless")), true);
  check("glasses list includes react", raw.glassesRows.some((r) => r.startsWith("react ")), true);
  check("glasses list includes @wearables-ui-toolkit/mrbd", raw.glassesRows.some((r) => r.startsWith("@wearables-ui-toolkit/mrbd")), true);
  check("developer-tools count is surfaced honestly", Number(raw.devN) > 0, true);
  await page.evaluate(() => document.getElementById("raw-back").click());
  await settle();
  check("back returns to trust", await page.$eval("#screen-trust", (e) => e.classList.contains("on")), true);

  console.log("\nLayout");
  for (const id of ["screen-home", "screen-contacts", "screen-edit", "screen-trust", "screen-rawsbom"]) {
    await page.evaluate((name) => go(name), id.replace("screen-", ""));
    const overflow = await page.$eval("#" + id, (e) => e.scrollWidth - e.clientWidth);
    check(`${id} has no sideways overflow`, overflow, 0);
  }
  check("no JavaScript errors", errors.join("; "), "");
  await page.close();
} finally {
  await browser.close();
}

console.log(failures ? `\n${failures} check(s) FAILED` : "\nAll checks passed");
process.exit(failures ? 1 : 0);
