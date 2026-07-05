# Top-5 ROI Remediation Plan

- **Date:** 2026-06-10 · **Source:** `docs/business-priority-review.md` §4
- **Goal:** reduce operational risk before opening additional stores. All five items are scoped to complete **within one week**.
- **Status:** plan only — nothing implemented.
- **Suggested execution order:** Day 1: items 4a + 1 (and the 10-minute 2a). Day 2–3: items 2 + 3. Day 4: item 5. Day 5: validation sweep + item 1's historical audit decision.
- PR discipline per project convention: DB/RPC/Auth/Payment = 1 PR per risk. Items 1, 2 are one migration PR each; item 3 is one Flutter PR; item 5 is one Flutter PR; item 4 is operations work + one small migration PR.

---

## Item 1 — Daily Closing 07:00 Bug

**What:** `create_daily_closing` computes `v_day_start := v_closing_date::TIMESTAMPTZ`, which resolves midnight in the DB session timezone (UTC) = 07:00 HCMC. All four metric queries use `created_at >= v_day_start` with no upper bound. Sales 00:00–07:00 HCMC are excluded from every close.

**Files to modify**
- **New migration** (the only code change): `supabase/migrations/<timestamp>_fix_daily_closing_hcmc_window.sql`
  - Must `CREATE OR REPLACE` the **latest** definition, which lives in `supabase/migrations/20260414000019_contract_store_naming_daily_closing_admin_audit.sql:19-…` (bug at line 63) — NOT the original `20260410000000_daily_closing_snapshot.sql`. Copy the 20260414000019 body verbatim and change only:
    ```sql
    v_day_start := v_closing_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
    v_day_end   := v_day_start + INTERVAL '1 day';
    ```
    and add `AND created_at < v_day_end` (and `o.created_at < v_day_end`) to the four metric queries (lines 81, 89, 101, 110 pattern).
- **No Dart changes**: `lib/core/services/daily_closing_service.dart` and `lib/features/admin/providers/daily_closing_provider.dart` only call the RPC.
- **New test:** `test/daily_closing_window_test.dart` — at minimum a contract test asserting the new migration contains `AT TIME ZONE 'Asia/Ho_Chi_Minh'` and `< v_day_end`; ideally a SQL-level test on a Supabase branch DB: insert payments at 23:50 (prev day HCMC), 00:10, 06:50, 23:50 HCMC; run close; assert only the three in-window rows are counted.
- **Check while in there:** `get_admin_today_summary` (same file, line 328) and `get_daily_closings` (line 167) — verify whether they share the same `::TIMESTAMPTZ` boundary pattern; if yes, fix in the same migration (same risk class).

**Estimates:** implementation 2–3 h · testing 3–4 h (branch-DB scenario) · historical-audit query + business decision: 0.5–1 day (separate, non-blocking).

**Deployment risk: Medium.** The function change itself is safe (next close simply computes correctly), but the **discontinuity day** matters: the first close after deployment covers 00:00 HCMC onward, while the previous day's close already (wrongly) included 07:00–24:00 of *its* day — the boundary day double-counts nothing but the historical record is inconsistent. Decide explicitly: backfill recompute vs documented cutover date. Never silently rewrite history rows.

**Rollback:** re-apply the 20260414000019 function body (keep it saved as `rollback_create_daily_closing.sql` alongside the PR). Pure function swap — no schema/data change, rollback is instant.

**Validation checklist**
- [ ] Branch-DB scenario test passes (23:50/00:10/06:50/23:50 HCMC boundary cases)
- [ ] `SELECT prosrc FROM pg_proc WHERE proname='create_daily_closing'` on prod shows the HCMC expression
- [ ] Run one manual close on a test store; totals match a hand `SUM(amount)` over `[00:00, 24:00) HCMC`
- [ ] Historical audit query run: per-day delta between recorded closes and recomputed window; result shared with Hyochang
- [ ] Backfill-or-cutover decision recorded in the vault
- [ ] `get_admin_today_summary` / `get_daily_closings` checked for the same pattern

