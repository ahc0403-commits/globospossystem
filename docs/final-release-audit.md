# FINAL RELEASE AUDIT

**Date:** 2026-06-10
**Branch:** `codex/pos-primary-job-phase5`
**Auditor:** Claude Code (independent production deployment audit)
**Method:** Direct source code verification — no prior reports trusted

---

## Executive Summary

**GO — after completing manual secrets prerequisites**

**Confidence: 94%**

All code changes are correct, all security improvements are real, and all 309 tests pass. The 2 test regressions identified in the initial audit have been fixed. Credentials in `credential-cleanup-report.md` have been redacted. SQL migrations are safe. Flutter architecture changes are well-structured. No security vulnerabilities were introduced by these changes.

---

## Verification Report Review

**File:** `docs/top5-final-verification-report.md`

### Findings

| Statement in Report | Verified? | Evidence |
|---------------------|-----------|----------|
| Daily closing uses AT TIME ZONE 'Asia/Ho_Chi_Minh' | TRUE | `20260610000001:56` — `v_closing_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'` |
| Upper bound v_day_end used in all 4 queries | TRUE | Lines 76, 85, 98, 108 all use `< v_day_end` |
| get_admin_today_summary also fixed | TRUE | Line 210 — same AT TIME ZONE pattern |
| get_daily_closings verified clean | TRUE | Reads from table by closing_date, no time boundary math |
| 13 views secured with security_invoker | TRUE | 11 ALTER VIEW + 2 conditional DO block |
| Office app unaffected by security_invoker | TRUE | service_role bypasses RLS regardless |
| No hardcoded secret in executable SQL (migration 3) | TRUE | Only in comments (line 101) |
| Edge functions use Deno.env.get | TRUE | Verified in test, edge function files exist |
| 5 providers have poll guard | TRUE | All 5 verified: identical pattern |
| Fall-through canAccessRouteForRole guard added | TRUE | `app_router.dart:174-182` |
| 12 providers invalidated on logout | TRUE | `auth_provider.dart:391-402` |
| **307 pass, 2 pre-existing failures** | **FALSE** | **Both failures are caused by the poll guard changes** |

### Accuracy Assessment

**MOSTLY ACCURATE with one critical factual error.** The report claims the 2 failing tests (`waiter_floor_layout_contract_test.dart` and `cashier_waiter_workspace_i18n_contract_test.dart`) are "pre-existing and unrelated." This is wrong:

- `waiter_floor_layout_contract_test.dart:66` asserts `Timer.periodic(_autoRefreshInterval` in `table_provider.dart` — this was changed to `Timer.periodic(_fallbackPollInterval` by the poll guard remediation.
- `cashier_waiter_workspace_i18n_contract_test.dart:195` asserts the same pattern in `payment_provider.dart` — also changed by the poll guard remediation.

**The claim that stashing changes reproduces the failures is impossible** — stashing would restore `_autoRefreshInterval` in `Timer.periodic`, making these tests pass again.

---

## Remediation Validation

### Item 1: Credential Rotation / Account Cleanup

**Status: VERIFIED**

**Evidence:** `docs/credential-cleanup-report.md` correctly identifies all accounts, the xlsx file, the CRON_SECRET, and vendor samples. No credentials are committed in code. The report is action-oriented with clear steps.

**Risk:** Low. This is documentation for manual execution, not code.

---

### Item 2: Daily Closing 07:00 Bug

**Status: VERIFIED**

**Evidence:**
- Original bug confirmed in `20260414000019:63` — `v_closing_date::TIMESTAMPTZ` resolves midnight UTC = 07:00 HCMC
- Fix at `20260610000001:56` — `v_closing_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'` correctly resolves midnight HCMC
- Upper bound `v_day_end := v_day_start + INTERVAL '1 day'` at line 57 creates proper `[00:00, 24:00)` HCMC window
- All 4 metric queries (orders, items_cancelled, payments, service_payments) use `>= v_day_start AND < v_day_end`
- `get_admin_today_summary` has the same fix at line 210-211
- `DROP FUNCTION IF EXISTS` before `CREATE OR REPLACE` at lines 9 and 166 — safe, handles signature changes
- Functions are `SECURITY DEFINER` with `SET search_path = public, auth` — correct, matches original
- Historical audit query included as comment — correct approach for data reconciliation

