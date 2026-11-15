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
const settle = () => new Promise((r) => setTimeout(r, 400));

// The app sits behind a sign-in screen and keeps its session and profile in
// localStorage. Every check below except the sign-in gate itself needs a
// signed-in wearer with a saved profile, so seed one before the page's own
// scripts run. These keys and the profile shape mirror index.html.
const DEMO_EMAIL = "demo@upright.test";
const DEMO_PROFILE = {
  userName: "Demo Wearer",
  glassesModel: "Meta Ray-Ban Wayfarer",
  contactName: "Elena Lakhani",
  contactRelation: "Parent",
  contactPhone: "+39 342 149 6978",
};
async function signedInPage(browser) {
  const page = await browser.newPage();
  await page.setViewport(VIEWPORT);
  await page.evaluateOnNewDocument((email, profile) => {
    localStorage.setItem("upright.session.v1", email);
    localStorage.setItem("upright.profile.v1:" + email, JSON.stringify(profile));
  }, DEMO_EMAIL, DEMO_PROFILE);
  return page;
}

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
  ["16-profile", "#/profile"],
  ["17-fall-detected", "#/fall-detected"],
  ["18-fall-alert", "#/fall-alert"],
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
    const orb = document.getElementById("fall-btn");
    return {
      // Fall protection is the large round button on the home screen.
      orbOff: orb.classList.contains("is-off"),
      orbLabel: orb.getAttribute("aria-label"),
      orbAction: text("orb-action"),
      locKnob: knob("loc-sw"),
      title: text("st-title"),
      sub: text("st-sub"),
      locVal: text("loc-val"),
      fallPressed: orb.getAttribute("aria-pressed"),
      locPressed: document.getElementById("loc-btn").getAttribute("aria-pressed"),
      sheetOpen: document.getElementById("scrim").classList.contains("on"),
      sheetTitle: text("sheet-title"),
      toastOn: document.getElementById("toast").classList.contains("on"),
      toast: text("toast-tag") + " | " + text("toast-text"),
    };
  });

