# Phase 2 Step 2 — Staging Run Report

Date: 2026-04-12  
Environment: linked Supabase project `globospossystem` (`ynriuoomotxuwhuxxmhj`)  
Window: pre-production staging run

## Task 1 — Apply forward migration to Supabase staging

Status: **FAIL**

Command executed:

```bash
supabase db query --linked -f supabase/migrations/20260412030000_rename_restaurants_to_stores.sql
```

Error summary:

- Postgres error `2BP01` while executing migration.
- Failure point: `DROP FUNCTION IF EXISTS get_user_restaurant_id();`
- Cause: dependent RLS policies still reference `get_user_restaurant_id()`.
- Representative dependency examples:
  - `policy restaurant_isolation on table staff_wage_configs`
  - `policy orders_policy on table orders`
  - `policy restaurants_select_policy on table stores`

Raw CLI failure message (first line):

```text
cannot drop function get_user_restaurant_id() because other objects depend on it
```

Per run instruction, execution stopped immediately after Task 1 failure.

## Task 2 — Run verification checklist against staging

Status: **SKIPPED** (blocked by Task 1 failure)

## Task 3 — Dart codemod dry-run

Status: **SKIPPED** (run halted per Task 1 instruction)

## Task 4 — Korean UI label sweep

Status: **SKIPPED** (run halted per Task 1 instruction)

## Task 5 — Rollback timing measurement

Status: **SKIPPED** (run halted per Task 1 instruction)

## Severity classification (harness format)

- 🔴 CRITICAL: 1
- 🟠 HIGH: 0
- 🟡 MEDIUM: 0
- 🟢 LOW: 0

Critical item:

1. Forward migration is not executable on current staging state due to dependency-order issue around `get_user_restaurant_id()` and RLS policies.

## GO / NO-GO recommendation

**NO-GO** for production window until forward migration ordering is fixed and re-validated on staging.
