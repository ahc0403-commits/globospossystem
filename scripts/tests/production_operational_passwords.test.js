const assert = require("node:assert/strict");
const test = require("node:test");
const passwordResetModule = import(
  "../reset_production_operational_passwords_db.mjs"
);

const validEnvironment = {
  POS_SUPABASE_URL: "https://ynriuoomotxuwhuxxmhj.supabase.co",
  POS_SUPABASE_ANON_KEY: `sb_publishable_${"a".repeat(31)}`,
  POS_INITIAL_PASSWORD: "eight-or-more",
  POS_EXPECTED_CREATED_DATE_VN: "2026-07-18",
  POS_PREFLIGHT_ONLY: "0",
  CONFIRM_PRODUCTION_PASSWORD_RESET: "RESET_GLOBOS_PROD_OPERATIONAL_PASSWORDS",
  PGHOST: "aws-0-ap-southeast-1.pooler.supabase.com",
  PGPORT: "5432",
  PGUSER: "cli_login_ynriuoomotxuwhuxxmhj",
  PGPASSWORD: "temporary-database-password",
  PGDATABASE: "postgres",
};

test("approved account parser allows production identities only", async () => {
  const { parseApprovedEmailText } = await passwordResetModule;
  assert.deepEqual(
    parseApprovedEmailText(
      "# production\nandre@globos.world\nbt_pos1@globos.world\n",
    ),
    ["andre@globos.world", "bt_pos1@globos.world"],
  );
  assert.throws(
    () => parseApprovedEmailText("fixture@globos.test\n"),
    /NON_OPERATIONAL_EMAIL_FORBIDDEN/,
  );
  assert.throws(
    () => parseApprovedEmailText("andre@globos.world\nandre@globos.world\n"),
    /HAS_DUPLICATES/,
  );
});

test("configuration pins production and temporary database credentials", async () => {
  const { parseConfig } = await passwordResetModule;
  const config = parseConfig(validEnvironment);
  assert.equal(config.expectedCreatedDate, "2026-07-18");
  assert.equal(config.preflightOnly, false);
  assert.equal(
    parseConfig({ ...validEnvironment, POS_PREFLIGHT_ONLY: "1" }).preflightOnly,
    true,
  );
  assert.throws(
    () =>
      parseConfig({
        ...validEnvironment,
        POS_SUPABASE_URL: "https://wrong.supabase.co",
      }),
    /POS_PROJECT_GUARD_FAILED/,
  );
  assert.throws(
    () => parseConfig({ ...validEnvironment, PGPORT: "6543" }),
    /POS_POOLER_DATABASE_CREDENTIAL_INVALID/,
  );
  assert.throws(
    () =>
      parseConfig({
        ...validEnvironment,
        CONFIRM_PRODUCTION_PASSWORD_RESET: "yes",
      }),
    /EXPLICIT_PRODUCTION_PASSWORD_RESET_CONFIRMATION_REQUIRED/,
  );
});

test("password reset must rearm a newer lifecycle generation", async () => {
  const { assertPasswordLifecycleTransition } = await passwordResetModule;
  const base = {
    authId: "auth-1",
    appMetadata: { role: "cashier" },
    profile: { role: "cashier", fixed_account_code: "cashier_1" },
    accessIds: ["store-1"],
  };
  const before = {
    ...base,
    passwordLifecycle: {
      mustChangePassword: false,
      requiredAt: null,
      changedAt: "2026-07-19T00:00:00Z",
      generation: 4,
    },
  };
  const after = {
    ...base,
    passwordLifecycle: {
      mustChangePassword: true,
      requiredAt: "2026-07-19T01:00:00Z",
      changedAt: "2026-07-19T00:00:00Z",
      generation: 5,
    },
  };

  assert.doesNotThrow(() =>
    assertPasswordLifecycleTransition("cashier_1@globos.world", before, after)
  );
  assert.throws(
    () =>
      assertPasswordLifecycleTransition(
        "cashier_1@globos.world",
        before,
        {
          ...after,
          passwordLifecycle: {
            ...after.passwordLifecycle,
            mustChangePassword: false,
          },
        },
      ),
    /PASSWORD_CHANGE_GATE_NOT_REARMED/,
  );
  assert.throws(
    () =>
      assertPasswordLifecycleTransition(
        "cashier_1@globos.world",
        before,
        {
          ...after,
          passwordLifecycle: {
            ...after.passwordLifecycle,
            generation: 4,
          },
        },
      ),
    /PASSWORD_CHANGE_GATE_NOT_REARMED/,
  );
});

test("login verification requires the rearmed password gate", async () => {
  const { loginProfileMatchesExpected } = await passwordResetModule;
  const expected = {
    profile: { role: "cashier", fixed_account_code: "cashier_1" },
    passwordLifecycle: { generation: 5 },
  };
  const valid = {
    is_active: true,
    role: "cashier",
    fixed_account_code: "cashier_1",
    must_change_password: true,
    password_change_required_at: "2026-07-19T01:00:00Z",
    password_change_generation: 5,
  };

  assert.equal(loginProfileMatchesExpected(valid, expected), true);
  assert.equal(
    loginProfileMatchesExpected(
      { ...valid, must_change_password: false },
      expected,
    ),
    false,
  );
  assert.equal(
    loginProfileMatchesExpected(
      { ...valid, password_change_generation: 4 },
      expected,
    ),
    false,
  );
});
