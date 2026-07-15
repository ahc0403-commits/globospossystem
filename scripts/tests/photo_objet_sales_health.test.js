const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const os = require('node:os');
const XLSX = require('xlsx');

const {
  FAILURE,
  SOURCE_IDENTITY_VERSION,
  aggregateDailyRawRows,
  assertAggregateComplete,
  assertImmutableSourceRows,
  buildStores,
  classifyError,
  claimScheduledExpectation,
  completeScheduledExpectation,
  createRunIdentity,
  inclusiveDateRange,
  parseArgs,
  parseSoldAt,
  parseSpreadsheetFile,
  normalizeRawSalesRows,
  operationalFailureClass,
  runWithTransientRetry,
  runPreflight,
  selectRowsForInterval,
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

test('a recognized header-only spreadsheet is a successful zero-sales report', () => {
  const workbook = XLSX.utils.book_new();
  const worksheet = XLSX.utils.aoa_to_sheet([
    ['Device Name', 'Device ID', 'Time', 'Amount', 'Type'],
  ]);
  XLSX.utils.book_append_sheet(workbook, worksheet, 'Sales');

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'photo-empty-xlsx-'));
  const filePath = path.join(tempDir, 'empty-sales.xlsx');
  try {
    fs.writeFileSync(filePath, XLSX.write(workbook, { type: 'buffer', bookType: 'xlsx' }));
    assert.deepEqual(parseSpreadsheetFile(filePath), []);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test('an unrecognized spreadsheet is transient and eligible for one retry', () => {
  const workbook = XLSX.utils.book_new();
  const worksheet = XLSX.utils.aoa_to_sheet([['Report unavailable']]);
  XLSX.utils.book_append_sheet(workbook, worksheet, 'Error');

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'photo-invalid-xlsx-'));
  const filePath = path.join(tempDir, 'invalid-report.xlsx');
  try {
    fs.writeFileSync(filePath, XLSX.write(workbook, { type: 'buffer', bookType: 'xlsx' }));
    assert.throws(
      () => parseSpreadsheetFile(filePath),
      error => error.failureClass === FAILURE.TRANSIENT &&
        /no recognizable sales table/.test(error.message),
    );
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
    'photo_objet_monitoring_policies',
    'photo_objet_expected_slots',
  ]);
  assert.deepEqual(writeProbed, [
    'photo_objet_sales_pull_runs',
    'photo_objet_sales_raw',
    'photo_objet_sales',
  ]);
});

