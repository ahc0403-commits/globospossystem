# GLOBOSVN POS — Full System Audit Report

- **Date:** 2026-06-10
- **Branch:** `codex/pos-primary-job-phase5`
- **Scope:** entire repo — `lib/` (119 Dart files, ~67k LOC excl. l10n), `supabase/migrations/` (197 files), `supabase/functions/` (7 edge functions), tests, repo hygiene
- **Method:** six parallel evidence-based audits (architecture, duplication, performance/cost, DB architecture, security/edge functions, code quality). Top P0 claims re-verified by hand. Known-intentional items per CLAUDE.md (restaurants/stores dual naming, two settlement functions, Office coupling) were excluded.
- **Companion documents:** `refactoring-roadmap.md`, `risk-register.md`, `duplicate-code-report.md`, `performance-improvement-plan.md`, `supabase-architecture-review.md`

---

## Step 1 — Project structure (as understood)

- **Frontend:** Flutter, Riverpod (StateNotifier pattern), go_router. Features under `lib/features/*` (order, table, kitchen, payment, cashier, admin, super_admin, inventory, inventory_purchase, qc, attendance, delivery, photo_ops, report, auth, settings, onboarding, waiter). Shared code in `lib/core/` (services, utils, hardware, router, ui, models) and `lib/widgets/`.
- **Backend:** Supabase Postgres with RLS (33 policies, helper `get_user_store_id()`), 7 edge functions (staff creation, two settlement generators, four WeTax e-invoice functions), pg_cron (dispatcher 1 min, poller 2 min, daily close 00:00 HCMC, email outbox jobs).
- **Payment anchor:** `process_payment` RPC — atomic order lock (`FOR UPDATE`), payment insert (UNIQUE per order), table release, inventory deduction, `einvoice_jobs` insert. WeTax dispatch is fully async (P6 verified compliant).
- **Data flow:** screens → Riverpod providers → Supabase PostgREST/RPC; realtime channels per store + 2 s fallback poll timers; Office app reads POS views/`restaurants` directly via service_role.
- **Auth:** Supabase Auth → `users` row (role read-only client-side; self-escalation closed in `20260409000009`). Router redirect guards some routes; role matrix in `lib/core/utils/role_routes.dart`.

---

## 🔴 CRITICAL (P0) — fix before production

### P0-1. Cross-tenant data leak: office/monitoring views bypass RLS for any authenticated user
- **Issue location:** `supabase/migrations/20260604001000_*.sql`, `20260609000000_office_pos_sales_photo_objet_events.sql` (uncommitted, line 248), `20260405000003_office_connection_views.sql`, `20260405000012_store_type_classification.sql`
- **Current problem:** `v_office_pos_sales_events`, `v_office_pos_sales_bucket_summary`, `v_store_daily_sales`, `v_store_attendance_summary`, `v_quality_monitoring`, `v_inventory_status`, `v_brand_kpi` are owner-executed views (postgres = BYPASSRLS) granted `SELECT … TO authenticated`, with **no** `security_invoker = true`. Verified: zero `security_invoker` matches in those files.
- **Why risky:** any cashier of store A can read every store's full payment feed, refund reasons, attendance, and Photo Objet revenue. Migration `299` already fixed four other views with exactly this pattern — these were missed.
- **Fix now/later:** NOW. **Direction:** `ALTER VIEW … SET (security_invoker = true)` on all seven, or revoke `authenticated` and keep service_role-only (Office connects via service_role anyway). Verify POS super_admin dashboards after. **Difficulty:** S (SQL) + M (verification). **Impact:** closes a live multi-tenant confidentiality hole.

### P0-2. Hardcoded CRON_SECRET committed to git
- **Issue location:** `supabase/migrations/20260413001843_phase_2_step_9_pg_cron_schedules.sql:28,43,58,73` (verified: 4 occurrences of hardcoded bearer token)
- **Current problem:** the bearer token that authenticates **all** cron-triggered edge functions (settlements, wetax-dispatcher/poller/daily-close) is in a committed migration, alongside the function URLs.
- **Why risky:** anyone with repo read access can invoke settlement generation, force WeTax dispatch/daily close, and mutate `delivery_settlements`/`external_sales`.
- **Fix now/later:** NOW. **Direction:** rotate the secret; store in Supabase Vault/secrets; rewrite cron job commands via `cron.alter_job` to read the secret at runtime; scrub git history. **Difficulty:** S–M. **Impact:** removes a standing remote-trigger backdoor.

