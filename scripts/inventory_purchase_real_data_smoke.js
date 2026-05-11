#!/usr/bin/env node

const fs = require('node:fs');
const path = require('node:path');

function loadEnvFile(filePath) {
  if (!fs.existsSync(filePath)) return;
  for (const line of fs.readFileSync(filePath, 'utf8').split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#') || !trimmed.includes('=')) {
      continue;
    }
    const index = trimmed.indexOf('=');
    const key = trimmed.slice(0, index).trim();
    const value = trimmed.slice(index + 1).trim().replace(/^['"]|['"]$/g, '');
    if (!process.env[key]) process.env[key] = value;
  }
}

loadEnvFile(path.resolve(process.cwd(), '.env.local'));
loadEnvFile(path.resolve(process.cwd(), '.env'));

const supabaseUrl = process.env.SUPABASE_URL;
const anonKey = process.env.SUPABASE_ANON_KEY;
const email = process.env.SMOKE_USER_EMAIL || 'admin@globos.test';
const password = process.env.SMOKE_USER_PASSWORD || 'Globos1234';
const shouldCreate = process.argv.includes('--create');

if (!supabaseUrl || !anonKey) {
  throw new Error('SUPABASE_URL and SUPABASE_ANON_KEY are required.');
}

async function request(pathname, options = {}) {
  const response = await fetch(`${supabaseUrl}${pathname}`, {
    ...options,
    headers: {
      apikey: anonKey,
      Authorization: `Bearer ${options.token || anonKey}`,
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
      ...(options.headers || {}),
    },
  });
  const text = await response.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch (_) {
    body = text;
  }
  return { status: response.status, body };
}

async function rpc(token, functionName, params) {
  return request(`/rest/v1/rpc/${functionName}`, {
    method: 'POST',
    token,
    body: JSON.stringify(params),
  });
}

function assertOk(label, result) {
  if (result.status < 200 || result.status >= 300) {
    throw new Error(`${label} failed: ${result.status} ${JSON.stringify(result.body)}`);
  }
}

(async () => {
  const login = await request('/auth/v1/token?grant_type=password', {
    method: 'POST',
    body: JSON.stringify({ email, password }),
  });
  assertOk('login', login);
  const token = login.body.access_token;
  if (!token) throw new Error('login did not return access_token');

  const store = await rpc(token, 'get_user_store_id', {});
  assertOk('get_user_store_id', store);
  const storeId = store.body;

  const cost = await rpc(token, 'get_inventory_cost_analysis', {
    p_store_id: storeId,
  });
  assertOk('get_inventory_cost_analysis', cost);

  let orders = await rpc(token, 'office_get_inventory_purchase_orders', {
    p_brand_id: null,
    p_store_id: storeId,
    p_status: null,
  });
  assertOk('office_get_inventory_purchase_orders', orders);

  if (shouldCreate && Array.isArray(orders.body) && orders.body.length === 0) {
    const run = await rpc(token, 'run_inventory_purchase_recommendation', {
      p_store_id: storeId,
      p_target_stock_days: 30,
    });
    assertOk('run_inventory_purchase_recommendation', run);
    const created = await rpc(token, 'create_purchase_orders_from_recommendation', {
      p_run_id: run.body,
    });
    assertOk('create_purchase_orders_from_recommendation', created);
    orders = await rpc(token, 'office_get_inventory_purchase_orders', {
      p_brand_id: null,
      p_store_id: storeId,
      p_status: null,
    });
    assertOk('office_get_inventory_purchase_orders after create', orders);
  }

  const tables = await request(
    `/rest/v1/tables?select=id,restaurant_id,table_number,status,seat_count,created_at,updated_at&restaurant_id=eq.${storeId}&order=table_number.asc`,
    { token },
  );
  assertOk('legacy table list', tables);

  const report = {
    storeId,
    costRows: Array.isArray(cost.body) ? cost.body.length : null,
    purchaseOrderRows: Array.isArray(orders.body) ? orders.body.length : null,
    firstPurchaseOrder: Array.isArray(orders.body)
      ? orders.body[0]?.purchase_order_no ?? null
      : null,
    tableRows: Array.isArray(tables.body) ? tables.body.length : null,
    firstTable: Array.isArray(tables.body) ? tables.body[0]?.table_number ?? null : null,
  };

  if (!report.costRows) throw new Error('Expected cost analysis rows.');
  if (!report.purchaseOrderRows) throw new Error('Expected purchase order rows.');
  if (!report.tableRows) throw new Error('Expected table rows.');

  console.log(JSON.stringify(report, null, 2));
})().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
