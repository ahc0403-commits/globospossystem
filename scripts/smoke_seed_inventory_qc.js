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
  `SMOKE-${new Date().toISOString().replace(/[-:T.Z]/g, '').slice(0, 14)}`;
const endDate = env.SMOKE_END_DATE || new Date().toISOString().slice(0, 10);

if (!supabaseUrl || !anonKey) {
  throw new Error('SUPABASE_URL and SUPABASE_ANON_KEY are required.');
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
  const data = text ? JSON.parse(text) : null;
  if (!response.ok) {
    const message = data?.message || data?.error_description || text;
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
  return /Could not find the function public\./.test(error.message);
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

async function rpcWithFallbacks(name, params, fallbacks) {
  let lastError;
  for (const attempt of [params, ...fallbacks]) {
    try {
      return await rpc(name, attempt);
    } catch (error) {
      lastError = error;
      if (!looksLikeSignatureMiss(error)) throw error;
    }
  }
  throw lastError;
}

async function select(table, query) {
  return request('GET', `/rest/v1/${table}?${query}`);
}

function addDays(dateString, delta) {
  const date = new Date(`${dateString}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + delta);
  return date.toISOString().slice(0, 10);
}

function asNumber(value) {
  if (typeof value === 'number') return value;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function stripQscTemplateParams(params) {
  const {
    p_qsc_domain,
    p_requires_photo,
    p_required_photo_count,
    p_weight,
    p_sort_group,
    p_is_sv_required,
    ...legacy
  } = params;
  return legacy;
}

function stripQscCheckParams(params) {
  const {
    p_submitted_at,
    p_submission_status,
    p_photo_required_count,
    p_photo_uploaded_count,
    p_score,
    p_grade,
    p_sv_review_status,
    p_sv_reviewed_by,
    p_sv_reviewed_at,
    p_sv_score,
    p_sv_note,
    p_visit_session_id,
    ...legacy
  } = params;
  return legacy;
}

async function createQcTemplateCompat(params) {
  const legacy = stripQscTemplateParams(params);
  return rpcWithFallbacks('create_qc_template', params, [
    legacy,
    legacyStoreParams(params),
    legacyStoreParams(legacy),
  ]);
}

async function upsertQcCheckCompat(params) {
  const legacy = stripQscCheckParams(params);
  return rpcWithFallbacks('upsert_qc_check', params, [
    legacy,
    legacyStoreParams(params),
    legacyStoreParams(legacy),
  ]);
}

function recipeFor(menuName, index, ingredientByKey) {
  const lower = menuName.toLowerCase();
  const pick = (...keys) => keys.map((key) => ingredientByKey.get(key));
  if (lower.includes('bingsu') || lower.includes('빙수')) {
    return [
      ['redBean', 85],
      ['milkPowder', 45],
      ['riceCake', 35],
      ['mango', 55],
    ];
  }
  if (lower.includes('hotteok') || lower.includes('호떡')) {
    return [
      ['flour', 95],
      ['brownSugar', 35],
      ['peanut', 22],
      ['cinnamon', 4],
    ];
  }
  if (lower.includes('coffee') || lower.includes('커피')) {
    return [
      ['coffeeBean', 18],
      ['milkPowder', 25],
      ['brownSugar', 8],
      ['cocoa', 5],
    ];
  }
  if (lower.includes('tea') || lower.includes('차')) {
    return [
      ['teaLeaf', 12],
      ['honey', 15],
      ['lemon', 18],
      ['ginger', 4],
    ];
  }
  if (lower.includes('chicken') || lower.includes('치킨')) {
    return [
      ['chicken', 160],
      ['flour', 35],
      ['garlic', 8],
      ['pepper', 3],
    ];
  }
  if (lower.includes('beef') || lower.includes('소고기')) {
    return [
      ['beef', 150],
      ['onion', 35],
      ['garlic', 7],
      ['sesame', 4],
    ];
  }
  if (lower.includes('pork') || lower.includes('돼지')) {
    return [
      ['pork', 155],
      ['kimchi', 45],
      ['garlic', 7],
      ['pepper', 3],
    ];
  }
  if (lower.includes('rice') || lower.includes('밥')) {
    return [
      ['rice', 180],
      ['egg', 55],
      ['carrot', 30],
      ['onion', 30],
    ];
  }

  const pools = [
    pick('rice', 'egg', 'onion', 'sesame'),
    pick('noodle', 'beef', 'garlic', 'pepper'),
    pick('chicken', 'flour', 'cabbage', 'carrot'),
    pick('pork', 'kimchi', 'onion', 'garlic'),
    pick('tofu', 'mushroom', 'sesame', 'greenOnion'),
  ];
  const quantities = [
    [120, 60, 25, 4],
    [130, 95, 8, 3],
    [145, 35, 40, 30],
    [150, 45, 28, 7],
    [120, 55, 9, 18],
  ];
  return pools[index % pools.length].map((ingredient, i) => [
    ingredient.key,
    quantities[index % quantities.length][i],
  ]);
}

async function main() {
  console.log(`Smoke run tag: ${runTag}`);
  console.log(`QC date window: ${addDays(endDate, -4)}..${endDate}`);

  const login = await request(
    'POST',
    '/auth/v1/token?grant_type=password',
    { email, password },
    { Authorization: `Bearer ${anonKey}` },
  );
  accessToken = login.access_token;
  const authUserId = login.user.id;

  const profiles = await select(
    'users',
    `select=id,auth_id,role,restaurant_id,is_active&auth_id=eq.${authUserId}`,
  );
  if (!Array.isArray(profiles) || profiles.length !== 1) {
    throw new Error(`Expected one POS user profile for ${email}.`);
  }
  const profile = profiles[0];
  const storeId = profile.restaurant_id;
  if (!storeId) throw new Error('Profile does not have restaurant_id/store_id.');

  const storeRows = await select(
    'restaurants',
    `select=id,name&${new URLSearchParams({ id: `eq.${storeId}` })}`,
  );
  const storeName = storeRows[0]?.name || storeId;
  console.log(`Actor: ${email} (${profile.role})`);
  console.log(`Store: ${storeName} (${storeId})`);

  const ingredientSeeds = [
    ['rice', '쌀'],
    ['flour', '밀가루'],
    ['brownSugar', '흑설탕'],
    ['cinnamon', '계피가루'],
    ['peanut', '땅콩분태'],
    ['redBean', '팥앙금'],
    ['milkPowder', '우유분말'],
    ['riceCake', '떡'],
    ['mango', '망고'],
    ['coffeeBean', '커피원두'],
    ['cocoa', '코코아파우더'],
    ['teaLeaf', '찻잎'],
    ['honey', '꿀파우더'],
    ['lemon', '레몬분말'],
    ['ginger', '생강분말'],
    ['chicken', '닭고기'],
    ['beef', '소고기'],
    ['pork', '돼지고기'],
    ['egg', '계란분말'],
    ['onion', '양파'],
    ['garlic', '마늘'],
    ['pepper', '후추'],
    ['sesame', '참깨'],
    ['kimchi', '김치'],
    ['carrot', '당근'],
    ['cabbage', '양배추'],
    ['noodle', '면'],
    ['tofu', '두부'],
    ['mushroom', '버섯'],
    ['greenOnion', '대파'],
  ];

  const ingredients = [];
  for (const [index, [key, label]] of ingredientSeeds.entries()) {
    const created = await rpcStoreCompat('create_inventory_item', {
      p_store_id: storeId,
      p_name: `${runTag} ${label}`,
      p_unit: 'g',
      p_current_stock: 9000 + index * 175,
      p_reorder_point: 1800 + (index % 6) * 120,
      p_cost_per_unit: 18 + (index % 10) * 2.75,
      p_supplier_name: `${runTag} 테스트 공급사 ${Math.floor(index / 5) + 1}`,
    });
    ingredients.push({ ...created, key, label });
  }

  const ingredientByKey = new Map(ingredients.map((item) => [item.key, item]));
  console.log(`Created ingredients: ${ingredients.length}`);

  const menuItems = await select(
    'menu_items',
    `select=id,name,price,sort_order&restaurant_id=eq.${storeId}&is_available=eq.true&order=sort_order.asc`,
  );
  if (!menuItems.length) {
    throw new Error('No available menu_items found for recipe smoke.');
  }

  let recipeLines = 0;
  for (const [menuIndex, menu] of menuItems.entries()) {
    for (const [ingredientKey, quantity] of recipeFor(
      menu.name,
      menuIndex,
      ingredientByKey,
    )) {
      const ingredient = ingredientByKey.get(ingredientKey);
      if (!ingredient) throw new Error(`Missing seed ingredient ${ingredientKey}`);
      await rpcStoreCompat('upsert_inventory_recipe_line', {
        p_store_id: storeId,
        p_menu_item_id: menu.id,
        p_ingredient_id: ingredient.id,
        p_quantity_g: quantity,
      });
      recipeLines += 1;
    }
  }
  console.log(`Available menu items mapped: ${menuItems.length}`);
  console.log(`Recipe lines upserted: ${recipeLines}`);

  const templates = [];
  const templateSeeds = [
    ['음식 품질', '완성 메뉴 온도와 플레이팅 기준을 충족했다.', 'quality', true, 1, 1.2, 'A', true],
    ['음식 품질', '주요 메뉴 맛 밸런스와 염도 기준을 충족했다.', 'quality', false, 0, 1.1, 'A', false],
    ['주방 위생', '작업대와 조리 도구가 교차오염 없이 관리되었다.', 'cleanliness', true, 1, 1.0, 'B', true],
    ['주방 위생', '냉장/냉동 보관 상태와 라벨링이 기준을 충족했다.', 'cleanliness', true, 1, 1.0, 'B', false],
    ['서비스', '주문 응대와 테이블 안내가 표준 멘트대로 진행되었다.', 'service', false, 0, 0.9, 'C', false],
    ['서비스', '결제 안내와 영수증 전달이 누락 없이 처리되었다.', 'service', false, 0, 0.9, 'C', false],
    ['매장 청결', '홀 바닥, 테이블, 의자 청결 상태가 기준을 충족했다.', 'cleanliness', true, 1, 1.0, 'D', true],
    ['매장 청결', '화장실과 손 세정 비품 상태가 정상이다.', 'cleanliness', true, 1, 1.0, 'D', false],
    ['운영 준비', '오픈 전 필수 재고와 소모품 준비가 완료되었다.', 'quality', false, 0, 1.0, 'E', false],
    ['운영 마감', '마감 체크와 폐기/실사 기록이 누락 없이 완료되었다.', 'quality', false, 0, 1.0, 'E', true],
  ];

  for (const [index, seed] of templateSeeds.entries()) {
    const [
      category,
      criteria,
      domain,
      requiresPhoto,
      photoCount,
      weight,
      sortGroup,
      requiresSv,
    ] = seed;
    const created = await createQcTemplateCompat({
      p_store_id: storeId,
      p_category: `${runTag} ${category}`,
      p_criteria_text: criteria,
      p_criteria_photo_url: null,
      p_sort_order: index + 1,
      p_is_global: false,
      p_qsc_domain: domain,
      p_requires_photo: requiresPhoto,
      p_required_photo_count: photoCount,
      p_weight: weight,
      p_sort_group: sortGroup,
      p_is_sv_required: requiresSv,
    });
    templates.push(created);
  }
  console.log(`Created QC templates: ${templates.length}`);

  const checks = [];
  const dates = Array.from({ length: 5 }, (_, i) => addDays(endDate, i - 4));
  for (const [dayIndex, checkDate] of dates.entries()) {
    for (const [templateIndex, template] of templates.entries()) {
      const mod = (dayIndex + templateIndex) % 10;
      const result = mod === 0 ? 'fail' : mod === 5 ? 'na' : 'pass';
      const score =
        result === 'pass'
          ? 91 + ((dayIndex + templateIndex) % 8)
          : result === 'fail'
            ? 58 + ((dayIndex + templateIndex) % 10)
            : null;
      const grade =
        result === 'pass' ? 'good' : result === 'fail' ? 'risk' : null;
      const saved = await upsertQcCheckCompat({
        p_store_id: storeId,
        p_template_id: template.id,
        p_check_date: checkDate,
        p_result: result,
        p_evidence_photo_url:
          template.requires_photo && result !== 'fail'
            ? `https://example.invalid/${runTag}/${template.id}/${checkDate}.jpg`
            : null,
        p_note: `${runTag} ${checkDate} ${result} smoke record`,
        p_checked_by: authUserId,
        p_submitted_at: `${checkDate}T04:30:00.000Z`,
        p_submission_status: 'submitted',
        p_photo_required_count: template.requires_photo
          ? template.required_photo_count || 1
          : 0,
        p_photo_uploaded_count:
          template.requires_photo && result !== 'fail'
            ? template.required_photo_count || 1
            : 0,
        p_score: score,
        p_grade: grade,
        p_sv_review_status: template.is_sv_required ? 'pending' : 'not_required',
      });
      checks.push(saved);
    }
  }
  console.log(`Created/updated QC checks: ${checks.length}`);

  const failedChecks = checks.filter((check) => check.result === 'fail');
  const followups = [];
  for (const failed of failedChecks.slice(0, 2)) {
    const followup = await rpcStoreCompat('create_qc_followup', {
      p_store_id: storeId,
      p_source_check_id: failed.id,
      p_assigned_to_name: `${runTag} 담당자`,
    });
    followups.push(followup);
  }
  console.log(`Created QC followups: ${followups.length}`);

  const stockBefore = new Map(
    (await rpcStoreCompat('get_inventory_ingredient_catalog', { p_store_id: storeId }))
      .filter((item) => String(item.name).startsWith(runTag))
      .map((item) => [item.id, asNumber(item.current_stock)]),
  );

  const table = await rpcStoreCompat('admin_create_table', {
    p_store_id: storeId,
    p_table_number: `${runTag}-T`,
    p_seat_count: 2,
  });
  const orderItems = menuItems.slice(0, Math.min(menuItems.length, 2)).map(
    (item, index) => ({
      menu_item_id: item.id,
      quantity: index === 0 ? 2 : 1,
    }),
  );
  const orderTotal = orderItems.reduce((sum, item) => {
    const menu = menuItems.find((candidate) => candidate.id === item.menu_item_id);
    return sum + asNumber(menu?.price) * item.quantity;
  }, 0);
  const order = await rpcStoreCompat('create_order', {
    p_store_id: storeId,
    p_table_id: table.id,
    p_items: orderItems,
  });
  const firstPayment = await rpcStoreCompat('process_payment', {
    p_order_id: order.id,
    p_store_id: storeId,
    p_amount: orderTotal,
    p_method: 'SERVICE',
  });
  let payments = [firstPayment];

  const paymentLineItems = await select(
    'order_items',
    `select=id,status,paying_amount_inc_tax,unit_price,quantity&${new URLSearchParams({
      order_id: `eq.${order.id}`,
    })}`,
  );
  const paymentRows = await select(
    'payments',
    `select=id,amount,amount_portion,method,is_revenue&${new URLSearchParams({
      order_id: `eq.${order.id}`,
    })}`,
  );
  const vatInclusiveTotal = paymentLineItems
    .filter((item) => item.status !== 'cancelled')
    .reduce(
      (sum, item) =>
        sum +
        (item.paying_amount_inc_tax == null
          ? asNumber(item.unit_price) * asNumber(item.quantity)
          : asNumber(item.paying_amount_inc_tax)),
      0,
    );
  const paidTotal = paymentRows.reduce(
    (sum, paymentRow) => sum + asNumber(paymentRow.amount_portion),
    0,
  );
  const remainingPayment = Number((vatInclusiveTotal - paidTotal).toFixed(2));
  if (remainingPayment > 0.01) {
    const topUpPayment = await rpcStoreCompat('process_payment', {
      p_order_id: order.id,
      p_store_id: storeId,
      p_amount: remainingPayment,
      p_method: 'SERVICE',
    });
    payments = [...paymentRows, topUpPayment];
  } else {
    payments = paymentRows;
  }

  const smokeRecipes = await rpcStoreCompat('get_inventory_recipe_catalog', {
    p_store_id: storeId,
    p_menu_item_id: null,
  });
  const expectedDeduct = new Map();
  for (const item of orderItems) {
    const lines = smokeRecipes.filter(
      (line) =>
        line.menu_item_id === item.menu_item_id &&
        stockBefore.has(line.ingredient_id),
    );
    for (const line of lines) {
      expectedDeduct.set(
        line.ingredient_id,
        (expectedDeduct.get(line.ingredient_id) || 0) +
          asNumber(line.quantity_g) * item.quantity,
      );
    }
  }

  const stockAfter = new Map(
    (await rpcStoreCompat('get_inventory_ingredient_catalog', { p_store_id: storeId }))
      .filter((item) => String(item.name).startsWith(runTag))
      .map((item) => [item.id, asNumber(item.current_stock)]),
  );
  const deductionMismatches = [];
  for (const [ingredientId, expected] of expectedDeduct.entries()) {
    const before = stockBefore.get(ingredientId);
    const after = stockAfter.get(ingredientId);
    const actual = Number((before - after).toFixed(3));
    if (Math.abs(actual - expected) > 0.001) {
      deductionMismatches.push({ ingredientId, expected, actual });
    }
  }
  console.log(`Inventory deduction ingredients checked: ${expectedDeduct.size}`);

  const transactionFrom = `${endDate}T00:00:00.000Z`;
  const transactionTo = `${addDays(endDate, 1)}T23:59:59.000Z`;
  const transactions = await rpcStoreCompat('get_inventory_transaction_visibility', {
    p_store_id: storeId,
    p_from: transactionFrom,
    p_to: transactionTo,
  });
  const smokeTransactions = transactions.filter((row) =>
    stockBefore.has(row.ingredient_id),
  );

  const fetchedTemplates = await rpcStoreCompat('get_qc_templates', {
    p_store_id: storeId,
    p_scope: 'visible',
  });
  const smokeTemplates = fetchedTemplates.filter((template) =>
    String(template.category).startsWith(runTag),
  );
  const fetchedChecks = await rpcStoreCompat('get_qc_checks', {
    p_store_id: storeId,
    p_from: dates[0],
    p_to: dates[dates.length - 1],
  });
  const smokeTemplateIds = new Set(templates.map((template) => template.id));
  const smokeChecks = fetchedChecks.filter((check) =>
    smokeTemplateIds.has(check.template_id),
  );
  const analyticsRows = await rpcStoreCompat('get_qc_analytics', {
    p_store_id: storeId,
    p_from: dates[0],
    p_to: dates[dates.length - 1],
  });
  const analytics = Array.isArray(analyticsRows) ? analyticsRows[0] : analyticsRows;

  let issueQueueCount = null;
  try {
    const issues = await select(
      'v_office_qsc_issue_queue',
      `select=check_id,store_id,result,category&store_id=eq.${storeId}`,
    );
    issueQueueCount = issues.filter((issue) =>
      failedChecks.some((check) => check.id === issue.check_id),
    ).length;
  } catch (error) {
    issueQueueCount = `read_failed: ${error.message}`;
  }

  const ingredientReadback = await rpcStoreCompat('get_inventory_ingredient_catalog', {
    p_store_id: storeId,
  });
  const smokeIngredients = ingredientReadback.filter((item) =>
    String(item.name).startsWith(runTag),
  );
  const readbackRecipes = smokeRecipes.filter((line) =>
    stockAfter.has(line.ingredient_id),
  );
  const menusWithSmokeRecipe = new Set(readbackRecipes.map((line) => line.menu_item_id));

  const checksByResult = smokeChecks.reduce((acc, check) => {
    acc[check.result] = (acc[check.result] || 0) + 1;
    return acc;
  }, {});

  const validations = {
    ingredientsCreated: smokeIngredients.length === 30,
    recipesMappedForEveryMenu: menusWithSmokeRecipe.size === menuItems.length,
    recipeLineCount: readbackRecipes.length >= menuItems.length * 4,
    qcTemplatesCreated: smokeTemplates.length === 10,
    qcChecksCreated: smokeChecks.length === 50,
    qcFollowupsCreated: followups.length === 2,
    serviceOrderCompleted: payments.length > 0 && Boolean(order?.id && table?.id),
    inventoryDeductionMatched: deductionMismatches.length === 0,
    inventoryTransactionsVisible: smokeTransactions.length >= expectedDeduct.size,
    qcAnalyticsReadable: Boolean(analytics),
  };

  const summary = {
    runTag,
    storeId,
    storeName,
    actorEmail: email,
    dateWindow: { from: dates[0], to: dates[dates.length - 1] },
    menuItemCount: menuItems.length,
    ingredientCount: smokeIngredients.length,
    recipeLineCount: readbackRecipes.length,
    menusWithSmokeRecipe: menusWithSmokeRecipe.size,
    qcTemplateCount: smokeTemplates.length,
    qcCheckCount: smokeChecks.length,
    qcChecksByResult: checksByResult,
    qcFollowupCount: followups.length,
    issueQueueSmokeFailCount: issueQueueCount,
    orderSmoke: {
      tableId: table.id,
      orderId: order.id,
      paymentIds: payments.map((paymentRow) => paymentRow.id),
      amount: payments.reduce(
        (sum, paymentRow) =>
          sum + asNumber(paymentRow.amount_portion ?? paymentRow.amount),
        0,
      ),
      methodInput: 'SERVICE',
      storedMethods: [
        ...new Set(payments.map((paymentRow) => paymentRow.method)),
      ],
      revenuePaymentCount: payments.filter(
        (paymentRow) => paymentRow.is_revenue === true,
      ).length,
    },
    inventoryDeduction: {
      checkedIngredientCount: expectedDeduct.size,
      mismatches: deductionMismatches,
      visibleSmokeTransactionCount: smokeTransactions.length,
    },
    qcAnalytics: analytics,
    validations,
  };

  const outputPath = path.join(
    root,
    'tmp',
    `smoke_inventory_qc_${runTag}.json`,
  );
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, JSON.stringify(summary, null, 2));

  console.log('\nSMOKE_SUMMARY');
  console.log(JSON.stringify(summary, null, 2));
  console.log(`\nWrote summary: ${outputPath}`);

  const failedValidations = Object.entries(validations)
    .filter(([, passed]) => !passed)
    .map(([name]) => name);
  if (failedValidations.length) {
    throw new Error(`Smoke validations failed: ${failedValidations.join(', ')}`);
  }
}

main().catch((error) => {
  console.error(`SMOKE_FAILED: ${error.message}`);
  process.exit(1);
});
