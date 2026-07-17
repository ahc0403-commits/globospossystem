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
  `SMOKE-QA-${new Date().toISOString().replace(/[-:T.Z]/g, '').slice(0, 14)}`;
const endDate = env.SMOKE_END_DATE || new Date().toISOString().slice(0, 10);
const auditDays = Number(env.SMOKE_QC_DAYS || 10);

if (!supabaseUrl || !anonKey) {
  throw new Error('SUPABASE_URL and SUPABASE_ANON_KEY are required.');
}

if (!Number.isInteger(auditDays) || auditDays <= 0) {
  throw new Error('SMOKE_QC_DAYS must be a positive integer.');
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

async function select(table, params) {
  return request('GET', `/rest/v1/${table}?${new URLSearchParams(params)}`);
}

function addDays(dateString, delta) {
  const date = new Date(`${dateString}T00:00:00.000Z`);
  date.setUTCDate(date.getUTCDate() + delta);
  return date.toISOString().slice(0, 10);
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

function asNumber(value) {
  if (typeof value === 'number') return value;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function checksByResult(checks) {
  return checks.reduce((acc, check) => {
    const result = String(check.result || 'unknown');
    acc[result] = (acc[result] || 0) + 1;
    return acc;
  }, {});
}

function resultFor(dayIndex, templateIndex) {
  const mod = (dayIndex * 3 + templateIndex) % 12;
  if (mod === 0 || mod === 7) return 'fail';
  if (mod === 5) return 'na';
  return 'pass';
}

function scoreFor(result, dayIndex, templateIndex) {
  if (result === 'pass') return 90 + ((dayIndex + templateIndex) % 9);
  if (result === 'fail') return 52 + ((dayIndex + templateIndex) % 12);
  return null;
}

async function main() {
  const runStartedAt = new Date().toISOString();
  const startDate = addDays(endDate, 1 - auditDays);
  const dates = Array.from({ length: auditDays }, (_, index) =>
    addDays(endDate, index - (auditDays - 1)),
  );
  const warnings = [];

  console.log(`Smoke run tag: ${runTag}`);
  console.log(`Quality audit date window: ${startDate}..${endDate}`);

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

  const templateSeeds = [
    ['음식 품질 감사', '대표 메뉴 온도와 서빙 온도가 기준 범위 안에 있다.', 'quality', true, 1, 1.2, 'A', true],
    ['음식 품질 감사', '대표 메뉴 맛, 염도, 식감이 표준 레시피와 일치한다.', 'quality', false, 0, 1.2, 'A', false],
    ['플레이팅 감사', '플레이팅, 토핑 위치, 용기 상태가 사진 기준과 일치한다.', 'quality', true, 1, 1.1, 'B', true],
    ['원료 품질 감사', '당일 사용 원료의 유통기한, 라벨, 개봉 상태가 정상이다.', 'quality', true, 1, 1.1, 'B', false],
    ['주방 위생 감사', '조리대, 도마, 칼, 집기류가 교차오염 없이 관리된다.', 'cleanliness', true, 1, 1.0, 'C', true],
    ['보관 온도 감사', '냉장/냉동/상온 보관 온도와 기록이 기준을 충족한다.', 'cleanliness', true, 1, 1.0, 'C', false],
    ['홀 청결 감사', '테이블, 의자, 바닥, 쓰레기통 상태가 오픈 기준을 충족한다.', 'cleanliness', true, 1, 0.9, 'D', false],
    ['서비스 품질 감사', '주문 응대, 안내 멘트, 결제 안내가 표준 프로세스대로 수행된다.', 'service', false, 0, 0.9, 'D', false],
    ['마감 품질 감사', '마감 청소, 폐기 기록, 재고 보관이 체크리스트대로 완료된다.', 'quality', false, 0, 1.0, 'E', true],
    ['안전 감사', '미끄럼, 화상, 전기, 소화기 주변 위험 요소가 즉시 조치되어 있다.', 'cleanliness', true, 1, 1.0, 'E', true],
  ];

  const templates = [];
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
      p_criteria_photo_url: requiresPhoto
        ? `https://example.invalid/${runTag}/criteria/${index + 1}.jpg`
        : null,
      p_sort_order: index + 1,
      p_is_global: false,
      p_qsc_domain: domain,
      p_requires_photo: requiresPhoto,
      p_required_photo_count: photoCount,
      p_weight: weight,
      p_sort_group: sortGroup,
      p_is_sv_required: requiresSv,
    });
    templates.push({
      ...created,
      seed: {
        category,
        criteria,
        domain,
        requiresPhoto,
        photoCount,
        weight,
        sortGroup,
        requiresSv,
      },
    });
  }
  console.log(`Created quality audit criteria: ${templates.length}`);

  const checks = [];
  for (const [dayIndex, checkDate] of dates.entries()) {
    for (const [templateIndex, template] of templates.entries()) {
      const result = resultFor(dayIndex, templateIndex);
      const score = scoreFor(result, dayIndex, templateIndex);
      const grade =
        result === 'pass' ? 'good' : result === 'fail' ? 'risk' : null;
      const photoRequired = template.seed.requiresPhoto;
      const evidencePhotoUrl =
        photoRequired && result !== 'na'
          ? `https://example.invalid/${runTag}/checks/${checkDate}/${template.id}.jpg`
          : null;
      const saved = await upsertQcCheckCompat({
        p_store_id: storeId,
        p_template_id: template.id,
        p_check_date: checkDate,
        p_result: result,
        p_evidence_photo_url: evidencePhotoUrl,
        p_note: `${runTag} ${checkDate} ${result} quality audit smoke`,
        p_checked_by: authUserId,
        p_submitted_at: `${checkDate}T04:30:00.000Z`,
        p_submission_status: 'submitted',
        p_photo_required_count: photoRequired ? template.seed.photoCount : 0,
        p_photo_uploaded_count: evidencePhotoUrl ? template.seed.photoCount : 0,
        p_score: score,
        p_grade: grade,
        p_sv_review_status: template.seed.requiresSv ? 'pending' : 'not_required',
      });
      checks.push(saved);
    }
  }
  console.log(`Created/updated quality audit executions: ${checks.length}`);

  const fetchedTemplates = await rpcStoreCompat('get_qc_templates', {
    p_store_id: storeId,
    p_scope: 'visible',
  });
  const smokeTemplates = fetchedTemplates.filter((template) =>
    String(template.category || '').startsWith(runTag),
  );

  const fetchedChecks = await rpcStoreCompat('get_qc_checks', {
    p_store_id: storeId,
    p_from: startDate,
    p_to: endDate,
  });
  const templateIds = new Set(templates.map((template) => template.id));
  const checkIds = new Set(checks.map((check) => check.id || check.check_id));
  const smokeChecks = fetchedChecks.filter((check) =>
    templateIds.has(check.template_id),
  );
  const smokeFetchedCheckIds = new Set(
    smokeChecks.map((check) => check.check_id || check.id),
  );

  const analyticsRows = await rpcStoreCompat('get_qc_analytics', {
    p_store_id: storeId,
    p_from: startDate,
    p_to: endDate,
  });
  const analytics = Array.isArray(analyticsRows) ? analyticsRows[0] : analyticsRows;

  let issueQueueSmokeFailCount = null;
  try {
    const issues = await select('v_office_qsc_issue_queue', {
      select: 'check_id,store_id,result,category,check_date,severity',
      store_id: `eq.${storeId}`,
    });
    issueQueueSmokeFailCount = issues.filter((issue) =>
      checkIds.has(issue.check_id),
    ).length;
  } catch (error) {
    warnings.push({
      code: 'issue_queue_read_failed',
      message: error.message,
    });
  }

  let auditTraceCount = null;
  try {
    const auditRows = await select('audit_logs', {
      select: 'id,action,entity_type,entity_id,created_at,details',
      created_at: `gte.${runStartedAt}`,
      action: 'in.(qc_template_created,qc_check_upserted)',
      order: 'created_at.desc',
      limit: '300',
    });
    auditTraceCount = auditRows.filter((row) => {
      if (row.action === 'qc_template_created') {
        return templateIds.has(row.entity_id);
      }
      if (row.action === 'qc_check_upserted') {
        return checkIds.has(row.entity_id);
      }
      return false;
    }).length;
  } catch (error) {
    warnings.push({
      code: 'audit_log_read_failed',
      message: error.message,
    });
  }

  const byResult = checksByResult(smokeChecks);
  const expectedRows = templates.length * dates.length;
  const expectedPhotoRows = checks.filter((check) =>
    String(check.evidence_photo_url || '').startsWith(
      `https://example.invalid/${runTag}/checks/`,
    ),
  ).length;
  const fetchedPhotoRows = smokeChecks.filter((check) =>
    String(check.evidence_photo_url || '').startsWith(
      `https://example.invalid/${runTag}/checks/`,
    ),
  ).length;
  const datesCovered = new Set(smokeChecks.map((check) => check.check_date));
  const allCheckedByActor = smokeChecks.every(
    (check) => check.checked_by === authUserId,
  );

  const validations = {
    qualityCriteriaCreated: smokeTemplates.length === 10,
    qualityAuditExecutionsCreated: smokeChecks.length === expectedRows,
    allTenDaysCovered: datesCovered.size === auditDays,
    eachDayHasTenCriteria: dates.every(
      (date) => smokeChecks.filter((check) => check.check_date === date).length === 10,
    ),
    fetchedAllCreatedChecks: checks.every((check) =>
      smokeFetchedCheckIds.has(check.id || check.check_id),
    ),
    checkedByActor: allCheckedByActor,
    evidencePhotoUrlsPersisted: fetchedPhotoRows === expectedPhotoRows,
    resultDistributionHasPass: asNumber(byResult.pass) > 0,
    resultDistributionHasFail: asNumber(byResult.fail) > 0,
    resultDistributionHasNa: asNumber(byResult.na) > 0,
    qcAnalyticsReadable: Boolean(analytics),
    qcAnalyticsIncludesSmokeRows:
      Boolean(analytics) && asNumber(analytics.total_checks) >= smokeChecks.length,
  };
  const failed = Object.entries(validations)
    .filter(([, passed]) => !passed)
    .map(([name]) => name);

  const summary = {
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
    dateWindow: {
      from: startDate,
      to: endDate,
      days: auditDays,
      timezone: 'Asia/Ho_Chi_Minh',
    },
    expected: {
      qualityCriteria: 10,
      auditExecutions: expectedRows,
      dailyCriteriaRuns: 10,
      evidencePhotoRows: expectedPhotoRows,
    },
    actual: {
      qualityCriteria: smokeTemplates.length,
      auditExecutions: smokeChecks.length,
      datesCovered: datesCovered.size,
      byResult,
      evidencePhotoRows: fetchedPhotoRows,
      checkedByActor: allCheckedByActor,
      issueQueueSmokeFailCount,
      auditTraceCount,
      analytics,
    },
    createdTemplateIds: templates.map((template) => template.id),
    createdCheckIds: checks.map((check) => check.id || check.check_id),
    validations,
    failed,
    warnings,
  };

  const outputPath = path.join(
    root,
    'tmp',
    `smoke_quality_audit_${runTag}.json`,
  );
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, `${JSON.stringify(summary, null, 2)}\n`);

  console.log('\nSMOKE_SUMMARY');
  console.log(JSON.stringify(summary, null, 2));
  console.log(`\nWrote summary: ${outputPath}`);

  if (failed.length) {
    throw new Error(`Smoke validations failed: ${failed.join(', ')}`);
  }
}

main().catch((error) => {
  console.error(`SMOKE_FAILED: ${error.message}`);
  process.exit(1);
});
