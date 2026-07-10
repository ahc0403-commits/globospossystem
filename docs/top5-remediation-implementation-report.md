# Top-5 Remediation Implementation Report

**Date:** 2026-06-10
**Branch:** `codex/pos-primary-job-phase5`
**Status:** Code changes complete. Credential rotation and Vault secret insertion require manual execution.

---

## Item 1: Credential Rotation / Account Cleanup

**Status:** Report produced; manual execution required.

### Files changed
- (none — no credentials committed)

### Files produced
- `docs/credential-cleanup-report.md` — full account list, steps, and sequence

### What was done
- Identified all accounts from the tracked xlsx requiring rotation
- Documented the CRON_SECRET rotation sequence (Vault-based)
- Documented xlsx removal steps (`git rm --cached` + relocate)

### What requires manual execution
1. Rotate passwords via Supabase Auth dashboard (POS + Office projects)
2. `git rm --cached 'GLOBOS_POS_화면플로우_계정정보_2026-05-25.xlsx'`
3. Move xlsx to `~/Documents/restaurant-ops-vault/`
4. Update `integration_test/full_multi_account_smoke_test.dart` credential source
5. Insert new CRON_SECRET into Vault before applying migration 20260610000003

### Remaining risks
- Until passwords are rotated, the xlsx credentials remain valid
- `full_multi_account_smoke_test.dart` will break after rotation until updated

---

## Item 2: Daily Closing 07:00 Bug

**Status:** Complete (migration written, tests pass).

### Files changed
- **New:** `supabase/migrations/20260610000001_fix_daily_closing_hcmc_window.sql`

### SQL migrations
- `CREATE OR REPLACE FUNCTION public.create_daily_closing` — fixes `v_day_start` to use `AT TIME ZONE 'Asia/Ho_Chi_Minh'` instead of `::TIMESTAMPTZ`; adds `v_day_end` upper bound to all 4 metric queries
- `CREATE OR REPLACE FUNCTION public.get_admin_today_summary` — same fix applied (had identical `::DATE::TIMESTAMPTZ` bug at line 369 of 20260414000019)
- `get_daily_closings` — verified: only reads from `daily_closings` table by `closing_date`, does NOT compute time boundaries; no fix needed

### Tests added
- `test/daily_closing_window_test.dart` (7 tests)
  - Verifies AT TIME ZONE usage
  - Verifies v_day_end upper bound exists
  - Verifies all 4 queries have upper bound
  - Verifies buggy pattern removed from executable code
  - Verifies historical audit query included
  - Verifies get_admin_today_summary also fixed

### Historical impact query
Included as a comment in the migration. Must be run manually against production to quantify previously excluded 00:00–06:59 HCMC sales. Backfill-or-cutover decision must be made with Hyochang.

### Rollback
Re-apply the function body from `20260414000019`. Pure function swap, no schema change.

---

## Item 3: Cross-Tenant View Leak

**Status:** Complete (uncommitted migration patched + new migration for live views).

### Files changed
- **Modified:** `supabase/migrations/20260609000000_office_pos_sales_photo_objet_events.sql` — added `security_invoker = true` for both views before grants
- **New:** `supabase/migrations/20260610000002_security_invoker_cross_tenant_views.sql`

### Views secured (14 total)
| View | Source migration |
|------|-----------------|
| v_store_daily_sales | 20260405000003/20260405000012 |
| v_store_attendance_summary | 20260405000003/20260405000012 |
| v_inventory_status | 20260405000003/20260405000012 |
| v_brand_kpi | 20260405000003/20260405000012 |
| v_quality_monitoring | 20260405000003, redefined 20260507000002 |
| v_qsc_dashboard_summary | 20260507000002 |
| v_qsc_store_status | 20260507000002 |
| v_qsc_item_status | 20260507000002 |
| v_office_qsc_dashboard | 20260507000006 (wrapper) |
| v_office_qsc_store_latest | 20260507000006 (wrapper) |
| v_office_qsc_issue_queue | 20260507000006 (wrapper) |
| v_office_pos_sales_events | 20260604001000/20260609000000 (conditional) |
| v_office_pos_sales_bucket_summary | 20260604001000/20260609000000 (conditional) |
| (uncommitted views) | 20260609000000 (patched in-place) |

### Tests added
- `test/security_invoker_views_test.dart` (15 tests)
  - Verifies each view name appears with `security_invoker = true`
  - Verifies uncommitted migration is patched
  - Verifies security_invoker comes before grants in uncommitted migration
  - Includes validation query for manual sweep

### Rollback
`ALTER VIEW ... SET (security_invoker = false)` per view. Instant, no data involved.

### Note
Office app connects with `service_role` (BYPASSRLS) — unaffected by `security_invoker`. POS super_admin dashboards use role-scoped RLS policies that already grant broad SELECT.

---

## Item 4: CRON_SECRET Rotation Support

**Status:** Migration written. Manual secret insertion into Vault required before applying.

### Files changed
- **New:** `supabase/migrations/20260610000003_rotate_cron_secret_to_vault.sql`

