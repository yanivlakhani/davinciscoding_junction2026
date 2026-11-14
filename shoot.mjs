// Render each app state in a real iPhone-sized viewport and write a PNG.
import puppeteer from "puppeteer";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { mkdirSync } from "node:fs";

const here = dirname(fileURLToPath(import.meta.url));
const shotsDir = join(here, "shots");
mkdirSync(shotsDir, { recursive: true });

const url = (hash = "") => `file://${join(here, "index.html")}${hash}`;

const shots = [
  ["01-home",     ""],
  ["02-contacts", "#/contacts"],
  ["03-edit",     "#/edit"],
  ["04-confirm",  "#/home?confirm=1"],
];

const browser = await puppeteer.launch({ headless: "new" });
try {
  for (const [name, hash] of shots) {
    const page = await browser.newPage();
    await page.setViewport({ width: 390, height: 844, deviceScaleFactor: 2 });
    await page.goto(url(hash), { waitUntil: "networkidle0" });
    await new Promise((r) => setTimeout(r, 350));
    await page.screenshot({ path: join(shotsDir, `${name}.png`), fullPage: false });
    await page.close();
    console.log(`wrote ${name}.png`);
  }
} finally {
  await browser.close();
}
