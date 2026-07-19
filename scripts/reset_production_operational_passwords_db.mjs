#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import pg from "pg";

const { Client } = pg;
const POS_PROJECT_REF = "ynriuoomotxuwhuxxmhj";
const POS_PROJECT_URL = `https://${POS_PROJECT_REF}.supabase.co`;
const CONFIRMATION = "RESET_GLOBOS_PROD_OPERATIONAL_PASSWORDS";
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

export function parseConfig(env) {
  const url = (env.POS_SUPABASE_URL || "").replace(/\/+$/, "");
  if (url !== POS_PROJECT_URL) {
    fail(`POS_PROJECT_GUARD_FAILED:${POS_PROJECT_REF}`);
  }
  if (env.CONFIRM_PRODUCTION_PASSWORD_RESET !== CONFIRMATION) {
    fail("EXPLICIT_PRODUCTION_PASSWORD_RESET_CONFIRMATION_REQUIRED");
  }
  const publishableKey = env.POS_SUPABASE_ANON_KEY || "";
  if (
    !publishableKey.startsWith("sb_publishable_") || publishableKey.length < 32
  ) {
    fail("POS_PUBLISHABLE_KEY_REQUIRED");
  }
  const password = env.POS_INITIAL_PASSWORD || "";
  if (password.length < 8) fail("INITIAL_PASSWORD_MINIMUM_8_CHARACTERS");
  if (/\s/.test(password)) fail("INITIAL_PASSWORD_WHITESPACE_FORBIDDEN");
  const expectedCreatedDate = env.POS_EXPECTED_CREATED_DATE_VN || "";
  if (!/^\d{4}-\d{2}-\d{2}$/.test(expectedCreatedDate)) {
    fail("EXPECTED_CREATED_DATE_VN_REQUIRED");
  }
  const host = env.PGHOST || "";
  const port = Number(env.PGPORT || 0);
  const user = env.PGUSER || "";
  const database = env.PGDATABASE || "";
  const dbPassword = env.PGPASSWORD || "";
  const directHost = `db.${POS_PROJECT_REF}.supabase.co`;
  const poolerHost = /^[a-z0-9-]+\.pooler\.supabase\.com$/;
  if (host === directHost) {
    if (
      port !== 5432 || !(user === "postgres" || user.startsWith("cli_login_"))
    ) {
      fail("POS_DIRECT_DATABASE_CREDENTIAL_INVALID");
    }
  } else if (poolerHost.test(host)) {
    if (port !== 5432 || !user.includes(POS_PROJECT_REF)) {
      fail("POS_POOLER_DATABASE_CREDENTIAL_INVALID");
    }
  } else {
    fail("POS_DATABASE_HOST_INVALID");
  }
  if (database !== "postgres" || !dbPassword) {
    fail("POS_DATABASE_CREDENTIAL_INVALID");
  }
  return {
    url,
    publishableKey,
    password,
    expectedCreatedDate,
    accountsFile: path.resolve(
      env.POS_OPERATIONAL_ACCOUNTS_FILE ||
        "docs/pos/pos_required_production_auth_emails.txt",
    ),
    preflightOnly: env.POS_PREFLIGHT_ONLY === "1",
    pg: { host, port, user, password: dbPassword, database },
  };
}

function sortedStrings(value) {
  if (!Array.isArray(value)) return [];
  return value.map(String).sort();
}

function sameStrings(left, right) {
  return JSON.stringify(sortedStrings(left)) ===
    JSON.stringify(sortedStrings(right));
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonical(value[key])]),
    );
  }
  return value;
}

