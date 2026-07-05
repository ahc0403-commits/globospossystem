# GLOBOSVN POS — Refactoring Roadmap

- **Date:** 2026-06-10 · **Status:** plan only — no code changed; large-scale changes require approval (per audit brief Step 5)
- PR sizing follows the established convention: DB/RLS/Auth/RPC/Payment changes strictly 1-PR-1-risk; same-risk-class small UI/util changes bundled.

## Overall shape

Four waves. Wave 0 is security-critical and small — it should ship before or alongside any production go-live. Waves 1–2 are targeted fixes with tests. Wave 3 is structural refactoring done opportunistically. Nothing here adds features.

---

## Wave 0 — Production blockers (≈ 1 week, 6 small PRs)

| PR | Change | Files | SQL? |
|----|--------|-------|------|
| 0.1 | `security_invoker = true` on 7 leaking views (incl. fixing the **uncommitted** `20260609000000` before it is applied) | 1 new migration + edit uncommitted migration | ✅ |
| 0.2 | Rotate CRON_SECRET → Vault/runtime lookup; `cron.alter_job`; scrub history (`git filter-repo`, coordinate with all clones) | 1 migration + Supabase secrets | ✅ |
| 0.3 | Redact `docs/vendor/samples/01_auth_login_plaintext.json`; rotate WeTax test account; audit `GLOBOS_POS_화면플로우_계정정보_2026-05-25.xlsx` for credentials (scrub if present, move to vault either way) | docs | — |
| 0.4 | Router: enforce `canAccessRouteForRole` as the redirect fall-through (update matrix for super_admin QC paths first) + per-role routing test | `app_router.dart`, `role_routes.dart`, new test | — |
| 0.5 | Poll-timer realtime guard in 5 providers (copy `payment_detail_screen.dart:212-227` pattern; fallback 10–15 s) | 5 provider files | — |
| 0.6 | `wetax-onboarding`: drop cashier from allowlist, store/brand-scope writes; fix `commons_refresh` cron auth | 1 edge function (+ optionally cron migration) | (✅) |

**Risky parts of Wave 0:** history scrubbing (coordinate clones); view grants (verify POS super_admin dashboards and Office pulls still work — Office uses service_role, so it is unaffected by `security_invoker`).

## Wave 1 — Money-path correctness (≈ 1–2 weeks, 5 PRs, each 1-risk)

| PR | Change | SQL? | Verify |
|----|--------|------|--------|
| 1.1 | **Daily-close window fix** (`create_daily_closing` HCMC boundary + upper bound) — write the behavioral test FIRST (red), fix (green); then audit historical `daily_closings` for understatement and decide backfill with Hyochang | ✅ | new `daily_closing` tests; recompute one known day by hand |
| 1.2 | Dispatcher job claiming: `claim_einvoice_jobs` RPC (`FOR UPDATE SKIP LOCKED`) + dispatcher uses it; conditional UPDATE in `admin_retry_einvoice_job`/`admin_mark_resolved` | ✅ | concurrent-run test via two simultaneous invocations on a branch DB |
| 1.3 | `einvoice_jobs` indexes + `UNIQUE(order_id)` (confirm no legitimate re-issue flow creates a second job first) | ✅ | `EXPLAIN` dispatcher query |
| 1.4 | Extract `supabase/functions/_shared/wetax.ts` (decodeByteaToString, getToken w/ encryption path, getConfig, logEvent); redeploy 4 functions | — | dispatch one test invoice end-to-end on apitest |
| 1.5 | Re-add server-side amount-vs-items check in `process_payment`; dispatcher 409/401/5xx handling (attempt caps, 409 sid lookup); poller batch backoff + poison isolation | ✅ | existing payment tests + new contract |

## Wave 2 — Operability & cost (≈ 2 weeks, bundled PRs allowed)

1. **Logging wrapper** (`lib/core/utils/log.dart` over `dart:developer`) + instrument the meaningful silent catches (`pin_service.dart:21`, `auth_provider.dart:269,340`, `table_provider.dart:62,96`, `einvoice_tab.dart:310`); fail-closed PIN verify.
2. **Logout provider reset** (`ref.invalidate` session-scoped providers; `.autoDispose` on family lookups).
3. **Report aggregation RPCs** (super_admin + store report); date-bound the `audit_logs` query; `Future.wait` independents.
4. **Realtime reload debounce** (500 ms coalescing in the 6 reload sites).
5. **Cost bundle:** connectivity probe transition-based; web QC photo compression; dispatcher/poller micro-batching + idle-run skip; kitchen clock leaf widget.
6. **Storage policies:** store-scope `qc-photos`/`attendance-photos`/`po-attendance` (✅ SQL); review `po_stores_read USING(true)`.
7. **Migration hygiene:** segregate/renumber Office numeric series, tombstone `210`/`211`, verify gaps 292–297 against both environments' `schema_migrations`, document canonical order. (Coordination-risky: do as its own PR with Hyochang verifying both Supabase projects.)

## Wave 3 — Structural refactoring (opportunistic, behind tests)

Ordered by blast radius (small → large):