---

## Item 2 — Cross-Tenant View Leak (`security_invoker`)

**What:** seven owner-executed views granted to `authenticated` without `security_invoker = true` expose all stores' payments/refunds/attendance/inventory/QC to any logged-in user.

### 2a — TODAY, 10 minutes, before anything else
- **File to modify:** `supabase/migrations/20260609000000_office_pos_sales_photo_objet_events.sql` (**uncommitted — edit in place**, it has never been applied): add after each `CREATE OR REPLACE VIEW`:
  ```sql
  ALTER VIEW public.v_office_pos_sales_events SET (security_invoker = true);
  ALTER VIEW public.v_office_pos_sales_bucket_summary SET (security_invoker = true);
  ```

### 2b — This week, the already-live views
- **New migration:** `supabase/migrations/<timestamp>_security_invoker_office_monitoring_views.sql`:
  ```sql
  ALTER VIEW public.v_office_pos_sales_events         SET (security_invoker = true); -- if 20260604001000 already applied
  ALTER VIEW public.v_office_pos_sales_bucket_summary SET (security_invoker = true);
  ALTER VIEW public.v_store_daily_sales               SET (security_invoker = true);
  ALTER VIEW public.v_store_attendance_summary        SET (security_invoker = true);
  ALTER VIEW public.v_quality_monitoring              SET (security_invoker = true);
  ALTER VIEW public.v_inventory_status                SET (security_invoker = true);
  ALTER VIEW public.v_brand_kpi                       SET (security_invoker = true);
  ```
- **Pre-work (1 h):** sweep for *other* views with the same defect and for **dependents**: `v_quality_monitoring` was redefined in `20260507000002_qsc_v2_monitoring_views.sql:18` (grant at :358) and is wrapped by Office read-model views in `20260507000006_qsc_v2_office_read_model_views.sql` — each wrapper granted to `authenticated` needs `security_invoker` too (a secured inner view does not protect an owner-executed outer view). Sweep command: every `CREATE OR REPLACE VIEW` + `GRANT … TO authenticated` pair lacking `security_invoker`, using `299_deliberry_integration_security_closure.sql` as the reference pattern.
- **No Dart changes expected.** POS consumers of these views run as super_admin/store-scoped users whose RLS already permits their own rows.

**Estimates:** implementation 1–2 h (incl. sweep) · testing 3–4 h (role-by-role verification).

**Deployment risk: Medium.** Two failure modes: (a) a POS dashboard that silently relied on cross-store reads (super_admin is fine — RLS policies grant super_admin broad SELECT; store roles will now see only their store, which is the intended behavior); (b) the Office app — **unaffected** because it connects with service_role, which bypasses RLS regardless of `security_invoker`. Verify both anyway.

**Rollback:** `ALTER VIEW … SET (security_invoker = false);` per view — instant, no data involved. Keep as `rollback_security_invoker.sql` in the PR.

**Validation checklist**
- [ ] As `waiter@…` (or any store-scoped user) via PostgREST: `GET /rest/v1/v_office_pos_sales_events` returns ONLY own-store rows (before fix: all stores)
- [ ] Same check on all 7 views + the 20260507000006 wrappers
- [ ] As super_admin in the POS app: Super Admin → Stores/Reports/QC dashboards render with all stores
- [ ] As store admin: Admin → Reports/Inventory/QC tabs render own store
- [ ] Office app: master admin store list + sales pull + dashboard still work (service_role — expected unaffected)
- [ ] Sweep result documented: zero remaining `authenticated`-granted views without `security_invoker`

---

## Item 3 — Realtime/Polling Cost (2-second timers)

**What:** five providers run `Timer.periodic(2s)` full-reload polls that never check `_realtimeConnected`. Reference implementation of the correct pattern: `lib/features/payment/payment_detail_screen.dart:212-227`.