test('health ledger probe failure cannot block collection preflight', async () => {
  const stores = buildStores(validEnv());
  const rows = stores.map(store => ({
    id: store.storeId,
    name: `PHOTO OBJET ${store.storeName}`,
    is_active: true,
    brand_id: '77000000-0000-0000-0000-000000000001',
    store_type: 'direct',
  }));
  const errors = [];
  const originalError = console.error;
  console.error = message => errors.push(String(message));
  const supabase = {
    from(table) {
      return {
        select() {
          if (table === 'restaurants') {
            return { in: async () => ({ data: rows, error: null }) };
          }
          return {
            limit: async () => table === 'photo_objet_monitoring_policies'
              || table === 'photo_objet_expected_slots'
              ? { data: null, error: { message: 'ledger unavailable' } }
              : { data: [], error: null },
          };
        },
        async insert() {
          return { data: null, error: { code: '23502', message: 'expected not-null violation' } };
        },
      };
    },
  };
  try {
    await assert.doesNotReject(runPreflight(supabase, stores, validEnv(), {
      nodeVersion: '22.17.0', webSocket() {}, executablePath: '/bin/sh',
    }));
  } finally {
    console.error = originalError;
  }
  assert.equal(errors.length, 2);
  assert.ok(errors.every(message => message.includes('AUDIT_INFRA_FAILED')));
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

test('slot audit infrastructure cannot overwrite collection execution success', async () => {
  const calls = [];
  const supabase = {
    async rpc(name, args) {
      calls.push({ name, args });
      return { data: null, error: { message: 'temporary ledger outage' } };
    },
  };
  const store = { storeId: ids[0] };
  const identity = {
    source: 'scheduled', slotDateHcm: '2026-07-14', slotTimeHcm: '10:00',
  };
  assert.equal(await claimScheduledExpectation(supabase, store, identity, 'run-1'), false);
  assert.equal(
    await completeScheduledExpectation(supabase, store, identity, 'run-1', true),
    false,
  );
  assert.deepEqual(calls.map(call => call.name), [
    'photo_objet_claim_expected_slot', 'photo_objet_complete_expected_slot',
  ]);
  assert.equal(operationalFailureClass(new Error('Incomplete aggregate snapshot')), 'DATA_INCOMPLETE');
  assert.equal(operationalFailureClass(new Error('login failed')), 'COLLECTION_FAILED');
});

test('slot identities distinguish scheduled, manual, and bounded backfill', () => {
  const scheduled = createRunIdentity(
    { backfill: false },
    '2026-07-11',
    {
      GITHUB_EVENT_NAME: 'schedule',
      PHOTO_OBJET_SCHEDULE_CRON: '0 3 * * *',
      PHOTO_OBJET_RUN_STARTED_AT: '2026-07-11T03:05:00Z',
    },
  );
  const manual = createRunIdentity(
    { backfill: false },
    '2026-07-11',
    {
      GITHUB_EVENT_NAME: 'workflow_dispatch',
      GITHUB_RUN_ID: '123',
      PHOTO_OBJET_SCHEDULE_CRON: '30 15 * * *',
      PHOTO_OBJET_RUN_STARTED_AT: '2026-07-11T17:10:00Z',
    },
  );
  const backfill = createRunIdentity(
    { backfill: true },
    '2026-07-11',
    {
      GITHUB_EVENT_NAME: 'workflow_dispatch',
      PHOTO_OBJET_SCHEDULE_CRON: '30 15 * * *',
      PHOTO_OBJET_RUN_STARTED_AT: '2026-07-11T17:10:00Z',
    },
  );

  assert.deepEqual(scheduled, {
    source: 'scheduled',
    slotId: 'scheduled:2026-07-11T10:00+07:00',
    slotDateHcm: '2026-07-11',
    slotTimeHcm: '10:00',
    intervalStartAt: '2026-07-11T02:00:00.000Z',
    intervalEndAt: '2026-07-11T03:00:00.000Z',
  });
  assert.equal(new Set([scheduled.slotId, manual.slotId, backfill.slotId]).size, 3);
  assert.deepEqual([manual.source, backfill.source], ['manual', 'backfill']);
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
  assert.equal(identity.intervalStartAt, '2026-07-11T13:00:00.000Z');
  assert.equal(identity.intervalEndAt, '2026-07-11T15:30:00.000Z');
  assert.throws(
    () => createRunIdentity(options, '2026-07-12', env),
    /does not match intended HCM slot date 2026-07-11/,
  );
});

test('12:00 scheduled collection accepts only 10:00:00 through 11:59:59', () => {
  const identity = createRunIdentity(
    { backfill: false },
    '2026-07-12',
    {
      GITHUB_EVENT_NAME: 'schedule',
      PHOTO_OBJET_SCHEDULE_CRON: '0 5 * * *',
      PHOTO_OBJET_RUN_STARTED_AT: '2026-07-12T05:17:00Z',
    },
  );
  const rows = [
    { 'Device Name': 'M1', Time: '2026-07-12 09:59:59', Amount: '100000' },
    { 'Device Name': 'M1', Time: '2026-07-12 10:00:00', Amount: '110000' },
    { 'Device Name': 'M1', Time: '2026-07-12 11:59:59', Amount: '120000' },
    { 'Device Name': 'M1', Time: '2026-07-12 12:00:00', Amount: '130000' },
  ];

  assert.deepEqual(
    selectRowsForInterval(rows, '2026-07-12', identity).map(item => item.row.Amount),
    ['110000', '120000'],
  );
  assert.equal(identity.intervalStartAt, '2026-07-12T03:00:00.000Z');
  assert.equal(identity.intervalEndAt, '2026-07-12T05:00:00.000Z');
});

test('scheduled intervals cover 09:00 through 22:30 without gaps or overlap', () => {
  const crons = [
    '0 3 * * *', '0 5 * * *', '0 7 * * *', '0 9 * * *',
    '0 11 * * *', '0 13 * * *', '30 15 * * *',
  ];
  const identities = crons.map(cron => createRunIdentity(
    { backfill: false },
    '2026-07-12',
    {
      GITHUB_EVENT_NAME: 'schedule',
      PHOTO_OBJET_SCHEDULE_CRON: cron,
      PHOTO_OBJET_RUN_STARTED_AT: `2026-07-12T${cron.split(' ')[1].padStart(2, '0')}:${cron.startsWith('30 ') ? '35' : '05'}:00Z`,
    },
  ));

  assert.deepEqual(identities.map(identity => identity.slotTimeHcm), [
    '10:00', '12:00', '14:00', '16:00', '18:00', '20:00', '22:30',
  ]);
  assert.equal(identities[0].intervalStartAt, '2026-07-12T02:00:00.000Z');
  assert.equal(identities.at(-1).intervalEndAt, '2026-07-12T15:30:00.000Z');
  for (let index = 1; index < identities.length; index += 1) {
    assert.equal(identities[index - 1].intervalEndAt, identities[index].intervalStartAt);
  }
  for (const unsupported of ['0 2 * * *', '0 16 * * *']) {
    assert.throws(
      () => createRunIdentity(
        { backfill: false },
        '2026-07-12',
        {
          GITHUB_EVENT_NAME: 'schedule',
          PHOTO_OBJET_SCHEDULE_CRON: unsupported,
          PHOTO_OBJET_RUN_STARTED_AT: '2026-07-12T16:05:00Z',
        },
      ),
      /Unsupported Photo Objet schedule slot/,
    );
  }
});

test('immutable Moers rows reject zero, negative, and invalid amounts', () => {
  const identity = {
    intervalStartAt: '2026-07-11T04:00:00.000Z',
    intervalEndAt: '2026-07-11T05:00:00.000Z',
  };
  for (const amount of ['0', '-10000', 'not-a-number']) {
    assert.throws(
      () => selectRowsForInterval([
        { 'Device Name': 'M1', Time: '11:30:00', Amount: amount },
      ], '2026-07-11', identity),
      error => error.failureClass === FAILURE.DETERMINISTIC &&
        /non-positive or invalid Amount/.test(error.message),
    );
  }
});

test('immutable source drift rejects removed or corrected rows', () => {
  const existing = ['hash-a', 'hash-b'];
  assert.doesNotThrow(() => assertImmutableSourceRows(existing, [
    { source_hash: 'hash-a' },
    { source_hash: 'hash-b' },
    { source_hash: 'hash-c' },
  ]));
  assert.throws(
    () => assertImmutableSourceRows(existing, [
      { source_hash: 'hash-a' },
      { source_hash: 'hash-b-corrected' },
    ]),
    error => error.failureClass === FAILURE.DETERMINISTIC &&
      /previously stored row\(s\) are missing or changed/.test(error.message),
  );
});

test('time parsing accepts Moers full timestamps and rejects another date', () => {
  assert.equal(
    parseSoldAt('2026-07-12', '2026-07-12 11:23:45'),
    '2026-07-12T11:23:45+07:00',
  );
  assert.equal(parseSoldAt('2026-07-12', '11:23'), '2026-07-12T11:23:00+07:00');
  assert.equal(parseSoldAt('2026-07-12', '2026-07-11 11:23:45'), null);
});

test('stable source identity ignores workbook order and preserves identical multiplicity', () => {
  const identity = {
    intervalStartAt: '2026-07-12T04:00:00.000Z',
    intervalEndAt: '2026-07-12T05:00:00.000Z',
  };
  const store = { storeId: ids[0], storeName: 'BIEN HOA' };
  const duplicate = {
    'Device Name': 'M1',
    'Device ID': 'D1',
    Time: '2026-07-12 11:15:00',
    Amount: '100000',
    Type: 'Sale',
  };
  const other = { ...duplicate, Time: '2026-07-12 11:20:00', Amount: '90000' };
  const first = selectRowsForInterval([duplicate, other, duplicate], '2026-07-12', identity);
  const reordered = selectRowsForInterval([other, duplicate, duplicate], '2026-07-12', identity);
  const firstHashes = normalizeRawSalesRows(
    first, store, '2026-07-12', 'excel', 'run-a', identity,
  ).map(row => row.source_hash).sort();
  const reorderedRows = normalizeRawSalesRows(
    reordered, store, '2026-07-12', 'excel', 'run-b', identity,
  );

  assert.deepEqual(reorderedRows.map(row => row.source_hash).sort(), firstHashes);
  assert.equal(new Set(firstHashes).size, 3);
  assert.deepEqual(
    reorderedRows.filter(row => row.amount === 100000).map(row => row.occurrence_no),
    [1, 2],
  );
  assert.equal(reorderedRows[0].source_identity_version, SOURCE_IDENTITY_VERSION);
  assert.equal('row_index' in reorderedRows[0].raw_payload, false);
});

test('daily aggregate is recomputed from the canonical raw ledger', () => {
  const rows = [
    { device_name: 'M1', device_id: 'D1', amount: 100000, raw_payload: { row: { id: 1 } } },
    { device_name: 'M1', device_id: 'D1', amount: 120000, raw_payload: { row: { id: 2 } } },
    { device_name: 'M2', device_id: 'D2', amount: 90000, raw_payload: { row: { id: 3 } } },
  ];
  assert.deepEqual(aggregateDailyRawRows(rows), [
    {
      device_name: 'M1', device_id: 'D1', gross_sales: 220000,
      service_amount: 0, transaction_count: 2, service_count: 0,
      raw_rows: [{ id: 1 }, { id: 2 }],
    },
    {
      device_name: 'M2', device_id: 'D2', gross_sales: 90000,
      service_amount: 0, transaction_count: 1, service_count: 0,
      raw_rows: [{ id: 3 }],
    },
  ]);
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

test('collection workflow stays green independently from slot health', () => {
  const workflow = fs.readFileSync(
    path.join(__dirname, '../../.github/workflows/photo_objet_sales_collect.yml'), 'utf8',
  );
  assert.match(workflow, /on:\n  schedule:/);
  assert.deepEqual([...workflow.matchAll(/cron: '([^']+)'/g)].map(match => match[1]), [
    '0 3 * * *', '0 5 * * *', '0 7 * * *', '0 9 * * *',
    '0 11 * * *', '0 13 * * *', '30 15 * * *',
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
      workflow.indexOf('uses: actions/setup-node@'),
    'runtime cache setup must run before Node and Chromium installation',
  );
  assert.match(workflow, /--preflight-only/);
  assert.doesNotMatch(workflow, /audit-missing-runs|slot_health|backfill/);
  assert.match(workflow, /COLLECTION_FAILED/);
  const collector = fs.readFileSync(path.join(__dirname, '../pull_moers_sales.js'), 'utf8');
  assert.match(collector, /runWithTransientRetry/);
  assert.match(collector, /attempt < 2/);
});

test('health, backfill, contract, and release proof are independent workflows', () => {
  const read = name => fs.readFileSync(
    path.join(__dirname, `../../.github/workflows/${name}`), 'utf8',
  );
  const health = read('photo_objet_sales_health.yml');
  const backfill = read('photo_objet_sales_backfill.yml');
  const contract = read('photo_objet_sales_contract.yml');
  const release = read('photo_objet_release_proof.yml');

  assert.deepEqual([...health.matchAll(/cron: '([^']+)'/g)].map(match => match[1]), [
    '40 4 * * *', '40 6 * * *', '40 8 * * *', '40 10 * * *',
    '40 12 * * *', '40 14 * * *', '40 17 * * *',
  ]);
  assert.match(health, /photo_objet_slot_health\.js --refresh/);
  assert.match(health, /--ack-file health-evidence\.json/);
  assert.match(health, /--assert-file health-evidence\.json/);
  assert.match(health, /Escalate detected audit infrastructure failure/);
  assert.doesNotMatch(health, /echo 'PHOTO_FAILURE_CLASS=SLOT_MISSING'/);
  assert.doesNotMatch(health, /MOERS_|Chromium|pull_moers_sales/);
  assert.match(backfill, /workflow_dispatch:/);
  assert.match(backfill, /execute_backfill:[\s\S]*default: false/);
  assert.match(backfill, /EXECUTE_IMMUTABLE_BACKFILL/);
  assert.doesNotMatch(backfill, /schedule:/);
  assert.match(contract, /pull_request:/);
  assert.match(contract, /push:[\s\S]*branches: \[main\]/);
  assert.match(contract, /photo_objet_release_proof\.yml/);
  assert.doesNotMatch(contract, /secrets\./);
  for (const command of [
    'dart analyze --fatal-infos',
    'flutter test',
    'flutter build web --release',
    'npm test',
    'npm audit',
    'npm run security-scan',
    'bash test/pos_deploy_psql_runner_test.sh',
    'bash test/photo_objet_expected_slot_ledger_test.sh',
    'git diff --check',
  ]) {
    assert.match(contract, new RegExp(command.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
  assert.match(release, /workflow_run:/);
  assert.match(release, /workflows: \['Photo Objet Sales Contract'\]/);
  assert.match(release, /branches: \[main\]/);
  assert.doesNotMatch(release, /workflow_dispatch:/);
  assert.match(release, /test "\$\{VALIDATION_EVENT\}" = 'push'/);
  assert.match(release, /test "\$\{VALIDATION_HEAD_BRANCH\}" = 'main'/);
  assert.match(release, /VALIDATION_HEAD_SHA.*\^\[0-9a-f\]\{40\}\$/s);
  assert.match(release, /api\.github\.com\/repos\/\$\{GITHUB_REPOSITORY\}\/git\/ref\/heads\/main/);
  assert.match(release, /test "\$\{current_main_sha\}" = "\$\{VALIDATION_HEAD_SHA\}"/);
  assert.match(release, /ref: \$\{\{ github\.event\.workflow_run\.head_sha \}\}/);
  assert.ok(
    release.indexOf('Reject non-main or stale validation before checkout')
      < release.indexOf('uses: actions/checkout@'),
    'event metadata and current main must fail closed before repository checkout',
  );
  assert.ok(
    release.indexOf('test "${current_main_sha}" = "${VALIDATION_HEAD_SHA}"')
      < release.indexOf('uses: actions/checkout@'),
    'a stale successful main validation must be rejected before checkout',
  );
  assert.ok(
    release.indexOf('uses: actions/checkout@')
      < release.indexOf('node scripts/verify_photo_objet_release.js'),
    'repository verification scripts must run only after exact-SHA checkout',
  );
  assert.match(release, /git merge-base --is-ancestor/);
  assert.match(release, /--check-validation-only/);
  assert.match(release, /code-validation\.json/);
  assert.match(release, /steps\.validated\.outputs\.main_sha/);
  assert.match(release, /photo_objet_slot_health\.js --read-only/);
  assert.match(release, /globospossystem\.vercel\.app/);
  assert.match(release, /release-proof-evidence\.json/);
});
