#!/usr/bin/env -S deno test

import assert from "node:assert";
import {
  dateInTimeZone,
  parseApprovedEmailText,
  parseConfig,
  selectOperationalUsers,
} from "./reset_production_operational_passwords.mjs";

function expectThrow(fn, expected) {
  assert.throws(fn, (error) => error.message.includes(expected));
}

const approved = parseApprovedEmailText(`
# production only
andre@globos.world
bt_pos1@globos.world
`);
assert.deepStrictEqual(approved, [
  "andre@globos.world",
  "bt_pos1@globos.world",
]);
expectThrow(
  () => parseApprovedEmailText("fixture@globos.test\n"),
  "NON_OPERATIONAL_EMAIL_FORBIDDEN",
);
expectThrow(
  () => parseApprovedEmailText("andre@globos.world\nandre@globos.world\n"),
  "HAS_DUPLICATES",
);

assert.strictEqual(
  dateInTimeZone("2026-07-17T18:13:28.875899Z"),
  "2026-07-18",
);

const exactUsers = approved.map((email, index) => ({
  id: `auth-${index}`,
  email,
  created_at: "2026-07-17T18:30:00Z",
  email_confirmed_at: "2026-07-17T18:31:00Z",
  banned_until: null,
}));
assert.strictEqual(
  selectOperationalUsers(
    [...exactUsers, { id: "test", email: "fixture@globos.test" }],
    approved,
    "2026-07-18",
  ).length,
  2,
);
expectThrow(
  () => selectOperationalUsers(exactUsers.slice(0, 1), approved, "2026-07-18"),
  "APPROVED_AUTH_MISSING",
);
expectThrow(
  () =>
    selectOperationalUsers(
      [
        { ...exactUsers[0], banned_until: "2126-01-01T00:00:00Z" },
        exactUsers[1],
      ],
      approved,
      "2026-07-18",
    ),
  "APPROVED_AUTH_BANNED",
);
expectThrow(
  () => selectOperationalUsers(exactUsers, approved, "2026-07-19"),
  "CREATED_DATE_MISMATCH",
);

const config = parseConfig({
  POS_SUPABASE_URL: "https://ynriuoomotxuwhuxxmhj.supabase.co",
  POS_SUPABASE_SERVICE_ROLE_KEY: "s".repeat(40),
  POS_SUPABASE_ANON_KEY: "a".repeat(40),
  POS_INITIAL_PASSWORD: "eight-or-more",
  POS_EXPECTED_CREATED_DATE_VN: "2026-07-18",
  CONFIRM_PRODUCTION_PASSWORD_RESET: "RESET_GLOBOS_PROD_OPERATIONAL_PASSWORDS",
});
assert.strictEqual(config.expectedCreatedDate, "2026-07-18");
assert.strictEqual(config.preflightOnly, false);
assert.strictEqual(
  parseConfig({
    POS_SUPABASE_URL: config.url,
    POS_SUPABASE_SERVICE_ROLE_KEY: config.serviceRoleKey,
    POS_SUPABASE_ANON_KEY: config.anonKey,
    POS_INITIAL_PASSWORD: "preflight-only-placeholder",
    POS_EXPECTED_CREATED_DATE_VN: config.expectedCreatedDate,
    POS_PREFLIGHT_ONLY: "1",
    CONFIRM_PRODUCTION_PASSWORD_RESET:
      "RESET_GLOBOS_PROD_OPERATIONAL_PASSWORDS",
  }).preflightOnly,
  true,
);
expectThrow(
  () =>
    parseConfig({
      ...Deno.env.toObject(),
      POS_SUPABASE_URL: "https://wrong.supabase.co",
    }),
  "POS_PROJECT_GUARD_FAILED",
);
expectThrow(
  () =>
    parseConfig({
      ...config,
      POS_SUPABASE_URL: config.url,
      POS_SUPABASE_SERVICE_ROLE_KEY: config.serviceRoleKey,
      POS_SUPABASE_ANON_KEY: config.anonKey,
      POS_INITIAL_PASSWORD: config.password,
      POS_EXPECTED_CREATED_DATE_VN: config.expectedCreatedDate,
    }),
  "EXPLICIT_PRODUCTION_PASSWORD_RESET_CONFIRMATION_REQUIRED",
);

Deno.test("production operational password reset guards", () => {
  // Top-level assertions above deliberately exercise module initialization too.
});
