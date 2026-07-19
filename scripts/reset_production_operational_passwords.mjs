#!/usr/bin/env -S deno run --allow-env --allow-read --allow-net

import path from "node:path";

const POS_PROJECT_REF = "ynriuoomotxuwhuxxmhj";
const POS_PROJECT_URL = `https://${POS_PROJECT_REF}.supabase.co`;
const CONFIRMATION = "RESET_GLOBOS_PROD_OPERATIONAL_PASSWORDS";
const TIME_ZONE = "Asia/Ho_Chi_Minh";
const SUPPORTED_ROLES = new Set([
  "super_admin",
  "brand_admin",
  "store_admin",
  "admin",
  "waiter",
  "kitchen",
  "cashier",
  "photo_objet_master",
  "photo_objet_store_admin",
  "photo_objet_store_operator",
]);

function fail(message) {
  throw new Error(message);
}

export function parseApprovedEmailText(text) {
  const emails = text
    .split(/\r?\n/)
    .map((line) => line.replace(/#.*/, "").trim().toLowerCase())
    .filter(Boolean);
  if (emails.length === 0) fail("APPROVED_OPERATIONAL_ACCOUNT_LIST_EMPTY");
  if (new Set(emails).size !== emails.length) {
    fail("APPROVED_OPERATIONAL_ACCOUNT_LIST_HAS_DUPLICATES");
  }
  for (const email of emails) {
    if (!/^[a-z0-9._%+-]+@globos\.world$/.test(email)) {
      fail(`NON_OPERATIONAL_EMAIL_FORBIDDEN:${email}`);
    }
  }
  return emails;
}

export function dateInTimeZone(value, timeZone = TIME_ZONE) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) fail("INVALID_AUTH_CREATED_AT");
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    })
      .formatToParts(date)
      .filter((part) => part.type !== "literal")
      .map((part) => [part.type, part.value]),
  );
  return `${parts.year}-${parts.month}-${parts.day}`;
}

function isLoginEnabled(user, now = new Date()) {
  if (!user.banned_until) return true;
  const bannedUntil = new Date(user.banned_until);
  return !Number.isNaN(bannedUntil.getTime()) && bannedUntil <= now;
}

export function selectOperationalUsers(
  allUsers,
  approvedEmails,
  expectedCreatedDate,
) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(expectedCreatedDate)) {
    fail("EXPECTED_CREATED_DATE_VN_REQUIRED");
  }
  const byEmail = new Map();
  for (const user of allUsers) {
    const email = (user.email || "").trim().toLowerCase();
    if (!approvedEmails.includes(email)) continue;
    const matches = byEmail.get(email) || [];
    matches.push(user);
    byEmail.set(email, matches);
  }

  const selected = [];
  for (const email of approvedEmails) {
    const matches = byEmail.get(email) || [];
    if (matches.length === 0) fail(`APPROVED_AUTH_MISSING:${email}`);
    if (matches.length !== 1) fail(`APPROVED_AUTH_DUPLICATE:${email}`);
    const user = matches[0];
    if (!user.email_confirmed_at) fail(`APPROVED_AUTH_UNCONFIRMED:${email}`);
    if (!isLoginEnabled(user)) fail(`APPROVED_AUTH_BANNED:${email}`);
    if (dateInTimeZone(user.created_at) !== expectedCreatedDate) {
      fail(`APPROVED_AUTH_CREATED_DATE_MISMATCH:${email}`);
    }
    selected.push(user);
  }
  return selected;
}

function sortedStrings(value) {
  if (!Array.isArray(value)) return [];
  return value.map(String).sort();
}

function sameStrings(left, right) {
  return JSON.stringify(sortedStrings(left)) ===
    JSON.stringify(sortedStrings(right));
}

function canonicalJson(value) {
  if (Array.isArray(value)) return value.map(canonicalJson);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, canonicalJson(value[key])]),
    );
  }
  return value;
}

export function parseConfig(env) {
  const url = (env.POS_SUPABASE_URL || "").replace(/\/+$/, "");
  if (url !== POS_PROJECT_URL) {
    fail(`POS_PROJECT_GUARD_FAILED:${POS_PROJECT_REF}`);
  }
  if (env.CONFIRM_PRODUCTION_PASSWORD_RESET !== CONFIRMATION) {
    fail("EXPLICIT_PRODUCTION_PASSWORD_RESET_CONFIRMATION_REQUIRED");
  }
  if ((env.POS_SUPABASE_SERVICE_ROLE_KEY || "").length < 32) {
    fail("POS_SERVICE_ROLE_KEY_REQUIRED");
  }
  if ((env.POS_SUPABASE_ANON_KEY || "").length < 32) {
    fail("POS_ANON_KEY_REQUIRED");
  }
  const password = env.POS_INITIAL_PASSWORD || "";
  if (password.length < 8) fail("INITIAL_PASSWORD_MINIMUM_8_CHARACTERS");
  if (/\s/.test(password)) fail("INITIAL_PASSWORD_WHITESPACE_FORBIDDEN");
  const expectedCreatedDate = env.POS_EXPECTED_CREATED_DATE_VN || "";
  if (!/^\d{4}-\d{2}-\d{2}$/.test(expectedCreatedDate)) {
    fail("EXPECTED_CREATED_DATE_VN_REQUIRED");
  }
  const accountsFile = path.resolve(
    env.POS_OPERATIONAL_ACCOUNTS_FILE ||
      "docs/pos/pos_required_production_auth_emails.txt",
  );
  return {
    url,
    serviceRoleKey: env.POS_SUPABASE_SERVICE_ROLE_KEY,
    anonKey: env.POS_SUPABASE_ANON_KEY,
    password,
    preflightOnly: env.POS_PREFLIGHT_ONLY === "1",
    expectedCreatedDate,
    accountsFile,
  };
}

