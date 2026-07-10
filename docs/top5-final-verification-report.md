# Top-5 Remediation — Final Verification Report

**Date:** 2026-06-10
**Branch:** `codex/pos-primary-job-phase5`
**Verifier:** Claude Code (post-implementation audit)

---

## 1. Daily Closing Fix

### 1.1 Timezone boundary correctness

**Migration:** `20260610000001_fix_daily_closing_hcmc_window.sql`

| Check | Result |
|-------|--------|
| `create_daily_closing` uses `AT TIME ZONE 'Asia/Ho_Chi_Minh'` | PASS |
| `get_admin_today_summary` uses `AT TIME ZONE 'Asia/Ho_Chi_Minh'` | PASS |
| Upper bound `v_day_end := v_day_start + INTERVAL '1 day'` present | PASS |
| All 4 metric queries use `< v_day_end` (half-open `[start, end)`) | PASS |
| No remaining `::TIMESTAMPTZ` cast in executable code | PASS |
| `get_daily_closings` verified clean (reads by `closing_date`, no time math) | PASS |
| Historical audit query included as comment | PASS |

### 1.2 Boundary logic

- `v_day_start` resolves to `2026-06-10 00:00:00+07` for closing_date `2026-06-10`
- `v_day_end` resolves to `2026-06-11 00:00:00+07`
- This captures the full HCMC business day including 00:00–06:59 (previously excluded)
- The `created_at < v_day_end` pattern avoids double-counting at the boundary

### 1.3 Rollback safety

Function replacement only — no schema changes. Revert by re-applying function body from `20260414000019`.

**Verdict: PASS**

---

## 2. Cross-Tenant View Security

### 2.1 View coverage

**Migration:** `20260610000002_security_invoker_cross_tenant_views.sql`
**Patched:** `20260609000000_office_pos_sales_photo_objet_events.sql`

| View | `security_invoker = true` | Method |
|------|--------------------------|--------|
| v_store_daily_sales | PASS | Direct ALTER |
| v_store_attendance_summary | PASS | Direct ALTER |
| v_inventory_status | PASS | Direct ALTER |
| v_brand_kpi | PASS | Direct ALTER |
| v_quality_monitoring | PASS | Direct ALTER |
| v_qsc_dashboard_summary | PASS | Direct ALTER |
| v_qsc_store_status | PASS | Direct ALTER |
| v_qsc_item_status | PASS | Direct ALTER |
| v_office_qsc_dashboard | PASS | Direct ALTER |
| v_office_qsc_store_latest | PASS | Direct ALTER |
| v_office_qsc_issue_queue | PASS | Direct ALTER |
| v_office_pos_sales_events | PASS | Conditional DO block + uncommitted migration patch |
| v_office_pos_sales_bucket_summary | PASS | Conditional DO block + uncommitted migration patch |

