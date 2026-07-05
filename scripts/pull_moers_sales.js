const puppeteer = require('puppeteer');
const { createClient } = require('@supabase/supabase-js');
const XLSX = require('xlsx');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const HCM_TIME_ZONE = 'Asia/Ho_Chi_Minh';

function envFlag(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === null || raw === '') return fallback;
  return ['1', 'true', 'yes', 'y', 'on'].includes(String(raw).toLowerCase());
}

function hcmDateString(offsetDays = 0) {
  const date = new Date();
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

function rowsFromMatrix(matrix) {
  const headerIndex = matrix.findIndex(hasDeviceHeader);
  if (headerIndex < 0) return [];

  const headers = matrix[headerIndex].map(canonicalHeader);
  return matrix
    .slice(headerIndex + 1)
    .map(cells => {
      const row = {};
      headers.forEach((header, index) => {
        row[header] = cells[index] !== undefined ? String(cells[index]).trim() : '';
      });
      return row;
    })
    .filter(row => String(row['Device Name'] || '').trim() !== '');
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
    return rowsFromMatrix(matrix);
  }

  const tablePattern = /<table[\s\S]*?<\/table>/gi;
  let tMatch;
  while ((tMatch = tablePattern.exec(body)) !== null) {
    const rows = parseOneTable(tMatch[0]);
    if (rows.length > 0) return rows;
  }

  return [];
}

function parseSpreadsheetFile(filePath) {
  const buffer = fs.readFileSync(filePath);
  const sample = buffer.toString('utf8', 0, Math.min(buffer.length, 2048));

  if (/<html|<table/i.test(sample)) {
    return parseHtmlXlsTable(buffer.toString('utf8'));
  }

  const workbook = XLSX.read(buffer, { type: 'buffer' });
  for (const sheetName of workbook.SheetNames) {
    const matrix = XLSX.utils.sheet_to_json(workbook.Sheets[sheetName], {
      header: 1,
      raw: false,
      blankrows: false,
    });
    const rows = rowsFromMatrix(matrix);
    if (rows.length > 0) return rows;
  }
  return [];
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
  return [];
}

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY,
);

const STORES = [
  {
    storeName: 'D7',
    enabled: envFlag('PHOTO_OBJET_D7_ENABLED', false),
    user: process.env.MOERS_D7_USER,
    pass: process.env.MOERS_D7_PASS,
    storeId: process.env.PHOTO_OBJET_D7_STORE_ID,
  },
  {
    storeName: 'BIEN HOA',
    enabled: envFlag('PHOTO_OBJET_BIENHOA_ENABLED', true),
    user: process.env.MOERS_BIENHOA_USER,
    pass: process.env.MOERS_BIENHOA_PASS,
    storeId: process.env.PHOTO_OBJET_BIENHOA_STORE_ID,
  },
  {
    storeName: 'DI AN',
    enabled: envFlag('PHOTO_OBJET_DIAN_ENABLED', true),
    user: process.env.MOERS_DIAN_USER,
    pass: process.env.MOERS_DIAN_PASS,
    storeId: process.env.PHOTO_OBJET_DIAN_STORE_ID,
  },
  {
    storeName: 'LONG THANH',
    enabled: envFlag('PHOTO_OBJET_LONGTHANH_ENABLED', true),
    user: process.env.MOERS_LONGTHANH_USER,
    pass: process.env.MOERS_LONGTHANH_PASS,
    storeId: process.env.PHOTO_OBJET_LONGTHANH_STORE_ID,
  },
  {
    storeName: 'THAO DIEN',
    enabled: envFlag('PHOTO_OBJET_THAODIEN_ENABLED', true),
    user: process.env.MOERS_THAODIEN_USER,
    pass: process.env.MOERS_THAODIEN_PASS,
    storeId: process.env.PHOTO_OBJET_THAODIEN_STORE_ID,
  },
  {
    storeName: 'QUANG TRUNG',
    enabled: envFlag('PHOTO_OBJET_QUANGTRUNG_ENABLED', true),
    user: process.env.MOERS_QUANGTRUNG_USER,
    pass: process.env.MOERS_QUANGTRUNG_PASS,
    storeId: process.env.PHOTO_OBJET_QUANGTRUNG_STORE_ID,
  },
  {
    storeName: 'NOW ZONE',
    enabled: envFlag('PHOTO_OBJET_NOWZONE_ENABLED', true),
    user: process.env.MOERS_NOWZONE_USER,
    pass: process.env.MOERS_NOWZONE_PASS,
    storeId: process.env.PHOTO_OBJET_NOWZONE_STORE_ID,
  },
];

