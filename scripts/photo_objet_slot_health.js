const fs = require('fs');
const { createClient } = require('@supabase/supabase-js');

const EXPECTED_POS_PROJECT_REF = 'ynriuoomotxuwhuxxmhj';
const FAILURE_CLASS = Object.freeze({
  COLLECTION_FAILED: 'COLLECTION_FAILED',
  SLOT_MISSING: 'SLOT_MISSING',
  DATA_INCOMPLETE: 'DATA_INCOMPLETE',
  AUDIT_INFRA_FAILED: 'AUDIT_INFRA_FAILED',
  RELEASE_SHA_DRIFT: 'RELEASE_SHA_DRIFT',
  RECEIPT_AUTOMATION_FAILED: 'RECEIPT_AUTOMATION_FAILED',
});

function parseArgs(argv) {
  const options = {
    mode: null,
    lookbackDays: 2,
    output: null,
    ackFile: null,
    assertFile: null,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--refresh') {
      if (options.mode) throw new Error('Choose exactly one health mode');
      options.mode = 'refresh';
    } else if (arg === '--read-only') {
      if (options.mode) throw new Error('Choose exactly one health mode');
      options.mode = 'read-only';
    } else if (arg === '--ack-file') {
      if (options.mode) throw new Error('Choose exactly one health mode');
      const value = argv[index + 1];
      if (!value || value.startsWith('--')) throw new Error('--ack-file requires a value');
      options.mode = 'ack';
      options.ackFile = value;
      index += 1;
    } else if (arg === '--assert-file') {
      if (options.mode) throw new Error('Choose exactly one health mode');
      const value = argv[index + 1];
      if (!value || value.startsWith('--')) throw new Error('--assert-file requires a value');
      options.mode = 'assert';
      options.assertFile = value;
      index += 1;
    } else if (arg === '--lookback-days' || arg === '--output') {
      const value = argv[index + 1];
      if (!value || value.startsWith('--')) throw new Error(`${arg} requires a value`);
      if (arg === '--lookback-days') options.lookbackDays = Number(value);
      else options.output = value;
      index += 1;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  if (!options.mode) {
    throw new Error(
      'Health mode must be --refresh, --read-only, --ack-file, or --assert-file',
    );
  }
  if (!Number.isInteger(options.lookbackDays) || options.lookbackDays < 1 || options.lookbackDays > 31) {
    throw new Error('--lookback-days must be an integer from 1 to 31');
  }
  return options;
}

function validateEnvironment(env) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_KEY) {
    throw new Error('Missing required POS health audit environment');
  }
  const target = new URL(env.SUPABASE_URL);
  if (target.protocol !== 'https:' || target.hostname !== `${EXPECTED_POS_PROJECT_REF}.supabase.co`) {
    throw new Error(`SUPABASE_URL must target POS project ${EXPECTED_POS_PROJECT_REF}`);
  }
}

function summarizeHealth(rows, observedAt) {
  const infrastructureFailures = (rows || []).filter(row => (
    Number(row.coverage_missing_slots) > 0
    || row.policy_store_active === false
    || row.status === 'audit_infra_failed'
  ));
  const unhealthy = (rows || []).filter(row => (
    Number(row.missing_slots) > 0 || Number(row.failed_slots) > 0
  ));
  const failureClasses = new Set();
  for (const row of rows || []) {
    for (const failureClass of row.failure_classes || []) {
      if (failureClass) failureClasses.add(failureClass);
    }
  }
  if (infrastructureFailures.length > 0) {
    failureClasses.add(FAILURE_CLASS.AUDIT_INFRA_FAILED);
  }
  const latestDueSlot = (rows || [])
    .map(row => row.latest_due_slot)
    .filter(Boolean)
    .sort()
    .at(-1) || null;
  return {
    audit_result: (rows || []).length === 0 || infrastructureFailures.length > 0
      ? 'ERROR'
      : unhealthy.length === 0 ? 'PASS' : 'FAIL',
    observed_at: observedAt,
    latest_due_slot: latestDueSlot,
    store_days_checked: (rows || []).length,
    unhealthy_store_days: unhealthy.length,
    infrastructure_failure_store_days: infrastructureFailures.length,
    failure_classes: [...failureClasses].sort(),
    unhealthy,
  };
}