**Files to modify (Flutter only, no SQL)**
1. `lib/features/order/order_provider.dart:292-307` (`_ensureAutoRefresh`)
2. `lib/features/kitchen/kitchen_provider.dart:278-290`
3. `lib/features/table/table_provider.dart:189-196`
4. `lib/features/payment/payment_provider.dart:356-363`
5. `lib/features/admin/providers/tables_provider.dart:198-203`

Change per file: in `_ensureAutoRefresh`, cancel the poll timer when `_realtimeConnected == true`; (re)create it only when disconnected; raise the fallback interval 2 s → 10–15 s. Ensure the realtime subscribe/unsubscribe callbacks call `_ensureAutoRefresh` on every state change (they already toggle `_realtimeConnected`; the bug is the early-return that never re-evaluates the timer).

- **New test:** `test/provider_poll_guard_test.dart` — unit tests on each notifier: simulate `_realtimeConnected=true` → assert timer cancelled; simulate disconnect → assert timer restarts. If notifiers aren't injectable enough for that, a contract test asserting each `_ensureAutoRefresh` body references `_realtimeConnected` is the minimum bar.

**Estimates:** implementation 2–3 h · testing 3–4 h (unit + manual two-device smoke).

**Deployment risk: Low–Medium.** The risk is staleness, not breakage: if realtime *appears* connected but events are dropped (channel zombie), screens that previously self-healed every 2 s now wait for the 10–15 s fallback only when disconnected. Mitigations: keep the fallback timer alive at 10–15 s even when connected for the first release (still a 5–7× reduction), or trust the existing `payment_detail_screen` pattern that production has already exercised. Recommend: exact `payment_detail_screen` semantics (cancel when connected) + the connectivity service's existing disconnect detection.

**Rollback:** `git revert` of the single PR; client-side only, ships with the next app build. No server state involved.

**Validation checklist**
- [ ] Supabase dashboard: REST request rate per store drops ~10× within an hour of rollout (baseline screenshot taken before)
- [ ] Two-device test: order created on waiter device appears on kitchen/cashier screens < 2 s (realtime path)
- [ ] Airplane-mode test: cut network on kitchen device, restore — orders resync within the fallback interval
- [ ] Channel-kill test: restart realtime (or toggle wifi briefly) — `_realtimeConnected` flips and the timer restarts (logs/debug)
- [ ] No `Timer.periodic` under 10 s remains in the five files (`grep -rn "Duration(seconds: 2)" lib/`)
- [ ] Full payment flow smoke (order → kitchen → payment → receipt) on the release build

---

## Item 4 — Credential Rotation and Cleanup

**What:** three live secrets, one session. (a) Working logins (incl. POS superadmin and Office super) documented with the live URL in the tracked xlsx; (b) CRON_SECRET hardcoded in a committed migration — also gates the **production Deliberry settlement** functions; (c) WeTax test credentials in vendor samples (low priority — test-only).

### 4a — TODAY (~30 min, no deploy): rotate the documented accounts
- In **POS Supabase Auth** (`ynriuoomotxuwhuxxmhj`): change passwords or disable: `superadmin@globos.test`, `admin@globos.test`, `cashier@globos.test`, `waiter@globos.test`, `kitchen@globos.test`, `pos.validation.codex@globos.test`.
- In **Office Supabase Auth** (`raghsbaxcwrxlsacaoau`): `super@globos.vn`, `brand.mk@globos.vn`, `brand.kn@globos.vn`, `store@globos.vn`, `staff@globos.vn`, `office.store@globos.vn`, `office.brand.kn@globos.vn`, `office.brand.mk@globos.vn`, `office.staff@globos.vn`, `office.super@globos.vn`.
- Decision per account: still needed for testing → strong unique password stored in the vault (NOT in git); not needed → disable/delete. New passwords go in `~/Documents/restaurant-ops-vault/`, never the repo.
- Move `GLOBOS_POS_화면플로우_계정정보_2026-05-25.xlsx` out of the repo (`git rm --cached` + relocate to the vault). History scrubbing unnecessary once passwords rotate.

