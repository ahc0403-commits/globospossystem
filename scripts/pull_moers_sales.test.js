const test = require('node:test');
const assert = require('node:assert/strict');

const mod = require('./pull_moers_sales.js');

test('NOW ZONE profile uses relaxed post-login navigation settings', () => {
  assert.equal(typeof mod.getStoreProfile, 'function');

  const profile = mod.getStoreProfile('NOW ZONE');
  assert.equal(profile.loginWaitUntil, 'domcontentloaded');
  assert.equal(profile.postLoginTimeoutMs, 90000);
});

test('default store profile keeps existing navigation settings', () => {
  const profile = mod.getStoreProfile('BIEN HOA');
  assert.equal(profile.loginWaitUntil, 'networkidle2');
  assert.equal(profile.postLoginTimeoutMs, 45000);
});
