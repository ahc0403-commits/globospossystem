#!/usr/bin/env node

const fs = require('node:fs');
const path = require('node:path');

function loadEnvFile(filePath) {
  if (!fs.existsSync(filePath)) return {};
  const result = {};
  for (const rawLine of fs.readFileSync(filePath, 'utf8').split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    result[key] = value;
  }
  return result;
}

const root = path.resolve(__dirname, '..');
const env = {
  ...loadEnvFile(path.join(root, '.env')),
  ...loadEnvFile(path.join(root, '.env.local')),
  ...process.env,
};

const supabaseUrl = env.SUPABASE_URL;
const anonKey = env.SUPABASE_ANON_KEY;
const email = env.SMOKE_USER_EMAIL || 'admin@globos.test';
const password = env.SMOKE_USER_PASSWORD || 'Globos1234';
const runTag =
  env.SMOKE_RUN_TAG ||
  `SMOKE-ATT-${new Date().toISOString().replace(/[-:T.Z]/g, '').slice(0, 14)}`;
const endDate = env.SMOKE_END_DATE || new Date().toISOString().slice(0, 10);
const hourlyRate = Number(env.SMOKE_PART_TIMER_HOURLY_RATE || 28000);
const attendanceDays = Number(env.SMOKE_ATTENDANCE_DAYS || 10);
const explicitStaffUserId = env.SMOKE_STAFF_USER_ID || '';

if (!supabaseUrl || !anonKey) {
  throw new Error('SUPABASE_URL and SUPABASE_ANON_KEY are required.');
}

if (!Number.isFinite(hourlyRate) || hourlyRate <= 0) {
  throw new Error('SMOKE_PART_TIMER_HOURLY_RATE must be a positive number.');
}

if (!Number.isInteger(attendanceDays) || attendanceDays <= 0) {
  throw new Error('SMOKE_ATTENDANCE_DAYS must be a positive integer.');
}

let accessToken;

function headers(extra = {}) {
  return {
    apikey: anonKey,
    Authorization: `Bearer ${accessToken || anonKey}`,
    'Content-Type': 'application/json',
    ...extra,
  };
}