### 4b — This week: CRON_SECRET rotation
- **Files to modify:**
  - Supabase edge-function secrets: set new `CRON_SECRET` (functions read it from env: `generate-settlement/index.ts:14`, `generate_delivery_settlement/index.ts:27`, `wetax-dispatcher/index.ts:251`, `wetax-poller/index.ts:101`, `wetax-daily-close/index.ts:76` — **no code change needed** if they already read `Deno.env`; verify, otherwise update those 5 files).
  - **New migration:** `supabase/migrations/<timestamp>_rotate_cron_secret.sql` — for each job (`wetax-dispatcher-every-minute`, `wetax-poller-every-2-minutes`, `wetax-daily-close-00-hcmc`, `wetax-commons-refresh-weekly`, plus the settlement jobs `generate-settlement-biweekly` etc. — enumerate via `SELECT jobname FROM cron.job`): `cron.unschedule(name)` then re-`cron.schedule` with the new bearer read from Vault (`vault.decrypted_secrets`) or, minimally, the new literal **applied directly via SQL editor and NOT committed** — with the committed migration containing a placeholder comment. Prefer the Vault read so the migration stays committable.
  - Optional, recommended while in there: `cron.unschedule('wetax-commons-refresh-weekly')` — it 401s every week anyway (auth mismatch, see risk register R-09); silence it until WeTax activation.
- **Sequence (avoids any gap):** set new secret in function env (functions accept it immediately) → update cron job commands → confirm next tick succeeds → old value is dead.
- `docs/vendor/samples/01_auth_login_plaintext.json`: redact the password/token fields; rotate the WeTax apitest account password at the vendor at convenience (test-only — P3).

**Estimates:** implementation 4a: 30 min; 4b: 2–3 h · testing 1–2 h (watch cron ticks).

**Deployment risk: Low (4a) / Medium (4b).** 4a risk: a forgotten automation logging in with an old test password (the integration smoke test `integration_test/full_multi_account_smoke_test.dart` and any CI use these creds — update its credential source the same day). 4b risk: a window where cron sends the old secret to functions expecting the new one → settlements/dispatch skip a tick or two. The sequence above eliminates it if functions compare against env at request time; verify before starting. Settlement jobs are biweekly — schedule the rotation away from a settlement day.

**Rollback:** 4a: reset passwords again (no rollback concept needed). 4b: re-point cron + env to a freshly generated secret (never back to the leaked one). Keep `SELECT jobid, jobname, command FROM cron.job` output captured before changes.

**Validation checklist**
- [ ] Old shared weak passwords fail on the live URL for every listed account (spot-check 3+)
- [ ] New credentials stored in the vault; xlsx removed from git index and relocated
- [ ] Integration smoke test updated and passing with new credential source
- [ ] `cron.job` shows no command containing the old secret prefix
- [ ] Next dispatcher/poller tick returns 200 (check `cron.job_run_details` / function logs)
- [ ] Manual POST with the OLD secret to `generate-settlement` returns 401
- [ ] `git grep` for the old secret prefix returns only the historical migration (and the new migration has no literal secret)
- [ ] Vendor sample file redacted; WeTax test password rotation ticketed

---

## Item 5 — Route Guard + Logout State Reset

**What:** (a) router enforces the role matrix only on `/payments/`; any role can deep-link to `/cashier`, `/waiter`, `/kitchen`. (b) `logout()` resets only auth state; ~20 app-lifetime StateNotifiers keep the previous user's cart/payment/report state on shared terminals.