function assertEvidenceHealthy(evidence) {
  if (evidence.audit_result === 'PASS') return evidence;
  const failureClasses = Array.isArray(evidence.failure_classes)
    ? evidence.failure_classes
    : [];
  const failureClass = evidence.audit_result === 'ERROR'
    ? FAILURE_CLASS.AUDIT_INFRA_FAILED
    : failureClasses.find(value => value !== FAILURE_CLASS.AUDIT_INFRA_FAILED)
      || FAILURE_CLASS.SLOT_MISSING;
  console.error(`PHOTO_FAILURE_CLASSES=${failureClasses.join(',') || failureClass}`);
  const error = new Error(
    `Expected-slot health is ${evidence.audit_result}; `
      + `${evidence.unhealthy_store_days || 0} unhealthy store-day(s), `
      + `${evidence.infrastructure_failure_store_days || 0} infrastructure failure(s)`,
  );
  error.failureClass = failureClass;
  throw error;
}

async function acknowledgeAlerts(supabase, alerts, alertedAt) {
  for (const alert of alerts) {
    const { data, error } = await supabase.rpc('photo_objet_ack_expected_slot_alert', {
      p_store_id: alert.store_id,
      p_slot_date_hcm: alert.slot_date_hcm,
      p_slot_time_hcm: alert.slot_time_hcm,
      p_failure_class: alert.failure_class,
      p_alerted_at: alertedAt,
    });
    if (error || data !== true) {
      throw new Error(`Expected-slot alert acknowledgement failed for ${alert.store_id}`);
    }
  }
}

function createSupabase(env) {
  return createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

async function queryReadOnlyHealth(supabase, observedAt, lookbackDays) {
  const { data, error } = await supabase.rpc('photo_objet_expected_slot_health_at', {
    p_observed_at: observedAt,
    p_lookback_days: lookbackDays,
  });
  if (error) throw new Error(`Expected-slot health query failed: ${error.message}`);
  return data || [];
}

async function refreshHealth(supabase, observedAt, lookbackDays) {
  const { data, error } = await supabase.rpc('photo_objet_refresh_expected_slot_health', {
    p_observed_at: observedAt,
    p_lookback_days: lookbackDays,
  });
  if (error) throw new Error(`Expected-slot health refresh failed: ${error.message}`);
  return data || [];
}

async function run(options, env = process.env, observedAt = new Date().toISOString(), client = null) {
  if (options.mode === 'assert') {
    return assertEvidenceHealthy(JSON.parse(fs.readFileSync(options.assertFile, 'utf8')));
  }
  validateEnvironment(env);
  const supabase = client || createSupabase(env);
  if (options.mode === 'ack') {
    const evidence = JSON.parse(fs.readFileSync(options.ackFile, 'utf8'));
    const alerts = Array.isArray(evidence.newly_alertable) ? evidence.newly_alertable : [];
    await acknowledgeAlerts(supabase, alerts, observedAt);
    const result = { acknowledged: alerts.length, observed_at: observedAt };
    console.log(`PHOTO_HEALTH_ACK=${JSON.stringify(result)}`);
    return result;
  }
  const newlyAlertable = options.mode === 'refresh'
    ? await refreshHealth(supabase, observedAt, options.lookbackDays)
    : [];
  const rows = await queryReadOnlyHealth(supabase, observedAt, options.lookbackDays);
  const evidence = {
    dimension: 'scheduler_reliability',
    mode: options.mode,
    ...summarizeHealth(rows, observedAt),
    newly_alertable: newlyAlertable,
  };
  if (options.output) fs.writeFileSync(options.output, `${JSON.stringify(evidence, null, 2)}\n`);
  console.log(`PHOTO_HEALTH_EVIDENCE=${JSON.stringify(evidence)}`);

  if (options.mode === 'read-only') assertEvidenceHealthy(evidence);
  return evidence;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  await run(options);
}

if (require.main === module) {
  main().catch(error => {
    const failureClass = error.failureClass || FAILURE_CLASS.AUDIT_INFRA_FAILED;
    console.error(`PHOTO_FAILURE_CLASS=${failureClass}`);
    console.error(`PHOTO_HEALTH_FAILED ${error.message}`);
    process.exit(failureClass === FAILURE_CLASS.AUDIT_INFRA_FAILED ? 4 : 5);
  });
}

module.exports = {
  EXPECTED_POS_PROJECT_REF,
  FAILURE_CLASS,
  assertEvidenceHealthy,
  parseArgs,
  acknowledgeAlerts,
  queryReadOnlyHealth,
  refreshHealth,
  run,
  summarizeHealth,
  validateEnvironment,
};
