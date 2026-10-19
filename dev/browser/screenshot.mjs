#!/usr/bin/env node
// screenshot.mjs - load a URL in headless Chromium and save a PNG screenshot.
// Usage: node dev/browser/screenshot.mjs <url> <out.png> [--full] [--wait-ms N] [--width W --height H]
//          [--wait-until load|domcontentloaded|networkidle|commit] [--selector CSS] [--timeout MS]
// --wait-until : navigation event to wait for (default networkidle). Material skin (/material/)
//                keeps a cometd long-poll open, so networkidle never fires there: for /material/
//                URLs the default is "load" plus --selector '#main-toolbar'.
// --selector   : also wait until this CSS selector is visible (e.g. '#browse-list' for Material).
// --wait-ms    : extra settle time after that (default 1500).
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
const timeout = Number(opt('--timeout', 30000));
let waitUntil = opt('--wait-until', undefined);
let selector = opt('--selector', undefined);
const [url, out] = args;
if (!url || !out) {
  console.error('usage: node screenshot.mjs <url> <out.png> [--full] [--wait-ms N] [--width W --height H]' +
    ' [--wait-until load|domcontentloaded|networkidle|commit] [--selector CSS] [--timeout MS]');
  process.exit(2);
}
const isMaterial = /^\/material(\/|$)/.test(new URL(url).pathname);
waitUntil ??= isMaterial ? 'load' : 'networkidle';
if (selector === undefined && isMaterial) selector = '#main-toolbar';

const browser = await chromium.launch({ headless: true });
try {
  // Material throws on the container's default locale (en-US@posix) and then renders no dialogs or player status.
  const page = await browser.newPage({ viewport: { width, height }, locale: 'en-AU' });
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  const resp = await page.goto(url, { waitUntil, timeout });
  if (selector) await page.waitForSelector(selector, { state: 'visible', timeout });
  await page.waitForTimeout(waitMs); // let LMS's JS (Material/Default skin) finish rendering
  await page.screenshot({ path: out, fullPage: full });
  console.log(JSON.stringify({ url, status: resp?.status(), title: await page.title(), out, waitUntil, selector: selector ?? null, pageErrors: errors }));
} finally {
  await browser.close();
}
