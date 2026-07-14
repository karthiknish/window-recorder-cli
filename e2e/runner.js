#!/usr/bin/env node

import { createRequire } from 'module';
import http from 'http';
import net from 'net';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SOCKET_PATH = '/tmp/window-recorder.sock';
const CDP_PORT = 9222;

const args = process.argv.slice(2);
let specFile = null;
let recordMode = false;
let urlOverride = null;

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--spec') { specFile = args[++i]; }
  else if (args[i] === '--record') { recordMode = true; }
  else if (args[i] === '--url') { urlOverride = args[++i]; }
  else if (args[i] === '--help' || args[i] === '-h') {
    printUsage();
    process.exit(0);
  }
}

function printUsage() {
  console.log(`
wr-e2e — E2E Test Runner with WindowRecorder + Chrome DevTools Protocol

Usage:
  node runner.js [options]

Options:
  --spec <file>     JSON test spec file to run (default: specs/example.json)
  --record          Enable WindowRecorder recording during test execution
  --url <url>       Override the start URL from the spec
  --help, -h        Show this help

Test Spec Format (JSON):
  {
    "name": "Example test",
    "url": "http://localhost:3000",
    "app": "Google Chrome",
    "steps": [
      { "action": "navigate", "url": "http://localhost:3000" },
      { "action": "click", "selector": "#login-btn" },
      { "action": "type", "selector": "#email", "text": "user@example.com" },
      { "action": "assert", "selector": "h1", "expected": "Dashboard" },
      { "action": "wait", "ms": 2000 },
      { "action": "screenshot", "path": "screenshots/step1.png" }
    ]
  }

Actions:
  navigate  — Navigate to a URL (field: url)
  click     — Click an element (field: selector)
  type      — Type text into an input (fields: selector, text)
  assert    — Assert element text matches (fields: selector, expected)
  wait      — Wait for N ms (field: ms)
  screenshot — Take a screenshot (field: path, optional)
  scroll    — Scroll to element (field: selector)
  select    — Select an option (fields: selector, value)
  press     — Press a key (field: key, e.g. "Enter", "Tab")
  evaluate  — Evaluate JS expression (field: expression)
`);
}

if (!specFile) {
  specFile = path.join(__dirname, 'specs', 'example.json');
}

// ─── CDP Client ──────────────────────────────────────────────────────

class CDPClient {
  constructor() {
    this.ws = null;
    this.msgId = 0;
    this.pending = new Map();
    this.enabledDomains = new Set();
  }

