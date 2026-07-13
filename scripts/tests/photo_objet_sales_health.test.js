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
  createRunIdentity,
  findMissingRuns,
  inclusiveDateRange,
  parseArgs,
  parseSoldAt,
  parseSpreadsheetFile,
  normalizeRawSalesRows,
  runWithTransientRetry,
  runPreflight,
  RUN_METADATA_AUDIT_START_AT,
  scheduledSlotsForDate,
  serializeRunMetadata,
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
    intervalStartAt: '2026-07-11T01:00:00.000Z',
    intervalEndAt: '2026-07-11T02:00:00.000Z',
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
  assert.equal(identity.intervalStartAt, '2026-07-11T15:00:00.000Z');
  assert.equal(identity.intervalEndAt, '2026-07-11T15:30:00.000Z');
  assert.throws(
    () => createRunIdentity(options, '2026-07-12', env),
    /does not match intended HCM slot date 2026-07-11/,
  );
});

test('12:00 scheduled collection accepts only 11:00:00 through 11:59:59', () => {
  const identity = createRunIdentity(
    { auditMissingRuns: false, backfill: false },
    '2026-07-12',
    {
      GITHUB_EVENT_NAME: 'schedule',
      PHOTO_OBJET_SCHEDULE_CRON: '0 5 * * *',
      PHOTO_OBJET_RUN_STARTED_AT: '2026-07-12T05:17:00Z',
    },
  );
  const rows = [
    { 'Device Name': 'M1', Time: '2026-07-12 10:59:59', Amount: '100000' },
    { 'Device Name': 'M1', Time: '2026-07-12 11:00:00', Amount: '110000' },
    { 'Device Name': 'M1', Time: '2026-07-12 11:59:59', Amount: '120000' },
    { 'Device Name': 'M1', Time: '2026-07-12 12:00:00', Amount: '130000' },
  ];

  assert.deepEqual(
    selectRowsForInterval(rows, '2026-07-12', identity).map(item => item.row.Amount),
    ['110000', '120000'],
  );
  assert.equal(identity.intervalStartAt, '2026-07-12T04:00:00.000Z');
  assert.equal(identity.intervalEndAt, '2026-07-12T05:00:00.000Z');
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
  const missing = findMissingRuns(
    [store],
    ['2026-07-11'],
    runs,
    new Date('2026-07-11T04:20:00Z'),
    Date.parse('2026-07-11T00:00:00Z'),
  );
  assert.deepEqual(missing, [{ storeName: 'BIEN HOA', date: '2026-07-11', slot: '2026-07-11 10:00' }]);
});

test('missing-run audit excludes historical metadata gaps but detects new gaps', () => {
  const stores = ids.slice(0, 6).map((storeId, index) => ({
    storeName: `STORE ${index + 1}`,
    storeId,
    enabled: true,
  }));
  const now = new Date('2026-07-13T04:20:00Z');

  assert.equal(RUN_METADATA_AUDIT_START_AT, Date.parse('2026-07-13T02:00:00Z'));
  assert.deepEqual(
    findMissingRuns(stores, ['2026-07-11', '2026-07-12'], [], now),
    [],
    'the 126 pre-cutover store-slot gaps are a historical metadata baseline',
  );

  const firstSlotIdentity = {
    source: 'scheduled',
    slotId: 'scheduled:2026-07-13T09:00+07:00',
    slotDateHcm: '2026-07-13',
    slotTimeHcm: '09:00',
  };
  const runs = stores.map(store => ({
    store_id: store.storeId,
    target_date: '2026-07-13',
    status: 'success',
    error_message: serializeRunMetadata(firstSlotIdentity),
  }));
  assert.deepEqual(
    findMissingRuns(
      stores,
      ['2026-07-11', '2026-07-12', '2026-07-13'],
      runs,
      new Date('2026-07-13T03:20:00Z'),
    ),
    [],
    'the first post-cutover success must not inherit historical audit failures',
  );
  assert.deepEqual(findMissingRuns(stores, ['2026-07-13'], runs, now),
    stores.map(store => ({
      storeName: store.storeName,
      date: '2026-07-13',
      slot: '2026-07-13 10:00',
    })),
    'a newly due slot after cutover must still fail health',
  );
});