function getTargetDates() {
  if (process.env.TARGET_DATE) return [process.env.TARGET_DATE];
  const dates = [hcmDateString(0)];
  if (envFlag('PHOTO_OBJET_INCLUDE_YESTERDAY', false)) {
    dates.push(hcmDateString(-1));
  }
  return [...new Set(dates)];
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

    if (!deviceName || amount <= 0) continue;

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
  const time = String(rawTime || '').trim();
  const match = time.match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?$/);
  if (!match) return null;
  const hh = match[1].padStart(2, '0');
  const mm = match[2];
  const ss = (match[3] || '00').padStart(2, '0');
  return `${targetDate}T${hh}:${mm}:${ss}+07:00`;
}

function normalizeRawSalesRows(rows, store, targetDate, method, pullRunId) {
  return rows
    .map((row, index) => {
      const deviceName = String(row['Device Name'] || '').trim();
      const deviceId = String(row['Device ID'] || '').trim();
      const saleTimeText = String(row['Time'] || '').trim();
      const rawType = String(row['Type'] || '').trim();
      const amount = parseAmount(row['Amount']);

      if (!deviceName || amount <= 0) return null;

      const rawPayload = {
        source: 'moers',
        collector_method: method,
        store_name: store.storeName,
        row_index: index,
        row,
      };
      const hashBasis = stableJson({
        store_id: store.storeId,
        sale_date: targetDate,
        device_id: deviceId,
        device_name: deviceName,
        sale_time_text: saleTimeText,
        amount,
        raw_type: rawType,
        row_index: index,
        row,
      });

      return {
        store_id: store.storeId,
        sale_date: targetDate,
        device_name: deviceName,
        device_id: deviceId || null,
        sale_time_text: saleTimeText || null,
        sold_at: parseSoldAt(targetDate, saleTimeText),
        amount,
        raw_type: rawType || null,
        payment_method: 'CASH',
        buyer_kind: 'anonymous',
        raw_payload: rawPayload,
        source_hash: sha256(hashBasis),
        pull_run_id: pullRunId,
        last_seen_at: new Date().toISOString(),
      };
    })
    .filter(Boolean);
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

  for (let attempt = 0; attempt < 3; attempt += 1) {
    if (attempt > 0) {
      await new Promise(r => setTimeout(r, 1500));
      await page.goto('http://moersinc.com/day.php', {
        waitUntil: 'networkidle2',
        timeout: 30000,
      });
      await page.waitForSelector('#selDate', { timeout: 10000 });
    }

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
    if (!rateLimited) break;
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

  return { method: 'html_scrape', rows };
}

async function startPullRun(store, targetDate) {
  const { data, error } = await supabase
    .from('photo_objet_sales_pull_runs')
    .insert({
      store_id: store.storeId,
      target_date: targetDate,
      status: 'started',
    })
    .select('id')
    .single();

  if (error) throw new Error(`Pull run create failed: ${error.message}`);
  return data.id;
}

async function finishPullRun(runId, patch) {
  if (!runId) return;
  const { error } = await supabase
    .from('photo_objet_sales_pull_runs')
    .update({
      ...patch,
      finished_at: new Date().toISOString(),
    })
    .eq('id', runId);
  if (error) {
    console.error(`  Pull run update failed: ${error.message}`);
  }
}

async function upsertRawSalesRows(rows) {
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
    .upsert(rows, { onConflict: 'source_hash' });
  if (error) {
    throw new Error(`Raw sales upsert failed: ${error.message}`);
  }

  return {
    inserted: rows.filter(row => !existingHashes.has(row.source_hash)).length,
    duplicate: rows.filter(row => existingHashes.has(row.source_hash)).length,
  };
}

async function processStore(store, targetDate, downloadDir) {
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

  const browser = await puppeteer.launch({
    headless: true,
    executablePath: process.env.PUPPETEER_EXECUTABLE_PATH || undefined,
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
  const page = await browser.newPage();
  page.setDefaultTimeout(15000);
  page.setDefaultNavigationTimeout(30000);
  let pullRunId = null;

  try {
    pullRunId = await startPullRun(store, targetDate);
    const { method, rows } = await loginAndGetData(
      page,
      user,
      pass,
      targetDate,
      downloadDir,
    );
    console.log(`  Method: ${method}, ${rows.length} rows`);

    const rawRows = normalizeRawSalesRows(
      rows,
      store,
      targetDate,
      method,
      pullRunId,
    );
    const rawResult = await upsertRawSalesRows(rawRows);
    console.log(
      `  ${storeName}: ${rawResult.inserted} new raw rows, ${rawResult.duplicate} duplicates`,
    );

    const deviceRows = aggregateByDevice(rows);
    console.log(`  ${storeName}: ${deviceRows.length} devices`);

    if (deviceRows.length === 0) {
      console.log(`  ${storeName}: no sales rows for target date`);
      await finishPullRun(pullRunId, {
        collector_method: method,
        status: 'success',
        rows_read: rows.length,
        rows_inserted: rawResult.inserted,
        rows_duplicate: rawResult.duplicate,
        aggregate_rows: 0,
      });
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
      pull_source: 'scheduled',
    }));

    const { error } = await supabase
      .from('photo_objet_sales')
      .upsert(payload, { onConflict: 'store_id,sale_date,device_name' });

    if (error) {
      throw new Error(`Supabase upsert failed: ${error.message}`);
    }

    console.log(`  ✓ ${storeName}: ${payload.length} device rows upserted`);
    await finishPullRun(pullRunId, {
      collector_method: method,
      status: 'success',
      rows_read: rows.length,
      rows_inserted: rawResult.inserted,
      rows_duplicate: rawResult.duplicate,
      aggregate_rows: payload.length,
    });
    return {
      storeName,
      success: true,
      rows: payload.length,
      rawInserted: rawResult.inserted,
      rawDuplicate: rawResult.duplicate,
    };
  } catch (err) {
    console.error(`  ✗ ${storeName}: ${err.message}`);
    await finishPullRun(pullRunId, {
      status: 'failed',
      error_message: err.message,
    });
    return { storeName, success: false, error: err.message };
  } finally {
    await page.close();
    await browser.close();
  }
}

function validateEnv() {
  const missing = [];
  if (!process.env.SUPABASE_URL) missing.push('SUPABASE_URL');
  if (!process.env.SUPABASE_SERVICE_KEY) missing.push('SUPABASE_SERVICE_KEY');

  for (const store of STORES) {
    if (!store.enabled) continue;
    if (!store.user) missing.push(`user for ${store.storeName}`);
    if (!store.pass) missing.push(`password for ${store.storeName}`);
    if (!store.storeId) missing.push(`store_id for ${store.storeName}`);
  }

  if (missing.length > 0) {
    throw new Error(`Missing required environment values: ${missing.join(', ')}`);
  }
}

async function main() {
  validateEnv();

  const targetDates = getTargetDates();
  const enabledStores = STORES.filter(store => store.enabled);
  const skippedStores = STORES.filter(store => !store.enabled);
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
      for (const store of STORES) {
        console.log(`\nProcessing: ${store.storeName} (${targetDate})`);
        const result = await processStore(store, targetDate, downloadDir);
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
      `  ✓ ${r.storeName} ${r.targetDate} (${r.rows} device rows, ${r.rawInserted || 0} new raw, ${r.rawDuplicate || 0} duplicate raw${r.skipped ? ', skipped' : ''})`,
    ),
  );
  if (failed.length > 0) {
    console.log('Failed:');
    failed.forEach(r => console.log(`  ✗ ${r.storeName}: ${r.error}`));
    process.exitCode = 1;
  }
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
