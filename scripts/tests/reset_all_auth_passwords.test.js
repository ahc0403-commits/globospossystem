const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const scriptPath = path.join(__dirname, '../reset_all_auth_passwords.js');

test('bulk password reset script is quarantined and cannot mutate Auth', () => {
  const source = fs.readFileSync(scriptPath, 'utf8');
  const result = spawnSync(process.execPath, [scriptPath], {
    encoding: 'utf8',
    env: {},
  });

  assert.equal(result.status, 1);
  assert.match(`${result.stdout}${result.stderr}`, /BULK_AUTH_PASSWORD_RESET_DISABLED/);
  assert.doesNotMatch(source, /updateUserById|listUsers|NEW_PASSWORD/);
});
