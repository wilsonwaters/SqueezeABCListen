#!/usr/bin/env node
// screenshot.mjs - load a URL in headless Chromium and save a PNG screenshot.
// Usage: node dev/browser/screenshot.mjs <url> <out.png> [--full] [--wait-ms N] [--width W --height H]
// Uses the pre-installed browsers in $PLAYWRIGHT_BROWSERS_PATH (/opt/pw-browsers); playwright is
// pinned to 1.56.1 to match chromium-1194 there. Never run `playwright install`.
import { chromium } from 'playwright';

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(name);
  if (i < 0) return def;
  const v = args[i + 1];
  args.splice(i, 2);
  return v;
};
const full = args.includes('--full');
if (full) args.splice(args.indexOf('--full'), 1);
const waitMs = Number(opt('--wait-ms', 1500));
const width = Number(opt('--width', 1280));
const height = Number(opt('--height', 900));
const [url, out] = args;
if (!url || !out) {
  console.error('usage: node screenshot.mjs <url> <out.png> [--full] [--wait-ms N] [--width W --height H]');
  process.exit(2);
}

const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width, height } });
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  const resp = await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });
  await page.waitForTimeout(waitMs); // let LMS's JS (Material/Default skin) finish rendering
  await page.screenshot({ path: out, fullPage: full });
  console.log(JSON.stringify({ url, status: resp?.status(), title: await page.title(), out, pageErrors: errors }));
} finally {
  await browser.close();
}