1. **Consolidation bundle (S):** `formatVnd()` (decide canonical format with the business first); `TimeUtils.startOfWeek()`; ban `.toLocal()` for business timestamps (sweep ~10 files); shared `restaurantNameProvider`/StoreService; `StoreSettings` → `core/models/`; `_RestaurantMissingView` → shared widget.
2. **Dead-code PR (S):** delete `staff_role_utils.dart`, `photo_objet_utils.dart`, `web_sidebar_layout.dart` + its 2 guard tests, `test/widget_test.dart`; remove `ignore_for_file: unused_element` from `reports_tab.dart:1` and delete what the analyzer reveals; remove unused deps (`freezed*`, `json_serializable`, `json_annotation`, `drift`, `sqlite3_flutter_libs`, `drift_dev`; keep `zkfinger10` — used via MethodChannel); decide dormant fingerprint kiosk (1,124 lines) — delete or document why kept.
3. **Lint ratchet (M):** `strict-casts` + `unawaited_futures` in `analysis_options.yaml`; burn down findings starting with `attendance_tab.dart`'s 12 bare casts.
4. **`main.dart` de-hubbing (M):** move global `supabase` to `core/services/supabase_client.dart`; delete the `app_theme` re-export; fix 58 imports (pure mechanical).
5. **Layering (S–M):** `widgets/order_workspace.dart` → `features/order/widgets/`; `menu_provider` out of `features/admin/`; einvoice queue query → `einvoice_service.dart`; payment_detail realtime channel → provider.
6. **Order model unification (L, last):** behavioral tests for payment/kitchen flows FIRST, then shared select fragments + single base `Order` model replacing `Order`/`KitchenOrder`/`CashierOrder`.
7. **File splits (L, only when touched):** `inventory_tab.dart` (6,709), `inventory_purchase_screen.dart` (6,289), `inventory_provider.dart` (4,301 — also move `inventoryPurchase*` providers into `features/inventory_purchase/`), then `reports_tab.dart`, `super_admin_screen.dart` (extract its 6 inline tabs).

## Files to fix first (top 10)

1. `supabase/migrations/20260609000000_…` (uncommitted — fix before applying) + new security_invoker migration
2. `supabase/migrations/20260413001843_…` (cron secret mechanism)
3. `lib/core/router/app_router.dart`
4. `lib/features/order/order_provider.dart` (+4 sibling providers — poll guard)
5. `supabase/functions/wetax-onboarding/index.ts`
6. `create_daily_closing` (new migration) + new `test/daily_closing_…_test.dart`
7. `supabase/functions/wetax-dispatcher/index.ts` (+ claim RPC migration)
8. `supabase/functions/_shared/wetax.ts` (new)
9. `lib/core/services/pin_service.dart` + `log.dart` (new)
10. `lib/features/auth/auth_provider.dart` (logout invalidation)

## Whether Supabase SQL changes are needed

**Yes** — consolidated SQL change list with exact statements is at the end of `supabase-architecture-review.md`. All are additive/expand-safe except: `UNIQUE(order_id)` on einvoice_jobs (confirm data has no duplicates first), the daily-close function replacement (behavioral change — coordinate the backfill decision), and CRON_SECRET rotation (brief cron-job downtime window).

## Removable code (complete list)

`lib/core/utils/staff_role_utils.dart` (148 lines) · `lib/core/utils/photo_objet_utils.dart` · `lib/core/layout/web_sidebar_layout.dart` (342 lines) + `test/legacy_ui_compatibility_budget_test.dart:32-39` / `test/admin_shell_redesign_contract_test.dart:18` guards · `test/widget_test.dart` · 7 unused pubspec deps · dormant kiosk flow (1,124 lines — pending product decision) · dead `'cancelled'` branch in `record_payment_adjustment` (or add the status to the CHECK) · `rpc_compat.dart` (NOT now — at Contract stage only).

## Consolidatable code (complete list)

See `duplicate-code-report.md` Clusters 1–8: VND formatting (7+ sites), WeTax edge helpers (×4), order models (×3) + order selects (×4), TimeUtils vs `.toLocal()` (≥10 files), `restaurantNameProvider` (×3) + ad-hoc store lookups (4), `_startOfWeek` (×5), `_RestaurantMissingView` (×2), report query shells.

## Risky changes (explicit call-outs)

| Change | Risk | Mitigation |
|--------|------|------------|
| Git-history scrubbing (secrets) | breaks all clones/forks | coordinate; rotate secrets FIRST so history value is dead anyway |
| `security_invoker` on monitoring views | could break POS super_admin dashboards if they relied on cross-store reads | test each dashboard as super_admin + as store admin before merge |
| Daily-close window fix | changes financial figures; historical rows inconsistent with new logic | decide backfill vs cutover-note with Hyochang; never silently rewrite history |
| `UNIQUE(order_id)` on einvoice_jobs | fails if duplicates exist or re-issue flow is legitimate | pre-check query; partial unique on non-terminal statuses as fallback |
| Migration renumbering | `schema_migrations` repair on two live projects | dry-run on a Supabase branch; `supabase migration repair` script reviewed first |
| Order model unification | payment/kitchen regressions | tests-first; feature-by-feature cutover, not big-bang |
| `main.dart` de-hubbing | 58-file import churn | pure mechanical, single PR, `flutter analyze` + full test run |

## Safe mechanical cleanups (no approval needed, marked per brief)

Delete local `flutter_01.log`, `smoke_test_run.log`, `.DS_Store` · move `INTEGRATION_CODEX_COMMANDS.md` → `docs/` · gitignore + `git rm -r --cached screenshots/` (81 tracked entries) · archive root `CLAUDE_PROMPT_*.md` (already gitignored) · rename private `_restaurantId` → `_storeId` (`payment_provider.dart:79`, `kitchen_provider.dart:121`, `qc_provider.dart:36,226`) · fix `app_router.dart:94` comment · `final dynamic router` → `final GoRouter router` (`main.dart:79`) · comment the empty catch at `zkteco_fingerprint_service.dart:111`.