const browser = await puppeteer.launch({ headless: "new" });
try {
  const isOn = (page, id) => page.$eval("#" + id, (e) => e.classList.contains("on"));

  // ---- 0. The sign-in gate ------------------------------------------------
  // A separate browser context has empty storage, so this is what a first
  // visit looks like: nothing behind the gate should be reachable.
  console.log("Sign-in gate");
  const guest = await browser.createBrowserContext();
  const gate = await guest.newPage();
  await gate.setViewport(VIEWPORT);
  await gate.goto(url("#/trust"), { waitUntil: "networkidle0" });
  await settle();
  check("without a session the app opens on sign-in", await isOn(gate, "screen-auth"), true);
  check("a deep link cannot skip sign-in", await isOn(gate, "screen-trust"), false);
  check("tab bar is hidden on sign-in",
    await gate.$eval(".tabbar", (e) => getComputedStyle(e).display), "none");
  await gate.screenshot({ path: join(shotsDir, "00-sign-in.png") });
  console.log("wrote 00-sign-in.png");
  await guest.close();

  // ---- 1. Screenshots of every state -------------------------------------
  for (const [name, hash] of shots) {
    const page = await signedInPage(browser);
    await page.goto(url(hash), { waitUntil: "networkidle0" });
    await settle();
    await page.screenshot({ path: join(shotsDir, `${name}.png`) });
    await page.close();
    console.log(`wrote ${name}.png`);
  }

  // ---- 2. Click-through checks -------------------------------------------
  const page = await signedInPage(browser);
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
  await page.goto(url(), { waitUntil: "networkidle0" });
  await settle();

  // Read the palette from the page instead of hard-coding it here, so a
  // restyle changes the colours without breaking the behaviour checks.
  const palette = await page.evaluate(() => {
    const probe = document.createElement("span");
    document.body.appendChild(probe);
    const resolve = (name) => {
      probe.style.color = `var(${name})`;
      return getComputedStyle(probe).color;
    };
    const out = { green: resolve("--green"), aqua: resolve("--aqua") };
    probe.remove();
    return out;
  });

  let s = await read(page);
  console.log("\nStarting state");
  check("a signed-in wearer lands on home", await isOn(page, "screen-home"), true);
  check("fall protection starts on", `${s.orbOff}/${s.fallPressed}`, "false/true");
  check("location slider is on (accent colour, right)", `${s.locKnob.off}/${s.locKnob.color}`, `false/${palette.aqua}`);
  check("title", s.title, "Protection is on");
  const locOnColor = s.locKnob.color;

  console.log("\nFall detection: tap, then 'Keep it on'");
  await page.click("#fall-btn"); await settle();
  s = await read(page);
  check("confirmation opens", s.sheetOpen, true);
  check("sheet asks about fall detection", s.sheetTitle, "Turn off fall detection?");
  await page.click("#sheet-keep"); await settle();
  s = await read(page);
  check("sheet closes", s.sheetOpen, false);
  check("still on", `${s.title}/${s.orbOff}`, "Protection is on/false");

  console.log("\nFall detection: tap, then 'Turn off'  (the reported bug)");
  await page.click("#fall-btn"); await settle();
  await page.click("#sheet-confirm"); await settle();
  s = await read(page);
  check("title says paused", s.title, "Protection is paused");
  check("orb shows the off state", s.orbOff, true);
  check("orb prompt flips", s.orbAction, "Tap to activate");
  check("orb label flips", s.orbLabel, "Activate fall protection");
  check("caption says paused", s.sub, "Fall protection paused \u00b7 tap to turn it back on");
  check("aria-pressed", s.fallPressed, "false");
  check("toast", `${s.toastOn} ${s.toast}`, "true Off | Fall detection off in this demo. No alert was sent.");
  check("location untouched", s.locKnob.off, false);
  await page.screenshot({ path: join(shotsDir, "08-after-turning-fall-off.png") });

  console.log("\nFall detection: tap again turns it back on without asking");
  await page.click("#fall-btn"); await settle();
  s = await read(page);
  check("no confirmation", s.sheetOpen, false);
  check("title says on", s.title, "Protection is on");
  check("orb shows the on state", s.orbOff, false);
  check("orb prompt flips back", s.orbAction, "Tap to pause");
  check("orb label flips back", s.orbLabel, "Deactivate fall protection");
  check("toast", s.toast, "On | Fall detection on in this demo.");

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
  check("slider knob changes colour when off", s.locKnob.color !== locOnColor, true);
  check("slider knob moved to the left", s.locKnob.onLeft, true);
  check("row text", s.locVal, "Off \u00b7 excluded from demo");
  check("aria-pressed", s.locPressed, "false");
  check("toast", s.toast, "Off | Location sharing off in this demo. No alert was sent.");
  check("fall detection untouched", `${s.title}/${s.orbOff}`, "Protection is on/false");
  await page.screenshot({ path: join(shotsDir, "09-after-turning-location-off.png") });

  console.log("\nLocation sharing: tap again turns it back on without asking");
  await page.click("#loc-btn"); await settle();
  s = await read(page);
  check("no confirmation", s.sheetOpen, false);
  check("slider knob is back to the accent colour", s.locKnob.color, palette.aqua);
  check("slider knob back on the right", s.locKnob.onLeft, false);
  check("row text", s.locVal, "On \u00b7 shown in demo only");

  console.log("\nNavigation");
  const homeContact = await page.$eval("#home-contact-list .contact-name", (e) => e.textContent.trim());
  check("home shows the saved emergency contact", homeContact, DEMO_PROFILE.contactName);
  await page.click('.tab[data-tab="contacts"]'); await settle();
  check("contacts tab opens contacts", await isOn(page, "screen-contacts"), true);
  check("contacts lists the saved contact",
    await page.$eval("#contacts-list .contact-info", (e) => e.textContent.trim()), DEMO_PROFILE.contactPhone);
  await page.click("#screen-contacts .contact"); await settle();
  check("contact row opens the contact editor", await isOn(page, "screen-edit"), true);
  check("contact form is filled from the saved profile",
    await page.$eval('#contact-form [name="contactName"]', (e) => e.value), DEMO_PROFILE.contactName);
  await page.click("#screen-edit .back"); await settle();
  check("back returns to contacts", await isOn(page, "screen-contacts"), true);
  await page.click('.tab[data-tab="home"]'); await settle();
  check("home tab returns home", await isOn(page, "screen-home"), true);
  await page.click('.tab[data-tab="trust"]'); await settle();
  check("trust tab opens the trust panel", await isOn(page, "screen-trust"), true);
  await page.click('.tab[data-tab="home"]'); await settle();
  check("home tab returns home", await isOn(page, "screen-home"), true);

  // The fall preview sits below the fold of a scrolling screen, so its
  // buttons are clicked through the DOM rather than by coordinates.
  console.log("\nFall preview flow");
  const tap = (sel) => page.evaluate((q) => document.querySelector(q).click(), sel);
  await tap(".fall-preview"); await settle();
  check("preview opens the countdown", await isOn(page, "screen-fall-detected"), true);
  check("tab bar is hidden during an alert",
    await page.$eval(".tabbar", (e) => getComputedStyle(e).display), "none");
  const countdown = Number(await page.$eval("#fall-countdown", (e) => e.textContent.trim()));
  check("countdown is running from 20", countdown > 0 && countdown <= 20, true);
  await tap("#screen-fall-detected .btn.ink"); await settle();
  check("'I am fine' cancels the alert", await isOn(page, "screen-fall-safe"), true);
  await tap("#screen-fall-safe .btn.ink"); await settle();
  check("cancelled flow returns home", await isOn(page, "screen-home"), true);
  await tap(".fall-preview"); await settle();
  await tap("#screen-fall-detected .fall-help-btn"); await settle();
  check("'ask for help' shows the alert screen", await isOn(page, "screen-fall-alert"), true);
  check("alert names the saved emergency contact",
    await page.$eval("#fall-alert-contact", (e) => e.textContent.trim()), DEMO_PROFILE.contactName);
  await tap("#screen-fall-alert .btn.ink"); await settle();
  check("alert flow returns home", await isOn(page, "screen-home"), true);
  check("tab bar is back after the alert",
    await page.$eval(".tabbar", (e) => getComputedStyle(e).display) !== "none", true);

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
      evidenceSource: window.TRUST_DATA?.evidence?.source,
      evidenceRun: window.TRUST_DATA?.evidence?.run?.id,
      packagesChecked: window.TRUST_DATA?.run?.packagesChecked,
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
  // The ticks must rest on SBOMs downloaded from CRACI for a named run, not
  // on the lockfile fallback.
  check("ticks rest on CRACI's own record", trust.evidenceSource, "craci");
  check("the record names the run it came from", /^\d+$/.test(trust.evidenceRun || ""), true);
  check("record traces to a real run", trust.headline, "Verified clean");
  check("runtime count is a real number", Number.isInteger(trust.runtimeTotal) && trust.runtimeTotal > 0, true);
  check("runtime count surfaced in copy", trust.runtimeN, String(trust.runtimeTotal));
  check("vulnerability line reflects 0 known", trust.vulnLine, "No known safety issues.");
  check("'checked' relative time is present", trust.ago.length > 0, true);
  check("'checked' absolute time is present", /UTC$/.test(trust.when), true);
  check("five purpose groups rendered", trust.groupCount, 5);
  check("groups start collapsed", trust.firstGroupOpen, false);
  check("packages-checked is a real total", Number.isInteger(trust.packagesChecked) && trust.packagesChecked > 0, true);
  check("packages-checked stat shows the total CRACI recorded", trust.pkgs, String(trust.packagesChecked));
  check("known-issues stat matches 0 from dashboard", trust.vulns, "0");
  check("jobs stat shows all five CRACI jobs succeeded", trust.jobs, "5/5");
  check("trust tab lights up", trust.tabActive, true);

  // Tapping a group should reveal the real component names, not generic text.
  await page.click("#trust-groups .group-row"); await settle();
  const firstGroup = await page.evaluate(() => {
    const row = document.querySelector("#trust-groups .group-row");
    return {
      open: row.classList.contains("is-open"),
      aria: row.getAttribute("aria-expanded"),
      names: Array.from(row.querySelectorAll(".comp-name")).map((c) => c.textContent.trim()),
      rows: row.querySelectorAll(".comp-row").length,
      ticks: Array.from(row.querySelectorAll(".comp-row .verified")).map((v) => v.textContent.trim()),
      tickColor: getComputedStyle(row.querySelector(".comp-row .verified")).color,
    };
  });
  check("tap opens the first group", firstGroup.open, true);
  check("aria-expanded flips", firstGroup.aria, "true");
  check("component rows show real package names", firstGroup.names.includes("anthropic"), true);
  check("every component row has a tick", firstGroup.ticks.length, firstGroup.rows);
  check("every tick reads Verified", firstGroup.ticks.every((t) => t === "Verified"), true);
  check("tick label uses the app's green", firstGroup.tickColor, palette.green);

  // Across the whole panel: one tick per runtime component, none missing.
  const allTicks = await page.evaluate(() => ({
    rows: document.querySelectorAll("#trust-groups .comp-row").length,
    verified: document.querySelectorAll("#trust-groups .comp-row .verified:not(.is-pending)").length,
    expected: window.TRUST_DATA.runtimeTotal,
  }));
  check("a row exists for every runtime component", allTicks.rows, allTicks.expected);
  check("every runtime component is verified", allTicks.verified, allTicks.expected);

  // CRACI banner under the seal.
  const band = await page.evaluate(() => {
    const b = document.getElementById("craci-band");
    const r = b.getBoundingClientRect();
    const seal = document.getElementById("trust-seal").getBoundingClientRect();
    return {
      text: b.textContent.replace(/\s+/g, " ").trim(),
      visible: r.width > 0 && r.height > 0,
      flush: Math.abs(r.top - seal.bottom) < 2,
    };
  });
  check("CRACI banner names CRACI", /Built and verified by\s*CRACI/.test(band.text), true);
  check("CRACI banner is visible", band.visible, true);
  check("CRACI banner sits flush under the seal", band.flush, true);
  await page.screenshot({ path: join(shotsDir, "12-trust-group-open.png") });

  // The longest group has the longest package names next to the tick, so it
  // is the one most likely to wrap badly. Open it and look.
  await page.evaluate(() => {
    document.getElementById("toast").classList.remove("on");
    const rows = document.querySelectorAll("#trust-groups .group-row");
    rows[0].classList.remove("is-open");
    rows[4].classList.add("is-open");
    rows[4].scrollIntoView({ block: "start" });
  });
  await settle();
  await page.screenshot({ path: join(shotsDir, "15-trust-display-group.png") });
  await page.evaluate(() => {
    document.querySelectorAll("#trust-groups .group-row").forEach((r) => r.classList.remove("is-open"));
    document.getElementById("screen-trust").scrollTo(0, 0);
  });

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
    const rows = (sel) => Array.from(document.querySelectorAll(sel + " .raw-name"))
      .map((e) => e.textContent.trim());
    const items = document.querySelectorAll(".raw-item");
    return {
      rawItems: items.length,
      rawTicks: document.querySelectorAll(".raw-item .verified:not(.is-pending)").length,
      rawBand: document.getElementById("craci-band-raw").textContent.replace(/\s+/g, " ").trim(),
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
  check("every raw row is ticked as verified", raw.rawTicks, raw.rawItems);
  check("raw list names CRACI as the verifier", /Verified by\s*CRACI/.test(raw.rawBand), true);
  // The two ends of each band must not overlap: this is the bug a text
  // assertion cannot see, so measure the boxes.
  const overlap = await page.evaluate(() => {
    const gap = (id) => {
      const b = document.getElementById(id);
      const mark = b.querySelector(".craci-by").getBoundingClientRect();
      const where = b.querySelector(".craci-where").getBoundingClientRect();
      return Math.round(where.left - mark.right);
    };
    return { main: gap("craci-band"), raw: gap("craci-band-raw") };
  });
  check("raw band: label and CRACI do not overlap", overlap.raw >= 4, true);
  await page.screenshot({ path: join(shotsDir, "14-rawsbom-verified.png") });
  await page.evaluate(() => document.getElementById("raw-back").click());
  await settle();
  check("back returns to trust", await page.$eval("#screen-trust", (e) => e.classList.contains("on")), true);

  console.log("\nLayout");
  for (const id of ["screen-home", "screen-contacts", "screen-edit", "screen-profile", "screen-trust", "screen-rawsbom"]) {
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
