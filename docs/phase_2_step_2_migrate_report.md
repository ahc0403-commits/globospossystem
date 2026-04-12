# Phase 2 Step 2 — Migrate Report

Date: 2026-04-12  
Scope lock: POS repository only (`/Users/andreahn/globos_pos_system`)  
Environment: linked Supabase project `globospossystem` (`ynriuoomotxuwhuxxmhj`)  
Execution lock: **STAGING only** / **Migrate only**

## Final verdict

**FAIL**

The POS-only Migrate apply failed on linked staging at the first execution attempt. Per run boundary, execution stopped immediately after the first failing command. No in-place patching was performed. Production was untouched.

## Truth lock

Pre-change staging truth was locked before any apply attempt.

- Expand alias state on staging:
  - `public.stores`: present
  - `public.public_store_profiles`: present
  - `public.get_user_store_id()`: present
  - `public.store_settings`: absent
- Pre-change policy count: `33`
- Pre-change old-path object counts:
  - views referencing old path: `13`
  - functions/RPCs referencing old path: `58`
  - policies referencing old path: `29`
  - trigger functions referencing old path: `1`

Objects that had to be migrated in this phase:

- Functions / RPCs: the 58 `public` functions captured from staging truth:
  - `add_items_to_order`
  - `admin_create_menu_category`
  - `admin_create_menu_item`
  - `admin_create_restaurant`
  - `admin_create_table`
  - `admin_deactivate_restaurant`
  - `admin_delete_menu_category`
  - `admin_delete_menu_item`
  - `admin_delete_table`
  - `admin_update_menu_category`
  - `admin_update_menu_item`
  - `admin_update_restaurant`
  - `admin_update_restaurant_settings`
  - `admin_update_staff_account`
  - `admin_update_table`
  - `apply_inventory_physical_count_line`
  - `cancel_order`
  - `cancel_order_item`
  - `complete_onboarding_account_setup`
  - `confirm_delivery_settlement_received`
  - `create_buffet_order`
  - `create_daily_closing`
  - `create_inventory_item`
  - `create_order`
  - `create_qc_followup`
  - `create_qc_template`
  - `deactivate_qc_template`
  - `edit_order_item_quantity`
  - `get_admin_mutation_audit_trace`
  - `get_admin_today_summary`
  - `get_attendance_log_view`
  - `get_attendance_staff_directory`
  - `get_cashier_today_summary`
  - `get_daily_closings`
  - `get_inventory_ingredient_catalog`
  - `get_inventory_physical_count_sheet`
  - `get_inventory_recipe_catalog`
  - `get_inventory_transaction_visibility`
  - `get_qc_analytics`
  - `get_qc_checks`
  - `get_qc_followups`
  - `get_qc_superadmin_summary`
  - `get_qc_templates`
  - `get_user_restaurant_id`
  - `get_user_store_id`
  - `on_payroll_store_submitted`
  - `process_payment`
  - `record_attendance_event`
  - `record_inventory_waste`
  - `require_admin_actor_for_restaurant`
  - `restock_inventory_item`
  - `transfer_order_table`
  - `update_inventory_item`
  - `update_order_item_status`
  - `update_qc_followup_status`
  - `update_qc_template`
  - `upsert_inventory_recipe_line`
  - `upsert_qc_check`
- Views referencing old path: `public_menu_items`, `public_restaurant_profiles`, `public_store_profiles`, `stores`, `v_brand_kpi`, `v_daily_revenue_by_channel`, `v_external_store_overview`, `v_external_store_sales`, `v_inventory_status`, `v_quality_monitoring`, `v_settlement_summary`, `v_store_attendance_summary`, `v_store_daily_sales`
- Policies referencing old path: 29 policies across `attendance_logs`, `delivery_settlement_items`, `delivery_settlements`, `external_sales`, `inventory_items`, `inventory_physical_counts`, `inventory_transactions`, `menu_categories`, `menu_items`, `menu_recipes`, `office_payroll_reviews`, `order_items`, `orders`, `payments`, `payroll_records`, `qc_checks`, `qc_followups`, `qc_templates`, `restaurant_settings`, `restaurants`, `staff_wage_configs`, `tables`, `users`
- Trigger-related object: `public.on_payroll_store_submitted()` attached via `trg_payroll_store_submitted`

