---
title: "Phase 2 Step 2 — Verification Plan"
version: "1.0"
date: "2026-04-12"
status: "historical plan — big-bang apply not used"
---

# Phase 2 Step 2 — Verification Plan

> Historical note: this checklist belongs to the abandoned atomic rename apply plan.
>
> It should not be used as the current rollout checklist. The shipped path is the coexistence-based Expand -> Migrate -> Contract sequence documented in `/Users/andreahn/globos_pos_system/docs/phase_1_architecture.md` Section 11 plus the Step 2 expand/migrate reports.

## Pre-Apply Checks

- [ ] **Backup confirmation**: Fresh Supabase backup taken within the last hour?
- [ ] **Staging environment**: Test environment available for first apply?
- [ ] **Maintenance window**: Scheduled for 03:00–05:00 Asia/Ho_Chi_Minh time?
- [ ] **Operator notification**: All operators notified of downtime window?
- [ ] **Rollback file reviewed**: `20260412030001_rollback_rename_stores_to_restaurants.sql` reviewed and ready?
- [ ] **Dart codemod previewed**: `phase_2_step_2_dart_codemod.sh` dry-run output reviewed?
- [ ] **Edge function code reviewed**: TypeScript changes in codemod reviewed?
- [ ] **No active transactions**: Verify no in-flight orders during maintenance window
- [ ] **Database connection count**: Verify minimal active connections before applying

## Apply Sequence (During Maintenance Window)

1. Take fresh Supabase backup
2. Set application to maintenance mode (if available)
3. Apply forward migration to **staging** first:
   ```bash
   supabase db push --db-url $STAGING_DB_URL
   ```
4. Run post-apply smoke tests on staging (see below)
5. If staging passes: apply to **production**:
   ```bash
   supabase db push
   ```
6. Run post-apply smoke tests on production
7. Apply Dart codemod:
   ```bash
   ./docs/phase_2_step_2_dart_codemod.sh --apply
   ```
8. Build and deploy Flutter app
9. Deploy updated edge functions:
   ```bash
   supabase functions deploy create_staff_user
   supabase functions deploy generate_delivery_settlement
   supabase functions deploy generate-settlement
   ```
10. Verify application startup
11. Monitor for 30 minutes
12. If issues detected: apply rollback (see Rollback section)

## Post-Apply Smoke Tests (SQL)

Run these queries against the database after migration:

### Table existence and data integrity
- [ ] `SELECT count(*) FROM stores;` — must match pre-migration `SELECT count(*) FROM restaurants;`
- [ ] `SELECT count(*) FROM store_settings;` — must match pre-migration count
- [ ] `SELECT count(*) FROM users WHERE store_id IS NOT NULL;` — all users have valid store reference
- [ ] `\d stores` — verify column list matches expected (id, name, address, slug, operation_mode, per_person_charge, is_active, created_at, brand_id, store_type, store_id should NOT exist on stores itself)

### FK constraint verification
- [ ] `SELECT conname, conrelid::regclass, confrelid::regclass FROM pg_constraint WHERE confrelid = 'stores'::regclass;` — all FKs point to stores
- [ ] Verify no FK references `restaurants` — `SELECT conname FROM pg_constraint WHERE confrelid::regclass::text = 'restaurants';` should return empty

### RLS policy verification
- [ ] `SELECT policyname, tablename FROM pg_policies WHERE policyname LIKE '%restaurant%';` — should return empty
- [ ] `SELECT policyname, tablename FROM pg_policies WHERE qual::text LIKE '%restaurant%' OR with_check::text LIKE '%restaurant%';` — should return empty
- [ ] Test RLS for a sample user: connect as non-super-admin, `SELECT * FROM stores;` should return only their store

### View verification
- [ ] `SELECT * FROM public_store_profiles LIMIT 1;` — returns data
- [ ] `SELECT * FROM public_restaurant_profiles LIMIT 1;` — compatibility alias works
- [ ] `SELECT * FROM v_store_daily_sales LIMIT 1;` — returns data
- [ ] `SELECT * FROM v_brand_kpi LIMIT 1;` — returns data
- [ ] Run SELECT on all 11 views — none should error

### Function verification
- [ ] `SELECT get_user_store_id();` — returns valid UUID for authenticated user
- [ ] `SELECT proname FROM pg_proc WHERE proname LIKE '%restaurant%' AND pronamespace = 'public'::regnamespace;` — should return empty (no functions with old name)
- [ ] Call `process_payment` with test data — should succeed
- [ ] Call `create_order` with test data — should succeed

## Post-Apply Smoke Tests (Dart/Flutter)

- [ ] App starts without runtime errors
- [ ] Login flow works (queries users table with store_id)
- [ ] Store selection works (super_admin can see all stores)
- [ ] Order creation works (create_order RPC)
- [ ] Payment processing works (process_payment RPC)
- [ ] Menu display works (menu_items with FK to stores)
- [ ] Kitchen display works (order subscription)
- [ ] Daily closing works (create_daily_closing RPC)
- [ ] Attendance logging works
- [ ] QC checks work
- [ ] Admin settings page loads (store_settings table)
- [ ] Payroll page loads
- [ ] Delivery settlement page loads

## Rollback Procedure

If any post-apply check fails within 30 minutes of deployment:

1. Apply rollback migration:
   ```bash
   # Apply the rollback SQL file directly
   psql $DATABASE_URL -f supabase/migrations/20260412030001_rollback_rename_stores_to_restaurants.sql
   ```
2. Revert Dart codemod:
   ```bash
   git checkout -- lib/ supabase/functions/
   ```
3. Redeploy previous Flutter build
4. Redeploy previous edge functions
5. Verify application returns to normal operation
6. Document what failed for post-mortem

**Rollback target time:** Under 2 minutes for SQL, under 5 minutes total including app redeployment.

## Rollback Decision Criteria

| Signal | Action |
|---|---|
| Any RPC returns error in first 5 min | Immediate rollback |
| RLS denying legitimate access | Immediate rollback |
| Edge function auth failures | Investigate first; rollback if persistent |
| Dart app build failures | Deploy old build; SQL rollback if needed |
| No errors after 30 minutes | Archive rollback SQL (do not delete) |

---

*Generated: 2026-04-12*