### P0-3. WeTax credentials and SYS_ADMIN token committed in vendor samples
- **Issue location:** `docs/vendor/samples/01_auth_login_plaintext.json:8-9`; also the apitest demo `WETAX_ENCRYPTION_KEY` documented at `supabase/functions/wetax-dispatcher/index.ts:11`
- **Current problem:** working login (`webcashvietnam_test_api@gmail.com` / password) and a real `SYS_ADMIN`-scope access token are in git.
- **Why risky:** authentication to the WeTax partner API as SYS_ADMIN; if the credential pattern is reused for production the blast radius is the live e-invoice channel.
- **Fix now/later:** NOW. **Direction:** redact samples, rotate the test account, confirm production creds were never committed, scrub history. **Difficulty:** S. **Impact:** closes a credential leak.

### P0-4. Router does not enforce the role matrix on `/waiter`, `/kitchen`, `/cashier`
- **Issue location:** `lib/core/router/app_router.dart:88-176` (verified: `canAccessRouteForRole` is called only once, line 134, for `/payments/`); matrix at `lib/core/utils/role_routes.dart:15-47`
- **Current problem:** the redirect guards `/super-admin`, `/admin`, `/photo-ops`, `/qc-*`, `/attendance-kiosk`, then `return null` for everything else. `/cashier`, `/waiter`, `/kitchen` have no role check; `cashier_screen.dart` only gates admin extras.
- **Why risky:** any authenticated role can deep-link to `/cashier` and operate the payment UI — separation of duties within a store is broken. RLS limits data to the store but not role-vs-role.
- **Fix now/later:** NOW. **Direction:** replace the final `return null` with a single `canAccessRouteForRole(...)` check → redirect to `homeRouteForRole(role)`; first update the matrix for super_admin QC paths; add a per-role routing test. **Difficulty:** S. **Impact:** restores payment-handling role separation.

### P0-5. 2-second DB polling runs even while realtime is connected (cost + load)
- **Issue location:** `lib/features/order/order_provider.dart:292-307`, `kitchen_provider.dart:278-290`, `table_provider.dart:189-196`, `payment_provider.dart:356-363`, `admin/providers/tables_provider.dart:198-203`
- **Current problem:** five always-on screens run `Timer.periodic(2s)` issuing a nested orders+items join, never checking `_realtimeConnected`. The correct guard already exists in `payment_detail_screen.dart:212-227` and was never copied.
- **Why risky:** ≈43,200 requests/day per screen; at 10 stores × ~5 screens ≈ **2.1M PostgREST calls/day** of pure duplicate load — the dominant cost/DB-CPU driver in the system, growing with device count.
- **Fix now/later:** NOW. **Direction:** copy the existing guard (cancel timer when subscribed; 10–15 s fallback interval). **Difficulty:** S. **Impact:** order-of-magnitude reduction in request volume.

---

## 🟠 HIGH (P1) — will bite within months

