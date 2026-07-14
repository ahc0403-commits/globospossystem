const puppeteer = require('puppeteer');
const { createClient } = require('@supabase/supabase-js');
const XLSX = require('xlsx');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const HCM_TIME_ZONE = 'Asia/Ho_Chi_Minh';
const EXPECTED_POS_PROJECT_REF = 'ynriuoomotxuwhuxxmhj';
const PHOTO_OBJET_BRAND_ID = '77000000-0000-0000-0000-000000000001';
const MAX_BACKFILL_DAYS = 7;
const SOURCE_IDENTITY_VERSION = 2;
const COLLECTOR_STARTED_AT = new Date();
const SCHEDULED_INTERVAL_MINUTES = Object.freeze({
  '10:00': 60,
  '12:00': 120,
  '14:00': 120,
  '16:00': 120,
  '18:00': 120,
  '20:00': 120,
  '22:30': 150,
});
const FAILURE = Object.freeze({
  DETERMINISTIC: 'deterministic',
  TRANSIENT: 'transient',
});
const OPERATIONAL_FAILURE = Object.freeze({
  COLLECTION_FAILED: 'COLLECTION_FAILED',
  DATA_INCOMPLETE: 'DATA_INCOMPLETE',
  AUDIT_INFRA_FAILED: 'AUDIT_INFRA_FAILED',
});

class CollectorError extends Error {
  constructor(message, failureClass, cause) {
    super(message, cause ? { cause } : undefined);
    this.name = 'CollectorError';
    this.failureClass = failureClass;
  }
}

function deterministic(message, cause) {
  return new CollectorError(message, FAILURE.DETERMINISTIC, cause);
}

function transient(message, cause) {
  return new CollectorError(message, FAILURE.TRANSIENT, cause);
}

function classifyError(error) {
  if (error && Object.values(FAILURE).includes(error.failureClass)) {
    return error.failureClass;
  }
  const message = String(error && error.message ? error.message : error);
  if (
    /timeout|timed out|econnreset|econnrefused|enotfound|fetch failed|network|socket|429|5\d\d/i.test(
      message,
    )
  ) {
    return FAILURE.TRANSIENT;
  }
  return FAILURE.DETERMINISTIC;
}

function asCollectorError(error, context) {
  if (error instanceof CollectorError) return error;
  const failureClass = classifyError(error);
  return new CollectorError(
    `${context}: ${error && error.message ? error.message : error}`,
    failureClass,
    error,
  );
}