function readConfigEnvironment() {
  const names = [
    "POS_SUPABASE_URL",
    "POS_SUPABASE_SERVICE_ROLE_KEY",
    "POS_SUPABASE_ANON_KEY",
    "POS_INITIAL_PASSWORD",
    "POS_EXPECTED_CREATED_DATE_VN",
    "POS_OPERATIONAL_ACCOUNTS_FILE",
    "POS_PREFLIGHT_ONLY",
    "CONFIRM_PRODUCTION_PASSWORD_RESET",
  ];
  return Object.fromEntries(names.map((name) => [name, Deno.env.get(name)]));
}

function apiHeaders(key) {
  return {
    apikey: key,
    Authorization: `Bearer ${key}`,
    Accept: "application/json",
    "Content-Type": "application/json",
  };
}

async function requestJson(url, key, options, errorCode) {
  const response = await fetch(url, {
    ...options,
    headers: {
      ...apiHeaders(key),
      ...(options.headers || {}),
    },
  });
  if (!response.ok) fail(`${errorCode}:HTTP_${response.status}`);
  try {
    return await response.json();
  } catch (_) {
    fail(`${errorCode}:INVALID_JSON`);
  }
}

function restUrl(config, table, params) {
  const url = new URL(`/rest/v1/${table}`, config.url);
  for (const [key, value] of Object.entries(params)) {
    url.searchParams.set(key, value);
  }
  return url;
}

async function restSelect(config, table, params, errorCode) {
  const data = await requestJson(
    restUrl(config, table, params),
    config.serviceRoleKey,
    { method: "GET" },
    errorCode,
  );
  if (!Array.isArray(data)) fail(`${errorCode}:EXPECTED_ARRAY`);
  return data;
}

async function fetchAllAuthUsers(config) {
  const users = [];
  for (let page = 1; page <= 100; page += 1) {
    const url = new URL("/auth/v1/admin/users", config.url);
    url.searchParams.set("page", String(page));
    url.searchParams.set("per_page", "1000");
    const data = await requestJson(
      url,
      config.serviceRoleKey,
      { method: "GET" },
      "AUTH_LIST_FAILED",
    );
    if (!Array.isArray(data.users)) {
      fail("AUTH_LIST_FAILED:EXPECTED_USERS_ARRAY");
    }
    users.push(...data.users);
    if (data.users.length < 1000) return users;
  }
  fail("AUTH_LIST_PAGE_LIMIT_EXCEEDED");
}

async function fetchOperationalState(config, users) {
  const authIds = users.map((user) => user.id);
  const profiles = await restSelect(
    config,
    "users",
    {
      select:
        "id,auth_id,role,restaurant_id,primary_store_id,account_type,fixed_account_code,is_active",
      auth_id: `in.(${authIds.join(",")})`,
    },
    "PROFILE_LOOKUP_FAILED",
  );

  const profilesByAuth = new Map();
  for (const profile of profiles) {
    const matches = profilesByAuth.get(profile.auth_id) || [];
    matches.push(profile);
    profilesByAuth.set(profile.auth_id, matches);
  }

  const orderedProfiles = users.map((user) => {
    const email = user.email.toLowerCase();
    const matches = profilesByAuth.get(user.id) || [];
    if (matches.length !== 1) fail(`PROFILE_CARDINALITY_INVALID:${email}`);
    const profile = matches[0];
    if (profile.is_active !== true) fail(`PROFILE_INACTIVE:${email}`);
    if (!SUPPORTED_ROLES.has(profile.role)) {
      fail(`PROFILE_ROLE_INVALID:${email}`);
    }
    if (profile.fixed_account_code !== email.split("@")[0]) {
      fail(`FIXED_ACCOUNT_CODE_MISMATCH:${email}`);
    }
    if (!profile.primary_store_id) fail(`PRIMARY_STORE_MISSING:${email}`);
    return profile;
  });

  const profileIds = orderedProfiles.map((profile) => profile.id);
  const access = await restSelect(
    config,
    "user_store_access",
    {
      select: "user_id,store_id,is_primary,is_active",
      user_id: `in.(${profileIds.join(",")})`,
      is_active: "eq.true",
    },
    "STORE_ACCESS_LOOKUP_FAILED",
  );

  const storeIds = [...new Set(access.map((row) => row.store_id))];
  const stores = await restSelect(
    config,
    "restaurants",
    {
      select: "id,is_active",
      id: `in.(${storeIds.join(",")})`,
    },
    "STORE_LOOKUP_FAILED",
  );
  const activeStoreIds = new Set(
    stores.filter((store) => store.is_active === true).map((store) => store.id),
  );

  const state = new Map();
  users.forEach((user, index) => {
    const email = user.email.toLowerCase();
    const profile = orderedProfiles[index];
    const accessIds = access
      .filter((row) => row.user_id === profile.id)
      .map((row) => row.store_id);
    const claimIds = sortedStrings(user.app_metadata?.accessible_store_ids);
    if (accessIds.length === 0) fail(`ACTIVE_STORE_ACCESS_MISSING:${email}`);
    if (accessIds.some((storeId) => !activeStoreIds.has(storeId))) {
      fail(`INACTIVE_STORE_ACCESS_FORBIDDEN:${email}`);
    }
    if (!sameStrings(accessIds, claimIds)) {
      fail(`STORE_CLAIMS_MISMATCH:${email}`);
    }
    if (user.app_metadata?.role !== profile.role) {
      fail(`ROLE_CLAIM_MISMATCH:${email}`);
    }
    if (user.app_metadata?.fixed_account_code !== profile.fixed_account_code) {
      fail(`FIXED_CODE_CLAIM_MISMATCH:${email}`);
    }
    state.set(email, {
      authId: user.id,
      appMetadata: JSON.stringify(canonicalJson(user.app_metadata || {})),
      profile: JSON.stringify(profile),
      accessIds: JSON.stringify(sortedStrings(accessIds)),
    });
  });
  return state;
}

