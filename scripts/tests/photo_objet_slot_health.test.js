const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  FAILURE_CLASS,
  assertEvidenceHealthy,
  parseArgs,
  run,
  summarizeHealth,
  validateEnvironment,
} = require('../photo_objet_slot_health');

const env = {
  SUPABASE_URL: 'https://ynriuoomotxuwhuxxmhj.supabase.co',
  SUPABASE_SERVICE_KEY: 'secret-value-must-never-appear',
};

function rpcClient(responses) {
  const calls = [];
  return {
    calls,
    async rpc(name, args) {
      calls.push({ name, args });
      return responses[name] || { data: [], error: null };
    },
  };
}

test('health mode is explicit and bounded', () => {
  assert.deepEqual(parseArgs(['--read-only', '--lookback-days', '3']), {
    mode: 'read-only', lookbackDays: 3, output: null, ackFile: null,
    assertFile: null,
  });
  assert.throws(() => parseArgs([]), /must be --refresh/);
  assert.throws(() => parseArgs(['--refresh', '--read-only']), /exactly one/);
  assert.throws(() => parseArgs(['--refresh', '--lookback-days', '32']), /1 to 31/);
});

test('health environment is pinned without printing credentials', () => {
  assert.doesNotThrow(() => validateEnvironment(env));
  assert.throws(
    () => validateEnvironment({ ...env, SUPABASE_URL: 'https://other.supabase.co' }),
    /must target POS project/,
  );
});

test('read-only release audit does not call refresh', async () => {
  const client = rpcClient({
    photo_objet_expected_slot_health_at: {
      data: [{
        latest_due_slot: '2026-07-14T03:00:00Z',
        missing_slots: 0,
        failed_slots: 0,
      }],
      error: null,
    },
  });
  const evidence = await run(
    { mode: 'read-only', lookbackDays: 2, output: null },
    env,
    '2026-07-14T03:20:00Z',
    client,
  );
  assert.equal(evidence.audit_result, 'PASS');
  assert.deepEqual(client.calls.map(call => call.name), [
    'photo_objet_expected_slot_health_at',
  ]);
});

test('refresh lists new typed alerts without acknowledging before delivery', async () => {
  const client = rpcClient({
    photo_objet_refresh_expected_slot_health: {
      data: [{
        store_id: 'store-a', slot_date_hcm: '2026-07-14', slot_time_hcm: '10:00:00',
        status: 'missing', failure_class: FAILURE_CLASS.SLOT_MISSING,
      }],
      error: null,
    },
    photo_objet_expected_slot_health_at: {
      data: [{ latest_due_slot: '2026-07-14T02:00:00Z', missing_slots: 1, failed_slots: 0 }],
      error: null,
    },
  });
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'photo-health-'));
  const output = path.join(dir, 'evidence.json');
  await run(
    { mode: 'refresh', lookbackDays: 2, output, ackFile: null },
    env, '2026-07-14T03:20:00Z', client,
  );
  const evidence = JSON.parse(fs.readFileSync(output, 'utf8'));
  assert.equal(evidence.newly_alertable.length, 1);
  assert.equal(evidence.newly_alertable[0].slot_time_hcm, '10:00:00');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('existing unhealthy slots do not create duplicate health alerts', async () => {
  const client = rpcClient({
    photo_objet_refresh_expected_slot_health: { data: [], error: null },
    photo_objet_expected_slot_health_at: {
      data: [{ latest_due_slot: '2026-07-14T02:00:00Z', missing_slots: 1, failed_slots: 0 }],
      error: null,
    },
  });
  const evidence = await run(
    { mode: 'refresh', lookbackDays: 2, output: null, ackFile: null },
    env,
    '2026-07-14T03:20:00Z',
    client,
  );
  assert.equal(evidence.audit_result, 'FAIL');
  assert.deepEqual(evidence.newly_alertable, []);
  assert.throws(
    () => assertEvidenceHealthy(evidence),
    error => error.failureClass === FAILURE_CLASS.SLOT_MISSING,
  );
});