  async connect() {
    const tabs = await this.listTabs();
    const tab = tabs.find(t => t.type === 'page') || tabs[0];
    if (!tab) throw new Error('No Chrome tab found. Is Chrome running with --remote-debugging-port=9222?');

    const WebSocket = await import('ws').then(m => m.default).catch(() => null);
    if (!WebSocket) {
      throw new Error('ws module not found. Install with: npm install ws');
    }

    this.ws = new WebSocket(tab.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => {
      this.ws.on('open', resolve);
      this.ws.on('error', reject);
    });

    this.ws.on('message', (data) => {
      const msg = JSON.parse(data.toString());
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(JSON.stringify(msg.error)));
        else resolve(msg.result);
      }
    });

    await this.send('Page.enable');
    await this.send('Runtime.enable');
    await this.send('DOM.enable');
    console.log(`Connected to Chrome tab: ${tab.title || tab.url}`);
  }

  async listTabs() {
    return new Promise((resolve, reject) => {
      const req = http.get(`http://localhost:${CDP_PORT}/json`, (res) => {
        let data = '';
        res.on('data', (chunk) => data += chunk);
        res.on('end', () => {
          try { resolve(JSON.parse(data)); }
          catch (e) { reject(new Error('Failed to parse Chrome tabs response')); }
        });
      });
      req.on('error', () => {
        reject(new Error(`Cannot connect to Chrome DevTools on port ${CDP_PORT}. Launch Chrome with: /Applications/Google\\ Chrome.app/Contents/MacOS/Google\\ Chrome --remote-debugging-port=9222`));
      });
      req.setTimeout(3000, () => req.destroy());
    });
  }

  async send(method, params = {}) {
    const id = ++this.msgId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }

  async navigate(url) {
    await this.send('Page.navigate', { url });
    await this.waitForLoad();
  }

  async waitForLoad() {
    return new Promise((resolve) => {
      const handler = (data) => {
        const msg = JSON.parse(data.toString());
        if (msg.method === 'Page.loadEventFired') {
          this.ws.off('message', handler);
          setTimeout(resolve, 500);
        }
      };
      this.ws.on('message', handler);
      setTimeout(() => {
        this.ws.off('message', handler);
        resolve();
      }, 10000);
    });
  }

  async evaluate(expression) {
    const result = await this.send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (result.exceptionDetails) {
      throw new Error(`JS error: ${result.exceptionDetails.text}`);
    }
    return result.result.value;
  }

  async click(selector) {
    const s = JSON.stringify(selector);
    await this.evaluate(`
      (function() {
        const el = document.querySelector(${s});
        if (!el) throw new Error('Element not found: ' + ${s});
        el.click();
      })()
    `);
  }

  async type(selector, text) {
    const s = JSON.stringify(selector);
    const t = JSON.stringify(text);
    await this.evaluate(`
      (function() {
        const el = document.querySelector(${s});
        if (!el) throw new Error('Element not found: ' + ${s});
        el.focus();
        el.value = ${t};
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      })()
    `);
  }

  async selectOption(selector, value) {
    const s = JSON.stringify(selector);
    const v = JSON.stringify(value);
    await this.evaluate(`
      (function() {
        const el = document.querySelector(${s});
        if (!el) throw new Error('Element not found: ' + ${s});
        el.value = ${v};
        el.dispatchEvent(new Event('change', { bubbles: true }));
      })()
    `);
  }

  async pressKey(key) {
    const keyMap = {
      'Enter': { key: 'Enter', keyCode: 13, code: 'Enter' },
      'Tab': { key: 'Tab', keyCode: 9, code: 'Tab' },
      'Escape': { key: 'Escape', keyCode: 27, code: 'Escape' },
      'Space': { key: ' ', keyCode: 32, code: 'Space' },
    };
    const keyDef = keyMap[key] || { key, keyCode: 0, code: key };

    await this.send('Input.dispatchKeyEvent', {
      type: 'keyDown', ...keyDef
    });
    await this.send('Input.dispatchKeyEvent', {
      type: 'keyUp', ...keyDef
    });
  }

  async scrollTo(selector) {
    const s = JSON.stringify(selector);
    await this.evaluate(`
      (function() {
        const el = document.querySelector(${s});
        if (!el) throw new Error('Element not found: ' + ${s});
        el.scrollIntoView({ behavior: 'smooth', block: 'center' });
      })()
    `);
  }

  async submit(selector) {
    const s = JSON.stringify(selector);
    await this.evaluate(`
      (function() {
        const el = document.querySelector(${s});
        if (!el) throw new Error('Element not found: ' + ${s});
        if (el.form) { el.form.submit(); }
        else if (el.tagName === 'FORM') { el.submit(); }
        else { el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', keyCode: 13, bubbles: true })); }
      })()
    `);
  }

  async assertText(selector, expected) {
    const actual = await this.evaluate(`
      (function() {
        const el = document.querySelector(${JSON.stringify(selector)});
        if (!el) return null;
        return el.textContent || el.innerText || '';
      })()
    `);
    if (actual === null) {
      throw new Error(`Assert failed: element "${selector}" not found`);
    }
    const trimmed = actual.trim();
    if (!trimmed.includes(expected)) {
      throw new Error(`Assert failed: expected "${expected}" in "${selector}", got "${trimmed}"`);
    }
  }

  async screenshot(outPath) {
    const result = await this.send('Page.captureScreenshot', { format: 'png' });
    const dir = path.dirname(outPath);
    if (dir && !fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(outPath, Buffer.from(result.data, 'base64'));
  }

  async close() {
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
  }
}

// ─── WindowRecorder CLI ──────────────────────────────────────────────

function wrCmd(...cmdArgs) {
  try {
    const result = execSync(`wr ${cmdArgs.join(' ')}`, { encoding: 'utf-8', timeout: 15000 });
    return result.trim();
  } catch (e) {
    return e.stdout || e.message;
  }
}

import { execSync } from 'child_process';

function wrSend(payload) {
  return new Promise((resolve, reject) => {
    const client = net.createConnection(SOCKET_PATH, () => {
      client.write(JSON.stringify(payload) + '\n');
    });
    let data = '';
    client.on('data', (chunk) => { data += chunk; });
    client.on('end', () => {
      try { resolve(JSON.parse(data)); }
      catch { resolve(data); }
    });
    client.on('error', () => {
      reject(new Error('Cannot connect to WindowRecorder. Run: wr launch'));
    });
    setTimeout(() => client.destroy(), 10000);
  });
}

async function wrLaunch() {
  console.log('[recorder] Launching WindowRecorder...');
  try {
    execSync('wr launch', { encoding: 'utf-8', timeout: 15000 });
  } catch (e) {
    console.log('[recorder] Already running or launch failed:', e.message);
  }
}

async function wrStart(app, outPath, duration) {
  console.log(`[recorder] Starting recording: app="${app}" out="${outPath}"`);
  const result = await wrSend({ cmd: 'start', app, out: outPath, duration });
  console.log('[recorder] Start result:', JSON.stringify(result));
  return result;
}

async function wrStop() {
  console.log('[recorder] Stopping recording...');
  const result = await wrSend({ cmd: 'stop' });
  console.log('[recorder] Stop result:', JSON.stringify(result));
  return result;
}

async function wrStatus() {
  return await wrSend({ cmd: 'status' });
}

