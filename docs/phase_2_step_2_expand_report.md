# Phase 2 Step 2 — Expand Report

Date: 2026-04-12  
Scope lock: POS repository only (`/Users/andreahn/globos_pos_system`)  
Execution lock: **Expand only** (Migrate/Contract not executed)

## Final verdict

**PASS**

Expand migration applied to linked staging successfully, coexistence checks passed, and no pre-existing authoritative object was modified.

## Truth lock

- Worked only in this repository.
- Did not inspect/modify `restaurant_office_app` or other repositories.
- Did not modify Dart/UI/app logic in this run.
- If staging apply had failed, flow would have stopped immediately (no in-place patching).

## Task 0 — POS-only precheck decision

Searches run (repo truth):

- `rg -n "restaurant_id|\\brestaurants\\b|get_user_restaurant_id\\(" lib supabase docs`
- `rg -l "restaurant_id|\\brestaurants\\b|get_user_restaurant_id\\(" lib supabase docs | sort`
- `rg -n "\\bstores\\b|store_settings|public_store_profiles|get_user_store_id\\(" lib supabase docs`

Staging object checks:

- Confirmed existing objects: `public.restaurants`, `public.restaurant_settings`, `public.public_restaurant_profiles`, `public.get_user_restaurant_id()`
- Confirmed absent pre-expand: `public.stores`, `public.store_settings`, `public.public_store_profiles`, `public.get_user_store_id()`

Decision:

- `stores` alias view: **safe** as thin pass-through (`SELECT * FROM public.restaurants`).
- `restaurant_settings` alias view (`store_settings`): **excluded** in Expand.
  - Reason: not immediately required by current POS runtime references in this phase, and avoiding additional view/RLS surface keeps change bounded.
- `public_restaurant_profiles` alias view (`public_store_profiles`): **safe** as thin read pass-through (`SELECT * FROM public.public_restaurant_profiles`).
- Column aliasing: **not required now** (kept default NO column alias).

## Exact files read

- `/Users/andreahn/globos_pos_system/docs/phase_2_step_2_staging_run_report.md`
- `/Users/andreahn/globos_pos_system/supabase/migrations/20260412030000_rename_restaurants_to_stores.sql`
- `/Users/andreahn/globos_pos_system/supabase/migrations/20260412030001_rollback_rename_stores_to_restaurants.sql`

Plus runtime truth queries/scans over:

- `lib/`, `supabase/`, `docs/` via `rg`
- Linked staging metadata (`information_schema`, `pg_views`, `pg_policies`, `pg_proc`)

## Exact files changed

- Moved to archive:
  - `/Users/andreahn/globos_pos_system/docs/archive/20260412030000_rename_restaurants_to_stores.sql`
  - `/Users/andreahn/globos_pos_system/docs/archive/20260412030001_rollback_rename_stores_to_restaurants.sql`
- Updated:
  - `/Users/andreahn/globos_pos_system/docs/phase_2_step_2_report.md` (OBSOLETE header)
- Created:
  - `/Users/andreahn/globos_pos_system/supabase/migrations/20260412140000_expand_add_store_aliases.sql`
  - `/Users/andreahn/globos_pos_system/supabase/migrations/20260412140001_rollback_expand_store_aliases.sql`
  - `/Users/andreahn/globos_pos_system/docs/phase_2_step_2_expand_report.md`

## Task 4 — Exact staging apply command(s)

```bash
supabase db query --linked -f /Users/andreahn/globos_pos_system/supabase/migrations/20260412140000_expand_add_store_aliases.sql
```

Result: **SUCCESS** (exit code 0).

## Task 5 — Verification queries and results

### 1. Count parity

Queries:

```sql
SELECT count(*) AS restaurants_count FROM public.restaurants;
SELECT count(*) AS stores_count FROM public.stores;
```

Result:

- `restaurants_count = 3`
- `stores_count = 3`
- **PASS** (counts match)

### 2. Function parity

Query:

```sql
SELECT public.get_user_restaurant_id() AS restaurant_id_ctx,
       public.get_user_store_id() AS store_id_ctx;
```

Result:

- `restaurant_id_ctx = NULL`
- `store_id_ctx = NULL`
- Same context, same value -> **PASS**

### 3. Updatable view write test

Feasibility check:

```sql
SELECT table_name, is_updatable
FROM information_schema.views
WHERE table_schema='public'
  AND table_name IN ('stores','public_store_profiles');
```

Result: `stores = YES`, `public_store_profiles = NO`

Write-through verification (safe transaction + rollback):

```sql
BEGIN;
SELECT count(*) AS restaurants_before FROM public.restaurants;
INSERT INTO public.stores (name)
VALUES ('expand_view_write_test_' || to_char(clock_timestamp(),'YYYYMMDDHH24MISS'));
SELECT count(*) AS restaurants_after FROM public.restaurants;
ROLLBACK;
```

Result:

- `restaurants_after = 4` inside transaction (from baseline 3)
- After rollback, persisted count remains unchanged
- **PASS** (`public.stores` writes through to `public.restaurants`)

### 4. Policy integrity

Queries/snapshots:

- Before: `SELECT count(*) AS policy_count FROM pg_policies WHERE schemaname='public';` -> `33`
- After: `SELECT count(*) AS policy_count_after FROM pg_policies WHERE schemaname='public';` -> `33`
- Full snapshot diff:
  - `/tmp/phase2_expand_policies_before.csv`
  - `/tmp/phase2_expand_policies_after.csv`
  - `diff -u` result: no differences

Result: **PASS** (no policy definition changes)

### 5. Object integrity

Checks:

- `public.restaurants` and `public.restaurant_settings` remain `BASE TABLE`
- `public.get_user_restaurant_id()` remains present and unchanged in purpose/body
- `public.public_restaurant_profiles` definition remains intact

Result: **PASS** (no authoritative object modification)

## Created objects

From Expand migration:

- `public.get_user_store_id()` (wrapper to `public.get_user_restaurant_id()`)
- `public.stores` view (`SELECT * FROM public.restaurants`)
- `public.public_store_profiles` view (`SELECT * FROM public.public_restaurant_profiles`)

## Excluded optional alias views

- `public.store_settings` was intentionally not created in this Expand phase.
- Reason: minimize risk/surface in first bounded rollout and avoid unnecessary view-policy interaction before Migrate phase.

## Not executed in this prompt

- **Migrate phase: NOT executed**
- **Contract phase: NOT executed**