Objects intentionally left untouched in this phase:

- Production
- Dart/UI/app code
- Contract stage
- Physical authoritative tables `public.restaurants` and `public.restaurant_settings`
- Compatibility entry points that had to remain alive:
  - `public.get_user_restaurant_id()`
  - `public.get_user_store_id()`
  - `public.stores`
  - `public.public_store_profiles`

## Exact files read

- `/Users/andreahn/globos_pos_system/docs/phase_2_step_2_expand_report.md`
- `/Users/andreahn/globos_pos_system/docs/phase_2_step_2_staging_run_report.md`
- `/Users/andreahn/globos_pos_system/docs/archive/20260412030000_rename_restaurants_to_stores.sql`
- `/Users/andreahn/globos_pos_system/docs/archive/20260412030001_rollback_rename_stores_to_restaurants.sql`
- `/Users/andreahn/globos_pos_system/supabase/migrations/20260412140000_expand_add_store_aliases.sql`
- Repository search over POS-only `supabase/**` for:
  - `restaurants`
  - `restaurant_settings`
  - `public_restaurant_profiles`
  - `get_user_restaurant_id()`
  - `restaurant_id`
- Remote staging metadata captured through linked Supabase queries:
  - policies
  - views
  - functions
  - trigger functions
  - table/column inventory
  - migration history

## Exact files changed

- `/Users/andreahn/globos_pos_system/supabase/migrations/20260412150000_migrate_pos_objects_to_stores.sql`
- `/Users/andreahn/globos_pos_system/supabase/migrations/20260412150001_rollback_migrate_pos_objects_to_restaurants.sql`
- `/Users/andreahn/globos_pos_system/docs/phase_2_step_2_migrate_report.md`

## Object counts before and after

Before apply:

- `pg_policies` count: `33`
- old-path views: `13`
- old-path functions/RPCs: `58`
- old-path policies: `29`
- old-path trigger functions: `1`

After apply:

- Not available
- Apply failed before migration completed
- No post-apply verification was executed

## Migration artifacts created

- Migrate migration file:
  - `/Users/andreahn/globos_pos_system/supabase/migrations/20260412150000_migrate_pos_objects_to_stores.sql`
- Manual rollback file:
  - `/Users/andreahn/globos_pos_system/supabase/migrations/20260412150001_rollback_migrate_pos_objects_to_restaurants.sql`

Generated object counts inside the Migrate SQL:

- Function/RPC rewrite count: `58`
- View create count: `34`
  - includes helper store-bridge views plus recreated POS views
- Policy create count: `29`
- Policy drop count: `29`

## Exact staging apply command(s)

Precheck / truth-lock commands:

```bash
supabase migration list
supabase db query --linked -f /tmp/staging_truth_lock.sql -o table
supabase db query --linked -f /tmp/staging_function_defs.sql -o csv
supabase db query --linked -f /tmp/staging_view_defs.sql -o csv
supabase db query --linked -f /tmp/staging_policy_defs.sql -o csv
supabase db query --linked -f /tmp/staging_column_inventory.sql -o csv
supabase db query --linked -f /tmp/staging_store_objects.sql -o table
supabase db query --linked -f /tmp/staging_remote_versions.sql -o csv
supabase db query --linked -f /tmp/staging_trigger_def.sql -o csv
supabase db query --linked -f /tmp/staging_base_table_columns.sql -o csv
supabase db query --linked -f /tmp/staging_truth_counts.sql -o csv
```

Apply command:

```bash
supabase db query --linked -f /Users/andreahn/globos_pos_system/supabase/migrations/20260412150000_migrate_pos_objects_to_stores.sql
```

Apply result: **FAIL**

Exact first error output:

```text
unexpected status 400: {"message":"Failed to run sql query: ERROR:  42601: syntax error at or near \"CREATE\"\nLINE 436: CREATE OR REPLACE FUNCTION public.admin_create_menu_category(p_restaurant_id uuid, p_name text, p_sort_order integer DEFAULT 0)\n          ^\n"}
```

