const assert = require('node:assert/strict');
const test = require('node:test');

const { scanRepository, scanText } = require('../scan_repository_secrets');

test('repository secret scan rejects high-risk credential formats without echoing values', () => {
  const databaseUrl = ['postgresql://user', 'password@db.example.com:5432/postgres'].join(':');
  const githubToken = ['ghp', 'A'.repeat(32)].join('_');
  const findings = scanText(`${databaseUrl}\n${githubToken}`);

  assert.deepEqual(findings.map(finding => finding.rule), ['database-url', 'github-token']);
  assert.equal(JSON.stringify(findings).includes('password'), false);
  assert.equal(JSON.stringify(findings).includes(githubToken), false);
});

test('tracked repository contains no high-risk credential values', () => {
  assert.deepEqual(scanRepository(), []);
});
