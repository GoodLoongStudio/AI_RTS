import { chromium } from 'playwright';
import fs from 'node:fs';

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
const errors = [];
page.on('pageerror', err => errors.push(`pageerror: ${err.message}`));
page.on('console', msg => { if (msg.type() === 'error') errors.push(`console: ${msg.text()}`); });
await page.goto('http://127.0.0.1:4173', { waitUntil: 'networkidle' });
await page.waitForTimeout(6500);
const telemetry = await page.evaluate(() => ({
  title: document.title,
  canvas: { width: document.querySelector('#scene')?.width, height: document.querySelector('#scene')?.height },
  fps: Number(document.querySelector('#fps')?.textContent || 0),
  unitCount: document.querySelector('#unit-count')?.textContent,
  strength: document.querySelector('#fleet-strength')?.textContent,
  webgl: !!document.querySelector('#scene')?.getContext('webgl2'),
  shipRows: document.querySelectorAll('.ship-row').length,
}));
fs.mkdirSync('qa/output', { recursive: true });
await page.screenshot({ path: 'qa/output/hero-1920x1080.png', fullPage: true });

await page.mouse.move(960, 540);
await page.mouse.wheel(0, -1450);
await page.waitForTimeout(800);
await page.screenshot({ path: 'qa/output/fleet-close-1920x1080.png', fullPage: true });
await browser.close();
console.log(JSON.stringify({ telemetry, errors }, null, 2));
if (!telemetry.webgl || telemetry.shipRows < 6 || telemetry.fps < 24 || errors.length) process.exit(1);