Local line read at failure point:

```sql
CREATE OR REPLACE FUNCTION public.admin_create_menu_category(p_restaurant_id uuid, p_name text, p_sort_order integer DEFAULT 0)
```

Execution stop behavior:

- Stopped immediately after the first failing apply command
- No retry
- No in-place patching on staging
- No verification queries from Task 4 were executed
- No smoke test from Task 5 was executed

## Exact verification queries run

Truth-lock / inventory queries executed before apply:

```sql
SELECT 'policy_count' AS key, count(*)::text AS value
FROM pg_policies
WHERE schemaname='public'
UNION ALL
SELECT 'expand_stores_exists', EXISTS (
  SELECT 1 FROM information_schema.views WHERE table_schema='public' AND table_name='stores'
)::text
UNION ALL
SELECT 'expand_public_store_profiles_exists', EXISTS (
  SELECT 1 FROM information_schema.views WHERE table_schema='public' AND table_name='public_store_profiles'
)::text
UNION ALL
SELECT 'expand_store_settings_exists', EXISTS (
  SELECT 1 FROM information_schema.views WHERE table_schema='public' AND table_name='store_settings'
)::text
UNION ALL
SELECT 'get_user_store_id_exists', EXISTS (
  SELECT 1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='get_user_store_id'
)::text;

SELECT schemaname, viewname
FROM pg_views
WHERE schemaname='public'
  AND (
    definition ILIKE '%restaurants%'
    OR definition ILIKE '%restaurant_settings%'
    OR definition ILIKE '%public_restaurant_profiles%'
    OR definition ILIKE '%restaurant_id%'
    OR definition ILIKE '%get_user_restaurant_id%'
  )
ORDER BY viewname;

SELECT p.proname,
       l.lanname,
       pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN pg_language l ON l.oid = p.prolang
WHERE n.nspname='public'
  AND (
    p.prosrc ILIKE '%restaurants%'
    OR p.prosrc ILIKE '%restaurant_settings%'
    OR p.prosrc ILIKE '%public_restaurant_profiles%'
    OR p.prosrc ILIKE '%restaurant_id%'
    OR p.prosrc ILIKE '%get_user_restaurant_id%'
  )
ORDER BY p.proname, args;

SELECT schemaname, tablename, policyname
FROM pg_policies
WHERE schemaname='public'
  AND (
    coalesce(qual,'') ILIKE '%restaurants%'
    OR coalesce(with_check,'') ILIKE '%restaurants%'
    OR coalesce(qual,'') ILIKE '%restaurant_settings%'
    OR coalesce(with_check,'') ILIKE '%restaurant_settings%'
    OR coalesce(qual,'') ILIKE '%public_restaurant_profiles%'
    OR coalesce(with_check,'') ILIKE '%public_restaurant_profiles%'
    OR coalesce(qual,'') ILIKE '%restaurant_id%'
    OR coalesce(with_check,'') ILIKE '%restaurant_id%'
    OR coalesce(qual,'') ILIKE '%get_user_restaurant_id%'
    OR coalesce(with_check,'') ILIKE '%get_user_restaurant_id%'
  )
ORDER BY tablename, policyname;

SELECT t.tgname,
       c.relname AS table_name,
       p.proname AS function_name
FROM pg_trigger t
JOIN pg_class c ON c.oid=t.tgrelid
JOIN pg_proc p ON p.oid=t.tgfoid
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE NOT t.tgisinternal
  AND n.nspname='public'
  AND (
    pg_get_functiondef(p.oid) ILIKE '%restaurants%'
    OR pg_get_functiondef(p.oid) ILIKE '%restaurant_settings%'
    OR pg_get_functiondef(p.oid) ILIKE '%public_restaurant_profiles%'
    OR pg_get_functiondef(p.oid) ILIKE '%restaurant_id%'
    OR pg_get_functiondef(p.oid) ILIKE '%get_user_restaurant_id%'
  )
ORDER BY c.relname, t.tgname;
```

Additional count query executed before apply:

```sql
SELECT 'views_old_ref_count' AS key, count(*)::text AS value
FROM pg_views
WHERE schemaname='public'
  AND (
    definition ILIKE '%restaurants%'
    OR definition ILIKE '%restaurant_settings%'
    OR definition ILIKE '%public_restaurant_profiles%'
    OR definition ILIKE '%restaurant_id%'
    OR definition ILIKE '%get_user_restaurant_id%'
  )
UNION ALL
SELECT 'functions_old_ref_count', count(*)::text
FROM pg_proc p
JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
  AND (
    p.prosrc ILIKE '%restaurants%'
    OR p.prosrc ILIKE '%restaurant_settings%'
    OR p.prosrc ILIKE '%public_restaurant_profiles%'
    OR p.prosrc ILIKE '%restaurant_id%'
    OR p.prosrc ILIKE '%get_user_restaurant_id%'
  )
UNION ALL
SELECT 'policies_old_ref_count', count(*)::text
FROM pg_policies
WHERE schemaname='public'
  AND (
    coalesce(qual,'') ILIKE '%restaurants%'
    OR coalesce(with_check,'') ILIKE '%restaurants%'
    OR coalesce(qual,'') ILIKE '%restaurant_settings%'
    OR coalesce(with_check,'') ILIKE '%restaurant_settings%'
    OR coalesce(qual,'') ILIKE '%public_restaurant_profiles%'
    OR coalesce(with_check,'') ILIKE '%public_restaurant_profiles%'
    OR coalesce(qual,'') ILIKE '%restaurant_id%'
    OR coalesce(with_check,'') ILIKE '%restaurant_id%'
    OR coalesce(qual,'') ILIKE '%get_user_restaurant_id%'
    OR coalesce(with_check,'') ILIKE '%get_user_restaurant_id%'
  )
UNION ALL
SELECT 'trigger_function_old_ref_count', count(*)::text
FROM (
  SELECT DISTINCT p.oid
  FROM pg_trigger t
  JOIN pg_class c ON c.oid=t.tgrelid
  JOIN pg_proc p ON p.oid=t.tgfoid
  JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE NOT t.tgisinternal
    AND n.nspname='public'
    AND (
      pg_get_functiondef(p.oid) ILIKE '%restaurants%'
      OR pg_get_functiondef(p.oid) ILIKE '%restaurant_settings%'
      OR pg_get_functiondef(p.oid) ILIKE '%public_restaurant_profiles%'
      OR pg_get_functiondef(p.oid) ILIKE '%restaurant_id%'
      OR pg_get_functiondef(p.oid) ILIKE '%get_user_restaurant_id%'
    )
) s;
```

## Verification results

- Task 4.1 policy count unchanged: **SKIPPED** (blocked by apply failure)
- Task 4.2 no policy still references old helper: **SKIPPED**
- Task 4.3 no migrated function body still references old path: **SKIPPED**
- Task 4.4 coexistence still holds: **SKIPPED**
- Task 4.5 old entry points callable: **SKIPPED**
- Task 4.6 compatibility write-path check: **SKIPPED**
- Task 4.7 no authoritative alias loss: **SKIPPED**

## Trigger-related notes

- Trigger object identified before apply:
  - trigger: `trg_payroll_store_submitted`
  - table: `payroll_records`
  - function: `public.on_payroll_store_submitted()`
- Migrate SQL rewrote the trigger function body only.
- Trigger recreation / trigger rename was **not** attempted.
- Apply failed before the trigger function rewrite could be committed.

## Smoke test results

- Task 5 POS smoke test against staging: **SKIPPED**
- Reason: apply failure in Task 3 triggered immediate stop per prompt boundary
- No login/auth, store load, order creation, payment, or daily closing runtime smoke verification was executed

## Boundary confirmations

- Production touched: **No**
- Dart/app code touched for this task: **No**
- Contract executed: **No**
- Office-system repository/docs/runtime inspected or modified for this task: **No**

## GO / NO-GO

**NO-GO** for the next Production Expand+Migrate window.

Reason:

- The STAGING Migrate apply is not currently executable.
- First execution failed with SQL parse error `42601` near `CREATE OR REPLACE FUNCTION public.admin_create_menu_category(...)`.
- Production must remain blocked until the migration SQL is corrected and re-validated on staging in a separate run.