export function assertPasswordLifecycleTransition(email, beforeState, afterState) {
  const beforeStable = { ...beforeState };
  const afterStable = { ...afterState };
  delete beforeStable.passwordLifecycle;
  delete afterStable.passwordLifecycle;
  if (JSON.stringify(beforeStable) !== JSON.stringify(afterStable)) {
    fail(`OPERATIONAL_STATE_CHANGED:${email}`);
  }
  if (
    afterState.passwordLifecycle.mustChangePassword !== true ||
    !afterState.passwordLifecycle.requiredAt ||
    afterState.passwordLifecycle.generation <=
      beforeState.passwordLifecycle.generation
  ) {
    fail(`PASSWORD_CHANGE_GATE_NOT_REARMED:${email}`);
  }
}

export function loginProfileMatchesExpected(profile, expected) {
  return profile.is_active === true &&
    profile.role === expected.profile.role &&
    profile.fixed_account_code === expected.profile.fixed_account_code &&
    profile.must_change_password === true &&
    Boolean(profile.password_change_required_at) &&
    Number(profile.password_change_generation) >=
      expected.passwordLifecycle.generation;
}

async function fetchOperationalState(
  client,
  approvedEmails,
  expectedCreatedDate,
) {
  const authResult = await client.query(
    `select
       id::text as id,
       lower(email) as email,
       to_char(created_at at time zone 'Asia/Ho_Chi_Minh', 'YYYY-MM-DD') as created_date_vn,
       email_confirmed_at is not null as confirmed,
       (banned_until is null or banned_until <= now()) as login_enabled,
       coalesce(raw_app_meta_data, '{}'::jsonb) as app_metadata
     from auth.users
     where lower(email) = any($1::text[])
     order by lower(email)`,
    [approvedEmails],
  );
  const authByEmail = new Map();
  for (const row of authResult.rows) {
    const matches = authByEmail.get(row.email) || [];
    matches.push(row);
    authByEmail.set(row.email, matches);
  }
  const authRows = approvedEmails.map((email) => {
    const matches = authByEmail.get(email) || [];
    if (matches.length === 0) fail(`APPROVED_AUTH_MISSING:${email}`);
    if (matches.length !== 1) fail(`APPROVED_AUTH_DUPLICATE:${email}`);
    const row = matches[0];
    if (!row.confirmed) fail(`APPROVED_AUTH_UNCONFIRMED:${email}`);
    if (!row.login_enabled) fail(`APPROVED_AUTH_BANNED:${email}`);
    if (row.created_date_vn !== expectedCreatedDate) {
      fail(`APPROVED_AUTH_CREATED_DATE_MISMATCH:${email}`);
    }
    return row;
  });

  const authIds = authRows.map((row) => row.id);
  const profileResult = await client.query(
    `select
       id::text as id,
       auth_id::text as auth_id,
       role::text as role,
       restaurant_id::text as restaurant_id,
       primary_store_id::text as primary_store_id,
       account_type,
       fixed_account_code,
       is_active,
       must_change_password,
       password_change_required_at,
       password_changed_at,
       password_change_generation::text as password_change_generation
     from public.users
     where auth_id = any($1::uuid[])`,
    [authIds],
  );
  const profilesByAuth = new Map();
  for (const profile of profileResult.rows) {
    const matches = profilesByAuth.get(profile.auth_id) || [];
    matches.push(profile);
    profilesByAuth.set(profile.auth_id, matches);
  }
  const profiles = authRows.map((authRow) => {
    const email = authRow.email;
    const matches = profilesByAuth.get(authRow.id) || [];
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

  const profileIds = profiles.map((profile) => profile.id);
  const accessResult = await client.query(
    `select user_id::text as user_id, store_id::text as store_id, is_primary
     from public.user_store_access
     where user_id = any($1::uuid[]) and is_active = true`,
    [profileIds],
  );
  const storeIds = [...new Set(accessResult.rows.map((row) => row.store_id))];
  const storeResult = await client.query(
    `select id::text as id from public.restaurants
     where id = any($1::uuid[]) and is_active = true`,
    [storeIds],
  );
  const activeStoreIds = new Set(storeResult.rows.map((row) => row.id));

  const state = new Map();
  authRows.forEach((authRow, index) => {
    const email = authRow.email;
    const profile = profiles[index];
    const accessIds = [
      ...new Set(
        accessResult.rows
          .filter((row) => row.user_id === profile.id)
          .map((row) => row.store_id),
      ),
    ];
    const claimIds = sortedStrings(authRow.app_metadata?.accessible_store_ids);
    if (accessIds.length === 0) fail(`ACTIVE_STORE_ACCESS_MISSING:${email}`);
    if (accessIds.some((storeId) => !activeStoreIds.has(storeId))) {
      fail(`INACTIVE_STORE_ACCESS_FORBIDDEN:${email}`);
    }
    if (!sameStrings(accessIds, claimIds)) {
      fail(`STORE_CLAIMS_MISMATCH:${email}`);
    }
    if (authRow.app_metadata?.role !== profile.role) {
      fail(`ROLE_CLAIM_MISMATCH:${email}`);
    }
    const stableProfile = { ...profile };
    delete stableProfile.must_change_password;
    delete stableProfile.password_change_required_at;
    delete stableProfile.password_changed_at;
    delete stableProfile.password_change_generation;
    state.set(email, {
      authId: authRow.id,
      appMetadata: canonical(authRow.app_metadata),
      profile: canonical(stableProfile),
      passwordLifecycle: {
        mustChangePassword: profile.must_change_password === true,
        requiredAt: profile.password_change_required_at,
        changedAt: profile.password_changed_at,
        generation: Number(profile.password_change_generation),
      },
      accessIds: sortedStrings(accessIds),
    });
  });
  return state;
}

async function verifyLogin(config, email, expected) {
  const loginResponse = await fetch(
    `${config.url}/auth/v1/token?grant_type=password`,
    {
      method: "POST",
      headers: {
        apikey: config.publishableKey,
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ email, password: config.password }),
    },
  );
  if (!loginResponse.ok) {
    fail(`LOGIN_VERIFY_FAILED:${email}:HTTP_${loginResponse.status}`);
  }
  const login = await loginResponse.json();
  if (!login.user || login.user.id !== expected.authId || !login.access_token) {
    fail(`LOGIN_IDENTITY_MISMATCH:${email}`);
  }
  if (
    !sameStrings(
      login.user.app_metadata?.accessible_store_ids,
      expected.accessIds,
    )
  ) {
    fail(`LOGIN_STORE_CLAIMS_MISMATCH:${email}`);
  }

  const profileUrl = new URL("/rest/v1/users", config.url);
  profileUrl.searchParams.set(
    "select",
    "role,restaurant_id,is_active,account_type,fixed_account_code,must_change_password,password_change_required_at,password_change_generation",
  );
  profileUrl.searchParams.set("auth_id", `eq.${login.user.id}`);
  profileUrl.searchParams.set("limit", "1");
  const profileResponse = await fetch(profileUrl, {
    headers: {
      apikey: config.publishableKey,
      Authorization: `Bearer ${login.access_token}`,
      Accept: "application/json",
    },
  });
  if (!profileResponse.ok) {
    fail(`LOGIN_PROFILE_VERIFY_FAILED:${email}:HTTP_${profileResponse.status}`);
  }
  const profiles = await profileResponse.json();
  if (
    !Array.isArray(profiles) ||
    profiles.length !== 1 ||
    !loginProfileMatchesExpected(profiles[0], expected)
  ) {
    fail(`LOGIN_PROFILE_MISMATCH:${email}`);
  }

  const logoutResponse = await fetch(
    `${config.url}/auth/v1/logout?scope=local`,
    {
      method: "POST",
      headers: {
        apikey: config.publishableKey,
        Authorization: `Bearer ${login.access_token}`,
      },
    },
  );
  if (!logoutResponse.ok) fail(`LOGIN_SESSION_CLEANUP_FAILED:${email}`);
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function main() {
  const config = parseConfig(process.env);
  const approvedEmails = parseApprovedEmailText(
    fs.readFileSync(config.accountsFile, "utf8"),
  );
  const client = new Client({
    ...config.pg,
    ssl: { rejectUnauthorized: false },
    application_name: "globos_pos_operational_password_reset",
  });
  let committed = false;
  await client.connect();
  try {
    await client.query("begin");
    await client.query("set role postgres");
    await client.query("set local statement_timeout = '30s'");
    await client.query("set local lock_timeout = '5s'");
    const passwordCapability = await client.query(
      "select crypt($1, gen_salt('bf', 10)) is not null as available",
      ["password-capability-probe"],
    );
    if (passwordCapability.rows[0]?.available !== true) {
      fail("PASSWORD_HASH_CAPABILITY_MISSING");
    }
    const before = await fetchOperationalState(
      client,
      approvedEmails,
      config.expectedCreatedDate,
    );
    console.log(
      `Preflight passed: ${approvedEmails.length} approved operational accounts only.`,
    );
    if (config.preflightOnly) {
      await client.query("rollback");
      console.log(
        `PASS: ${approvedEmails.length} operational accounts verified; preflight-only mode changed no passwords.`,
      );
      return;
    }

    const updated = await client.query(
      `update auth.users
       set encrypted_password = crypt($1, gen_salt('bf', 10)),
           updated_at = now()
       where lower(email) = any($2::text[])
       returning lower(email) as email`,
      [config.password, approvedEmails],
    );
    const updatedEmails = updated.rows.map((row) => row.email).sort();
    if (!sameStrings(updatedEmails, approvedEmails)) {
      fail("PASSWORD_UPDATE_TARGET_SET_MISMATCH");
    }
    const passwordCheck = await client.query(
      `select count(*)::int as matched
       from auth.users
       where lower(email) = any($2::text[])
         and encrypted_password = crypt($1, encrypted_password)`,
      [config.password, approvedEmails],
    );
    if (passwordCheck.rows[0]?.matched !== approvedEmails.length) {
      fail("PASSWORD_HASH_VERIFY_FAILED");
    }
    const rearmed = await client.query(
      `update public.users profile
       set must_change_password = true,
           password_change_required_at = coalesce(
             profile.password_change_required_at,
             clock_timestamp()
           )
       from auth.users identity
       where identity.id = profile.auth_id
         and lower(identity.email) = any($1::text[])
       returning lower(identity.email) as email`,
      [approvedEmails],
    );
    const rearmedEmails = rearmed.rows.map((row) => row.email).sort();
    if (!sameStrings(rearmedEmails, approvedEmails)) {
      fail("PASSWORD_CHANGE_GATE_TARGET_SET_MISMATCH");
    }
    const after = await fetchOperationalState(
      client,
      approvedEmails,
      config.expectedCreatedDate,
    );
    for (const email of approvedEmails) {
      assertPasswordLifecycleTransition(
        email,
        before.get(email),
        after.get(email),
      );
    }
    await client.query("commit");
    committed = true;
    console.log(
      `Password transaction committed: ${approvedEmails.length} accounts.`,
    );

    for (const email of approvedEmails) {
      await verifyLogin(config, email, after.get(email));
      console.log(`Login verified and session closed: ${email}`);
      await sleep(500);
    }
    console.log(
      `PASS: ${approvedEmails.length} operational passwords reset; all logins and scopes verified.`,
    );
  } catch (error) {
    if (!committed) await client.query("rollback").catch(() => {});
    throw error;
  } finally {
    await client.end();
  }
}

const invokedPath = process.argv[1] ? fs.realpathSync(process.argv[1]) : "";
if (fs.realpathSync(fileURLToPath(import.meta.url)) === invokedPath) {
  main().catch((error) => {
    console.error(
      error instanceof Error ? error.message : "PASSWORD_RESET_FAILED",
    );
    process.exit(1);
  });
}