| # | Issue | Location | Problem / risk | Fix direction | Diff |
|---|-------|----------|----------------|---------------|------|
| P1-1 | Daily-close window starts 07:00 HCMC, not 00:00 | `20260410000000:100-101` | `v_closing_date::TIMESTAMPTZ` resolves midnight in UTC; sales 00:00–07:00 HCMC excluded from close — violates the project invariant; historical rows may be wrong | `::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'` + upper bound; audit/backfill history | S+M |
| P1-2 | wetax-dispatcher has no job claiming | `functions/wetax-dispatcher/index.ts:261` | overlapping cron runs double-dispatch the same pending jobs; idempotency relies on vendor behavior | claim via CAS/`FOR UPDATE SKIP LOCKED` RPC | M |
| P1-3 | `wetax-onboarding`: cashier in allowlist + no store/brand scoping | `functions/wetax-onboarding/index.ts:99-145,248` | any cashier can register/alter tax entities tenant-wide; store_admin A can modify store B's tax config | drop cashier; verify target entity against `user_accessible_stores` | S–M |
| P1-4 | `commons_refresh` cron auth mismatch (dead cron) | cron migration `:71-79` vs `wetax-onboarding/index.ts:231-257` | cron sends CRON_SECRET; function only accepts service_role/INTERNAL_SECRET/JWT → 401 forever; WeTax reference caches never refresh, silently | accept CRON_SECRET for that op, or send service key | S |
| P1-5 | Edge-function helper drift (`getToken` ×4 copies) | all four `wetax-*/index.ts` | only dispatcher supports encrypted credentials; migrating to encrypted login silently breaks 3 of 4 functions | extract `functions/_shared/wetax.ts` | M |
| P1-6 | Two migration series interleaved (numeric Office `001–299` vs timestamp POS) | `supabase/migrations/` | lexicographic vs numeric ordering diverge; fresh rebuild fragile; duplicate `office_purchases` definitions with drift (210 vs 20260405000006) | segregate/renumber Office series; tombstone 210/211; record baseline | M |
| P1-7 | `einvoice_jobs` missing indexes + UNIQUE(order_id) | `20260412145159` | dispatcher seq-scans status every minute on a table growing 1.8M rows/yr; duplicate job per order possible via manual paths | `(status, created_at)` + `(order_id)` indexes; UNIQUE(order_id) | S |
| P1-8 | Realtime reload amplification | `order_provider.dart:197-256` + 5 siblings | every store event triggers full nested reload on every device — thousands of redundant reloads/day/device | debounce 500 ms; filter `order_items` by order_id | M |
| P1-9 | Reports: N+1 per store, unbounded raw-row aggregation | `super_admin_provider.dart:371-409`, `report_provider.dart:171-229` | month-range = ~150k rows to device; `audit_logs` query has **no date filter** | aggregate RPC/view; date-bound audit query; `Future.wait` | M |
| P1-10 | `main.dart` is a dependency hub (58 importers; global `supabase` + theme re-export) | `lib/main.dart:15,75` | inverted layering, untestable widgets, hidden deps | move client to `core/services/`; kill the re-export | M |
| P1-11 | DB queries inside widget files; `restaurantNameProvider` ×3 | `einvoice_tab.dart:261-299`, `waiter_screen.dart:21-62`, `kitchen_screen.dart:21-31`, `fingerprint_provider.dart:128` | schema knowledge scattered; einvoice (compliance surface) untestable | move to `core/services/` (einvoice_service, store_service exist) | M |
| P1-12 | Giant files: `inventory_tab.dart` 6,709 / `inventory_purchase_screen.dart` 6,289 / `inventory_provider.dart` 4,301 | `lib/features/...` | single 6,650-line State class; active workstream → conflicts, review blindness | per-section extraction when touched | L |
| P1-13 | VND formatting drifted across 7+ implementations | see `duplicate-code-report.md` Cluster 1 | same amount renders `1.234.567 VND` vs `1,234,567 ₫` vs hand-rolled commas, including on printed receipts | single `formatVnd()` in `core/utils/` | M |
| P1-14 | Timestamp display split: `TimeUtils.toVietnam()` vs raw `.toLocal()` in ≥10 files | e.g. `payment_detail_screen.dart:1143`, `einvoice_tab.dart:1200` | device not on UTC+7 shows different times per screen; daily close is fixed HCMC | route all display through TimeUtils | M |
| P1-15 | Daily closing has **zero tests** | `lib/core/services/daily_closing_service.dart`; `docs/FAILED_DAILY_CLOSING_CONTRACT_TEST_RESTORE_2026_05_12.md` | money path, removed test never restored; P1-1 would have been caught | behavioral tests incl. timezone window | M |
| P1-16 | Silent failures + no logging at all | 40× `catch (_)`; `pin_service.dart:21`, `auth_provider.dart:269,340`; zero logger usage in lib/ | failure indistinguishable from empty state; no field diagnostics for a production POS | small `log.dart` wrapper; instrument the meaningful catches | M |
| P1-17 | Tracked `GLOBOS_POS_화면플로우_계정정보_2026-05-25.xlsx` may contain account credentials | repo root | "account info" file in git history | audit contents; move to vault; scrub if credentials present | S |
| P1-18 | Logout doesn't reset session providers | `auth_provider.dart:168-172` | shared POS terminals: stale cart/payment/report state survives user switch | `ref.invalidate(...)` session providers on logout | S |

## 🟡 MEDIUM (P2)

- **process_payment dropped amount-vs-items verification** (`20260412155915:79` vs original `20260409000000:446-463`): server now trusts the client total. Re-add sum check. (S)
- **Poller batch fragility** (`wetax-poller/index.ts:155-185`): no backoff on WT06 failure; one poison ref_id stalls 49 jobs until the 24 h stale sweep. Per-job backoff + poison isolation. (M)
- **Dispatcher 409/401/5xx handling** (`wetax-dispatcher/index.ts:180-204`): 409 falls through to "dispatched" with null sid; no attempt cap → unbounded per-minute retries. (M)
- **`generate-settlement` non-atomic** (insert settlement → insert items → link sales as separate statements): partial failure permanently orphans sales (existence check skips re-run). Wrap in one RPC transaction. (M)
- **`admin_retry_einvoice_job` TOCTOU** (`20260414000011`): retry racing dispatcher resets in-flight job to pending. Conditional UPDATE. (S)
- **`current_stock` negative drift** (no CHECK/floor; unconditional decrement in process_payment). (S)
- **Order entity modeled 3× / order select strings rebuilt in 4 providers** — see duplicate-code-report Clusters 4–5. (L)
- **Connectivity probe**: DB ping every 10 s per device (~430k calls/day fleet-wide) — `connectivity_service.dart:104`. (S)
- **QC photo upload uncompressed on web** (`qc_service.dart:386-393`): 4–8 MB/photo to storage. (S)
- **Kitchen screen rebuilds whole tree every second** (`kitchen_screen.dart:56-63`): isolate clock widget. (S)
- **Unchecked casts in admin UI** (`attendance_tab.dart` — 12 bare `as String`/`as int` sites): null → admin-screen crash. (M)
- **analysis_options.yaml is the stock template**: enable `strict-casts`, `unawaited_futures`; "0 issues" is weak evidence (and `reports_tab.dart:1` suppresses `unused_element` file-wide). (M)
- **Unused deps**: freezed/json_serializable/drift/sqlite3_flutter_libs + annotations — declared, zero usage, zero generated files. (S)
- **Storage policies**: `qc-photos`, `attendance-photos`, `po-attendance` readable/writable by any authenticated user across tenants (only `payment-proofs` is store-scoped). (S)
- **Residual `USING(true)` policies**: `photo_objet_stores` (`251_photo_objet.sql:115`) et al. — review/scope or document. (S)
- **`widgets/` layer imports features** (`order_workspace.dart:11-14`): move into `features/order/`; `menu_provider` out of admin. (S–M)
- **Migration gaps 292–297**: verify against `schema_migrations` in both environments and record. (S)