### SQL migrations
- Unschedules all 4 WeTax cron jobs
- Reschedules them with `vault.decrypted_secrets` lookup for the bearer token
- No hardcoded secrets in the migration

### Cron jobs affected
| Job name | Schedule |
|----------|----------|
| wetax-dispatcher-every-minute | * * * * * |
| wetax-poller-every-2-minutes | */2 * * * * |
| wetax-daily-close-00-hcmc | 0 17 * * * |
| wetax-commons-refresh-weekly | 0 18 * * 0 |

### Edge functions
All 5 edge functions already read `CRON_SECRET` from `Deno.env.get("CRON_SECRET")` — no code changes needed.

### Tests added
- `test/cron_secret_rotation_test.dart` (6 tests)
  - Verifies no hardcoded secret in executable code
  - Verifies vault.decrypted_secrets usage
  - Verifies all 4 jobs unscheduled and rescheduled
  - Verifies edge functions read from Deno.env

### Deployment sequence (zero-gap cutover)
1. Set new CRON_SECRET in edge function env (dashboard → Functions → Secrets)
2. Insert same value into Vault: `INSERT INTO vault.secrets (name, secret, description) VALUES ('cron_secret', '<new-value>', 'Bearer token for cron → edge function auth')`
3. Apply migration `20260610000003`
4. Verify: `SELECT jobname, command LIKE '%vault.decrypted_secrets%' FROM cron.job`
5. Verify: wait 2 min, check `cron.job_run_details` for 200 status

### Rollback
Generate a fresh secret, insert into Vault + function env, re-run migration. Never revert to the leaked value.

---

## Item 5: Realtime / Polling Cost

**Status:** Complete.

### Files changed
- `lib/features/order/order_provider.dart` — `_ensureAutoRefresh`: guard on `_realtimeConnected`, cancel timer when connected, poll at 15s when disconnected
- `lib/features/kitchen/kitchen_provider.dart` — same pattern
- `lib/features/table/table_provider.dart` — same pattern
- `lib/features/payment/payment_provider.dart` — same pattern
- `lib/features/admin/providers/tables_provider.dart` — same pattern

### Change pattern (applied to all 5)
```dart
void _ensureAutoRefresh(...) {
  if (_realtimeConnected) {
    _pollTimer?.cancel();
    _pollTimer = null;
    return;
  }
  // ... existing guard ...
  _pollTimer = Timer.periodic(_fallbackPollInterval, ...);
}
```

### Tests added
- `test/provider_poll_guard_test.dart` (15 tests)
  - Verifies each provider's `_ensureAutoRefresh` checks `_realtimeConnected`
  - Verifies timer cancellation when connected
  - Verifies `_fallbackPollInterval` >= 10 seconds
  - Verifies no `Timer.periodic(_autoRefreshInterval)` remains

### Expected impact
- ~95% reduction in baseline PostgREST request volume per store
- From ~43,200 req/day/screen → polling only when realtime disconnected at 15s intervals
- Realtime-driven updates continue instantly (< 2s delivery unchanged)

### Rollback
`git revert` the Flutter PR. Client-side only, ships with next app build.

---

## Item 6: Route Guard + Logout State Reset

**Status:** Complete (separate changes for independent revert).

### Route guard changes
- `lib/core/utils/role_routes.dart` — added `/privacy-consent` to always-allowed routes
- `lib/core/router/app_router.dart` — added `canAccessRouteForRole` as fall-through guard before `return null`. This means ANY route not explicitly handled by prior special-case blocks is now checked against the role matrix. Previously only `/payments/` was checked.

### Logout state reset changes
- `lib/features/auth/auth_provider.dart`:
  - `AuthNotifier` now accepts `onLogout` callback
  - `logout()` calls `onLogout?.call()` after `signOut()` completes
  - `authProvider` definition wires up `ref.invalidate(...)` for 12 session-scoped providers

### Providers invalidated on logout
`orderProvider`, `paymentProvider`, `kitchenProvider`, `waiterTableProvider`, `staffProvider`, `attendanceProvider`, `settingsProvider`, `recipeProvider`, `ingredientProvider`, `qcCheckProvider`, `qcTemplateProvider`, `photoOpsProvider`

### Tests added
- `test/router_role_guard_test.dart` (38 tests)
  - Table-driven: role × route matrix for all 9 roles
  - QC permission checks (admin-like vs extra permissions)
  - Home route verification for each role
  - Public route, attendance-kiosk, null-role edge cases
- `test/logout_state_reset_test.dart` (14 tests)
  - Verifies onLogout callback exists and is called
  - Verifies each of 12 providers is invalidated
  - Verifies invalidation happens after signOut

### Rollback
Two independent reverts:
- Route guard: revert changes to `app_router.dart` and `role_routes.dart`
- Logout reset: revert changes to `auth_provider.dart`

---

## Commands run