**Files to modify (Flutter only, no SQL)**
1. `lib/core/utils/role_routes.dart` — first, extend `canAccessRouteForRole()` so it returns correct results for every route the redirect currently special-cases (super_admin on `/qc-review`/`/qc-check`, admin store-scoped paths, `/photo-ops`, onboarding/auth paths). The matrix must become the single source of truth before the router trusts it.
2. `lib/core/router/app_router.dart:88-176` — replace the final `return null` fall-through with: `if (!canAccessRouteForRole(role, fullLocation, extraPermissions: auth.extraPermissions)) return homeRouteForRole(role);`. Keep the existing special cases initially (belt-and-braces), remove them in a later cleanup once the test below is trusted.
3. `lib/features/auth/auth_provider.dart:168-172` (`logout()`, and the error-path sign-out if separate) — invalidate session-scoped providers. Mechanism: a `ref.invalidate(...)` sweep over the known list (`orderProvider`, `paymentProvider`, `kitchenProvider`, `tableProvider`, `tablesProvider`, `reportProvider`, `staffProvider`, `settingsProvider`, `recipeProvider`, `qcCheckProvider`, `photoOpsProvider`, inventory/inventory-purchase providers from `lib/features/inventory/inventory_provider.dart`), or cleaner: introduce `final sessionEpochProvider = StateProvider<int>(...)`, bump it on logout, and have session notifiers watch it. For one week of scope, the explicit invalidate list is fine; add a comment that new session providers must be added to it.
4. **New tests:**
   - `test/router_role_guard_test.dart` — table-driven: for each role × each route in the matrix, pump the router redirect and assert allowed/redirected. This is the test that lets you delete the special-case ifs later.
   - `test/logout_state_reset_test.dart` — populate `orderProvider`/`paymentProvider` state in a `ProviderContainer`, call logout, assert state is back to initial.

**Estimates:** implementation 4–6 h (matrix correctness is the real work) · testing 4–5 h (the role × route table + manual multi-role walk).

**Deployment risk: Medium.** Highest-regression-risk item of the five: an over-strict matrix locks a legitimate role out of its own screen (e.g. admin opening `/payments/...` detail, super_admin drilling into `/admin/:storeId` — that scoped-override flow is documented in the xlsx flow sheets and must keep working). The table-driven test plus a manual pass with each of the six roles from sheet 2 is the defense. Logout invalidation risk: invalidating a provider something still watches mid-teardown → transient errors on the login screen; invalidate AFTER `signOut()` completes and navigation lands on `/login`.

**Rollback:** `git revert` the PR (client-only). The two changes are independent — if only one misbehaves, revert is per-commit (keep route guard and logout reset as separate commits in the PR).

**Validation checklist**
- [ ] Role × route table test passes for: waiter, kitchen, cashier, admin, super_admin (+ extraPermissions variants qc_check/qc_visit_review)
- [ ] Manual: waiter deep-links `/cashier` → redirected to `/waiter`; kitchen → `/waiter` blocked; cashier → `/admin` blocked
- [ ] Manual: admin reaches all Admin tabs; super_admin reaches `/super-admin` AND `/admin/:storeId` scoped override; QC-permission users reach `/qc-check`/`/qc-review`
- [ ] Payment detail route still reachable by cashier/admin (existing `/payments/` guard semantics unchanged)
- [ ] Logout/login as different role on the same device: no stale cart, table status, report data, or selected store (walk waiter→cashier→admin)
- [ ] Logout completes with no provider-disposal errors in console
- [ ] `integration_test/full_multi_account_smoke_test.dart` passes (it exercises multi-account switching — closest existing coverage)

---

## Week summary

| # | Item | Impl | Test | Deploy risk | SQL migrations |
|---|------|------|------|-------------|----------------|
| 1 | Daily close window | 2–3 h | 3–4 h (+1 d audit) | Medium (history discontinuity) | 1 new (replaces fn from `20260414000019`) |
| 2 | View leak | 1–2 h | 3–4 h | Medium (dashboard verify) | 1 new + edit uncommitted `20260609000000` |
| 3 | Polling | 2–3 h | 3–4 h | Low–Medium (staleness) | none |
| 4 | Credentials | 3–4 h | 1–2 h | Low/Medium (cron tick gap) | 1 new (cron re-schedule via Vault) |
| 5 | Guard + logout | 4–6 h | 4–5 h | Medium (lockout regression) | none |

Total: roughly 3.5–4.5 working days including validation — fits one week with buffer. Items 1+2+4 are server-side (effective immediately on deploy); items 3+5 ship with the next app build — cut one release containing both Flutter PRs at end of week.
