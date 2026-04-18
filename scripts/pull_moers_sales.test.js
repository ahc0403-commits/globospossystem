const test = require('node:test');
const assert = require('node:assert/strict');

const mod = require('./pull_moers_sales.js');

test('NOW ZONE profile uses relaxed post-login navigation settings', () => {
  assert.equal(typeof mod.getStoreProfile, 'function');

  const profile = mod.getStoreProfile('NOW ZONE');
  assert.equal(profile.loginWaitUntil, 'domcontentloaded');
  assert.equal(profile.postLoginTimeoutMs, 90000);
  assert.equal(profile.allowDirectDailyPageFallback, true);
});

test('default store profile keeps existing navigation settings', () => {
  const profile = mod.getStoreProfile('BIEN HOA');
  assert.equal(profile.loginWaitUntil, 'networkidle2');
  assert.equal(profile.postLoginTimeoutMs, 45000);
  assert.equal(profile.allowDirectDailyPageFallback, false);
});

test('navigation timeout is eligible for direct daily-page fallback only when enabled', () => {
  const timeoutError = new Error('Navigation timeout of 90000 ms exceeded');

  assert.equal(
    mod.shouldFallbackToDirectDailyPage(timeoutError, mod.getStoreProfile('NOW ZONE')),
    true,
  );
  assert.equal(
    mod.shouldFallbackToDirectDailyPage(timeoutError, mod.getStoreProfile('BIEN HOA')),
    false,
  );
  assert.equal(
    mod.shouldFallbackToDirectDailyPage(
      new Error('Login failed - check credentials'),
      mod.getStoreProfile('NOW ZONE'),
    ),
    false,
  );
});
