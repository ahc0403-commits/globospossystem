import {
  parseBootstrapEnvironment,
  POS_MASTER_CONFIRMATION,
  POS_MASTER_EMAIL,
  POS_PROJECT_URL,
  verifyExistingMasterState,
} from "./bootstrap_pos_master_account_lib.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function assertThrows(fn: () => void, expected: string): void {
  try {
    fn();
  } catch (error) {
    assert(error instanceof Error, "expected Error");
    assert(
      error.message.includes(expected),
      `missing ${expected}: ${error.message}`,
    );
    return;
  }
  throw new Error(`expected throw containing ${expected}`);
}

const validEnv = {
  POS_SUPABASE_URL: POS_PROJECT_URL,
  POS_SUPABASE_SERVICE_ROLE_KEY: "x".repeat(48),
  POS_MASTER_PASSWORD: "correct-horse-battery-staple",
  POS_MASTER_ANCHOR_STORE_ID: "123e4567-e89b-42d3-a456-426614174000",
  CONFIRM_POS_MASTER_BOOTSTRAP: POS_MASTER_CONFIRMATION,
};

Deno.test("bootstrap configuration is exact-project, explicit, and env-only", () => {
  const parsed = parseBootstrapEnvironment(validEnv);
  assert(parsed.supabaseUrl === POS_PROJECT_URL, "unexpected project URL");
  assert(
    parsed.password === validEnv.POS_MASTER_PASSWORD,
    "password not read from env",
  );
  assertThrows(
    () =>
      parseBootstrapEnvironment({
        ...validEnv,
        POS_SUPABASE_URL: "https://wrong.supabase.co",
      }),
    "POS_PROJECT_GUARD_FAILED",
  );
  assertThrows(
    () =>
      parseBootstrapEnvironment({
        ...validEnv,
        CONFIRM_POS_MASTER_BOOTSTRAP: "yes",
      }),
    "POS_MASTER_EXPLICIT_CONFIRMATION_REQUIRED",
  );
  assertThrows(
    () =>
      parseBootstrapEnvironment({ ...validEnv, POS_MASTER_PASSWORD: "short" }),
    "POS_MASTER_PASSWORD_MINIMUM_12_CHARACTERS",
  );
});

function exactState() {
  return {
    authId: "auth-1",
    authEmail: POS_MASTER_EMAIL,
    emailConfirmed: true,
    authRole: "super_admin",
    authAccountType: "master",
    authFixedCode: "andre",
    profileAuthId: "auth-1",
    profileRole: "super_admin",
    profileAccountType: "master",
    profileFixedCode: "andre",
    profileRestaurantId: "store-1",
    profilePrimaryStoreId: "store-1",
    profileActive: true,
    hasActivePrimaryAccess: true,
  };
}

Deno.test("existing Andre identity is accepted only when profile, claims, and access agree", () => {
  verifyExistingMasterState(exactState());
  for (
    const [field, value] of [
      ["authRole", "cashier"],
      ["profileAccountType", "legacy_user"],
      ["profileFixedCode", "andre2"],
      ["profileActive", false],
      ["hasActivePrimaryAccess", false],
    ] as const
  ) {
    assertThrows(
      () => verifyExistingMasterState({ ...exactState(), [field]: value }),
      "POS_MASTER_STATE_MISMATCH",
    );
  }
});