function hcmDateString(offsetDays = 0, now = new Date()) {
  const date = new Date(now);
  date.setUTCDate(date.getUTCDate() + offsetDays);
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: HCM_TIME_ZONE,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(date);
  const value = Object.fromEntries(parts.map(part => [part.type, part.value]));
  return `${value.year}-${value.month}-${value.day}`;
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value)
      .sort()
      .map(key => `${JSON.stringify(key)}:${stableJson(value[key])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function hasDeviceHeader(cells) {
  return cells.some(cell =>
    ['device name', '기기명'].some(header =>
      String(cell).trim().toLowerCase().includes(header),
    ),
  );
}

function canonicalHeader(header) {
  const normalized = String(header).trim().toLowerCase();
  if (normalized === '매장' || normalized === 'store') return 'Store';
  if (normalized === '기기명' || normalized === 'device name') {
    return 'Device Name';
  }
  if (normalized === '기기id' || normalized === 'device id') return 'Device ID';
  if (normalized === '시간' || normalized === 'time') return 'Time';
  if (normalized === '금액' || normalized === 'amount') return 'Amount';
  if (normalized === '구분' || normalized === 'type') return 'Type';
  return String(header).trim();
}

function salesTableFromMatrix(matrix) {
  const headerIndex = matrix.findIndex(hasDeviceHeader);
  if (headerIndex < 0) return { recognized: false, rows: [] };

  const headers = matrix[headerIndex].map(canonicalHeader);
  const rows = matrix
    .slice(headerIndex + 1)
    .map(cells => {
      const row = {};
      headers.forEach((header, index) => {
        row[header] = cells[index] !== undefined ? String(cells[index]).trim() : '';
      });
      return row;
    })
    .filter(row => String(row['Device Name'] || '').trim() !== '');
  return { recognized: true, rows };
}

function rowsFromMatrix(matrix) {
  return salesTableFromMatrix(matrix).rows;
}

function parseHtmlXlsTable(htmlContent) {
  const stripTags = s =>
    s
      .replace(/<[^>]+>/g, '')
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&#\d+;/g, '')
      .trim();

  const body = htmlContent
    .replace(/^\uFEFF/, '')
    .replace(/<head[\s\S]*?<\/head>/gi, '')
    .replace(/<style[\s\S]*?<\/style>/gi, '');

  const cellPattern = /<t[dh][^>]*>([\s\S]*?)<\/t[dh]>/gi;
  const trPattern = /<tr[\s\S]*?<\/tr>/gi;

  function parseOneTable(tableHtml) {
    const matrix = [];
    const trp = new RegExp(trPattern.source, 'gi');
    let trMatch;
    while ((trMatch = trp.exec(tableHtml)) !== null) {
      const cells = [];
      const cp = new RegExp(cellPattern.source, 'gi');
      let cm;
      while ((cm = cp.exec(trMatch[0])) !== null) {
        cells.push(stripTags(cm[1]));
      }
      if (cells.length === 0 || cells.every(c => c === '')) continue;
      matrix.push(cells);
    }
    return salesTableFromMatrix(matrix);
  }

  const tablePattern = /<table[\s\S]*?<\/table>/gi;
  let tMatch;
  while ((tMatch = tablePattern.exec(body)) !== null) {
    const table = parseOneTable(tMatch[0]);
    if (table.recognized) return table;
  }

  return { recognized: false, rows: [] };
}

function parseSpreadsheetFile(filePath) {
  const buffer = fs.readFileSync(filePath);
  const sample = buffer.toString('utf8', 0, Math.min(buffer.length, 2048));

  if (/<html|<table/i.test(sample)) {
    const table = parseHtmlXlsTable(buffer.toString('utf8'));
    if (table.recognized) return table.rows;
    throw transient('Downloaded spreadsheet has no recognizable sales table');
  }

  const workbook = XLSX.read(buffer, { type: 'buffer' });
  for (const sheetName of workbook.SheetNames) {
    const matrix = XLSX.utils.sheet_to_json(workbook.Sheets[sheetName], {
      header: 1,
      raw: false,
      blankrows: false,
    });
    const table = salesTableFromMatrix(matrix);
    if (table.recognized) return table.rows;
  }
  throw transient('Downloaded spreadsheet has no recognizable sales table');
}

function parseVisibleDeviceTable() {
  const tables = Array.from(document.querySelectorAll('table'));
  for (const table of tables) {
    const matrix = Array.from(table.querySelectorAll('tr'))
      .map(row =>
        Array.from(row.querySelectorAll('th, td')).map(cell =>
          cell.innerText.trim(),
        ),
      )
      .filter(cells => cells.length > 0 && cells.some(cell => cell !== ''));

    const headerIndex = matrix.findIndex(cells =>
      cells.some(cell =>
        ['device name', '기기명'].some(header =>
          cell.toLowerCase().includes(header),
        ),
      ),
    );
    if (headerIndex < 0) continue;

    const headers = matrix[headerIndex].map(header => {
      const normalized = String(header).trim().toLowerCase();
      if (normalized === '매장' || normalized === 'store') return 'Store';
      if (normalized === '기기명' || normalized === 'device name') {
        return 'Device Name';
      }
      if (normalized === '기기id' || normalized === 'device id') {
        return 'Device ID';
      }
      if (normalized === '시간' || normalized === 'time') return 'Time';
      if (normalized === '금액' || normalized === 'amount') return 'Amount';
      if (normalized === '구분' || normalized === 'type') return 'Type';
      return String(header).trim();
    });
    return matrix
      .slice(headerIndex + 1)
      .map(cells => {
        const row = {};
        headers.forEach((header, index) => {
          row[header] = cells[index] || '';
        });
        return row;
      })
      .filter(row => String(row['Device Name'] || '').trim() !== '');
  }
  return null;
}

const STORE_DEFINITIONS = [
  ['BIEN HOA', 'BIENHOA'],
  ['DI AN', 'DIAN'],
  ['LONG THANH', 'LONGTHANH'],
  ['THAO DIEN', 'THAODIEN'],
  ['QUANG TRUNG', 'QUANGTRUNG'],
  ['NOW ZONE', 'NOWZONE'],
];

function buildStores(env = process.env) {
  return STORE_DEFINITIONS.map(([storeName, key]) => ({
    storeName,
    key,
    enabled: envFlagFrom(env, `PHOTO_OBJET_${key}_ENABLED`, true),
    user: env[`MOERS_${key}_USER`],
    pass: env[`MOERS_${key}_PASS`],
    storeId: env[`PHOTO_OBJET_${key}_STORE_ID`],
  }));
}

function envFlagFrom(env, name, fallback) {
  const raw = env[name];
  if (raw === undefined || raw === null || raw === '') return fallback;
  const normalized = String(raw).trim().toLowerCase();
  if (['1', 'true', 'yes', 'y', 'on'].includes(normalized)) return true;
  if (['0', 'false', 'no', 'n', 'off'].includes(normalized)) return false;
  throw deterministic(
    `${name} must be one of true/false, 1/0, yes/no, y/n, or on/off; received ${raw}`,
  );
}

function getTargetDates(env = process.env, now = COLLECTOR_STARTED_AT) {
  if (env.TARGET_DATE) return [env.TARGET_DATE];
  if (env.GITHUB_EVENT_NAME === 'schedule') {
    return [scheduledSlotFromCron(
      env.PHOTO_OBJET_SCHEDULE_CRON,
      resolveRunTimestamp(env, now),
    ).slotDateHcm];
  }
  const dates = [hcmDateString(0, now)];
  if (envFlagFrom(env, 'PHOTO_OBJET_INCLUDE_YESTERDAY', false)) {
    dates.push(hcmDateString(-1, now));
  }
  return [...new Set(dates)];
}

function validateDate(value, label) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value || '')) {
    throw deterministic(`${label} must use YYYY-MM-DD`);
  }
  const parsed = new Date(`${value}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) {
    throw deterministic(`${label} is not a valid calendar date`);
  }
  return parsed;
}

function inclusiveDateRange(from, to) {
  const start = validateDate(from, '--backfill-from');
  const end = validateDate(to, '--backfill-to');
  if (end < start) {
    throw deterministic('--backfill-to must be on or after --backfill-from');
  }
  const days = Math.floor((end - start) / 86400000) + 1;
  if (days > MAX_BACKFILL_DAYS) {
    throw deterministic(`Backfill is limited to ${MAX_BACKFILL_DAYS} days`);
  }
  return Array.from({ length: days }, (_, index) => {
    const date = new Date(start);
    date.setUTCDate(date.getUTCDate() + index);
    return date.toISOString().slice(0, 10);
  });
}

function parseArgs(argv, env = process.env) {
  const args = new Set(argv);
  const valueAfter = flag => {
    const index = argv.indexOf(flag);
    if (index < 0) return null;
    if (!argv[index + 1] || argv[index + 1].startsWith('--')) {
      throw deterministic(`${flag} requires a value`);
    }
    return argv[index + 1];
  };
  const known = new Set([
    '--preflight-only',
    '--execute',
    '--backfill-from',
    '--backfill-to',
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg.startsWith('--') || !known.has(arg)) {
      throw deterministic(`Unknown argument: ${arg}`);
    }
    if (['--backfill-from', '--backfill-to'].includes(arg)) {
      index += 1;
    }
  }

  const backfillFrom = valueAfter('--backfill-from');
  const backfillTo = valueAfter('--backfill-to');
  if (Boolean(backfillFrom) !== Boolean(backfillTo)) {
    throw deterministic('--backfill-from and --backfill-to must be provided together');
  }
  if (args.has('--execute') && !backfillFrom) {
    throw deterministic('--execute is only valid with a bounded backfill');
  }

  return {
    preflightOnly: args.has('--preflight-only'),
    backfill: Boolean(backfillFrom),
    execute: args.has('--execute'),
    targetDates: backfillFrom
      ? inclusiveDateRange(backfillFrom, backfillTo)
      : getTargetDates(env),
  };
}

