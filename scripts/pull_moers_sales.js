const puppeteer = require('puppeteer');
const { createClient } = require('@supabase/supabase-js');
const fs = require('fs');
const path = require('path');

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
    const rows = [];
    let headers = null;
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
      if (headers === null) {
        headers = cells;
      } else {
        const row = {};
        headers.forEach((h, i) => {
          row[h] = cells[i] !== undefined ? cells[i] : '';
        });
        rows.push(row);
      }
    }
    return { headers: headers || [], rows };
  }

  const tablePattern = /<table[\s\S]*?<\/table>/gi;
  let tMatch;
  while ((tMatch = tablePattern.exec(body)) !== null) {
    const { headers, rows } = parseOneTable(tMatch[0]);
    if (
      headers.some(
        h => h === 'Device Name' || h.toLowerCase().includes('device name'),
      )
    ) {
      return rows;
    }
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
    user: process.env.MOERS_D7_USER,
    pass: process.env.MOERS_D7_PASS,
    storeId: process.env.PHOTO_OBJET_D7_STORE_ID,
  },
  {
    storeName: 'BIEN HOA',
    user: process.env.MOERS_BIENHOA_USER,
    pass: process.env.MOERS_BIENHOA_PASS,
    storeId: process.env.PHOTO_OBJET_BIENHOA_STORE_ID,
  },
  {
    storeName: 'DI AN',
    user: process.env.MOERS_DIAN_USER,
    pass: process.env.MOERS_DIAN_PASS,
    storeId: process.env.PHOTO_OBJET_DIAN_STORE_ID,
  },
  {
    storeName: 'LONG THANH',
    user: process.env.MOERS_LONGTHANH_USER,
    pass: process.env.MOERS_LONGTHANH_PASS,
    storeId: process.env.PHOTO_OBJET_LONGTHANH_STORE_ID,
  },
  {
    storeName: 'THAO DIEN',
    user: process.env.MOERS_THAODIEN_USER,
    pass: process.env.MOERS_THAODIEN_PASS,
    storeId: process.env.PHOTO_OBJET_THAODIEN_STORE_ID,
  },
  {
    storeName: 'QUANG TRUNG',
    user: process.env.MOERS_QUANGTRUNG_USER,
    pass: process.env.MOERS_QUANGTRUNG_PASS,
    storeId: process.env.PHOTO_OBJET_QUANGTRUNG_STORE_ID,
  },
  {
    storeName: 'NOW ZONE',
    user: process.env.MOERS_NOWZONE_USER,
    pass: process.env.MOERS_NOWZONE_PASS,
    storeId: process.env.PHOTO_OBJET_NOWZONE_STORE_ID,
  },
];

