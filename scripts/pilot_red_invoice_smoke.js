#!/usr/bin/env node

const fs = require('node:fs');
const path = require('node:path');

function loadEnvFile(filePath) {
  if (!fs.existsSync(filePath)) return {};
  const result = {};
  for (const rawLine of fs.readFileSync(filePath, 'utf8').split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#') || !line.includes('=')) continue;
    const index = line.indexOf('=');
    const key = line.slice(0, index).trim();
    let value = line.slice(index + 1).trim();
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
  ...loadEnvFile(path.join(root, '.vercel', '.env.production.local')),
  ...process.env,
};

const args = new Set(process.argv.slice(2));
const execute = args.has('--execute');
const rate = Number(env.PILOT_RED_INVOICE_RATE || '0.10');
const storeId = env.PILOT_RED_INVOICE_STORE_ID || env.SMOKE_STORE_ID;
const email = env.PILOT_RED_INVOICE_USER_EMAIL || 'superadmin@globos.test';
const password = env.PILOT_RED_INVOICE_USER_PASSWORD || 'Globos1234';
const buyerTaxCode = env.PILOT_RED_INVOICE_BUYER_TAX_CODE || '0312345678';
const buyerName =
  env.PILOT_RED_INVOICE_BUYER_NAME || 'GLOBOS PILOT SMOKE BUYER';
const buyerAddress =
  env.PILOT_RED_INVOICE_BUYER_ADDRESS ||
  'Pilot red invoice smoke address';
const receiverEmail =
  env.PILOT_RED_INVOICE_RECEIVER_EMAIL ||
  'pilot-red-invoice-smoke@globos.test';

const supabaseUrl = env.SUPABASE_URL;
const anonKey = env.SUPABASE_ANON_KEY;

if (!supabaseUrl || !anonKey) {
  throw new Error('SUPABASE_URL and SUPABASE_ANON_KEY are required.');
}
if (!storeId) {
  throw new Error('PILOT_RED_INVOICE_STORE_ID or SMOKE_STORE_ID is required.');
}
if (!Number.isFinite(rate) || rate < 0 || rate > 1) {
  throw new Error('PILOT_RED_INVOICE_RATE must be between 0 and 1.');
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
    const message = data?.message || data?.error_description || text;
    throw new Error(`${method} ${urlPath} failed: ${message}`);
  }
  return data;
}

async function rpc(name, params = {}) {
  return request('POST', `/rest/v1/rpc/${name}`, params);
}

async function signIn() {
  const result = await request('POST', '/auth/v1/token?grant_type=password', {
    email,
    password,
  });
  accessToken = result.access_token;
  if (!accessToken) {
    throw new Error('Login did not return an access token.');
  }
}

function buildQuery(params) {
  return Object.entries(params)
    .map(([key, value]) => `${key}=${encodeURIComponent(value)}`)
    .join('&');
}

async function select(table, params) {
  return request('GET', `/rest/v1/${table}?${buildQuery(params)}`);
}

async function loadStoreEinvoiceConfig() {
  const stores = await select('restaurants', {
    select: 'id,name,tax_entity_id,tax_entity(id,tax_code,name)',
    id: `eq.${storeId}`,
    limit: '1',
  });
  const store = stores[0] || null;
  const taxEntity = store?.tax_entity || null;
  const shops = taxEntity
    ? await select('einvoice_shop', {
        select: 'id,provider_shop_code,shop_name,templates',
        tax_entity_id: `eq.${taxEntity.id}`,
      })
    : [];

  const activeShopCount = shops.filter((shop) =>
    (Array.isArray(shop.templates) ? shop.templates : []).some(
      (template) => String(template.status_code) === '1',
    ),
  ).length;

  return {
    store_id: store?.id || storeId,
    store_name: store?.name || null,
    tax_entity_id: store?.tax_entity_id || null,
    tax_code: taxEntity?.tax_code || null,
    is_placeholder_tax_entity: taxEntity?.tax_code === 'PLACEHOLDER_DEV_000',
    einvoice_shop_count: shops.length,
    active_einvoice_shop_count: activeShopCount,
  };
}