function parseAmount(raw) {
  if (!raw && raw !== 0) return 0;
  return parseInt(String(raw).replace(/,/g, '').trim(), 10) || 0;
}

function aggregateByDevice(rows) {
  const devices = {};
  for (const row of rows) {
    const deviceName = String(row['Device Name'] || '').trim();
    const deviceId = String(row['Device ID'] || '').trim();
    const amount = parseAmount(row['Amount']);

    if (!deviceName) continue;
    if (amount <= 0) {
      throw deterministic(
        `Moers immutable sales row has a non-positive or invalid Amount: ${String(row['Amount'] ?? '<empty>')}`,
      );
    }

    if (!devices[deviceName]) {
      devices[deviceName] = {
        device_name: deviceName,
        device_id: deviceId,
        gross_sales: 0,
        service_amount: 0,
        transaction_count: 0,
        service_count: 0,
        raw_rows: [],
      };
    }

    devices[deviceName].gross_sales += amount;
    devices[deviceName].transaction_count += 1;

    devices[deviceName].raw_rows.push(row);
  }

  return Object.values(devices);
}

function parseSoldAt(targetDate, rawTime) {
  const value = String(rawTime || '').trim();
  const match = value.match(
    /^(?:(\d{4}-\d{2}-\d{2})[ T])?(\d{1,2}):(\d{2})(?::(\d{2}))?$/,
  );
  if (!match) return null;
  const rowDate = match[1] || targetDate;
  const hour = Number(match[2]);
  const minute = Number(match[3]);
  const second = Number(match[4] || '0');
  if (rowDate !== targetDate || hour > 23 || minute > 59 || second > 59) return null;
  const hh = String(hour).padStart(2, '0');
  const mm = String(minute).padStart(2, '0');
  const ss = String(second).padStart(2, '0');
  return `${targetDate}T${hh}:${mm}:${ss}+07:00`;
}

function selectRowsForInterval(rows, targetDate, identity) {
  const intervalStart = identity.intervalStartAt
    ? Date.parse(identity.intervalStartAt)
    : null;
  const intervalEnd = identity.intervalEndAt ? Date.parse(identity.intervalEndAt) : null;

  return rows
    .map(row => {
      const deviceName = String(row['Device Name'] || '').trim();
      const saleTimeText = String(row['Time'] || '').trim();
      const amount = parseAmount(row['Amount']);
      if (!deviceName) return null;
      if (amount <= 0) {
        throw deterministic(
          `Moers immutable sales row has a non-positive or invalid Amount: ${String(row['Amount'] ?? '<empty>')}`,
        );
      }

      const soldAt = parseSoldAt(targetDate, saleTimeText);
      if (!soldAt) {
        throw deterministic(
          `Moers row has invalid or out-of-date Time value: ${saleTimeText || '<empty>'}`,
        );
      }
      const soldAtMs = Date.parse(soldAt);
      if (intervalStart !== null && soldAtMs < intervalStart) return null;
      if (intervalEnd !== null && soldAtMs >= intervalEnd) return null;
      return { row, soldAt };
    })
    .filter(Boolean);
}

function assertImmutableSourceRows(existingHashes, incomingRows) {
  const incomingHashes = new Set(incomingRows.map(row => row.source_hash));
  const missingCount = existingHashes.filter(hash => !incomingHashes.has(hash)).length;
  if (missingCount > 0) {
    throw deterministic(
      `Moers immutable source drift: ${missingCount} previously stored row(s) are missing or changed`,
    );
  }
}

function normalizeRawSalesRows(selectedRows, store, targetDate, method, pullRunId, identity) {
  const occurrences = new Map();
  return selectedRows.map(({ row, soldAt }) => {
      const deviceName = String(row['Device Name'] || '').trim();
      const deviceId = String(row['Device ID'] || '').trim();
      const saleTimeText = String(row['Time'] || '').trim();
      const rawType = String(row['Type'] || '').trim();
      const amount = parseAmount(row['Amount']);

      const canonicalIdentity = {
        source_identity_version: SOURCE_IDENTITY_VERSION,
        store_id: store.storeId,
        sale_date: targetDate,
        device_id: deviceId,
        device_name: deviceName,
        sold_at: soldAt,
        amount,
        raw_type: rawType,
      };
      const canonicalKey = stableJson(canonicalIdentity);
      const occurrenceNo = (occurrences.get(canonicalKey) || 0) + 1;
      occurrences.set(canonicalKey, occurrenceNo);

      const rawPayload = {
        source: 'moers',
        collector_method: method,
        store_name: store.storeName,
        source_identity_version: SOURCE_IDENTITY_VERSION,
        occurrence_no: occurrenceNo,
        interval_start_at: identity.intervalStartAt,
        interval_end_at: identity.intervalEndAt,
        row,
      };
      const hashBasis = stableJson({
        ...canonicalIdentity,
        occurrence_no: occurrenceNo,
      });

      return {
        store_id: store.storeId,
        sale_date: targetDate,
        device_name: deviceName,
        device_id: deviceId || null,
        sale_time_text: saleTimeText || null,
        sold_at: soldAt,
        amount,
        raw_type: rawType || null,
        payment_method: 'CASH',
        buyer_kind: 'anonymous',
        raw_payload: rawPayload,
        source_hash: sha256(hashBasis),
        source_identity_version: SOURCE_IDENTITY_VERSION,
        occurrence_no: occurrenceNo,
        interval_start_at: identity.intervalStartAt,
        interval_end_at: identity.intervalEndAt,
        pull_run_id: pullRunId,
        last_seen_at: new Date().toISOString(),
      };
    });
}

