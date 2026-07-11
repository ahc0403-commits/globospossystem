const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const os = require('node:os');
const XLSX = require('xlsx');

const {
  FAILURE,
  assertAggregateComplete,
  buildStores,
  classifyError,
  createRunIdentity,
  findMissingRuns,
  inclusiveDateRange,
  parseArgs,
  parseSpreadsheetFile,
  runWithTransientRetry,
  runPreflight,
  serializeRunMetadata,
  validateStaticPreflight,
  validateStoreMappings,
} = require('../pull_moers_sales');

test('SheetJS uses the patched official release and parses a real workbook', () => {
  assert.equal(XLSX.version, '0.20.3');
  const workbook = XLSX.utils.book_new();
  const worksheet = XLSX.utils.aoa_to_sheet([
    ['Device Name', 'Amount', 'Time'],
    ['M1', '100000', '09:30'],
  ]);
  XLSX.utils.book_append_sheet(workbook, worksheet, 'Sales');

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'photo-xlsx-'));
  const filePath = path.join(tempDir, 'sales.xlsx');
  try {
    fs.writeFileSync(filePath, XLSX.write(workbook, { type: 'buffer', bookType: 'xlsx' }));
    assert.deepEqual(parseSpreadsheetFile(filePath), [
      { 'Device Name': 'M1', Amount: '100000', Time: '09:30' },
    ]);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

const ids = [
  '77000000-0000-4000-8000-000000000102',
  '77000000-0000-4000-8000-000000000103',
  '77000000-0000-4000-8000-000000000104',
  '77000000-0000-4000-8000-000000000105',
  '77000000-0000-4000-8000-000000000106',
  '77000000-0000-4000-8000-000000000107',
];

function validEnv() {
  const env = {
    SUPABASE_URL: 'https://ynriuoomotxuwhuxxmhj.supabase.co',
    SUPABASE_SERVICE_KEY: 'test-service-key',
    PUPPETEER_EXECUTABLE_PATH: '/bin/sh',
  };
  const keys = ['BIENHOA', 'DIAN', 'LONGTHANH', 'THAODIEN', 'QUANGTRUNG', 'NOWZONE'];
  keys.forEach((key, index) => {
    env[`MOERS_${key}_USER`] = `user-${index}`;
    env[`MOERS_${key}_PASS`] = `pass-${index}`;
    env[`PHOTO_OBJET_${key}_STORE_ID`] = ids[index];
  });
  return env;
}

test('preflight requires Node 22, WebSocket, executable Chromium, and pinned POS', () => {
  const env = validEnv();
  const stores = buildStores(env);
  assert.doesNotThrow(() =>
    validateStaticPreflight(stores, env, {
      nodeVersion: '22.17.0',
      webSocket: function WebSocket() {},
      executablePath: '/bin/sh',
    }),
  );
  assert.throws(
    () => validateStaticPreflight(stores, env, { nodeVersion: '20.19.0', webSocket() {}, executablePath: '/bin/sh' }),
    /Node 22 is required/,
  );
  assert.throws(
    () => validateStaticPreflight(stores, { ...env, SUPABASE_URL: 'https://example.supabase.co' }, { nodeVersion: '22.17.0', webSocket() {}, executablePath: '/bin/sh' }),
    /must target POS project/,
  );
});

test('store mappings fail closed unless active and in the Photo Objet brand', () => {
  const stores = buildStores(validEnv());
  const rows = stores.map(store => ({
    id: store.storeId,
    name: `PHOTO OBJET ${store.storeName}`,
    is_active: true,
    brand_id: '77000000-0000-0000-0000-000000000001',
    store_type: 'direct',
  }));
  rows[0].name = '  photo objet   bien hoa  ';
  rows[0].store_type = 'external';
  assert.doesNotThrow(() => validateStoreMappings(rows, stores));
  assert.throws(
    () => validateStoreMappings(rows.map(row => row.id === ids[1] ? { ...row, is_active: false } : row), stores),
    /DI AN mapping is inactive/,
  );
  assert.throws(
    () => validateStoreMappings(rows.map(row => row.id === ids[2] ? { ...row, brand_id: null } : row), stores),
    /outside the Photo Objet brand/,
  );
  assert.throws(
    () => validateStoreMappings(rows.map(row => row.id === ids[3] ? { ...row, name: 'PHOTO OBJET NOW ZONE' } : row), stores),
    /resolves to unexpected store/,
  );
  assert.throws(
    () => validateStoreMappings(rows.map(row => row.id === ids[0] ? { ...row, name: 'BIEN HOA' } : row), stores),
    /BIEN HOA mapping resolves to unexpected store BIEN HOA/,
  );
});

test('store enable flags reject unknown values instead of silently disabling', () => {
  assert.equal(buildStores({ ...validEnv(), PHOTO_OBJET_BIENHOA_ENABLED: 'false' })[0].enabled, false);
  assert.equal(buildStores({ ...validEnv(), PHOTO_OBJET_BIENHOA_ENABLED: 'ON' })[0].enabled, true);
  assert.throws(
    () => buildStores({ ...validEnv(), PHOTO_OBJET_BIENHOA_ENABLED: 'flase' }),
    /PHOTO_OBJET_BIENHOA_ENABLED must be one of true\/false/,
  );
});

test('preflight probes pull runs, raw ledger, and aggregate before collection', async () => {
  const stores = buildStores(validEnv());
  const rows = stores.map(store => ({
    id: store.storeId,
    name: `PHOTO OBJET ${store.storeName}`,
    is_active: true,
    brand_id: '77000000-0000-0000-0000-000000000001',
    store_type: 'direct',
  }));
  const probed = [];
  const writeProbed = [];
  const supabase = {
    from(table) {
      return {
        select() {
          if (table === 'restaurants') {
            return { in: async () => ({ data: rows, error: null }) };
          }
          return {
            limit: async () => {
              probed.push(table);
              return { data: [], error: null };
            },
          };
        },
        async insert() {
          writeProbed.push(table);
          return { data: null, error: { code: '23502', message: 'expected not-null violation' } };
        },
      };
    },
  };

  await runPreflight(supabase, stores, validEnv(), {
    nodeVersion: '22.17.0',
    webSocket() {},
    executablePath: '/bin/sh',
  });
  assert.deepEqual(probed, [
    'photo_objet_sales_pull_runs',
    'photo_objet_sales_raw',
    'photo_objet_sales',
  ]);
  assert.deepEqual(writeProbed, probed);
});

test('bounded backfill is dry-run by default and rejects more than seven days', () => {
  assert.deepEqual(inclusiveDateRange('2026-07-01', '2026-07-07'), [
    '2026-07-01', '2026-07-02', '2026-07-03', '2026-07-04',
    '2026-07-05', '2026-07-06', '2026-07-07',
  ]);
  assert.throws(() => inclusiveDateRange('2026-07-01', '2026-07-08'), /limited to 7 days/);
  const options = parseArgs(['--backfill-from', '2026-07-01', '--backfill-to', '2026-07-02'], {});
  assert.equal(options.backfill, true);
  assert.equal(options.execute, false);
  assert.throws(() => parseArgs(['--execute'], {}), /only valid with a bounded backfill/);
});

test('only transient failures receive one retry', async () => {
  let transientAttempts = 0;
  const recovered = await runWithTransientRetry(() => {
    transientAttempts += 1;
    return transientAttempts === 1
      ? { success: false, failureClass: FAILURE.TRANSIENT, error: 'timeout' }
      : { success: true };
  });
  assert.equal(recovered.attempts, 2);

  let deterministicAttempts = 0;
  const failed = await runWithTransientRetry(() => {
    deterministicAttempts += 1;
    return { success: false, failureClass: FAILURE.DETERMINISTIC, error: 'bad mapping' };
  });
  assert.equal(failed.attempts, 1);
  assert.equal(deterministicAttempts, 1);
  assert.equal(classifyError(new Error('navigation timeout')), FAILURE.TRANSIENT);
});

test('slot identities distinguish scheduled, manual, audit, and bounded backfill', () => {
  const scheduled = createRunIdentity(
    { auditMissingRuns: false, backfill: false },
    '2026-07-11',
    {
      GITHUB_EVENT_NAME: 'schedule',
      PHOTO_OBJET_SCHEDULE_CRON: '0 2 * * *',
      PHOTO_OBJET_RUN_STARTED_AT: '2026-07-11T02:05:00Z',
    },
  );
  const manual = createRunIdentity(
    { auditMissingRuns: false, backfill: false },
    '2026-07-11',
    {
      GITHUB_EVENT_NAME: 'workflow_dispatch',
      GITHUB_RUN_ID: '123',
      PHOTO_OBJET_SCHEDULE_CRON: '30 15 * * *',
      PHOTO_OBJET_RUN_STARTED_AT: '2026-07-11T17:10:00Z',
    },
  );
  const audit = createRunIdentity(
    { auditMissingRuns: true, backfill: false },
    '2026-07-11',
    {},
  );
  const backfill = createRunIdentity(
    { auditMissingRuns: false, backfill: true },
    '2026-07-11',
    {
      GITHUB_EVENT_NAME: 'workflow_dispatch',
      PHOTO_OBJET_SCHEDULE_CRON: '30 15 * * *',
      PHOTO_OBJET_RUN_STARTED_AT: '2026-07-11T17:10:00Z',
    },
  );

  assert.deepEqual(scheduled, {
    source: 'scheduled',
    slotId: 'scheduled:2026-07-11T09:00+07:00',
    slotDateHcm: '2026-07-11',
    slotTimeHcm: '09:00',
  });
  assert.equal(new Set([scheduled.slotId, manual.slotId, audit.slotId, backfill.slotId]).size, 4);
  assert.deepEqual([manual.source, audit.source, backfill.source], ['manual', 'audit', 'backfill']);
});

test('delayed 22:30 schedule crossing HCM midnight retains the previous target date and slot', () => {
  const env = {
    GITHUB_EVENT_NAME: 'schedule',
    PHOTO_OBJET_SCHEDULE_CRON: '30 15 * * *',
    PHOTO_OBJET_RUN_STARTED_AT: '2026-07-11T17:10:00Z',
  };
  const options = parseArgs([], env);
  const identity = createRunIdentity(options, options.targetDates[0], env);

  assert.deepEqual(options.targetDates, ['2026-07-11']);
  assert.equal(identity.slotDateHcm, options.targetDates[0]);
  assert.equal(identity.slotTimeHcm, '22:30');
  assert.equal(identity.slotId, 'scheduled:2026-07-11T22:30+07:00');
  assert.throws(
    () => createRunIdentity(options, '2026-07-12', env),
    /does not match intended HCM slot date 2026-07-11/,
  );
});

test('missing-run audit uses explicit slot metadata, not delayed started_at', () => {
  const store = { storeName: 'BIEN HOA', storeId: ids[0], enabled: true };
  const identity = createRunIdentity(
    { auditMissingRuns: false, backfill: false },
    '2026-07-11',
    {
      GITHUB_EVENT_NAME: 'schedule',
      PHOTO_OBJET_SCHEDULE_CRON: '0 2 * * *',
      PHOTO_OBJET_RUN_STARTED_AT: '2026-07-11T03:55:00Z',
    },
  );
  const runs = [{
    store_id: ids[0],
    target_date: '2026-07-11',
    status: 'success',
    started_at: '2026-07-11T03:55:00Z',
    error_message: serializeRunMetadata(identity),
  }];
  const missing = findMissingRuns([store], ['2026-07-11'], runs, new Date('2026-07-11T04:20:00Z'));
  assert.deepEqual(missing, [{ storeName: 'BIEN HOA', date: '2026-07-11', slot: '2026-07-11 10:00' }]);
});

test('partial aggregate snapshots never overwrite fuller totals', () => {
  const existing = [{ device_name: 'M1', gross_sales: 100000, transaction_count: 4 }];
  assert.throws(
    () => assertAggregateComplete(existing, [{ device_name: 'M1', gross_sales: 0, transaction_count: 0 }]),
    error => error.failureClass === FAILURE.TRANSIENT && /existing totals preserved/.test(error.message),
  );
  assert.throws(
    () => assertAggregateComplete(existing, []),
    /would erase existing device totals/,
  );
  assert.doesNotThrow(() => assertAggregateComplete([], []));
});

test('workflow uses locked Node 22 install, exact schedule, audit, and deduplicated escalation', () => {
  const workflow = fs.readFileSync(path.join(__dirname, '../../.github/workflows/photo_objet_sales.yml'), 'utf8');
  assert.deepEqual([...workflow.matchAll(/cron: '([^']+)'/g)].map(match => match[1]), [
    ...Array.from({ length: 14 }, (_, index) => `0 ${index + 2} * * *`),
    '30 15 * * *',
  ]);
  assert.match(workflow, /node-version: '22'/);
  assert.match(workflow, /npm ci/);
  assert.match(
    workflow,
    /npx puppeteer browsers install "chrome@\$\{CHROME_VERSION\}"/,
  );
  assert.doesNotMatch(workflow, /--install-deps/);
  assert.match(workflow, /PHOTO_OBJET_RUN_STARTED_AT=.*date -u/);
  assert.doesNotMatch(workflow, /\$\{\{\s*runner\.temp\s*\}\}/);
  assert.match(
    workflow,
    /echo "PUPPETEER_CACHE_DIR=\$\{RUNNER_TEMP\}\/puppeteer" >> "\$\{GITHUB_ENV\}"/,
  );
  assert.ok(
    workflow.indexOf('PUPPETEER_CACHE_DIR=${RUNNER_TEMP}/puppeteer') <
      workflow.indexOf('uses: actions/setup-node@v4'),
    'runtime cache setup must run before Node and Chromium installation',
  );
  assert.match(workflow, /--preflight-only/);
  assert.match(workflow, /--audit-missing-runs/);
  assert.match(workflow, /Collector failure/);
  assert.match(workflow, /issues\.find/);
  assert.match(workflow, /if: >-\n\s+always\(\) &&/);
  assert.match(workflow, /steps\.node_setup\.outcome != 'success'/);
  assert.match(workflow, /steps\.setup\.outcome != 'success'/);
  assert.match(workflow, /steps\.chromium\.outcome != 'success'/);
  assert.match(workflow, /collector\.log unavailable; use setup outcomes below/);
  const collector = fs.readFileSync(path.join(__dirname, '../pull_moers_sales.js'), 'utf8');
  assert.match(collector, /runWithTransientRetry/);
  assert.match(collector, /attempt < 2/);
});