**Risk:** Low. Pure function replacement, no schema changes. Instant rollback.

---

### Item 3: Cross-Tenant View Leak

**Status: VERIFIED**

**Evidence:**
- 11 ALTER VIEW statements in `20260610000002:6-23` — all correct
- 2 conditional ALTER VIEW statements in DO block at `20260610000002:28-42` — handles migration ordering edge case
- 2 views secured in-place in `20260609000000:246-247` — placed after view creation, before grants
- `pg_notify('pgrst', 'reload schema')` at line 44 — ensures PostgREST picks up changes
- Original migrations (`20260405000003`, `20260405000012`, `20260507000002`, `20260507000006`) confirmed to lack security_invoker (grep returns empty)
- `stores` view is NOT included — correct, it's a dual-naming alias, not a data view with authenticated grants

**Risk:** Low. `ALTER VIEW SET (security_invoker = true)` is instant, no data involved. Rollback is `SET (security_invoker = false)`.

**Note:** The `v_office_pos_sales_bucket_summary` depends on `v_office_pos_sales_events`. Both are secured. The bucket summary is created via `SELECT ... FROM v_office_pos_sales_events`, so its `security_invoker` flag means it runs as the caller, which then hits the inner view also as the caller. Correct chain — no bypass.

---

### Item 4: CRON_SECRET Rotation

**Status: VERIFIED**

**Evidence:**
- All 4 jobs unscheduled at `20260610000003:31-34`
- All 4 rescheduled with `vault.decrypted_secrets` subquery at lines 37-95
- `format($cmd$ ... %L ... $cmd$, v_base_url)` pattern correctly uses `%L` for safe SQL literal quoting of base URL
- Vault INSERT is commented out at line 20 with `REPLACE_WITH_NEW_SECRET` placeholder — no real secret in code
- `ON CONFLICT (name) DO UPDATE` in the commented INSERT — correct upsert pattern
- Old secret (now rotated) exists in `20260413001843:28,43,58,73` — this is in git history and cannot be purged. The rotation makes it dead.

**Risk:** Medium. `cron.unschedule` will throw if a job name doesn't exist. The DO block wraps all 4 in a single transaction — if any unschedule fails, the entire migration fails. This is actually safe since the jobs were created in `20260413001843`. However, if this migration is run twice (e.g., retry after partial failure), the second run would fail because the old jobs are already gone and the new ones exist. **Not idempotent.** Mitigation: Supabase migration tracking prevents double-run.

**Critical prerequisite:** Vault secret must exist BEFORE this migration runs, or all 4 cron jobs will execute with a NULL bearer token and get rejected by edge functions.

---

### Item 5: Polling Reduction

**Status: PARTIALLY VERIFIED**

**Evidence:**
- All 5 providers have correct `_ensureAutoRefresh` guard pattern — verified
- `_realtimeConnected` check, timer cancel, `_fallbackPollInterval` usage — all correct
- `_autoRefreshInterval` removed from `Timer.periodic` in all 5 providers — correct
- `_autoRefreshInterval` retained for `Future.delayed` in 3 providers (kitchen, table, payment) — correct, still used for initial subscribe fallback

**Issue:** Two existing contract tests assert `Timer.periodic(_autoRefreshInterval` and now fail. These are NOT pre-existing failures — they are regressions caused by this change. The contract tests must be updated to assert `Timer.periodic(_fallbackPollInterval`.

**Risk:** Low for the code change itself. **Medium for deployment** because the test suite has 2 regressions that must be fixed first.

---

### Item 6: Route Guard + Logout State Reset

**Status: VERIFIED**

**Evidence:**

*Route guard:*
- `canAccessRouteForRole` at `role_routes.dart:15-49` — complete role matrix, handles null role, public routes, QC permissions
- Fall-through guard at `app_router.dart:174-182` — catches any route not handled by prior special-case blocks
- `/privacy-consent` at `role_routes.dart:23` — correctly in always-allowed list
- `super_admin` at `/admin` is handled by special-case redirect at `app_router.dart:88` before reaching the fall-through — no conflict
- Route guard correctly uses `auth.extraPermissions` for QC routes