function getTargetDate() {
  if (process.env.TARGET_DATE) return process.env.TARGET_DATE;
  const d = new Date();
  d.setDate(d.getDate() - 1);
  return d.toISOString().split('T')[0];
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
    const type = String(row['Type'] || '').trim();

    if (!deviceName) continue;

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

    if (type === 'Cash') {
      devices[deviceName].gross_sales += amount;
      devices[deviceName].transaction_count += 1;
    } else {
      devices[deviceName].service_amount += amount;
      devices[deviceName].service_count += 1;
    }

    devices[deviceName].raw_rows.push(row);
  }

  return Object.values(devices);
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
    page.waitForNavigation({ waitUntil: 'networkidle2', timeout: 20000 }),
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

  await page.$eval(
    '#selDate',
    (el, date) => {
      el.value = date;
      el.dispatchEvent(new Event('change', { bubbles: true }));
      el.dispatchEvent(new Event('input', { bubbles: true }));
    },
    targetDate,
  );
  await new Promise(r => setTimeout(r, 2000));

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
        const htmlContent = fs.readFileSync(
          path.join(downloadDir, files[0]),
          'utf8',
        );
        return { method: 'excel', rows: parseHtmlXlsTable(htmlContent) };
      }
    }
    throw new Error('Download timeout — no Excel file appeared after 30s');
  }

  await page.evaluate(() => {
    const submitBtn = document.querySelector(
      'form button[type=submit], form input[type=submit]',
    );
    if (submitBtn) {
      submitBtn.click();
    } else {
      const form = document.querySelector('form');
      if (form) form.submit();
    }
  });
  await page
    .waitForNavigation({ waitUntil: 'networkidle2', timeout: 15000 })
    .catch(() => {});
  await new Promise(r => setTimeout(r, 1000));

  const rows = await page.evaluate(() => {
    const table = document.querySelectorAll('table')[1] || document.querySelector('table');
    if (!table) return [];
    const headerRow = table.querySelector('tr');
    if (!headerRow) return [];
    const headers = Array.from(headerRow.querySelectorAll('th, td')).map(el =>
      el.innerText.trim(),
    );
    const dataRows = Array.from(table.querySelectorAll('tr')).slice(1);
    return dataRows
      .map(row => {
        const cells = Array.from(row.querySelectorAll('td')).map(el =>
          el.innerText.trim(),
        );
        if (cells.length === 0) return null;
        const obj = {};
        headers.forEach((h, i) => {
          obj[h] = cells[i] || '';
        });
        return obj;
      })
      .filter(Boolean);
  });

  return { method: 'html_scrape', rows };
}

async function processStore(browser, store, targetDate, downloadDir) {
  const { storeName, user, pass, storeId } = store;

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

  const context = await browser.createBrowserContext();
  const page = await context.newPage();

  try {
    const { method, rows } = await loginAndGetData(
      page,
      user,
      pass,
      targetDate,
      downloadDir,
    );
    console.log(`  Method: ${method}, ${rows.length} rows`);

    const deviceRows = aggregateByDevice(rows);
    console.log(`  ${storeName}: ${deviceRows.length} devices`);

    if (deviceRows.length === 0) {
      console.log(`  ${storeName}: no sales rows for target date`);
      return { storeName, success: true, rows: 0 };
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
      pull_source: 'scheduled',
    }));

    const { error } = await supabase
      .from('photo_objet_sales')
      .upsert(payload, { onConflict: 'store_id,sale_date,device_name' });

    if (error) {
      throw new Error(`Supabase upsert failed: ${error.message}`);
    }

    console.log(`  ✓ ${storeName}: ${payload.length} device rows upserted`);
    return { storeName, success: true, rows: payload.length };
  } catch (err) {
    console.error(`  ✗ ${storeName}: ${err.message}`);
    return { storeName, success: false, error: err.message };
  } finally {
    await page.close();
    await context.close();
  }
}

function validateEnv() {
  const missing = [];
  if (!process.env.SUPABASE_URL) missing.push('SUPABASE_URL');
  if (!process.env.SUPABASE_SERVICE_KEY) missing.push('SUPABASE_SERVICE_KEY');

  for (const store of STORES) {
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

  const targetDate = getTargetDate();
  console.log('\n=== Photo Objet Sales Pull ===');
  console.log(`Target date: ${targetDate}`);
  console.log(`Started at: ${new Date().toISOString()}\n`);

  const downloadDir = path.join(__dirname, 'downloads_tmp');
  fs.mkdirSync(downloadDir, { recursive: true });

  const browser = await puppeteer.launch({
    headless: true,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--single-process',
    ],
  });

  const results = [];

  try {
    for (const store of STORES) {
      console.log(`\nProcessing: ${store.storeName}`);
      const result = await processStore(browser, store, targetDate, downloadDir);
      results.push(result);
    }
  } finally {
    await browser.close();
    try {
      fs.rmSync(downloadDir, { recursive: true, force: true });
    } catch {}
  }

  console.log('\n=== Summary ===');
  const success = results.filter(r => r.success);
  const failed = results.filter(r => !r.success);
  console.log(`Success: ${success.length}/${results.length}`);
  success.forEach(r =>
    console.log(`  ✓ ${r.storeName} (${r.rows} device rows)`),
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