async function loadCardPayPayments() {
  const payments = await select('payments', {
    select:
      'id,order_id,restaurant_id,amount,method,is_revenue,created_at,orders(id,status,created_at)',
    restaurant_id: `eq.${storeId}`,
    is_revenue: 'eq.true',
    method: 'in.(CREDITCARD,OTHER)',
    order: 'created_at.asc',
  });

  const orderIds = payments.map((payment) => payment.order_id).filter(Boolean);
  if (orderIds.length === 0) {
    return {
      all: payments,
      withJobs: [],
      withoutJobs: payments,
    };
  }

  const jobs = await select('einvoice_jobs', {
    select: 'id,order_id,redinvoice_requested,status,created_at',
    order_id: `in.(${orderIds.join(',')})`,
    order: 'created_at.desc',
  });
  const latestJobByOrder = new Map();
  for (const job of jobs) {
    if (!latestJobByOrder.has(job.order_id)) {
      latestJobByOrder.set(job.order_id, job);
    }
  }

  const withJob = [];
  const withoutJob = [];
  for (const payment of payments) {
    const einvoiceJob = latestJobByOrder.get(payment.order_id) || null;
    if (einvoiceJob) {
      withJob.push({ ...payment, einvoice_job: einvoiceJob });
    } else {
      withoutJob.push(payment);
    }
  }

  return {
    all: payments,
    withJobs: withJob,
    withoutJobs: withoutJob,
  };
}

function choosePaymentsForSmoke(eligiblePayments) {
  const alreadyRequested = eligiblePayments.filter(
    (payment) => payment.einvoice_job.redinvoice_requested,
  );
  const targetCount = Math.ceil(eligiblePayments.length * rate);
  const needed = Math.max(0, targetCount - alreadyRequested.length);
  const candidates = eligiblePayments.filter(
    (payment) => !payment.einvoice_job.redinvoice_requested,
  );

  return {
    targetCount,
    alreadyRequestedCount: alreadyRequested.length,
    neededCount: needed,
    candidates,
    selected: candidates.slice(0, needed),
  };
}

async function requestRedInvoiceFor(payment) {
  return rpc('request_red_invoice', {
    p_order_id: payment.order_id,
    p_store_id: storeId,
    p_buyer_tax_code: buyerTaxCode,
    p_buyer_name: buyerName,
    p_buyer_address: buyerAddress,
    p_receiver_email: receiverEmail,
    p_receiver_email_cc: null,
    p_buyer_tel: null,
  });
}

(async () => {
  await signIn();

  const storeConfig = await loadStoreEinvoiceConfig();
  const cardPayPayments = await loadCardPayPayments();
  const selection = choosePaymentsForSmoke(cardPayPayments.withJobs);
  const requested = [];
  const failed = [];

  if (execute) {
    for (const payment of selection.selected) {
      try {
        const result = await requestRedInvoiceFor(payment);
        requested.push({
          payment_id: payment.id,
          order_id: payment.order_id,
          method: payment.method,
          amount: payment.amount,
          result,
        });
      } catch (error) {
        failed.push({
          payment_id: payment.id,
          order_id: payment.order_id,
          method: payment.method,
          amount: payment.amount,
          error: error.message,
        });
      }
    }
  }

  const report = {
    mode: execute ? 'execute' : 'dry-run',
    store_id: storeId,
    rate,
    store_einvoice_config: storeConfig,
    card_pay_revenue_payments: cardPayPayments.all.length,
    payments_with_einvoice_job: cardPayPayments.withJobs.length,
    skipped_without_einvoice_job: cardPayPayments.withoutJobs.length,
    target_red_invoice_count: selection.targetCount,
    already_requested_count: selection.alreadyRequestedCount,
    needed_count: selection.neededCount,
    selected_count: selection.selected.length,
    selected: selection.selected.map((payment) => ({
      payment_id: payment.id,
      order_id: payment.order_id,
      method: payment.method,
      amount: payment.amount,
      einvoice_job_id: payment.einvoice_job.id,
      einvoice_job_status: payment.einvoice_job.status,
    })),
    requested,
    failed,
  };

  console.log(JSON.stringify(report, null, 2));

  if (failed.length > 0) {
    process.exitCode = 1;
  }
})().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