async function wrKill() {
  try { execSync('wr kill', { encoding: 'utf-8', timeout: 5000 }); } catch {}
}

// ─── Test Runner ─────────────────────────────────────────────────────

async function runSpec(specPath) {
  const spec = JSON.parse(fs.readFileSync(specPath, 'utf-8'));
  const testUrl = urlOverride || spec.url;
  const appName = spec.app || 'Google Chrome';
  const recordingPath = path.join(__dirname, '..', 'recordings', `${spec.name.replace(/\s+/g, '_')}_${Date.now()}.mov`);

  console.log(`\n========================================`);
  console.log(`  E2E Test: ${spec.name}`);
  console.log(`  Spec: ${specPath}`);
  console.log(`  URL:  ${testUrl}`);
  console.log(`  Steps: ${spec.steps.length}`);
  console.log(`  Record: ${recordMode ? 'YES' : 'NO'}`);
  console.log(`========================================\n`);

  const cdp = new CDPClient();
  let passed = 0;
  let failed = 0;
  const results = [];

  try {
    // Connect to Chrome
    await cdp.connect();

    // Start recording if enabled
    if (recordMode) {
      await wrLaunch();
      await new Promise(r => setTimeout(r, 1000));
      await wrStart(appName, recordingPath, 0);

      // Give recorder a moment to start capturing
      await new Promise(r => setTimeout(r, 1500));
    }

    // Navigate to initial URL
    if (testUrl) {
      console.log(`[step] Navigate to ${testUrl}`);
      await cdp.navigate(testUrl);
    }

    // Execute steps
    for (let i = 0; i < spec.steps.length; i++) {
      const step = spec.steps[i];
      const stepLabel = `Step ${i + 1}/${spec.steps.length}: ${step.action}`;
      console.log(`[step] ${stepLabel}`);

      try {
        switch (step.action) {
          case 'navigate':
            await cdp.navigate(step.url);
            break;
          case 'click':
            await cdp.click(step.selector);
            break;
          case 'type':
            await cdp.type(step.selector, step.text);
            break;
          case 'select':
            await cdp.selectOption(step.selector, step.value);
            break;
          case 'press':
            await cdp.pressKey(step.key);
            break;
          case 'scroll':
            await cdp.scrollTo(step.selector);
            break;
          case 'assert':
            await cdp.assertText(step.selector, step.expected);
            console.log(`  ✓ assert passed: "${step.selector}" contains "${step.expected}"`);
            break;
          case 'wait':
            await new Promise(r => setTimeout(r, step.ms || 1000));
            break;
          case 'screenshot':
            const ssPath = step.path
              ? path.resolve(__dirname, step.path)
              : path.join(__dirname, 'screenshots', `step_${i + 1}.png`);
            await cdp.screenshot(ssPath);
            console.log(`  screenshot saved: ${ssPath}`);
            break;
          case 'evaluate':
            const evalResult = await cdp.evaluate(step.expression);
            if (step.expected !== undefined && String(evalResult) !== String(step.expected)) {
              throw new Error(`Evaluate assert failed: expected "${step.expected}", got "${evalResult}"`);
            }
            console.log(`  result: ${evalResult}`);
            break;
          default:
            throw new Error(`Unknown action: ${step.action}`);
        }
        passed++;
        results.push({ step: i + 1, action: step.action, status: 'pass' });
      } catch (err) {
        failed++;
        console.error(`  ✗ FAILED: ${err.message}`);
        results.push({ step: i + 1, action: step.action, status: 'fail', error: err.message });

        // Take failure screenshot
        const failPath = path.join(__dirname, 'screenshots', `failure_step_${i + 1}.png`);
        try { await cdp.screenshot(failPath); } catch {}
      }
    }

  } finally {
    // Stop recording if enabled
    if (recordMode) {
      await new Promise(r => setTimeout(r, 500));
      await wrStop();
      console.log(`[recorder] Recording saved: ${recordingPath}`);
    }

    await cdp.close();
  }

  // Summary
  console.log(`\n========================================`);
  console.log(`  Results: ${passed} passed, ${failed} failed`);
  if (recordMode) {
    console.log(`  Recording: ${recordingPath}`);
  }
  console.log(`========================================\n`);

  // Write results JSON
  const resultsPath = path.join(__dirname, 'results.json');
  fs.writeFileSync(resultsPath, JSON.stringify({
    spec: spec.name,
    timestamp: new Date().toISOString(),
    passed,
    failed,
    total: spec.steps.length,
    recording: recordMode ? recordingPath : null,
    steps: results,
  }, null, 2));

  process.exit(failed > 0 ? 1 : 0);
}

// ─── Main ────────────────────────────────────────────────────────────

if (!fs.existsSync(specFile)) {
  console.error(`Spec file not found: ${specFile}`);
  console.error('Create a test spec JSON file or use the default: specs/example.json');
  process.exit(1);
}

runSpec(specFile).catch(err => {
  console.error('Fatal error:', err.message);
  process.exit(1);
});