test('missing-run audit reports the final 22:30 slot at 22:45 HCM', () => {
  const store = { storeName: 'BIEN HOA', storeId: ids[0], enabled: true };
  const successfulRuns = scheduledSlotsForDate('2026-07-13')
    .slice(0, -1)
    .map(slot => ({
      store_id: ids[0],
      target_date: '2026-07-13',
      status: 'success',
      error_message: serializeRunMetadata({
        source: 'scheduled',
        slotId: slot.slotId,
        slotDateHcm: '2026-07-13',
        slotTimeHcm: slot.label.slice(-5),
      }),
    }));

  assert.deepEqual(
    findMissingRuns([store], ['2026-07-13'], successfulRuns, new Date('2026-07-13T15:44:59Z')),
    [],
  );
  assert.deepEqual(
    findMissingRuns([store], ['2026-07-13'], successfulRuns, new Date('2026-07-13T15:45:00Z')),
    [{ storeName: 'BIEN HOA', date: '2026-07-13', slot: '2026-07-13 22:30' }],
  );
});

test('schedule health requires each exact slot even when a later snapshot succeeds', () => {
  const store = { storeName: 'BIEN HOA', storeId: ids[0], enabled: true };
  const laterIdentity = {
    source: 'scheduled',
    slotId: 'scheduled:2026-07-13T11:00+07:00',
    slotDateHcm: '2026-07-13',
    slotTimeHcm: '11:00',
  };
  const laterSuccess = [{
    store_id: ids[0],
    target_date: '2026-07-13',
    status: 'success',
    error_message: serializeRunMetadata(laterIdentity),
  }];

  assert.deepEqual(
    findMissingRuns(
      [store],
      ['2026-07-13'],
      laterSuccess,
      new Date('2026-07-13T04:20:00Z'),
    ),
    [
      { storeName: 'BIEN HOA', date: '2026-07-13', slot: '2026-07-13 09:00' },
      { storeName: 'BIEN HOA', date: '2026-07-13', slot: '2026-07-13 10:00' },
    ],
    'data recovery must not hide missed scheduler slots',
  );
  assert.deepEqual(
    findMissingRuns(
      [store],
      ['2026-07-13'],
      laterSuccess,
      new Date('2026-07-13T06:20:00Z'),
    ),
    [
      { storeName: 'BIEN HOA', date: '2026-07-13', slot: '2026-07-13 09:00' },
      { storeName: 'BIEN HOA', date: '2026-07-13', slot: '2026-07-13 10:00' },
      { storeName: 'BIEN HOA', date: '2026-07-13', slot: '2026-07-13 12:00' },
    ],
    'every completed slot needs its own successful run',
  );
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
  assert.match(workflow, /on:\n  pull_request:\n  schedule:/);
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
  const productionStart = workflow.indexOf('  pull-sales:');
  const productionJob = workflow.slice(productionStart);
  assert.ok(
    productionJob.indexOf('PUPPETEER_CACHE_DIR=${RUNNER_TEMP}/puppeteer') <
      productionJob.indexOf('uses: actions/setup-node@v4'),
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
  const contractStart = workflow.indexOf('  photo-contract:');
  assert.ok(contractStart > 0 && productionStart > contractStart);
  const contractJob = workflow.slice(contractStart, productionStart);
  assert.match(contractJob, /name: Photo Objet contract/);
  assert.match(contractJob, /if: github\.event_name == 'pull_request'/);
  assert.match(contractJob, /node-version: '22'/);
  assert.match(contractJob, /run: npm ci/);
  assert.match(contractJob, /run: \|\n\s+npm run security-scan\n\s+npm test/);
  assert.doesNotMatch(contractJob, /secrets\./);
  assert.match(productionJob, /if: github\.event_name != 'pull_request'/);
  assert.doesNotMatch(
    workflow.slice(0, contractStart),
    /issues: write/,
    'write permission must not be global or available to the PR contract job',
  );
  assert.match(productionJob, /issues: write/);
  const collector = fs.readFileSync(path.join(__dirname, '../pull_moers_sales.js'), 'utf8');
  assert.match(collector, /runWithTransientRetry/);
  assert.match(collector, /attempt < 2/);
});
