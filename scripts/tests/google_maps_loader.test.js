const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');

const html = fs.readFileSync(path.join(__dirname, '../../web/index.html'), 'utf8');
const start = html.lastIndexOf('(() => {', html.indexOf('let googleMapsLoadPromise'));
const end = html.indexOf('})();', start) + 5;
const loader = html.slice(start, end);

function fixture() {
  let now = 0;
  let nextId = 0;
  const timers = new Map();
  const scripts = [];
  const window = {
    setTimeout(callback, delay) {
      const id = ++nextId;
      timers.set(id, { callback, at: now + delay });
      return id;
    },
    clearTimeout(id) { timers.delete(id); },
  };
  const context = {
    window,
    Date: { now: () => now },
    document: {
      createElement: () => ({}),
      head: { appendChild: script => scripts.push(script) },
    },
  };
  vm.runInNewContext(loader, context);
  async function advance(milliseconds) {
    const target = now + milliseconds;
    while (true) {
      const next = [...timers.entries()].filter(([, timer]) => timer.at <= target)
        .sort((a, b) => a[1].at - b[1].at)[0];
      if (!next) break;
      now = next[1].at;
      timers.delete(next[0]);
      next[1].callback();
      await Promise.resolve();
      await Promise.resolve();
    }
    now = target;
    await Promise.resolve();
    await Promise.resolve();
  }
  function ready() {
    window.google = { maps: { Map: function Map() {}, MapTypeId: {}, Marker: function Marker() {} } };
  }
  return { window, scripts, advance, ready };
}

test('Maps loader waits for constructors after the bootstrap namespace appears', async () => {
  const f = fixture();
  let settled = false;
  const pending = f.window.globosLoadGoogleMaps('fixture-key').then(() => { settled = true; });
  f.window.google = { maps: {} };
  f.scripts[0].onload();
  await f.advance(100);
  assert.equal(settled, false);
  f.ready();
  await f.advance(25);
  await pending;
  assert.equal(settled, true);
});

test('Maps loader bounds a stalled script download', async () => {
  const f = fixture();
  const rejected = assert.rejects(f.window.globosLoadGoogleMaps('fixture-key'), /GOOGLE_MAPS_READY_TIMEOUT/);
  await f.advance(10000);
  await rejected;
});

test('Maps loader shares an in-flight download', async () => {
  const f = fixture();
  const first = f.window.globosLoadGoogleMaps('fixture-key');
  const second = f.window.globosLoadGoogleMaps('fixture-key');
  assert.equal(first, second);
  assert.equal(f.scripts.length, 1);
  f.ready();
  f.scripts[0].onload();
  await first;
});

test('late Maps authentication failure remains visible and prevents a false ready result', async () => {
  const f = fixture();
  const pending = f.window.globosLoadGoogleMaps('fixture-key');
  f.ready();
  f.scripts[0].onload();
  await pending;
  f.window.gm_authFailure();
  assert.equal(f.window.globosDidGoogleMapsAuthenticationFail(), true);
  await assert.rejects(f.window.globosLoadGoogleMaps('fixture-key'), /GOOGLE_MAPS_AUTHENTICATION_FAILED/);
});