Total: 13 distinct views secured (11 direct + 2 conditional). The `stores` view is excluded (intentional — it's a dual-naming alias, not a data view).

### 2.2 Office app impact

Office app connects via `service_role` key (BYPASSRLS). `security_invoker` does not affect service_role connections — they bypass RLS regardless. **No impact on Office app.**

### 2.3 Conditional handling

The DO block in migration 20260610000002 checks `pg_class` for `v_office_pos_sales_events` existence. If 20260604001000 was applied but 20260609000000 was not, the conditional ALTER fires. If 20260609000000 was applied, those views already have `security_invoker` from the patched migration. Either path results in secured views.

### 2.4 Rollback safety

`ALTER VIEW ... SET (security_invoker = false)` per view. Instant, no data involved.

**Verdict: PASS**

---

## 3. CRON_SECRET Rotation

### 3.1 Migration correctness

**Migration:** `20260610000003_rotate_cron_secret_to_vault.sql`

| Check | Result |
|-------|--------|
| No hardcoded secret value in executable SQL | PASS |
| All 4 jobs unscheduled before reschedule | PASS |
| All 4 jobs rescheduled with `vault.decrypted_secrets` subquery | PASS |
| `format()` with `%L` for safe interpolation of base URL | PASS |
| Vault INSERT is commented out (placeholder, not real secret) | PASS |
| Verification queries included as comments | PASS |

### 3.2 Edge function compatibility

All 5 edge functions use `Deno.env.get("CRON_SECRET")`. The Vault secret feeds the `Authorization: Bearer` header in the cron job HTTP call. The edge function reads the same secret from its environment. No edge function code changes needed — the rotation is transparent.

### 3.3 Manual prerequisites

Before applying this migration:
1. Generate new CRON_SECRET value
2. Set it in edge function env (Supabase dashboard → Functions → Secrets)
3. Insert into Vault: `INSERT INTO vault.secrets (name, secret, description) VALUES ('cron_secret', '<value>', 'cron auth')`

**If the Vault INSERT is not done before applying the migration, all 4 cron jobs will fail** (the `vault.decrypted_secrets` subquery returns NULL, and the HTTP call gets rejected).

### 3.4 Rollback safety

Generate another secret, insert into both Vault and edge function env, re-run migration. Never revert to the leaked value.

**Verdict: PASS (requires manual Vault insertion before deploy)**

---

## 4. Polling Reduction

### 4.1 Provider coverage

| Provider file | `_realtimeConnected` guard | Timer cancel when connected | `_fallbackPollInterval` (15s) | No `Timer.periodic(_autoRefreshInterval)` |
|---------------|---------------------------|---------------------------|------------------------------|------------------------------------------|
| order_provider.dart | PASS | PASS | PASS | PASS |
| kitchen_provider.dart | PASS | PASS | PASS | PASS |
| table_provider.dart | PASS | PASS | PASS | PASS |
| payment_provider.dart | PASS | PASS | PASS | PASS |
| admin/providers/tables_provider.dart | PASS | PASS | PASS | PASS |

### 4.2 Pattern consistency

All 5 providers follow the identical pattern:
```dart
void _ensureAutoRefresh(String storeId) {
  if (_realtimeConnected) {
    _pollTimer?.cancel();
    _pollTimer = null;
    return;
  }
  if (_pollTimer != null && _pollStoreId == storeId) return;
  _pollTimer?.cancel();
  _pollStoreId = storeId;
  _pollTimer = Timer.periodic(_fallbackPollInterval, ...);
}
```

### 4.3 `_autoRefreshInterval` cleanup

- `order_provider.dart`: removed (was unused after change)
- `tables_provider.dart` (admin): removed (was unused after change)
- `kitchen_provider.dart`: kept (still used in `Future.delayed` at subscribe)
- `table_provider.dart`: kept (still used in `Future.delayed` at subscribe)
- `payment_provider.dart`: kept (still used in `Future.delayed` at subscribe)

`flutter analyze` confirms no unused variable warnings.

### 4.4 Risk assessment

If realtime appears connected but silently drops events (zombie channel), screens rely on the connectivity service's disconnect detection to flip `_realtimeConnected` to false. The 15s fallback only activates after that flip. This is the same trade-off accepted in the existing `payment_detail_screen.dart` reference implementation.

**Verdict: PASS**

---

## 5. Route Guard + Logout State Reset

### 5.1 Route guard

**Files:** `app_router.dart`, `role_routes.dart`

| Check | Result |
|-------|--------|
| Fall-through `canAccessRouteForRole` guard added before `return null` | PASS |
| Guard uses `auth.extraPermissions` for QC routes | PASS |
| `/privacy-consent` added to always-allowed routes | PASS |
| `/login`, `/`, `/privacy-consent` bypass role check | PASS |
| Guard redirects to `homeRouteForRole(role)` on denial | PASS |

Role matrix verified (38 tests):
- super_admin: `/super-admin`, `/admin/*`, `/payments/*`, `/photo-ops`
- admin/brand_admin/store_admin: `/admin`, `/payments/*`
- waiter: `/waiter` only
- kitchen: `/kitchen` only
- cashier: `/cashier`, `/payments/*`
- photo_objet roles: `/photo-ops` only
- Admin-like roles get implicit QC access; non-admin roles need `extraPermissions`

### 5.2 Logout state reset

**File:** `auth_provider.dart`

| Check | Result |
|-------|--------|
| `AuthNotifier` accepts `onLogout` callback | PASS |
| `logout()` calls `onLogout?.call()` after `signOut()` | PASS |
| Provider definition wires `ref.invalidate(...)` for 12 providers | PASS |

Providers invalidated: `orderProvider`, `paymentProvider`, `kitchenProvider`, `waiterTableProvider`, `staffProvider`, `attendanceProvider`, `settingsProvider`, `recipeProvider`, `ingredientProvider`, `qcCheckProvider`, `qcTemplateProvider`, `photoOpsProvider`.

### 5.3 Ordering correctness

`signOut()` completes before `onLogout?.call()` fires. This ensures the Supabase session is cleared before providers are invalidated, preventing any provider from accidentally re-fetching with the old session during teardown.

### 5.4 Rollback safety

Two independent reverts possible:
- Route guard: revert `app_router.dart` + `role_routes.dart`
- Logout reset: revert `auth_provider.dart`

**Verdict: PASS**

---

## 6. Test Review

### 6.1 New test files (6 files, 95 remediation-specific tests)

| Test file | Tests | Status |
|-----------|-------|--------|
| daily_closing_window_test.dart | 7 | ALL PASS |
| security_invoker_views_test.dart | 15 | ALL PASS |
| provider_poll_guard_test.dart | 15 | ALL PASS |
| router_role_guard_test.dart | 38 | ALL PASS |
| logout_state_reset_test.dart | 14 | ALL PASS |
| cron_secret_rotation_test.dart | 6 | ALL PASS |

### 6.2 Full suite

```
flutter test: 307 pass, 2 fail
flutter analyze: No issues found
```

### 6.3 Pre-existing failures (not caused by this change)

| Test | File |
|------|------|
| waiter floor table cards show active order menu previews | waiter_floor_layout_contract_test.dart |
| cashier payment queue follows kitchen served handoff | cashier_waiter_workspace_i18n_contract_test.dart |

Both fail identically on the clean branch before any remediation changes. **These are pre-existing and unrelated.**

**Verdict: PASS**

---

## 7. Deployment Readiness

### 7.1 SQL migration ordering

| Order | Migration | Dependencies |
|-------|-----------|-------------|
| 1 | 20260609000000 (patched) | None — creates new views + applies security_invoker |
| 2 | 20260610000001 | None — replaces functions only |
| 3 | 20260610000002 | 20260609000000 must be applied first (conditional DO block) |
| 4 | 20260610000003 | Vault secret must exist before apply |

No circular dependencies. Migrations 1 and 2 are independent. Migration 3 depends on 1. Migration 4 depends on manual Vault insertion.

### 7.2 Manual prerequisites before deploy

| Prerequisite | Blocking migration |
|-------------|-------------------|
| Generate new CRON_SECRET | 20260610000003 |
| Set CRON_SECRET in edge function env | 20260610000003 |
| INSERT into vault.secrets | 20260610000003 |
| Rotate account passwords | None (recommended before go-live) |
| `git rm --cached` xlsx file | None (recommended before merge) |

### 7.3 Post-deploy verification steps

1. `SELECT prosrc FROM pg_proc WHERE proname='create_daily_closing'` — confirm `AT TIME ZONE` present
2. Run manual close on test store — verify totals include 00:00–06:59 HCMC sales
3. `SELECT relname, pg_options_to_table(reloptions) FROM pg_class WHERE relname LIKE 'v_%'` — all views show `security_invoker=true`
4. `SELECT jobname, command LIKE '%vault%' FROM cron.job` — all 4 WeTax jobs use Vault
5. Wait 2 minutes → `SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10` — confirm 200 status
6. Manual smoke: order → kitchen → payment flow
7. Manual: deep-link waiter to `/cashier` → confirm redirect to `/waiter`
8. Manual: logout as admin, login as cashier → confirm no stale admin data

### 7.4 Rollback plan

Each item is independently revertible:
- Daily close: re-apply function body from 20260414000019
- Views: `ALTER VIEW ... SET (security_invoker = false)` per view
- CRON_SECRET: generate new secret, re-insert to Vault + env
- Polling: `git revert` Flutter changes (client-side only)
- Route guard / logout: `git revert` Flutter changes (client-side only)

---

## Conclusion

### READY AFTER MANUAL SECRET ROTATION

All code changes are verified correct. The 3 SQL migrations and 9 modified Flutter files implement the Top-5 remediation plan as specified, with 95 new tests passing and zero regressions introduced.

**Before deploying migration 20260610000003**, the following manual steps must be completed:

1. Generate a new CRON_SECRET value
2. Set it in Supabase dashboard → Functions → Secrets
3. Insert into Vault: `INSERT INTO vault.secrets (name, secret, description) VALUES ('cron_secret', '<value>', 'cron auth')`

Migrations 20260609000000 (patched), 20260610000001, and 20260610000002 can be deployed immediately without prerequisites.

**Recommended but not blocking:** rotate account passwords and `git rm --cached` the xlsx file before merging to main.
