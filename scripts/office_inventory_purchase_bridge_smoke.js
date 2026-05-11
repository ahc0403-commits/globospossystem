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
loadEnvFile(
  process.env.OFFICE_ENV_FILE ||
    '/Users/andreahn/Documents/restaurant_office_app/.env.local',
);

const officeUrl = process.env.OFFICE_SUPABASE_URL;
const officeAnonKey =
  process.env.OFFICE_PUBLISHABLE_KEY || process.env.OFFICE_SUPABASE_ANON_KEY;
const email = process.env.SMOKE_OFFICE_EMAIL || 'super@globos.vn';
const password = process.env.SMOKE_OFFICE_PASSWORD || 'Test1234!';

if (!officeUrl || !officeAnonKey) {
  throw new Error(
    'OFFICE_SUPABASE_URL and OFFICE_PUBLISHABLE_KEY are required.',
  );
}

async function request(pathname, options = {}) {
  const response = await fetch(`${officeUrl}${pathname}`, {
    ...options,
    headers: {
      apikey: officeAnonKey,
      Authorization: `Bearer ${options.token || officeAnonKey}`,
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

async function bridge(token, payload) {
  return request('/functions/v1/pos-bridge', {
    method: 'POST',
    token,
    body: JSON.stringify(payload),
  });
}

function assertOk(label, result) {
  if (result.status < 200 || result.status >= 300) {
    throw new Error(
      `${label} failed: ${result.status} ${JSON.stringify(result.body)}`,
    );
  }
}

(async () => {
  const login = await request('/auth/v1/token?grant_type=password', {
    method: 'POST',
    body: JSON.stringify({ email, password }),
  });
  assertOk('office login', login);
  const token = login.body.access_token;
  if (!token) throw new Error('office login did not return access_token');

  const config = await bridge(token, { action: 'config_status' });
  assertOk('pos-bridge config_status', config);

  const orders = await bridge(token, { action: 'inventory_purchase_orders' });
  assertOk('pos-bridge inventory_purchase_orders', orders);
  if (!Array.isArray(orders.body) || orders.body.length === 0) {
    throw new Error('Expected Office bridge to return purchase order rows.');
  }

  const firstOrder = orders.body[0];
  const detail = await bridge(token, {
    action: 'inventory_purchase_detail',
    orderId: firstOrder.id,
  });
  assertOk('pos-bridge inventory_purchase_detail', detail);
  if (!Array.isArray(detail.body.lines) || detail.body.lines.length === 0) {
    throw new Error('Expected Office bridge detail to include order lines.');
  }

  console.log(
    JSON.stringify(
      {
        account: email,
        bridgeConfigured: config.body.configured === true,
        purchaseOrderRows: orders.body.length,
        firstOrderNo: firstOrder.purchase_order_no ?? null,
        firstStatus: firstOrder.status ?? null,
        firstSupplier: firstOrder.supplier_name ?? null,
        detailLineCount: detail.body.lines.length,
      },
      null,
      2,
    ),
  );
})().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
