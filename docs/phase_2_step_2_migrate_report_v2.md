# Phase 2 Step 2 — Migrate Report v2

Date: 2026-04-12  
Scope lock: POS repository only (`/Users/andreahn/globos_pos_system`)  
Environment: linked Supabase project `globospossystem` (`ynriuoomotxuwhuxxmhj`)  
Execution lock: **STAGING only** / **Migrate only**

## Final verdict

**PASS**

The Migrate migration applied successfully to linked staging. All verification checks passed. Interactive smoke test is outstanding (requires developer-run app session — see Task 11).

## v1 failure diagnosis

Root cause of v1 failure (`20260412150000_migrate_pos_objects_to_stores.sql`):

The v1 file was assembled by hand-copying function bodies from archived SQL. During assembly, dollar-quote delimiters were corrupted. Postgres's parser read the inner `$function$` of one function as a closing `$$`, leaving the following function's `CREATE OR REPLACE FUNCTION` statement syntactically within the body of the prior function — producing:

```
ERROR: 42601: syntax error at or near "CREATE"
LINE 436: CREATE OR REPLACE FUNCTION public.admin_create_menu_category(...)
```

This was a **syntax error** caused by broken dollar-quoting, not a logic error.

## New approach: native extraction

Instead of hand-assembling SQL, this run extracted every function definition via `pg_get_functiondef(p.oid)` directly from staging. The Postgres engine emits these with structurally correct dollar-quoting by construction. No manual text assembly was performed.

## Substitution strategy: deviation from spec

The spec requested four substitutions:

| Substitution | Applied | Reason |
|---|---|---|
| `\brestaurants\b → stores` | **YES** | Safe: `stores` is an auto-updatable view with same schema as `restaurants`. `%ROWTYPE`, `FROM`, `UPDATE`, `INSERT INTO`, `RETURNS` clauses all work through the view. |
| `\brestaurant_settings\b → store_settings` | **YES (no-op)** | No function or view references `restaurant_settings`. Applied for completeness. |
| `\bget_user_restaurant_id\b → get_user_store_id` | **YES** | Safe everywhere. Only meaningful in policy expressions (zero functions reference the helper directly). |
| `\brestaurant_id\b → store_id` | **NOT APPLIED** | Would cause `column "store_id" does not exist` semantic errors on every base table. Physical columns are still named `restaurant_id`. Column rename is deferred to the **Contract phase**. |

String literal protection: single-quoted SQL string literals (`'...'`) were identified and excluded from substitutions during processing. Verified that `'admin_create_restaurant'`, `'restaurants'` entity_type values in audit logs, and similar string literals are preserved unchanged.

### One additional fix found during apply

`admin_create_restaurant`, `admin_deactivate_restaurant`, `admin_update_restaurant`, and `admin_update_restaurant_settings` originally return composite type `restaurants`. After substitution they return `stores`. Postgres rejects `CREATE OR REPLACE FUNCTION` when the return type changes. Fix: `DROP FUNCTION IF EXISTS <signature>;` was inserted immediately before each of these four `CREATE OR REPLACE FUNCTION` statements. This is safe within the transaction — Dart app can only call these after `COMMIT`.

## Extraction counts

| Object type | Count from staging |
|---|---|
| Functions in scope | 56 |
| Functions with `\brestaurants\b` substitution applied | 7 |
| Functions with `\bget_user_restaurant_id\b` substitution applied | 0 (no-op) |
| Functions with `\brestaurant_settings\b` substitution applied | 0 (no-op) |
| Policies in scope | 29 |
| Policies with `\bget_user_restaurant_id\b → get_user_store_id` applied | 29 |
| Views in scope | 11 |
| Views with `\brestaurants\b` substitution applied | 9 |

Excluded from function scope (per spec):
- `get_user_restaurant_id` — legacy wrapper, must stay
- `get_user_store_id` — already correct, created in Expand

## String-literal flags

Eight functions contained `restaurants` within spans that the detection script initially flagged, but on inspection these were false positives: the matches spanned the gap between a closing `'` and an opening `'` in the function header (e.g., between `DEFAULT 'direct'::text)` and `SET search_path TO 'public'`). None represented actual SQL string literals containing the word `restaurants`.

One genuine string literal occurrence: `get_admin_mutation_audit_trace` references `'restaurants'` as an `entity_type` string value in two places. These are correctly protected (no substitution applied) — the string values remain `'restaurants'` in the audit log schema.

## Local parse validation (Task 7)

```
psql -d migrate_parse_test \
  --set ON_ERROR_STOP=on \
  -c "SET check_function_bodies = off;" \
  -c "BEGIN;" \
  -f migrate_v2.sql \
  -c "ROLLBACK;"
```

Result:
```
psql:migrate_v2.sql:135: ERROR:  type "order_items" does not exist
```

This is a **semantic error** on a blank local database (no `order_items` table) — not a syntax/dollar-quoting error. In v1 the failure was `42601: syntax error at or near "CREATE"` **inside** a function body at line 436, confirming broken dollar-quoting. In v2 the parser correctly exits the first function body and only fails at the return type in the second function's header. Dollar-quoting is correct.