async function loginAndGetData(page, user, pass, targetDate, downloadDir) {
  await page.goto('http://moersinc.com/', {
    waitUntil: 'networkidle2',
    timeout: 30000,
  });
  await page.waitForSelector('#id', { timeout: 10000 });
  await page.$eval('#id', el => (el.value = ''));
  await page.type('#id', user);
  await page.$eval('#pw', el => (el.value = ''));
  await page.type('#pw', pass);
  await Promise.all([
    page
      .waitForNavigation({ waitUntil: 'networkidle2', timeout: 45000 })
      .catch(() => {}),
    page.click('button, input[type=submit]'),
  ]);

  if (page.url().includes('login')) {
    throw new Error('Login failed - check credentials');
  }

  await page.goto('http://moersinc.com/day.php', {
    waitUntil: 'networkidle2',
    timeout: 30000,
  });
  await page.waitForSelector('#selDate', { timeout: 10000 });

  await new Promise(r => setTimeout(r, 1200));
  await Promise.all([
    page
      .waitForNavigation({ waitUntil: 'networkidle2', timeout: 30000 })
      .catch(() => {}),
    page.$eval(
      '#selDate',
      (el, date) => {
        el.value = date;
        if (typeof window.onChange === 'function') {
          window.onChange();
          return;
        }
        el.dispatchEvent(new Event('change', { bubbles: true }));
        el.dispatchEvent(new Event('input', { bubbles: true }));
      },
      targetDate,
    ),
  ]);
  await new Promise(r => setTimeout(r, 1000));

  const rateLimited = await page.evaluate(() =>
    document.body.innerText.includes('Can be viewed every'),
  );
  if (rateLimited) {
    throw transient('Moers rate limit prevented the daily report from loading');
  }

  const hasDownloadBtn = await page.evaluate(() => {
    const candidates = Array.from(
      document.querySelectorAll(
        'button, input[type=submit], input[type=button], a, [onclick]',
      ),
    );
    return candidates.some(el => {
      const text = (el.innerText || el.textContent || el.value || el.title || '')
        .toLowerCase()
        .replace(/\s+/g, ' ')
        .trim();
      return (
        text.includes('excel') ||
        text.includes('download') ||
        text.includes('xls') ||
        text.includes('엑셀') ||
        text.includes('다운')
      );
    });
  });

  if (hasDownloadBtn) {
    const client = await page.createCDPSession();
    await client.send('Page.setDownloadBehavior', {
      behavior: 'allow',
      downloadPath: path.resolve(downloadDir),
    });

    await page.evaluate(() => {
      const candidates = Array.from(
        document.querySelectorAll(
          'button, input[type=submit], input[type=button], a, [onclick]',
        ),
      );
      const btn = candidates.find(el => {
        const text = (el.innerText || el.textContent || el.value || el.title || '')
          .toLowerCase()
          .replace(/\s+/g, ' ')
          .trim();
        return (
          text.includes('excel') ||
          text.includes('download') ||
          text.includes('xls') ||
          text.includes('엑셀') ||
          text.includes('다운')
        );
      });
      if (btn) btn.click();
    });

    const maxWait = 30000;
    const pollStart = Date.now();
    while (Date.now() - pollStart < maxWait) {
      await new Promise(r => setTimeout(r, 500));
      const files = fs
        .readdirSync(downloadDir)
        .filter(
          f =>
            (f.endsWith('.xls') || f.endsWith('.xlsx')) &&
            !f.endsWith('.crdownload'),
        );
      if (files.length > 0) {
        await new Promise(r => setTimeout(r, 500));
        files.sort((a, b) => {
          const ta = fs.statSync(path.join(downloadDir, a)).mtimeMs;
          const tb = fs.statSync(path.join(downloadDir, b)).mtimeMs;
          return tb - ta;
        });
        return {
          method: 'excel',
          rows: parseSpreadsheetFile(path.join(downloadDir, files[0])),
        };
      }
    }
    throw new Error('Download timeout — no Excel file appeared after 30s');
  }

  const rows = await page.evaluate(parseVisibleDeviceTable);
  if (rows === null) {
    throw deterministic('Moers page has no recognizable sales table');
  }

  return { method: 'html_scrape', rows };
}