```bash
flutter analyze                    # No issues found
flutter test test/daily_closing_window_test.dart     # 7/7 pass
flutter test test/security_invoker_views_test.dart   # 15/15 pass
flutter test test/provider_poll_guard_test.dart       # 15/15 pass
flutter test test/router_role_guard_test.dart         # 38/38 pass (updated)
flutter test test/logout_state_reset_test.dart        # 14/14 pass
flutter test test/cron_secret_rotation_test.dart      # 6/6 pass (updated)
flutter test                                          # 307 pass, 2 pre-existing failures
```

## Pre-existing test failures (not caused by this change)

- `waiter_floor_layout_contract_test.dart`: "waiter floor table cards show active order menu previews"
- `cashier_waiter_workspace_i18n_contract_test.dart`: "cashier payment queue follows kitchen served handoff"

Both fail on the clean branch before any changes.

---

## Summary of all files

### New files (8)
| File | Item |
|------|------|
| `supabase/migrations/20260610000001_fix_daily_closing_hcmc_window.sql` | Daily close fix |
| `supabase/migrations/20260610000002_security_invoker_cross_tenant_views.sql` | View leak fix |
| `supabase/migrations/20260610000003_rotate_cron_secret_to_vault.sql` | CRON_SECRET rotation |
| `docs/credential-cleanup-report.md` | Credential cleanup |
| `test/daily_closing_window_test.dart` | Daily close tests |
| `test/security_invoker_views_test.dart` | View leak tests |
| `test/provider_poll_guard_test.dart` | Poll guard tests |
| `test/router_role_guard_test.dart` | Route guard tests |
| `test/logout_state_reset_test.dart` | Logout reset tests |
| `test/cron_secret_rotation_test.dart` | CRON_SECRET tests |

### Modified files (9)
| File | Item |
|------|------|
| `supabase/migrations/20260609000000_…` | View leak (uncommitted patch) |
| `lib/features/order/order_provider.dart` | Poll guard |
| `lib/features/kitchen/kitchen_provider.dart` | Poll guard |
| `lib/features/table/table_provider.dart` | Poll guard |
| `lib/features/payment/payment_provider.dart` | Poll guard |
| `lib/features/admin/providers/tables_provider.dart` | Poll guard |
| `lib/core/router/app_router.dart` | Route guard |
| `lib/core/utils/role_routes.dart` | Route guard |
| `lib/features/auth/auth_provider.dart` | Logout reset |

---

## Remaining risks

1. **Historical daily closings:** Pre-fix closings excluded 00:00–06:59 HCMC sales. Run the commented historical audit query and decide backfill-or-cutover with Hyochang.
2. **Credential rotation not yet executed:** Accounts listed in `credential-cleanup-report.md` still have weak passwords until manually rotated.
3. **CRON_SECRET Vault insertion:** Must be done before applying migration 20260610000003 or cron jobs will fail (no secret to read).
4. **Route guard lockout risk:** If the `canAccessRouteForRole` matrix is missing a legitimate route for a role, that role gets redirected to home. The 38-test matrix covers all known routes. Manual walk-through with each role recommended.
5. **Polling staleness:** If realtime appears connected but drops events (zombie channel), screens now rely on the connectivity service's disconnect detection rather than a 2s safety net. The 15s fallback only kicks in when `_realtimeConnected` flips to false.

## Deployment checklist

### Pre-deploy (manual)
- [ ] Rotate all account passwords (see credential-cleanup-report.md)
- [ ] `git rm --cached` the xlsx file
- [ ] Generate new CRON_SECRET
- [ ] Set new CRON_SECRET in edge function env (dashboard)
- [ ] Insert into Vault: `INSERT INTO vault.secrets (name, secret, description) VALUES ('cron_secret', '<value>', 'cron auth')`

### Deploy SQL (in order)
- [ ] Apply `20260609000000_office_pos_sales_photo_objet_events.sql` (patched)
- [ ] Apply `20260610000001_fix_daily_closing_hcmc_window.sql`
- [ ] Apply `20260610000002_security_invoker_cross_tenant_views.sql`
- [ ] Apply `20260610000003_rotate_cron_secret_to_vault.sql`

### Post-deploy SQL verification
- [ ] `SELECT prosrc FROM pg_proc WHERE proname='create_daily_closing'` — contains `AT TIME ZONE`
- [ ] Run manual close on test store — totals match hand SUM
- [ ] `SELECT relname, reloptions FROM pg_class WHERE relname LIKE 'v_%'` — all secured views show security_invoker
- [ ] `SELECT jobname, command LIKE '%vault%' FROM cron.job` — all 4 WeTax jobs use vault
- [ ] Wait 2 min → check `cron.job_run_details` for success

### Deploy Flutter (single release)
- [ ] Build with poll guard + route guard + logout reset changes
- [ ] Manual smoke: order→kitchen→payment flow
- [ ] Manual: deep-link waiter to /cashier → redirected
- [ ] Manual: logout as admin, login as cashier on same device → no stale data
- [ ] Supabase dashboard: REST request rate drops within 1 hour

### Post-deploy
- [ ] Run historical daily closing audit query
- [ ] Decide backfill-or-cutover with Hyochang
- [ ] Redact `docs/vendor/samples/01_auth_login_plaintext.json` (P3)