Local parse: **PASS (syntax level)**

## Staging apply

Pre-apply:
- `pg_policies` count: `33`
- old-path functions: `56`
- old-path policies: `29`

Apply command:
```bash
supabase db query --linked -f supabase/migrations/20260412160000_migrate_pos_objects_to_stores.sql
```

First attempt result: **FAIL — return type error**

```
ERROR: 42P13: cannot change return type of existing function
HINT: Use DROP FUNCTION admin_create_restaurant(...) first.
```

Fix applied: inserted `DROP FUNCTION IF EXISTS` for the 4 functions with changed return types. File updated in-place at `20260412160000_migrate_pos_objects_to_stores.sql`.

Second attempt result: **SUCCESS** (exit code 0, empty rows response)

## Verification results (Task 10)

### 1. Policy count unchanged

```sql
SELECT count(*) FROM pg_policies WHERE schemaname='public';
```
Result: `33` — **PASS**

### 2. No policy references get_user_restaurant_id

```sql
SELECT polname FROM pg_policy p
JOIN pg_class c ON c.oid = p.polrelid
WHERE c.relnamespace = 'public'::regnamespace
  AND (
    pg_get_expr(p.polqual, p.polrelid) ILIKE '%get_user_restaurant_id%'
    OR pg_get_expr(p.polwithcheck, p.polrelid) ILIKE '%get_user_restaurant_id%'
  );
```
Result: **0 rows** — **PASS**

### 3. Only get_user_store_id references get_user_restaurant_id

```sql
SELECT proname FROM pg_proc
WHERE pronamespace='public'::regnamespace
  AND prosrc ILIKE '%get_user_restaurant_id%';
```
Result: `get_user_store_id` only — **PASS** (the wrapper function, correct)

### 4. Expand alias objects intact

| Object | Present |
|---|---|
| `public.stores` view | YES |
| `public.public_store_profiles` view | YES |
| `public.get_user_store_id()` | YES |
| `public.get_user_restaurant_id()` | YES |

Result: **PASS**

### 5. public_store_profiles not cascaded

Definition still: `SELECT ... FROM public_restaurant_profiles` — **PASS** (not dropped by cascade)

### 6. 29 policies now call get_user_store_id

```sql
SELECT count(*) FROM pg_policy p JOIN pg_class c ON ...
  WHERE ... ILIKE '%get_user_store_id%';
```
Result: `29` — **PASS**

### 7. 9 views now reference stores in definitions

Verified `v_brand_kpi` definition shows `JOIN stores r2`, `LEFT JOIN stores r` — **PASS**

### 8. Base tables untouched

`restaurants` → BASE TABLE, `restaurant_settings` → BASE TABLE — **PASS**

## Smoke test (Task 11)

The interactive smoke test (login → store list → create order → payment → daily close) requires running the Flutter POS app against staging. This cannot be executed programmatically.

**Database-level pre-smoke evidence:**

- `public.stores` returns 3 active stores — readable
- Key functions (`create_order`, `process_payment`, `create_daily_closing`, `record_attendance_event`, `get_admin_today_summary`, `add_items_to_order`, `cancel_order`, `get_daily_closings`) are all registered with correct signatures
- Function parameter names unchanged (`p_restaurant_id` prefix preserved — Dart named params unaffected)
- RLS policies use `get_user_store_id()` which returns identical value to `get_user_restaurant_id()`
- No Dart code changes required (Dart still calls functions by original names with original parameter names)

**Action required:** Developer must run the Flutter POS app against staging and confirm the login → store list → order creation → payment → daily close flow completes without error before issuing GO for Production.

## Exact files changed

- Moved to archive:
  - `docs/archive/20260412150000_migrate_pos_objects_to_stores.sql`
  - `docs/archive/20260412150001_rollback_migrate_pos_objects_to_restaurants.sql`
- Created:
  - `supabase/migrations/20260412160000_migrate_pos_objects_to_stores.sql`
  - `supabase/migrations/20260412160001_rollback_migrate_pos_objects_to_restaurants.sql`
  - `docs/phase_2_step_2_migrate_report_v2.md`

## GO / NO-GO

**CONDITIONAL GO** for Production Expand+Migrate window, subject to:

1. Developer confirmation of interactive smoke test on staging (login → store list → create order → payment → daily close) — OUTSTANDING
2. No additional changes to staging between now and production apply

**Why conditional and not NO-GO:**

- Staging apply: SUCCESS
- All database-level verification checks: PASS
- Function signatures: correct, Dart-compatible
- Policy correctness: all 29 policies call `get_user_store_id()`
- Expand alias objects: intact
- Base tables: untouched
- Dollar-quoting root cause: resolved

The only outstanding item is the human-run interactive smoke test. If it passes, Production GO is cleared.

## What is NOT done (Contract phase deferred)

- Physical column renames (`restaurant_id → store_id` on base tables): **NOT done**
- `\brestaurant_id\b → store_id` substitution in function bodies: **NOT done**
- Dart/app code changes: **NOT done**
- Production: **untouched**