function scheduledSlotFromCron(cron, runTimestamp) {
  const match = /^(\d{1,2}) (\d{1,2}) \* \* \*$/.exec(String(cron || '').trim());
  if (!match) throw deterministic('Scheduled runs require a single fixed UTC cron slot');
  const minute = Number(match[1]);
  const utcHour = Number(match[2]);
  if (minute > 59 || utcHour > 23) {
    throw deterministic(`Invalid Photo Objet schedule slot: ${cron}`);
  }
  const hcmHour = (utcHour + 7) % 24;
  const slotTimeHcm = `${String(hcmHour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
  const valid = Object.prototype.hasOwnProperty.call(
    SCHEDULED_INTERVAL_MINUTES,
    slotTimeHcm,
  );
  if (!valid) throw deterministic(`Unsupported Photo Objet schedule slot: ${cron}`);
  const anchor = new Date(runTimestamp);
  if (Number.isNaN(anchor.getTime())) {
    throw deterministic('Scheduled runs require a valid event or run timestamp');
  }
  const occurrence = new Date(anchor);
  occurrence.setUTCHours(utcHour, minute, 0, 0);
  if (occurrence > anchor) occurrence.setUTCDate(occurrence.getUTCDate() - 1);
  return {
    slotDateHcm: hcmDateString(0, occurrence),
    slotTimeHcm,
  };
}

function fullDayInterval(targetDate) {
  const start = new Date(`${targetDate}T00:00:00+07:00`);
  const end = new Date(start.getTime() + 24 * 60 * 60 * 1000);
  return {
    intervalStartAt: start.toISOString(),
    intervalEndAt: end.toISOString(),
  };
}

function scheduledInterval(slot) {
  const end = new Date(`${slot.slotDateHcm}T${slot.slotTimeHcm}:00+07:00`);
  const durationMinutes = SCHEDULED_INTERVAL_MINUTES[slot.slotTimeHcm];
  if (!durationMinutes) {
    throw deterministic(`Unsupported Photo Objet slot interval: ${slot.slotTimeHcm}`);
  }
  return {
    intervalStartAt: new Date(end.getTime() - durationMinutes * 60 * 1000).toISOString(),
    intervalEndAt: end.toISOString(),
  };
}

function resolveRunTimestamp(env = process.env, fallback = COLLECTOR_STARTED_AT) {
  const value = env.PHOTO_OBJET_EVENT_TIMESTAMP ||
    env.PHOTO_OBJET_RUN_STARTED_AT ||
    fallback;
  const timestamp = new Date(value);
  if (Number.isNaN(timestamp.getTime())) {
    throw deterministic('PHOTO_OBJET event/run timestamp must be a valid timestamp');
  }
  return timestamp;
}

function createRunIdentity(options, targetDate, env = process.env) {
  if (options.backfill) {
    return {
      source: 'backfill',
      slotId: `backfill:${targetDate}`,
      slotDateHcm: targetDate,
      slotTimeHcm: null,
      ...fullDayInterval(targetDate),
    };
  }
  if (env.GITHUB_EVENT_NAME === 'schedule') {
    const slot = scheduledSlotFromCron(
      env.PHOTO_OBJET_SCHEDULE_CRON,
      resolveRunTimestamp(env),
    );
    if (targetDate !== slot.slotDateHcm) {
      throw deterministic(
        `Scheduled target date ${targetDate} does not match intended HCM slot date ${slot.slotDateHcm}`,
      );
    }
    return {
      source: 'scheduled',
      slotId: `scheduled:${slot.slotDateHcm}T${slot.slotTimeHcm}+07:00`,
      slotDateHcm: slot.slotDateHcm,
      slotTimeHcm: slot.slotTimeHcm,
      ...scheduledInterval(slot),
    };
  }
  const invocation = env.GITHUB_RUN_ID || env.PHOTO_OBJET_INVOCATION_ID || 'local';
  return {
    source: 'manual',
    slotId: `manual:${targetDate}:${invocation}`,
    slotDateHcm: targetDate,
    slotTimeHcm: null,
    ...fullDayInterval(targetDate),
  };
}

function expectedSlotRpcArgs(store, identity) {
  return {
    p_store_id: store.storeId,
    p_slot_date_hcm: identity.slotDateHcm,
    p_slot_time_hcm: identity.slotTimeHcm,
  };
}

async function bestEffortSlotRpc(supabase, name, args) {
  const { error } = await supabase.rpc(name, args);
  if (error) {
    console.error(
      `PHOTO_FAILURE_CLASS=${OPERATIONAL_FAILURE.AUDIT_INFRA_FAILED} ` +
      `slot_rpc=${name} message=${error.message}`,
    );
    return false;
  }
  return true;
}

async function claimScheduledExpectation(supabase, store, identity, runId) {
  if (identity.source !== 'scheduled') return true;
  return bestEffortSlotRpc(supabase, 'photo_objet_claim_expected_slot', {
    ...expectedSlotRpcArgs(store, identity),
    p_run_id: runId,
  });
}

async function completeScheduledExpectation(
  supabase,
  store,
  identity,
  runId,
  zeroSales,
) {
  if (identity.source !== 'scheduled') return true;
  return bestEffortSlotRpc(supabase, 'photo_objet_complete_expected_slot', {
    ...expectedSlotRpcArgs(store, identity),
    p_run_id: runId,
    p_zero_sales: zeroSales,
  });
}

function operationalFailureClass(error) {
  return /incomplete aggregate|immutable source drift/i.test(String(error?.message || error))
    ? OPERATIONAL_FAILURE.DATA_INCOMPLETE
    : OPERATIONAL_FAILURE.COLLECTION_FAILED;
}

async function failScheduledExpectation(supabase, store, identity, error) {
  if (identity.source !== 'scheduled') return true;
  return bestEffortSlotRpc(supabase, 'photo_objet_fail_expected_slot', {
    ...expectedSlotRpcArgs(store, identity),
    p_failure_class: operationalFailureClass(error),
  });
}

async function startPullRun(supabase, store, targetDate, identity) {
  const { data, error } = await supabase
    .from('photo_objet_sales_pull_runs')
    .insert({
      store_id: store.storeId,
      target_date: targetDate,
      run_source: identity.source,
      slot_id: identity.slotId,
      slot_date_hcm: identity.slotDateHcm,
      slot_time_hcm: identity.slotTimeHcm,
      interval_start_at: identity.intervalStartAt,
      interval_end_at: identity.intervalEndAt,
      status: 'started',
      error_message: null,
    })
    .select('id')
    .single();

  if (error) throw new Error(`Pull run create failed: ${error.message}`);
  return data.id;
}

async function finishPullRun(supabase, runId, identity, patch, bestEffort = false) {
  if (!runId) return;
  const { error } = await supabase
    .from('photo_objet_sales_pull_runs')
    .update({
      ...patch,
      error_message: patch.error_message || null,
      finished_at: new Date().toISOString(),
    })
    .eq('id', runId);
  if (error) {
    const collectorError = asCollectorError(error, 'Pull run update failed');
    if (!bestEffort) throw collectorError;
    console.error(`  Pull run update failed: ${collectorError.message}`);
  }
}

async function upsertRawSalesRows(supabase, rows) {
  if (rows.length === 0) {
    return { inserted: 0, duplicate: 0 };
  }

  const hashes = rows.map(row => row.source_hash);
  const { data: existing, error: lookupError } = await supabase
    .from('photo_objet_sales_raw')
    .select('source_hash')
    .in('source_hash', hashes);
  if (lookupError) {
    throw new Error(`Raw sales lookup failed: ${lookupError.message}`);
  }

  const existingHashes = new Set((existing || []).map(row => row.source_hash));
  const { error } = await supabase
    .from('photo_objet_sales_raw')
    .upsert(rows, { onConflict: 'source_hash', ignoreDuplicates: true });
  if (error) {
    throw new Error(`Raw sales upsert failed: ${error.message}`);
  }

  return {
    inserted: rows.filter(row => !existingHashes.has(row.source_hash)).length,
    duplicate: rows.filter(row => existingHashes.has(row.source_hash)).length,
  };
}

async function loadExistingIntervalSourceHashes(supabase, storeId, identity) {
  const { data, error } = await supabase
    .from('photo_objet_sales_raw')
    .select('source_hash')
    .eq('store_id', storeId)
    .eq('source_identity_version', SOURCE_IDENTITY_VERSION)
    .gte('sold_at', identity.intervalStartAt)
    .lt('sold_at', identity.intervalEndAt);
  if (error) throw new Error(`Immutable source lookup failed: ${error.message}`);
  return (data || []).map(row => row.source_hash);
}

async function loadDailyRawSalesRows(supabase, storeId, targetDate) {
  const { data, error } = await supabase
    .from('photo_objet_sales_raw')
    .select('device_name,device_id,amount,raw_payload')
    .eq('store_id', storeId)
    .eq('sale_date', targetDate)
    .eq('source_identity_version', SOURCE_IDENTITY_VERSION);
  if (error) throw new Error(`Daily raw sales lookup failed: ${error.message}`);
  return data || [];
}

function aggregateDailyRawRows(rows) {
  const devices = new Map();
  for (const row of rows) {
    const deviceName = String(row.device_name || '').trim();
    const amount = Number(row.amount || 0);
    if (!deviceName || !Number.isSafeInteger(amount) || amount <= 0) {
      throw deterministic('Canonical Photo Objet raw ledger contains an invalid sales row');
    }
    if (!devices.has(deviceName)) {
      devices.set(deviceName, {
        device_name: deviceName,
        device_id: row.device_id || '',
        gross_sales: 0,
        service_amount: 0,
        transaction_count: 0,
        service_count: 0,
        raw_rows: [],
      });
    }
    const device = devices.get(deviceName);
    device.gross_sales += amount;
    device.transaction_count += 1;
    device.raw_rows.push(row.raw_payload?.row || {});
  }
  return [...devices.values()];
}

async function loadExistingAggregates(supabase, storeId, targetDate) {
  const { data, error } = await supabase
    .from('photo_objet_sales')
    .select('device_name,gross_sales,transaction_count')
    .eq('store_id', storeId)
    .eq('sale_date', targetDate);
  if (error) {
    throw asCollectorError(error, 'Existing aggregate lookup failed');
  }
  return data || [];
}

function assertAggregateComplete(existingRows, nextRows) {
  if (nextRows.length === 0) {
    if (existingRows.length > 0) {
      throw transient('Empty aggregate snapshot would erase existing device totals');
    }
    return;
  }
  const nextByDevice = new Map(nextRows.map(row => [row.device_name, row]));
  for (const existing of existingRows) {
    const next = nextByDevice.get(existing.device_name);
    if (
      !next ||
      Number(next.gross_sales) < Number(existing.gross_sales) ||
      Number(next.transaction_count) < Number(existing.transaction_count)
    ) {
      throw transient(
        `Incomplete aggregate snapshot for device ${existing.device_name}; existing totals preserved`,
      );
    }
  }
}

async function processStore(supabase, store, targetDate, downloadDir, runIdentity) {
  const { storeName, user, pass, storeId, enabled } = store;

  if (!enabled) {
    return {
      storeName,
      success: true,
      skipped: true,
      rows: 0,
      rawInserted: 0,
      rawDuplicate: 0,
    };
  }

  if (!storeId) {
    return {
      storeName,
      success: false,
      error: `Missing store id secret for ${storeName}`,
    };
  }

  if (fs.existsSync(downloadDir)) {
    fs.readdirSync(downloadDir).forEach(f => {
      try {
        fs.unlinkSync(path.join(downloadDir, f));
      } catch {}
    });
  } else {
    fs.mkdirSync(downloadDir, { recursive: true });
  }

  let browser;
  let page;
  let pullRunId = null;

  try {
    browser = await puppeteer.launch({
      headless: true,
      executablePath: process.env.PUPPETEER_EXECUTABLE_PATH,
      protocolTimeout: 120000,
      args: [
        '--no-sandbox',
        '--disable-setuid-sandbox',
        '--disable-dev-shm-usage',
        '--disable-gpu',
        '--disable-extensions',
        '--disable-component-extensions-with-background-pages',
        '--disable-client-side-phishing-detection',
        '--disable-features=BlockInsecurePrivateNetworkRequests,PrivateNetworkAccessSendPreflights,HttpsFirstBalancedModeAutoEnable,HttpsUpgrades,SubresourceFilter',
      ],
    });
    console.log(`  ${storeName}: opening browser page`);
    page = await browser.newPage();
    page.setDefaultTimeout(15000);
    page.setDefaultNavigationTimeout(30000);
    pullRunId = await startPullRun(supabase, store, targetDate, runIdentity);
    await claimScheduledExpectation(supabase, store, runIdentity, pullRunId);
    const { method, rows } = await loginAndGetData(
      page,
      user,
      pass,
      targetDate,
      downloadDir,
    );
    console.log(`  Method: ${method}, ${rows.length} rows`);

    const selectedRows = selectRowsForInterval(rows, targetDate, runIdentity);
    const zeroSalesInterval = selectedRows.length === 0;
    console.log(
      `  ${storeName}: accepted ${selectedRows.length}/${rows.length} rows for ` +
        `${runIdentity.intervalStartAt} <= sold_at < ${runIdentity.intervalEndAt}`,
    );
    const rawRows = normalizeRawSalesRows(
      selectedRows,
      store,
      targetDate,
      method,
      pullRunId,
      runIdentity,
    );
    const existingSourceHashes = await loadExistingIntervalSourceHashes(
      supabase,
      storeId,
      runIdentity,
    );
    assertImmutableSourceRows(existingSourceHashes, rawRows);
    const rawResult = await upsertRawSalesRows(supabase, rawRows);
    console.log(
      `  ${storeName}: ${rawResult.inserted} new raw rows, ${rawResult.duplicate} duplicates`,
    );

    const dailyRawRows = await loadDailyRawSalesRows(supabase, storeId, targetDate);
    const deviceRows = aggregateDailyRawRows(dailyRawRows);
    console.log(`  ${storeName}: ${deviceRows.length} devices`);
    const existingRows = await loadExistingAggregates(supabase, storeId, targetDate);
    assertAggregateComplete(existingRows, deviceRows);

    if (deviceRows.length === 0) {
      console.log(`  ${storeName}: no sales rows for target date`);
      await finishPullRun(supabase, pullRunId, runIdentity, {
        collector_method: method,
        status: 'success',
        rows_read: rows.length,
        rows_inserted: rawResult.inserted,
        rows_duplicate: rawResult.duplicate,
        aggregate_rows: 0,
        interval_rows: selectedRows.length,
      });
      await completeScheduledExpectation(
        supabase, store, runIdentity, pullRunId, zeroSalesInterval,
      );
      return {
        storeName,
        success: true,
        rows: 0,
        rawInserted: rawResult.inserted,
        rawDuplicate: rawResult.duplicate,
      };
    }

    const payload = deviceRows.map(d => ({
      store_id: storeId,
      sale_date: targetDate,
      device_name: d.device_name,
      device_id: d.device_id,
      gross_sales: d.gross_sales,
      service_amount: d.service_amount,
      transaction_count: d.transaction_count,
      service_count: d.service_count,
      raw_rows: d.raw_rows,
      pulled_at: new Date().toISOString(),
      pull_source: runIdentity.source === 'scheduled' ? 'scheduled' : 'manual',
    }));

    const { error } = await supabase
      .from('photo_objet_sales')
      .upsert(payload, { onConflict: 'store_id,sale_date,device_name' });

    if (error) {
      throw new Error(`Supabase upsert failed: ${error.message}`);
    }

    console.log(`  ✓ ${storeName}: ${payload.length} device rows upserted`);
    await finishPullRun(supabase, pullRunId, runIdentity, {
      collector_method: method,
      status: 'success',
      rows_read: rows.length,
      rows_inserted: rawResult.inserted,
      rows_duplicate: rawResult.duplicate,
      aggregate_rows: payload.length,
      interval_rows: selectedRows.length,
    });
    await completeScheduledExpectation(
      supabase, store, runIdentity, pullRunId, zeroSalesInterval,
    );
    return {
      storeName,
      success: true,
      rows: payload.length,
      rawInserted: rawResult.inserted,
      rawDuplicate: rawResult.duplicate,
    };
  } catch (err) {
    const collectorError = asCollectorError(err, storeName);
    console.error(`  FAILED ${storeName}: ${collectorError.message}`);
    await finishPullRun(supabase, pullRunId, runIdentity, {
      status: 'failed',
      error_message: collectorError.message,
    }, true);
    await failScheduledExpectation(supabase, store, runIdentity, collectorError);
    return {
      storeName,
      success: false,
      error: collectorError.message,
      failureClass: collectorError.failureClass,
    };
  } finally {
    if (page) await page.close().catch(() => {});
    if (browser) await browser.close().catch(() => {});
  }
}

function validateStaticPreflight(stores, env = process.env, runtime = {}) {
  const missing = [];
  if (!env.SUPABASE_URL) missing.push('SUPABASE_URL');
  if (!env.SUPABASE_SERVICE_KEY) missing.push('SUPABASE_SERVICE_KEY');

  for (const store of stores) {
    if (!store.enabled) continue;
    if (!store.user) missing.push(`MOERS_${store.key}_USER`);
    if (!store.pass) missing.push(`MOERS_${store.key}_PASS`);
    if (!store.storeId) missing.push(`PHOTO_OBJET_${store.key}_STORE_ID`);
  }

  if (missing.length > 0) {
    throw deterministic(`Missing required environment values: ${missing.join(', ')}`);
  }
  if (stores.filter(store => store.enabled).length === 0) {
    throw deterministic('At least one Photo Objet store must be enabled');
  }

  const nodeVersion = runtime.nodeVersion || process.versions.node;
  if (Number(nodeVersion.split('.')[0]) !== 22) {
    throw deterministic(`Node 22 is required; found ${nodeVersion}`);
  }
  const webSocket = runtime.webSocket === undefined ? globalThis.WebSocket : runtime.webSocket;
  if (typeof webSocket !== 'function') {
    throw deterministic('Node WebSocket global is unavailable');
  }

  let target;
  try {
    target = new URL(env.SUPABASE_URL);
  } catch (error) {
    throw deterministic('SUPABASE_URL is invalid', error);
  }
  if (
    target.protocol !== 'https:' ||
    target.hostname !== `${EXPECTED_POS_PROJECT_REF}.supabase.co`
  ) {
    throw deterministic(
      `SUPABASE_URL must target POS project ${EXPECTED_POS_PROJECT_REF}`,
    );
  }

  const ids = stores.filter(store => store.enabled).map(store => store.storeId);
  const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (ids.some(id => !uuidPattern.test(id))) {
    throw deterministic('Every enabled Photo Objet store mapping must be a UUID');
  }
  if (new Set(ids).size !== ids.length) {
    throw deterministic('Photo Objet store mappings must be unique');
  }

  const executablePath = runtime.executablePath || env.PUPPETEER_EXECUTABLE_PATH;
  if (!executablePath || !path.isAbsolute(executablePath)) {
    throw deterministic('PUPPETEER_EXECUTABLE_PATH must be an absolute path');
  }
  try {
    fs.accessSync(executablePath, fs.constants.X_OK);
  } catch (error) {
    throw deterministic(`Chromium is not executable at ${executablePath}`, error);
  }
}

function validateStoreMappings(rows, stores) {
  const enabled = stores.filter(store => store.enabled);
  const byId = new Map((rows || []).map(row => [row.id, row]));
  const normalizeName = value => String(value || '').trim().replace(/\s+/g, ' ').toUpperCase();
  for (const store of enabled) {
    const row = byId.get(store.storeId);
    if (!row) {
      throw deterministic(`${store.storeName} mapping is not a POS restaurant`);
    }
    if (row.is_active !== true) {
      throw deterministic(`${store.storeName} mapping is inactive`);
    }
    if (row.brand_id !== PHOTO_OBJET_BRAND_ID) {
      throw deterministic(`${store.storeName} mapping is outside the Photo Objet brand`);
    }
    const mappedName = normalizeName(row.name);
    const expectedPosName = normalizeName(`PHOTO OBJET ${store.storeName}`);
    if (mappedName !== expectedPosName) {
      throw deterministic(
        `${store.storeName} mapping resolves to unexpected store ${row.name || '(unnamed)'}`,
      );
    }
    if (!['direct', 'external'].includes(row.store_type)) {
      throw deterministic(`${store.storeName} mapping has invalid ownership type`);
    }
  }
}

function createSupabaseClient(env = process.env) {
  return createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

async function runPreflight(supabase, stores, env = process.env, runtime = {}) {
  validateStaticPreflight(stores, env, runtime);
  const ids = stores.filter(store => store.enabled).map(store => store.storeId);
  const { data, error } = await supabase
    .from('restaurants')
    .select('id,name,is_active,brand_id,store_type')
    .in('id', ids);
  if (error) throw asCollectorError(error, 'POS store mapping query failed');
  validateStoreMappings(data, stores);

  const targetProbes = [
    ['photo_objet_sales_pull_runs', 'id,target_date,status,error_message'],
    ['photo_objet_sales_raw', 'id,source_hash'],
    ['photo_objet_sales', 'id'],
  ];
  for (const [table, columns] of targetProbes) {
    const { error: targetError } = await supabase.from(table).select(columns).limit(1);
    if (targetError) {
      throw asCollectorError(targetError, `POS ${table} target is unavailable`);
    }
    const { error: insertProbeError } = await supabase.from(table).insert({});
    if (!insertProbeError) {
      throw deterministic(`POS ${table} insert probe unexpectedly created an empty row`);
    }
    if (insertProbeError.code !== '23502') {
      throw asCollectorError(insertProbeError, `POS ${table} insert permission probe failed`);
    }
  }
  for (const [table, columns] of [
    ['photo_objet_monitoring_policies', 'id,store_id,effective_from,is_enabled'],
    ['photo_objet_expected_slots', 'id,store_id,slot_date_hcm,slot_time_hcm,status'],
  ]) {
    const { error: ledgerError } = await supabase.from(table).select(columns).limit(1);
    if (ledgerError) {
      console.error(
        `PHOTO_FAILURE_CLASS=${OPERATIONAL_FAILURE.AUDIT_INFRA_FAILED} `
          + `ledger_probe=${table} message=${ledgerError.message}`,
      );
    }
  }
  const nodeVersion = runtime.nodeVersion || process.versions.node;
  console.log(
    `PREFLIGHT_OK node=${nodeVersion} websocket=available project=${EXPECTED_POS_PROJECT_REF} stores=${ids.length}`,
  );
}

async function runWithTransientRetry(task, onRetry = () => {}) {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const result = await task(attempt);
    if (result.success || result.failureClass !== FAILURE.TRANSIENT || attempt === 1) {
      return { ...result, attempts: attempt + 1 };
    }
    onRetry(result);
  }
  throw new Error('unreachable');
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  options.targetDates.forEach(date => validateDate(date, 'target date'));
  const stores = buildStores();
  validateStaticPreflight(stores);
  const supabase = createSupabaseClient();
  await runPreflight(supabase, stores);
  if (options.preflightOnly) return;
  const enabledStores = stores.filter(store => store.enabled);
  const skippedStores = stores.filter(store => !store.enabled);
  if (options.backfill && !options.execute) {
    console.log('BACKFILL_DRY_RUN no browser or database writes will occur');
    console.log(`Dates: ${options.targetDates.join(', ')}`);
    console.log(`Stores: ${enabledStores.map(store => store.storeName).join(', ')}`);
    console.log(`Planned store-days: ${options.targetDates.length * enabledStores.length}`);
    return;
  }

  const targetDates = options.targetDates;
  console.log('\n=== Photo Objet Sales Pull ===');
  console.log(`Target dates: ${targetDates.join(', ')}`);
  console.log(`Enabled stores: ${enabledStores.map(s => s.storeName).join(', ')}`);
  if (skippedStores.length > 0) {
    console.log(`Skipped stores: ${skippedStores.map(s => s.storeName).join(', ')}`);
  }
  console.log(`Started at: ${new Date().toISOString()}\n`);

  const downloadDir = path.join(__dirname, 'downloads_tmp');
  fs.mkdirSync(downloadDir, { recursive: true });

  const results = [];

  try {
    for (const targetDate of targetDates) {
      const runIdentity = createRunIdentity(options, targetDate);
      console.log(`RUN_IDENTITY slot=${runIdentity.slotId} source=${runIdentity.source}`);
      for (const store of enabledStores) {
        console.log(`\nProcessing: ${store.storeName} (${targetDate})`);
        const result = await runWithTransientRetry(
          () => processStore(
            supabase,
            store,
            targetDate,
            downloadDir,
            runIdentity,
          ),
          failure => console.warn(
            `  RETRY transient failure for ${store.storeName}: ${failure.error}`,
          ),
        );
        results.push({ ...result, targetDate });
      }
    }
  } finally {
    try {
      fs.rmSync(downloadDir, { recursive: true, force: true });
    } catch {}
  }

  console.log('\n=== Summary ===');
  const success = results.filter(r => r.success);
  const failed = results.filter(r => !r.success);
  console.log(`Success: ${success.length}/${results.length}`);
  success.forEach(r =>
    console.log(
      `  OK ${r.storeName} ${r.targetDate} (${r.rows} device rows, ${r.rawInserted || 0} new raw, ${r.rawDuplicate || 0} duplicate raw, ${r.attempts} attempt(s))`,
    ),
  );
  if (failed.length > 0) {
    console.log('Failed:');
    failed.forEach(r => console.log(`  FAILED ${r.storeName}: ${r.error}`));
    const failureClass = failed.some(r => r.failureClass === FAILURE.DETERMINISTIC)
      ? FAILURE.DETERMINISTIC
      : FAILURE.TRANSIENT;
    throw new CollectorError(
      `${failed.length} of ${results.length} store pulls failed`,
      failureClass,
    );
  }
}

if (require.main === module) {
  main().catch(err => {
    const failureClass = classifyError(err);
    console.error(`FLARE_FAILURE_CLASS=${failureClass}`);
    console.error(`COLLECTOR_FAILED ${err.message || err}`);
    process.exit(failureClass === FAILURE.DETERMINISTIC ? 2 : 3);
  });
}

module.exports = {
  CollectorError,
  FAILURE,
  OPERATIONAL_FAILURE,
  MAX_BACKFILL_DAYS,
  SOURCE_IDENTITY_VERSION,
  aggregateDailyRawRows,
  assertAggregateComplete,
  assertImmutableSourceRows,
  buildStores,
  classifyError,
  claimScheduledExpectation,
  createRunIdentity,
  completeScheduledExpectation,
  failScheduledExpectation,
  inclusiveDateRange,
  parseArgs,
  parseSoldAt,
  parseSpreadsheetFile,
  runPreflight,
  runWithTransientRetry,
  scheduledSlotFromCron,
  selectRowsForInterval,
  normalizeRawSalesRows,
  operationalFailureClass,
  validateStaticPreflight,
  validateStoreMappings,
};