## 🟢 LOW (P3)

Dead code (`staff_role_utils.dart`, `photo_objet_utils.dart`, `web_sidebar_layout.dart` + its 2 guard tests, `test/widget_test.dart` placeholder); dormant fingerprint kiosk (1,124 lines wired but hard-redirected); `_startOfWeek` ×5; `_RestaurantMissingView` ×2; `restaurantNameProvider` family caches without autoDispose; `dynamic router` in `main.dart:79`; navigation history pushed inside `redirect` + unbounded; `'cancelled'` status not in einvoice CHECK (dead branch in `record_payment_adjustment`); einvoice state machine not trigger-guarded; payroll PIN unsalted SHA-256 with **default-allow when unset** (`pin_service.dart:8-30` — treat as P2 if payroll is sensitive); 10-year signed URLs stored in DB; partial-unique open-order-per-table index as belt-and-braces; composite indexes `payments(restaurant_id, created_at)`, `attendance_logs(restaurant_id, logged_at)`; `ListView` → `ListView.builder` on kitchen/super-admin; root-dir hygiene (`screenshots/` 81 tracked entries, `INTEGRATION_CODEX_COMMANDS.md` → docs/); private `_restaurantId` → `_storeId` renames; ~50 of 63 test files are text-pattern "contract tests" (verify shape, not behavior).

## ✅ CONFIRMED WORKING

- **P6 verified:** `process_payment` contains no WeTax/HTTP calls — einvoice job inserted `pending`, dispatched async.
- **process_payment atomicity:** order `FOR UPDATE` before all checks/writes; `UNIQUE(order_id)` on payments backstops double payment.
- **Money types:** uniformly `DECIMAL/numeric`; zero float money columns; amount CHECKs present.
- **Key UNIQUEs exist:** `daily_closings(restaurant_id, closing_date)`, `external_sales(source_system, external_order_id)`, `delivery_settlements(restaurant_id, source_system, period_label)`, `einvoice_jobs.ref_id`.
- **ref_id UUIDv7 invariant:** schema-level CHECK enforces version 7 + variant; retry preserves ref_id.
- **Self-escalation closed**; `create_staff_user` privilege checks solid with full rollback; `partner_credentials`/`daily_closings` deny-all RLS; SECURITY DEFINER search_path retro-fixed; decodeByteaToString used per ADR-014; `.env` properly gitignored, no service_role in `lib/`; settlement/refund RPCs lock correctly (`confirm_delivery_settlement_received`, `record_payment_adjustment`); create_order locks table row; channel/timer disposal hygiene in providers is good; daily-close cron fires at true 00:00 HCMC (`0 17 * * *`).

## Priority Fix List (top 12)

1. **[P0]** `security_invoker = true` on the 7 leaking views — cross-tenant data exposure (`supabase-architecture-review.md` §2.1)
2. **[P0]** Rotate + vault CRON_SECRET; scrub history
3. **[P0]** Redact/rotate WeTax sample credentials
4. **[P0]** Router: enforce `canAccessRouteForRole` on all routes
5. **[P0]** Poll-timer realtime guard in 5 providers
6. **[P1]** Fix daily-close timezone window + audit history
7. **[P1]** Dispatcher job claiming (SKIP LOCKED/CAS)
8. **[P1]** wetax-onboarding: drop cashier, add store scoping; fix commons_refresh auth
9. **[P1]** `einvoice_jobs` indexes + UNIQUE(order_id)
10. **[P1]** Extract `functions/_shared/wetax.ts` (getToken drift)
11. **[P1]** Audit the tracked 계정정보 xlsx
12. **[P1]** Daily-closing behavioral tests + logging wrapper