*Logout state reset:*
- `AuthNotifier({this.onLogout})` at `auth_provider.dart:37` — callback pattern
- `onLogout?.call()` at `auth_provider.dart:183` — called after `signOut()` and `NavigationHistoryService.instance.clear()` and `state = const PosAuthState()`
- 12 providers invalidated at `auth_provider.dart:391-402`
- `tablesProvider` (admin) is NOT invalidated but is `autoDispose.family` — self-cleans when no longer watched. Acceptable.

**Risk:** Low. Route guard is additive (doesn't remove existing checks, adds a catch-all). Logout reset uses `ref.invalidate()` which is the canonical Riverpod pattern.

---

## Migration Review

### Safe for Immediate Deployment

| Migration | Risk | Notes |
|-----------|------|-------|
| `20260609000000` (patched) | Low | Transaction-wrapped, `security_invoker` + view creation in single commit. Must apply before `20260610000002`. |
| `20260610000001` | Low | Pure function replacement, no schema changes. `DROP + CREATE OR REPLACE` is safe. |
| `20260610000002` | Low | `ALTER VIEW SET OPTIONS` is instant, non-blocking. Conditional DO block handles migration ordering. |

### Requires Manual Intervention

| Migration | Prerequisite | Risk if Skipped |
|-----------|-------------|-----------------|
| `20260610000003` | 1. Generate new CRON_SECRET<br>2. Set in edge function env<br>3. INSERT into vault.secrets | All 4 cron jobs fail with NULL token. WeTax dispatch, polling, daily close, and commons refresh stop working. |

### Do Not Deploy

None. All migrations are safe given prerequisites.

### Rollback Considerations

| Migration | Rollback Method | Duration | Risk |
|-----------|----------------|----------|------|
| `20260610000001` | Re-run function body from `20260414000019` | Instant | Low — but daily closings revert to buggy 07:00 boundary |
| `20260610000002` | `ALTER VIEW ... SET (security_invoker = false)` per view | Instant | Low — but cross-tenant leak reopens |
| `20260610000003` | Generate new secret, re-insert to Vault + env | 5 min | Medium — downtime during rotation |
| `20260609000000` | DROP views + re-run previous version | Low | Must happen before 20260610000002 rollback |

### Idempotency Assessment

- `20260610000001`: **Idempotent.** `DROP FUNCTION IF EXISTS` + `CREATE OR REPLACE`. Safe to re-run.
- `20260610000002`: **Idempotent.** `ALTER VIEW SET OPTIONS` is a no-op if already set. Conditional DO block checks existence.
- `20260610000003`: **NOT idempotent.** `cron.unschedule` throws if job doesn't exist (already unscheduled on first run). Second run fails. Mitigated by Supabase migration tracking.

---

## Flutter Architecture Review

### Findings

**Logout flow** — Correct ordering:
1. `supabase.auth.signOut()` (clears session)
2. `NavigationHistoryService.instance.clear()` (clears nav state)
3. `state = const PosAuthState()` (clears auth state)
4. `onLogout?.call()` (invalidates 12 providers)

This ordering prevents any provider from accidentally re-fetching with the old session during teardown.

**Auth state transitions** — The `_init()` method subscribes to `supabase.auth.onAuthStateChange`. On `signedOut`, it clears state and applies `_pendingSignedOutErrorMessage`. This pattern correctly handles both voluntary logout and forced sign-out (deactivated account, permission denied).

**Provider invalidation** — Uses `ref.invalidate()` in the `onLogout` callback. This is the correct Riverpod pattern — it disposes the notifier (triggering timer cancellation in `dispose()`) and creates a fresh instance on next access. **The `tablesProvider` is not invalidated** but uses `autoDispose.family`, so it self-cleans when the admin screen is unmounted. Acceptable.

**Realtime subscriptions** — All 5 providers properly handle:
- Channel unsubscription in `dispose()`
- Timer cancellation in `dispose()`
- `mounted` checks before state updates in callbacks
- `_realtimeConnected` flag tracking

**Payment provider dual-channel edge case** — `_realtimeConnected` is shared between `_ordersChannel` and `_paymentsChannel`. If one channel disconnects while the other stays connected, the flag goes false and the fallback poll timer starts. This is conservative (polls unnecessarily) rather than optimistic (misses data). Pre-existing design; not introduced by these changes.

### Risks

1. **Race condition (theoretical, low severity):** In `order_provider.dart`, `_ensureAutoRefresh` is called from the realtime subscribe callback (async) and from `_subscribeOrderItems` (sync). If the subscribe callback fires while `_subscribeOrderItems` is still setting up, the timer state could be momentarily inconsistent. In practice, the subscribe callback fires after `_subscribeOrderItems` returns, so this doesn't manifest.

2. **Zombie channel risk (documented, accepted):** If realtime appears connected but silently drops events, screens rely on the connectivity service to detect the disconnect. The 15s fallback only activates after `_realtimeConnected` flips false. This is the same trade-off accepted in the existing `payment_detail_screen.dart` reference implementation.

### Recommendations

No code changes recommended for architecture. The patterns are consistent and well-structured.

---

## Security Review

### Critical

None.

### High

**H1: CRON_SECRET in git history** — The old value (now rotated) is in `supabase/migrations/20260413001843:28,43,58,73`. Git history cannot be purged from Supabase migration tracking. The rotation to Vault makes this dead, but the value is permanently exposed. **Mitigation: rotation makes it non-exploitable. No additional action required beyond completing the rotation.**

### Medium

**M1: Verification comment references old secret prefix** — `20260610000003:101` contains `WHERE command LIKE '%8689bac6%'` in a comment. Not exploitable (comments don't execute), but the prefix is in cleartext. **No action required** — it's needed for manual verification.

**M2: credential-cleanup-report.md — RESOLVED** — Plaintext passwords redacted to `[REDACTED — shared weak password]`. All other doc files (`docs/manual_test/`, `docs/business-priority-review.md`, `docs/top5-remediation-plan.md`) also redacted in this branch.

### Low

**L1: vendor sample contains auth response** — `docs/vendor/samples/01_auth_login_plaintext.json` (noted in credential report, P3 priority).

**L2: SECURITY DEFINER functions** — Both `create_daily_closing` and `get_admin_today_summary` are `SECURITY DEFINER`. This is correct (they need to write to `audit_logs` and `daily_closings` which the caller might not have direct INSERT on), but any SQL injection in input handling would execute with definer privileges. The functions use parameterized queries exclusively (no string concatenation) — safe.

---

## Production Readiness Review

### Reliability

**Good.** The timezone fix eliminates a data correctness bug that would silently exclude 7 hours of sales per day. The `security_invoker` fix closes a real cross-tenant leak. The poll guard reduces unnecessary load. All changes are function replacements or ALTER VIEW — no schema changes that could cause data corruption.

### Scalability

**Improved.** The poll guard reduces baseline PostgREST requests from ~43,200/day/screen (2s poll) to near-zero when realtime is connected, with 15s fallback. This directly reduces Supabase costs under multi-store growth.

### Maintainability

**Good.** The poll guard pattern is identical across 5 providers — easy to understand and maintain. The `onLogout` callback is a clean extension point. The route guard fall-through is additive and won't break existing behavior.

### Operational Risk

**1 month:** Low. The main risk is the CRON_SECRET Vault migration — if the Vault secret is not inserted before migration push, all WeTax cron jobs fail. This is a one-time manual step.

**6 months:** Low-medium. The `_realtimeConnected` flag tracks only subscribe status, not message delivery health. If Supabase realtime degrades without fully disconnecting, screens may appear stale. This is a pre-existing design limitation, not introduced by these changes.

**Likely failure points:**
- New views added in future migrations without `security_invoker` — requires ongoing discipline
- New roles added without updating `canAccessRouteForRole` matrix — route guard will deny by default (safe failure)
- New providers added without adding to the `onLogout` invalidation list — stale state after re-login

**Cost implications:** Reduced. The poll guard directly lowers PostgREST request volume.

---

## Test Review

### 307/309 Validation

**CORRECTED.** After fixing the 2 test regressions identified in the initial audit:

```
flutter test: 309/309 pass, 0 failures
flutter analyze: No issues found
```

The 2 contract tests (`waiter_floor_layout_contract_test.dart:66`, `cashier_waiter_workspace_i18n_contract_test.dart:195`) were updated to assert `Timer.periodic(_fallbackPollInterval` matching the poll guard implementation.

### Failure Analysis

| Test | Assertion | Root Cause | Fix |
|------|-----------|-----------|-----|
| `waiter_floor_layout_contract_test.dart:66` | `contains('Timer.periodic(_autoRefreshInterval')` | `table_provider.dart` now uses `_fallbackPollInterval` in Timer.periodic | Update assertion to `_fallbackPollInterval` |
| `cashier_waiter_workspace_i18n_contract_test.dart:195` | `contains('Timer.periodic(_autoRefreshInterval')` | `payment_provider.dart` now uses `_fallbackPollInterval` in Timer.periodic | Update assertion to `_fallbackPollInterval` |

Both are 1-line fixes. The tests also assert `static const _autoRefreshInterval` at lines 64/193 — these still pass because the constant is retained (used in `Future.delayed`).

### Coverage Gaps

1. **No test for the payment provider's dual-channel `_realtimeConnected` behavior** — the shared flag between `_ordersChannel` and `_paymentsChannel` is untested. Pre-existing gap.
2. **No integration test for the actual timezone boundary** — the tests verify SQL patterns but don't execute SQL against a real database. This is acceptable for a migration-based fix (verified at deploy time).
3. **No test for `cron.unschedule` error on missing job** — if jobs don't exist, the migration fails. Covered by Supabase migration tracking preventing double-run.
4. **Route guard tests don't cover deep query parameters** — e.g., `/admin?tab=settings` passes through `canAccessRouteForRole` which parses `Uri.parse(location).path`, correctly extracting `/admin`. Covered by the URI parsing logic.

---

## Hidden Risk Scan

Risks **not mentioned** in the existing verification report:

1. **Credential exposure in docs — RESOLVED** — All plaintext passwords redacted across `docs/credential-cleanup-report.md`, `docs/manual_test/`, `docs/business-priority-review.md`, `docs/top5-remediation-plan.md`, `docs/supabase-architecture-review.md`, `docs/system-audit-report.md`, and this file.

2. **cron.unschedule is not idempotent** — Migration `20260610000003` will fail on re-run. Not a practical risk (Supabase tracks applied migrations), but notable for manual troubleshooting.

3. **No `pg_notify('pgrst', 'reload schema')` in migration 1** — `20260610000001` replaces functions but doesn't trigger PostgREST schema reload. This is fine — function replacements don't change the PostgREST schema cache (only view/table changes do).

4. **`onLogout` fires synchronously after `signOut` await** — If `ref.invalidate()` triggers a provider that re-fetches data, the Supabase session is already cleared, so the fetch will fail with an auth error. This is actually correct behavior (the provider is being disposed, not re-initialized), but if any invalidated provider has an eager initialization that fetches on create, it would briefly error before the router redirects to `/login`. Mitigated by the `mounted` checks in all providers.

5. **`tablesProvider` (admin) not invalidated on logout** — Uses `autoDispose.family`, so it self-cleans. But if the admin screen is still mounted during logout (brief window before router redirect), the provider remains alive with stale data. The router redirect unmounts it within one frame. Acceptable.

---

## Final Deployment Decision

**GO**

All code changes are correct, all 309 tests pass, no analyze issues, credentials redacted.

## Required Actions Before Production

**Priority 1 (DONE):**

- [x] Fix `test/waiter_floor_layout_contract_test.dart:66` — assertion updated
- [x] Fix `test/cashier_waiter_workspace_i18n_contract_test.dart:195` — assertion updated
- [x] 309/309 tests pass
- [x] Redact plaintext credentials in `docs/credential-cleanup-report.md`

**Priority 2 — Must complete before deploying migration 20260610000003:**

- [ ] Generate new CRON_SECRET value
- [ ] Set new CRON_SECRET in Supabase dashboard → Functions → Secrets
- [ ] `INSERT INTO vault.secrets (name, secret, description) VALUES ('cron_secret', '<value>', 'cron auth')`

**Priority 3 — Must complete before merge to main:**

- [x] Redact `docs/credential-cleanup-report.md` plaintext passwords — DONE
- [ ] `git rm --cached 'GLOBOS_POS_화면플로우_계정정보_2026-05-25.xlsx'`

**Priority 4 — Recommended before go-live:**

- [ ] Rotate all account passwords per credential-cleanup-report.md
- [ ] Redact `docs/vendor/samples/01_auth_login_plaintext.json`
- [ ] Run historical daily closing audit query on production
- [ ] Manual smoke test: each role deep-links to unauthorized route → confirm redirect
- [ ] Manual smoke test: logout as admin, login as cashier → confirm no stale data
- [ ] Monitor Supabase REST request rate for 1 hour after deploy → confirm poll reduction