async function request(method, urlPath, body, extraHeaders = {}) {
  const response = await fetch(`${supabaseUrl}${urlPath}`, {
    method,
    headers: headers(extraHeaders),
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let data = null;
  if (text) {
    try {
      data = JSON.parse(text);
    } catch (_) {
      data = text;
    }
  }
  if (!response.ok) {
    const message =
      data?.message || data?.error_description || data?.hint || text;
    throw new Error(`${method} ${urlPath} failed: ${message}`);
  }
  return data;
}

async function rpc(name, params = {}) {
  return request('POST', `/rest/v1/rpc/${name}`, params);
}

function legacyStoreParams(params) {
  const next = { ...params };
  if (Object.prototype.hasOwnProperty.call(next, 'p_store_id')) {
    next.p_restaurant_id = next.p_store_id;
    delete next.p_store_id;
  }
  return next;
}

function looksLikeSignatureMiss(error) {
  return /Could not find the function public\.|function public\..*does not exist/.test(
    error.message,
  );
}

async function rpcStoreCompat(name, params = {}) {
  try {
    return await rpc(name, params);
  } catch (error) {
    if (!looksLikeSignatureMiss(error) || !('p_store_id' in params)) {
      throw error;
    }
    return rpc(name, legacyStoreParams(params));
  }
}

async function select(table, params) {
  return request('GET', `/rest/v1/${table}?${new URLSearchParams(params)}`);
}

async function insertReturning(table, rows, columns) {
  const query = columns ? `?select=${encodeURIComponent(columns)}` : '';
  return request('POST', `/rest/v1/${table}${query}`, rows, {
    Prefer: 'return=representation',
  });
}

async function updateReturning(table, filters, row, columns) {
  const params = new URLSearchParams(filters);
  if (columns) params.set('select', columns);
  return request('PATCH', `/rest/v1/${table}?${params}`, row, {
    Prefer: 'return=representation',
  });
}

function addDays(dateString, delta) {
  const date = new Date(`${dateString}T00:00:00.000Z`);
  date.setUTCDate(date.getUTCDate() + delta);
  return date.toISOString().slice(0, 10);
}

function toUtcIsoFromVietnam(dateString, hhmmss) {
  return new Date(`${dateString}T${hhmmss}+07:00`).toISOString();
}

function fromUtcIsoToVietnamDate(isoString) {
  return new Date(new Date(isoString).getTime() + 7 * 60 * 60 * 1000);
}

function round2(value) {
  return Number(value.toFixed(2));
}

function asNumber(value) {
  if (typeof value === 'number') return value;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function buildShiftPlan(periodEndDate, days) {
  const seeds = [
    ['10:00:00', '16:00:00'],
    ['11:30:00', '17:00:00'],
    ['17:00:00', '22:00:00'],
    ['18:00:00', '22:30:00'],
    ['16:00:00', '21:30:00'],
    ['17:30:00', '22:30:00'],
    ['18:00:00', '23:00:00'],
    ['09:30:00', '15:30:00'],
    ['12:00:00', '18:00:00'],
    ['15:00:00', '21:00:00'],
  ];
  return Array.from({ length: days }, (_, index) => {
    const [clockIn, clockOut] = seeds[index % seeds.length];
    const date = addDays(periodEndDate, index - (days - 1));
    const inUtc = toUtcIsoFromVietnam(date, clockIn);
    const outUtc = toUtcIsoFromVietnam(date, clockOut);
    const hours = round2(
      (new Date(outUtc).getTime() - new Date(inUtc).getTime()) /
        (60 * 60 * 1000),
    );
    return {
      date,
      clockIn,
      clockOut,
      clockInUtc: inUtc,
      clockOutUtc: outUtc,
      hours,
      amount: round2(hours * hourlyRate),
    };
  });
}

function pairLogsLikeApp(rows) {
  const sorted = [...rows].sort((a, b) => {
    const at = new Date(a.logged_at || a.loggedAt).getTime();
    const bt = new Date(b.logged_at || b.loggedAt).getTime();
    return at - bt;
  });
  const pairs = [];
  let pendingIn = null;
  for (const row of sorted) {
    const type = String(row.attendance_type || row.type).toLowerCase();
    const raw = row.logged_at || row.loggedAt;
    if (!raw) continue;
    const vietnamTime = fromUtcIsoToVietnamDate(raw);
    if (type === 'clock_in') {
      if (pendingIn) pairs.push([pendingIn, null]);
      pendingIn = vietnamTime;
    } else if (type === 'clock_out') {
      if (!pendingIn) {
        pairs.push([null, vietnamTime]);
      } else {
        pairs.push([pendingIn, vietnamTime]);
        pendingIn = null;
      }
    }
  }
  if (pendingIn) pairs.push([pendingIn, null]);
  return pairs.map(([clockIn, clockOut]) => {
    const hours =
      clockIn && clockOut
        ? round2(Math.max(0, clockOut.getTime() - clockIn.getTime()) / 3600000)
        : 0;
    return {
      date: (clockIn || clockOut).toISOString().slice(0, 10),
      clockIn: clockIn ? clockIn.toISOString() : null,
      clockOut: clockOut ? clockOut.toISOString() : null,
      hours,
      amount: round2(hours * hourlyRate),
      isUnpaired: !clockIn || !clockOut,
    };
  });
}

async function fetchAttendanceLogs(storeId, periodStart, periodEnd, userId) {
  return rpcStoreCompat('get_attendance_log_view', {
    p_store_id: storeId,
    p_from: toUtcIsoFromVietnam(periodStart, '00:00:00'),
    p_to: toUtcIsoFromVietnam(periodEnd, '23:59:59'),
    p_user_id: userId || null,
  });
}

function normalizeAttendanceRpcRow(result) {
  const row = Array.isArray(result) ? result[0] : result;
  if (!row) throw new Error('record_attendance_event returned no row.');
  const id = row.attendance_log_id || row.id;
  if (!id) throw new Error('record_attendance_event returned no attendance log id.');
  return {
    id,
    restaurant_id: row.restaurant_id,
    user_id: row.user_id,
    type: row.attendance_type || row.type,
    photo_url: row.photo_url,
    photo_thumbnail_url: row.photo_thumbnail_url,
    logged_at: row.logged_at,
    created_at: row.created_at,
  };
}

async function recordAttendanceAction(storeId, userId, type, photoUrl) {
  const result = await rpcStoreCompat('record_attendance_event', {
    p_store_id: storeId,
    p_user_id: userId,
    p_type: type,
    p_photo_url: photoUrl,
    p_photo_thumbnail_url: photoUrl.replace('.jpg', '_thumb.jpg'),
  });
  return normalizeAttendanceRpcRow(result);
}

async function createAttendanceActionLogs(storeId, userId, shiftPlan, markerBase, warnings) {
  const actionRows = [];
  const patchedRows = [];

  for (const shift of shiftPlan) {
    for (const event of [
      ['clock_in', shift.clockInUtc],
      ['clock_out', shift.clockOutUtc],
    ]) {
      const [type, targetLoggedAt] = event;
      const photoUrl = `${markerBase}/${shift.date}/${type}.jpg`;
      let actionRow;
      try {
        actionRow = await recordAttendanceAction(storeId, userId, type, photoUrl);
      } catch (error) {
        warnings.push({
          code: 'record_attendance_event_failed',
          message:
            'record_attendance_event failed; used direct attendance_logs insert fallback for this action row.',
          detail: error.message,
          type,
          date: shift.date,
        });
        const inserted = await insertReturning(
          'attendance_logs',
          {
            restaurant_id: storeId,
            user_id: userId,
            type,
            logged_at: targetLoggedAt,
            photo_url: photoUrl,
            photo_thumbnail_url: photoUrl.replace('.jpg', '_thumb.jpg'),
          },
          'id,restaurant_id,user_id,type,logged_at,photo_url,photo_thumbnail_url,created_at',
        );
        actionRows.push(inserted[0]);
        patchedRows.push(inserted[0]);
        continue;
      }

      actionRows.push(actionRow);
      const patched = await updateReturning(
        'attendance_logs',
        { id: `eq.${actionRow.id}` },
        {
          logged_at: targetLoggedAt,
          photo_url: photoUrl,
          photo_thumbnail_url: photoUrl.replace('.jpg', '_thumb.jpg'),
        },
        'id,restaurant_id,user_id,type,logged_at,photo_url,photo_thumbnail_url,created_at',
      );
      patchedRows.push(patched[0]);
    }
  }

  return { actionRows, patchedRows };
}

async function upsertWageConfig(storeId, userId, effectiveFrom, warnings) {
  const payload = {
    p_store_id: storeId,
    p_user_id: userId,
    p_wage_type: 'hourly',
    p_hourly_rate: hourlyRate,
    p_shift_rates: [],
    p_effective_from: effectiveFrom,
  };
  try {
    const row = await rpcStoreCompat('upsert_staff_wage_config', payload);
    return { row, path: 'rpc' };
  } catch (error) {
    if (!looksLikeSignatureMiss(error)) throw error;
    warnings.push({
      code: 'upsert_staff_wage_config_rpc_missing',
      message:
        'The deployed database did not expose upsert_staff_wage_config; used direct staff_wage_configs write fallback for this smoke run.',
      detail: error.message,
    });
  }

  const existing = await select('staff_wage_configs', {
    select: 'id,restaurant_id,user_id,wage_type,hourly_rate,effective_from,is_active',
    user_id: `eq.${userId}`,
    effective_from: `eq.${effectiveFrom}`,
    limit: '1',
  });
  const directPayload = {
    restaurant_id: storeId,
    user_id: userId,
    wage_type: 'hourly',
    hourly_rate: hourlyRate,
    shift_rates: [],
    effective_from: effectiveFrom,
    is_active: true,
  };
  if (existing.length) {
    const updated = await updateReturning(
      'staff_wage_configs',
      { id: `eq.${existing[0].id}` },
      directPayload,
      'id,restaurant_id,user_id,wage_type,hourly_rate,effective_from,is_active',
    );
    return { row: updated[0], path: 'direct_update' };
  }

  const inserted = await insertReturning(
    'staff_wage_configs',
    directPayload,
    'id,restaurant_id,user_id,wage_type,hourly_rate,effective_from,is_active',
  );
  return { row: inserted[0], path: 'direct_insert' };
}

async function savePayrollCache(storeId, periodStart, periodEnd, payrollPayload, warnings) {
  try {
    const count = await rpcStoreCompat('save_payroll_cache', {
      p_store_id: storeId,
      p_period_start: periodStart,
      p_period_end: periodEnd,
      p_payrolls: payrollPayload,
    });
    return { count, path: 'rpc', rows: [] };
  } catch (error) {
    if (!looksLikeSignatureMiss(error)) throw error;
    warnings.push({
      code: 'save_payroll_cache_rpc_missing',
      message:
        'The deployed database did not expose save_payroll_cache; used direct payroll_records insert fallback for this smoke run.',
      detail: error.message,
    });
  }

  const directRows = payrollPayload.map((row) => ({
    restaurant_id: storeId,
    user_id: row.user_id,
    period_start: periodStart,
    period_end: periodEnd,
    total_hours: row.total_hours,
    total_amount: row.total_amount,
    breakdown: row.breakdown,
    status: 'draft',
  }));
  const inserted = await insertReturning(
    'payroll_records',
    directRows,
    'id,restaurant_id,user_id,period_start,period_end,total_hours,total_amount,status,created_at,breakdown',
  );
  return { count: inserted.length, path: 'direct_insert', rows: inserted };
}

async function chooseStaff(storeId, staffList, periodStart, periodEnd) {
  if (explicitStaffUserId) {
    const explicit = staffList.find((staff) => staff.user_id === explicitStaffUserId);
    if (!explicit) {
      throw new Error(`SMOKE_STAFF_USER_ID not found in staff directory: ${explicitStaffUserId}`);
    }
    return { ...explicit, existingLogCount: null };
  }

  const roleRank = new Map([
    ['waiter', 0],
    ['cashier', 1],
    ['kitchen', 2],
    ['admin', 3],
    ['store_admin', 4],
    ['brand_admin', 5],
    ['super_admin', 6],
  ]);

  const candidates = [...staffList].sort((a, b) => {
    const ar = roleRank.get(a.role) ?? 99;
    const br = roleRank.get(b.role) ?? 99;
    if (ar !== br) return ar - br;
    return String(a.full_name || '').localeCompare(String(b.full_name || ''));
  });

  const measured = [];
  for (const candidate of candidates) {
    const logs = await fetchAttendanceLogs(
      storeId,
      periodStart,
      periodEnd,
      candidate.user_id,
    );
    measured.push({ ...candidate, existingLogCount: logs.length });
  }

  measured.sort((a, b) => {
    const aAdmin = String(a.role).includes('admin') ? 1 : 0;
    const bAdmin = String(b.role).includes('admin') ? 1 : 0;
    if (aAdmin !== bAdmin) return aAdmin - bAdmin;
    if (a.existingLogCount !== b.existingLogCount) {
      return a.existingLogCount - b.existingLogCount;
    }
    return String(a.full_name || '').localeCompare(String(b.full_name || ''));
  });

  return measured[0];
}

async function main() {
  const runStartedAt = new Date().toISOString();
  const warnings = [];
  const periodStart = addDays(endDate, 1 - attendanceDays);
  const periodEnd = endDate;
  const shiftPlan = buildShiftPlan(periodEnd, attendanceDays);
  const expectedHours = round2(shiftPlan.reduce((sum, row) => sum + row.hours, 0));
  const expectedAmount = round2(expectedHours * hourlyRate);

  console.log(`Smoke run tag: ${runTag}`);
  console.log(`Attendance date window: ${periodStart}..${periodEnd}`);

  const login = await request(
    'POST',
    '/auth/v1/token?grant_type=password',
    { email, password },
    { Authorization: `Bearer ${anonKey}` },
  );
  accessToken = login.access_token;
  const authUserId = login.user.id;

  const profiles = await select('users', {
    select: 'id,auth_id,full_name,role,restaurant_id,is_active',
    auth_id: `eq.${authUserId}`,
  });
  if (!Array.isArray(profiles) || profiles.length !== 1) {
    throw new Error(`Expected one POS user profile for ${email}.`);
  }
  const profile = profiles[0];
  const storeId = profile.restaurant_id;
  if (!storeId) throw new Error('Profile does not have restaurant_id/store_id.');

  const storeRows = await select('restaurants', {
    select: 'id,name',
    id: `eq.${storeId}`,
  });
  const storeName = storeRows[0]?.name || storeId;
  console.log(`Actor: ${email} (${profile.role})`);
  console.log(`Store: ${storeName} (${storeId})`);

  const staffList = await rpcStoreCompat('get_attendance_staff_directory', {
    p_store_id: storeId,
  });
  if (!Array.isArray(staffList) || staffList.length === 0) {
    throw new Error('No active staff found for attendance smoke.');
  }
  const staff = await chooseStaff(storeId, staffList, periodStart, periodEnd);
  console.log(
    `Selected hourly part-timer candidate: ${staff.full_name} (${staff.role}, existing logs in window: ${staff.existingLogCount ?? 'not checked'})`,
  );

  const wageConfigResult = await upsertWageConfig(
    storeId,
    staff.user_id,
    periodStart,
    warnings,
  );
  const wageConfig = wageConfigResult.row;
  console.log(
    `Upserted hourly wage config: ${hourlyRate} VND/hour (${wageConfigResult.path})`,
  );

  const markerBase = `https://example.invalid/${runTag}/attendance`;
  const attendanceWriteResult = await createAttendanceActionLogs(
    storeId,
    staff.user_id,
    shiftPlan,
    markerBase,
    warnings,
  );
  const insertedLogs = attendanceWriteResult.patchedRows;
  const directFallbackRows = warnings.filter(
    (warning) => warning.code === 'record_attendance_event_failed',
  ).length;
  console.log(
    `Recorded attendance actions: ${attendanceWriteResult.actionRows.length} (${insertedLogs.length} historical log rows, direct fallback rows: ${directFallbackRows})`,
  );

  const fetchedForStaff = await fetchAttendanceLogs(
    storeId,
    periodStart,
    periodEnd,
    staff.user_id,
  );
  const fetchedForStore = await fetchAttendanceLogs(storeId, periodStart, periodEnd, null);
  const smokeRows = fetchedForStaff.filter((row) =>
    String(row.photo_url || '').startsWith(markerBase),
  );
  const storeSmokeRows = fetchedForStore.filter((row) =>
    String(row.photo_url || '').startsWith(markerBase),
  );
  const pairs = pairLogsLikeApp(smokeRows);
  const calculatedHours = round2(pairs.reduce((sum, row) => sum + row.hours, 0));
  const calculatedAmount = round2(pairs.reduce((sum, row) => sum + row.amount, 0));
  const unpairedCount = pairs.filter((pair) => pair.isUnpaired).length;
  const rowsWithPhotos = smokeRows.filter(
    (row) => row.photo_url && row.photo_thumbnail_url,
  ).length;
  const clockInActions = smokeRows.filter(
    (row) => row.attendance_type === 'clock_in',
  ).length;
  const clockOutActions = smokeRows.filter(
    (row) => row.attendance_type === 'clock_out',
  ).length;

  const payrollPayload = [
    {
      user_id: staff.user_id,
      total_hours: calculatedHours,
      total_amount: calculatedAmount,
      breakdown: pairs.map((record) => ({
        date: record.date,
        clock_in: record.clockIn,
        clock_out: record.clockOut,
        hours: record.hours,
        amount: record.amount,
      })),
    },
  ];

  const payrollSaveResult = await savePayrollCache(
    storeId,
    periodStart,
    periodEnd,
    payrollPayload,
    warnings,
  );
  const payrollInsertedCount = payrollSaveResult.count;
  console.log(
    `Saved payroll cache rows: ${payrollInsertedCount} (${payrollSaveResult.path})`,
  );

  const wageRows = await select('staff_wage_configs', {
    select: 'id,restaurant_id,user_id,wage_type,hourly_rate,effective_from,is_active',
    restaurant_id: `eq.${storeId}`,
    user_id: `eq.${staff.user_id}`,
    effective_from: `eq.${periodStart}`,
    is_active: 'eq.true',
    order: 'created_at.desc',
    limit: '1',
  });

  const payrollRecords = await select('payroll_records', {
    select:
      'id,restaurant_id,user_id,period_start,period_end,total_hours,total_amount,status,created_at,breakdown',
    restaurant_id: `eq.${storeId}`,
    user_id: `eq.${staff.user_id}`,
    period_start: `eq.${periodStart}`,
    period_end: `eq.${periodEnd}`,
    created_at: `gte.${runStartedAt}`,
    order: 'created_at.desc',
    limit: '5',
  });

  const validations = {
    recordedActionRows: attendanceWriteResult.actionRows.length === attendanceDays * 2,
    insertedLogRows: insertedLogs.length === attendanceDays * 2,
    fetchedStaffSmokeRows: smokeRows.length === attendanceDays * 2,
    fetchedStoreSmokeRows: storeSmokeRows.length === attendanceDays * 2,
    clockInActions: clockInActions === attendanceDays,
    clockOutActions: clockOutActions === attendanceDays,
    photoUrlsPersisted: rowsWithPhotos === attendanceDays * 2,
    pairedShifts: pairs.length === attendanceDays,
    noUnpairedLogs: unpairedCount === 0,
    hoursMatch: calculatedHours === expectedHours,
    amountMatch: calculatedAmount === expectedAmount,
    wageConfigReadable:
      wageRows.length === 1 &&
      wageRows[0].wage_type === 'hourly' &&
      asNumber(wageRows[0].hourly_rate) === hourlyRate,
    payrollCacheInserted: payrollInsertedCount === 1,
    payrollCacheReadable:
      payrollRecords.length >= 1 &&
      asNumber(payrollRecords[0].total_hours) === calculatedHours &&
      asNumber(payrollRecords[0].total_amount) === calculatedAmount,
  };
  const failed = Object.entries(validations)
    .filter(([, passed]) => !passed)
    .map(([name]) => name);

  const report = {
    runTag,
    runStartedAt,
    actor: {
      email,
      authUserId,
      profileId: profile.id,
      role: profile.role,
    },
    store: {
      id: storeId,
      name: storeName,
    },
    selectedStaff: {
      userId: staff.user_id,
      fullName: staff.full_name,
      role: staff.role,
      existingLogCountBeforeSmoke: staff.existingLogCount,
    },
    warnings,
    period: {
      start: periodStart,
      end: periodEnd,
      days: attendanceDays,
      timezone: 'Asia/Ho_Chi_Minh',
    },
    photoSimulation: {
      mode: 'synthetic_url_only',
      storageUploadSkipped: true,
      note: 'Photo capture was treated as already saved by writing photo_url and photo_thumbnail_url.',
    },
    wageConfig,
    wageConfigWritePath: wageConfigResult.path,
    payrollSavePath: payrollSaveResult.path,
    attendanceWritePath: directFallbackRows === 0 ? 'record_attendance_event_rpc_then_backdate' : 'mixed_rpc_and_direct_fallback',
    shiftPlan,
    expected: {
      rows: attendanceDays * 2,
      shifts: attendanceDays,
      hours: expectedHours,
      amount: expectedAmount,
      hourlyRate,
    },
    actual: {
      recordedAttendanceActionRows: attendanceWriteResult.actionRows.length,
      insertedAttendanceRows: insertedLogs.length,
      fetchedStaffSmokeRows: smokeRows.length,
      fetchedStoreSmokeRows: storeSmokeRows.length,
      clockInActions,
      clockOutActions,
      rowsWithPhotos,
      directFallbackRows,
      pairedShifts: pairs.length,
      unpairedCount,
      calculatedHours,
      calculatedAmount,
      payrollInsertedCount,
      payrollSaveRows: payrollSaveResult.rows,
      wageRows,
      payrollRecords,
    },
    validations,
    failed,
  };

  fs.mkdirSync(path.join(root, 'tmp'), { recursive: true });
  const reportPath = path.join(root, 'tmp', `smoke_attendance_part_timer_${runTag}.json`);
  fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
  console.log(`Report: ${reportPath}`);

  if (failed.length) {
    console.error(`FAILED validations: ${failed.join(', ')}`);
    process.exit(1);
  }

  console.log(
    `PASS: ${pairs.length} shifts, ${calculatedHours} hours, ${calculatedAmount} VND`,
  );
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
