const assert = require('node:assert/strict');
const test = require('node:test');

const {
  buildEvidence,
  verifyCodeValidation,
  verifyDeployment,
} = require('../verify_photo_objet_release');

const sha = '0123456789abcdef0123456789abcdef01234567';
const deployment = {
  target: 'production',
  readyState: 'READY',
  meta: {
    githubCommitSha: sha,
    githubCommitRef: 'main',
    githubCommitOrg: 'ahc0403-commits',
    githubCommitRepo: 'globospossystem',
  },
};
const validation = {
  name: 'Photo Objet Sales Contract',
  path: '.github/workflows/photo_objet_sales_contract.yml',
  head_sha: sha,
  head_branch: 'main',
  event: 'push',
  status: 'completed',
  conclusion: 'success',
  id: 123,
  html_url: 'https://github.com/example/actions/runs/123',
};

test('code validation requires a successful contract run for the exact main SHA', () => {
  assert.deepEqual(verifyCodeValidation(validation, sha), {
    state: 'SUCCESS',
    sha,
    run_id: 123,
    run_url: 'https://github.com/example/actions/runs/123',
  });
  for (const rejected of [
    null,
    { ...validation, head_sha: 'f'.repeat(40) },
    { ...validation, head_branch: 'feature' },
    { ...validation, event: 'pull_request' },
    { ...validation, status: 'in_progress', conclusion: null },
    { ...validation, conclusion: 'failure' },
    { ...validation, conclusion: 'cancelled' },
    { ...validation, conclusion: 'skipped' },
  ]) {
    assert.throws(() => verifyCodeValidation(rejected, sha), /CODE_VALIDATED/);
  }
});

test('release proof rejects absent, failed, and stale workflow run lists', () => {
  assert.equal(verifyCodeValidation({ workflow_runs: [validation] }, sha).sha, sha);
  assert.throws(
    () => verifyCodeValidation({ workflow_runs: [] }, sha),
    /absent for the exact main SHA/,
  );
  assert.throws(
    () => verifyCodeValidation({
      workflow_runs: [{ ...validation, conclusion: 'failure' }],
    }, sha),
    /did not complete successfully/,
  );
  assert.throws(
    () => verifyCodeValidation({
      workflow_runs: [{ ...validation, head_sha: 'e'.repeat(40) }],
    }, sha),
    /absent for the exact main SHA/,
  );
});

test('release proof requires the exact production main deployment', () => {
  assert.equal(verifyDeployment(deployment, sha), true);
  for (const mutated of [
    { ...deployment, target: 'preview' },
    { ...deployment, readyState: 'BUILDING' },
    { ...deployment, meta: { ...deployment.meta, githubCommitSha: 'f'.repeat(40) } },
    { ...deployment, meta: { ...deployment.meta, githubCommitRef: 'feature' } },
    { ...deployment, meta: { ...deployment.meta, githubCommitRepo: 'other' } },
  ]) {
    assert.throws(
      () => verifyDeployment(mutated, sha),
      error => error.failureClass === 'RELEASE_SHA_DRIFT',
    );
  }
});

test('machine evidence records main SHA, audit, latest slot, and observation time', () => {
  const evidence = buildEvidence(
    { sha, deploymentState: 'READY' },
    validation,
    deployment,
    { audit_result: 'PASS', latest_due_slot: '2026-07-14T15:30:00Z' },
    '2026-07-14T15:55:00Z',
  );
  assert.deepEqual(evidence, {
    state: 'PRODUCTION_OBSERVED',
    main_sha: sha,
    code_validation_state: 'SUCCESS',
    validated_sha: sha,
    validation_run_id: 123,
    validation_run_url: 'https://github.com/example/actions/runs/123',
    deployment_sha: sha,
    deployment_state: 'READY',
    deployment_target: 'production',
    audit_result: 'PASS',
    latest_due_slot: '2026-07-14T15:30:00Z',
    production_http_status: 200,
    observed_at: '2026-07-14T15:55:00Z',
  });
  assert.equal(evidence.main_sha, evidence.validated_sha);
  assert.equal(evidence.main_sha, evidence.deployment_sha);
});

test('release proof never accepts missing or failed production health', () => {
  assert.throws(
    () => buildEvidence(
      { sha }, validation, deployment, { audit_result: 'FAIL' },
    ),
    /absent or unhealthy/,
  );
});