test('health summaries keep scheduler and collection dimensions separate', () => {
  const summary = summarizeHealth([
    { latest_due_slot: '2026-07-14T02:00:00Z', missing_slots: 0, failed_slots: 0 },
    { latest_due_slot: '2026-07-14T03:00:00Z', missing_slots: 0, failed_slots: 1 },
  ], '2026-07-14T03:20:00Z');
  assert.equal(summary.audit_result, 'FAIL');
  assert.equal(summary.latest_due_slot, '2026-07-14T03:00:00Z');
});

test('secret values never appear in health evidence or errors', async () => {
  const client = rpcClient({
    photo_objet_expected_slot_health_at: {
      data: [{ latest_due_slot: null, missing_slots: 0, failed_slots: 0 }],
      error: null,
    },
  });
  const evidence = await run(
    { mode: 'read-only', lookbackDays: 1, output: null, ackFile: null }, env,
    '2026-07-14T01:00:00Z', client,
  );
  assert.equal(JSON.stringify(evidence).includes(env.SUPABASE_SERVICE_KEY), false);
});

test('empty policy or expectation results fail closed', async () => {
  const client = rpcClient({
    photo_objet_expected_slot_health_at: { data: [], error: null },
  });
  await assert.rejects(
    run(
      { mode: 'read-only', lookbackDays: 1, output: null, ackFile: null },
      env, '2026-07-14T01:00:00Z', client,
    ),
    error => error.failureClass === FAILURE_CLASS.AUDIT_INFRA_FAILED,
  );
});

test('one missing policy materialization fails closed even when another store is healthy', () => {
  const summary = summarizeHealth([
    {
      coverage_missing_slots: 0,
      policy_store_active: true,
      latest_due_slot: '2026-07-14T02:00:00Z',
      missing_slots: 0,
      failed_slots: 0,
      failure_classes: [],
    },
    {
      coverage_missing_slots: 15,
      policy_store_active: true,
      latest_due_slot: null,
      missing_slots: 0,
      failed_slots: 0,
      status: 'audit_infra_failed',
      failure_classes: [FAILURE_CLASS.AUDIT_INFRA_FAILED],
    },
  ], '2026-07-14T03:20:00Z');
  assert.equal(summary.audit_result, 'ERROR');
  assert.equal(summary.infrastructure_failure_store_days, 1);
  assert.deepEqual(summary.failure_classes, [FAILURE_CLASS.AUDIT_INFRA_FAILED]);
});

test('assert mode keeps an acknowledged persistent failure red with its real class', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'photo-health-assert-'));
  const assertFile = path.join(dir, 'evidence.json');
  fs.writeFileSync(assertFile, JSON.stringify({
    audit_result: 'FAIL',
    unhealthy_store_days: 1,
    infrastructure_failure_store_days: 0,
    failure_classes: [FAILURE_CLASS.DATA_INCOMPLETE],
    newly_alertable: [],
  }));
  await assert.rejects(
    run({
      mode: 'assert', lookbackDays: 2, output: null, ackFile: null, assertFile,
    }, {}, '2026-07-14T03:20:00Z'),
    error => error.failureClass === FAILURE_CLASS.DATA_INCOMPLETE,
  );
  fs.rmSync(dir, { recursive: true, force: true });
});

test('alerts are acknowledged only in the post-delivery ack mode', async () => {
  const client = rpcClient({
    photo_objet_ack_expected_slot_alert: { data: true, error: null },
  });
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'photo-health-ack-'));
  const ackFile = path.join(dir, 'evidence.json');
  fs.writeFileSync(ackFile, JSON.stringify({ newly_alertable: [{
    store_id: 'store-a', slot_date_hcm: '2026-07-14', slot_time_hcm: '10:00:00',
    failure_class: FAILURE_CLASS.SLOT_MISSING,
  }] }));
  const result = await run(
    { mode: 'ack', lookbackDays: 2, output: null, ackFile },
    env, '2026-07-14T03:21:00Z', client,
  );
  assert.equal(result.acknowledged, 1);
  assert.equal(client.calls[0].name, 'photo_objet_ack_expected_slot_alert');
  fs.rmSync(dir, { recursive: true, force: true });
});