async function verifyPasswordLogin(config, user, expectedState) {
  const email = user.email.toLowerCase();
  const data = await requestJson(
    `${config.url}/auth/v1/token?grant_type=password`,
    config.anonKey,
    {
      method: "POST",
      body: JSON.stringify({ email, password: config.password }),
    },
    `LOGIN_VERIFY_FAILED:${email}`,
  );
  if (!data.user) fail(`LOGIN_VERIFY_FAILED:${email}:USER_MISSING`);
  if (data.user.id !== expectedState.authId) {
    fail(`LOGIN_AUTH_ID_MISMATCH:${email}`);
  }
  if (
    !sameStrings(
      data.user.app_metadata?.accessible_store_ids,
      JSON.parse(expectedState.accessIds),
    )
  ) {
    fail(`LOGIN_STORE_CLAIMS_MISMATCH:${email}`);
  }
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function main() {
  const config = parseConfig(readConfigEnvironment());
  const approvedEmails = parseApprovedEmailText(
    Deno.readTextFileSync(config.accountsFile),
  );

  const allUsers = await fetchAllAuthUsers(config);
  const selectedUsers = selectOperationalUsers(
    allUsers,
    approvedEmails,
    config.expectedCreatedDate,
  );
  const beforeState = await fetchOperationalState(config, selectedUsers);
  console.log(
    `Preflight passed: ${selectedUsers.length} approved operational accounts only.`,
  );
  if (config.preflightOnly) {
    console.log(
      `PASS: ${selectedUsers.length} operational accounts verified; preflight-only mode changed no passwords.`,
    );
    return;
  }

  const failures = [];
  for (const user of selectedUsers) {
    const email = user.email.toLowerCase();
    try {
      await requestJson(
        `${config.url}/auth/v1/admin/users/${user.id}`,
        config.serviceRoleKey,
        {
          method: "PUT",
          body: JSON.stringify({ password: config.password }),
        },
        `PASSWORD_RESET_FAILED:${email}`,
      );
      console.log(`Password reset: ${email}`);
    } catch (_) {
      failures.push(email);
      console.error(`PASSWORD_RESET_FAILED:${email}`);
    }
    await sleep(250);
  }
  if (failures.length > 0) {
    fail(`PASSWORD_RESET_PARTIAL_FAILURE_COUNT:${failures.length}`);
  }

  const refreshedUsers = selectOperationalUsers(
    await fetchAllAuthUsers(config),
    approvedEmails,
    config.expectedCreatedDate,
  );
  const afterState = await fetchOperationalState(config, refreshedUsers);
  for (const user of refreshedUsers) {
    const email = user.email.toLowerCase();
    const before = beforeState.get(email);
    const after = afterState.get(email);
    if (!before || !after || JSON.stringify(before) !== JSON.stringify(after)) {
      fail(`OPERATIONAL_STATE_CHANGED:${email}`);
    }
    await verifyPasswordLogin(config, user, before);
    console.log(`Login verified: ${email}`);
    await sleep(500);
  }

  console.log(
    `PASS: ${refreshedUsers.length} operational passwords reset; all logins and scopes verified.`,
  );
}

if (import.meta.main) {
  main().catch((error) => {
    console.error(
      error instanceof Error ? error.message : "PASSWORD_RESET_FAILED",
    );
    Deno.exit(1);
  });
}
