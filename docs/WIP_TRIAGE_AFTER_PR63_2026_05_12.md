# WIP Triage After PR #63 — 2026-05-12

> Read-only triage. No files added, edited, or committed.
> Authored by Claude (assistant) per CLAUDE.md §3 / §4 governance.
> Supersedes the earlier stub at this same path.

## 1. Anchor state — Current HEAD and branch

| Field | Value |
|---|---|
| Current branch | `main` |
| Current HEAD | `fbf8a7bdbc8d12a7ba32a30f47a986c2d43e0136` |
| Tip commit | `chore(db): add reflected schema baseline (#63)` — empty `supabase/schema.sql` (0 bytes) |
| `origin/main` | up to date with HEAD |
| `docs/governance/` | exists but **empty** — no enumerated "Law" file in tracked sources |
| `supabase/schema.sql` | 0 bytes (intentional baseline placeholder; **DB is source of truth**) |
| Tracked migrations under `supabase/migrations/` | 184 files (oldest `001_*`, newest `299_deliberry_integration_security_closure.sql`) |
| Working-tree clean? | No — 38 untracked entries from `git status --short` |

## 2. Full untracked inventory (38 entries)

### 2.1 Build / asset surface (3)
- `.vercelignore`
- `assets/fonts/NotoSansKR-Bold.ttf` (~6.2 MB)
- `assets/fonts/NotoSansKR-Regular.ttf` (~6.2 MB)

### 2.2 Dart source — feature module (5)
- `lib/features/admin/providers/admin_sidebar_signal_provider.dart` (142 lines)
- `lib/features/inventory_purchase/inventory_purchase_provider.dart` (744 lines)
- `lib/features/inventory_purchase/inventory_purchase_screen.dart` (3661 lines)
- `lib/features/inventory_purchase/inventory_purchase_service.dart` (1319 lines)
- `lib/features/payment/payment_detail_screen.dart` (1352 lines)

### 2.3 Supabase SQL — migrations and snippet (4)
- `supabase/migrations/20260428000002_vat_pricing_mode.sql` (1029 lines)
- `supabase/migrations/20260428000004_disable_photo_objet_red_invoice.sql` (361 lines)
- `supabase/migrations/20260428000006_restore_wt03_feature_payload.sql` (443 lines)
- `supabase/snippets/vui_vui_food_inclusive_validation.sql` (533 lines, seed + validation script)

### 2.4 Contract tests (29)
| # | File | Lines |
|---|---|---|
| 1 | `test/admin_table_layout_editor_contract_test.dart` | 36 |
| 2 | `test/admin_tables_order_workspace_contract_test.dart` | 17 |
| 3 | `test/admin_tables_payment_amount_contract_test.dart` | 19 |
| 4 | `test/app_nav_scope_contract_test.dart` | 24 |
| 5 | `test/audit_findings_contract_test.dart` | 135 |
| 6 | `test/cashier_receipt_contract_test.dart` | 19 |
| 7 | `test/daily_closing_role_contract_test.dart` | 22 |
| 8 | `test/delivery_scope_reload_contract_test.dart` | 20 |
| 9 | `test/einvoice_scope_contract_test.dart` | 29 |
| 10 | `test/inventory_purchase_flutter_contract_test.dart` | 774 |
| 11 | `test/inventory_scope_contract_test.dart` | 24 |
| 12 | `test/kitchen_cashier_i18n_contract_test.dart` | 38 |
| 13 | `test/kitchen_realtime_contract_test.dart` | 17 |
| 14 | `test/operational_offline_contract_test.dart` | 23 |
| 15 | `test/order_mutation_role_contract_test.dart` | 41 |
| 16 | `test/order_total_contract_test.dart` | 49 |
| 17 | `test/order_workspace_realtime_contract_test.dart` | 17 |
| 18 | `test/payment_detail_contract_test.dart` | 50 |
| 19 | `test/photo_ops_role_contract_test.dart` | 43 |
| 20 | `test/qc_role_contract_test.dart` | 80 |
| 21 | `test/remaining_i18n_contract_test.dart` | 114 |
| 22 | `test/report_summary_contract_test.dart` | 23 |
| 23 | `test/staff_account_role_guard_contract_test.dart` | 23 |
| 24 | `test/table_layout_model_contract_test.dart` | 45 |
| 25 | `test/waiter_buffet_guest_count_contract_test.dart` | 16 |
| 26 | `test/waiter_floor_layout_contract_test.dart` | 24 |
| 27 | `test/waiter_i18n_contract_test.dart` | 45 |
| 28 | `test/waiter_table_realtime_contract_test.dart` | 16 |
| 29 | `test/wt08_reconciliation_contract_test.dart` | 38 |

## 3. Provenance findings

### 3.1 SQL migration sandwich
The three untracked SQL migration files have monotonic timestamps **interleaved with already-tracked siblings**, which is an unusual on-disk shape:

| File | Tracked? |
|---|---|
| `20260428000001_harden_admin_actor_helper_multi_access.sql` | tracked |
| `20260428000002_vat_pricing_mode.sql` | **untracked** |
| `20260428000003_fix_generate_uuidv7_pgcrypto_schema.sql` | tracked |
| `20260428000004_disable_photo_objet_red_invoice.sql` | **untracked** |
| `20260428000005_drop_legacy_request_red_invoice_overload.sql` | tracked |
| `20260428000006_restore_wt03_feature_payload.sql` | **untracked** |
| `20260428000007_switch_red_invoice_to_request_einvoice_info.sql` | tracked |
| `20260428000008_photo_ops_active_path_runtime_closure.sql` | tracked |

The neighboring tracked migrations (`...05`, `...07`, `...08`) reference downstream behavior of `request_red_invoice` / `process_payment` that pre-supposes the changes in the untracked `...02`/`...04`/`...06`. This means **either**:
1. The untracked files were applied directly to the live DB (via Supabase MCP) and never committed, **or**
2. They are abandoned drafts and the tracked files are the canonical sequence.

Distinction matters because `process_payment` is the atomic anchor (CLAUDE.md §7) for einvoice job creation. We **cannot** assume which is true from disk alone.

### 3.2 New column dependency
`vat_pricing_mode` column on `restaurants` exists **only** in the two untracked migrations (`...02` and `...06`). It is also referenced by:
- `supabase/snippets/vui_vui_food_inclusive_validation.sql` (untracked)
- `process_payment` body inside `...02` and `...06` (untracked)
- `admin_update_restaurant_settings(...)` 6-arg overload inside `...02` (untracked)

If the column does not exist in production DB, every untracked file that names it is broken. If it does exist, the disk migrations need to be re-derived from live `\d+ restaurants` rather than trusted from disk.

### 3.3 Dart feature mount points

**`payment_detail_screen.dart`** — file exists on disk; `test/payment_detail_contract_test.dart` requires:
- `lib/core/router/app_router.dart` to contain `path: '/payments/:paymentId'` — **NOT PRESENT** in router on `main`
- `lib/core/services/payment_service.dart` to contain `fetchPaymentDetail`, `einvoice_jobs`, `request_einvoice_payload`, `send_order_payload`, `order_total_amount`, `paying_amount_inc_tax` — **all present** on `main`
- `lib/core/utils/role_routes.dart` to contain `location.startsWith('/payments/')` — **present** on `main` (3 occurrences)

→ Router mount missing. Cannot land the screen + test as-is.

**`lib/features/inventory_purchase/`** — files exist on disk; `test/inventory_purchase_flutter_contract_test.dart` requires:
- `lib/features/admin/admin_screen.dart` to import `../inventory_purchase/inventory_purchase_screen.dart` and use `const InventoryPurchaseScreen()`, and to **not** import `tabs/inventory_tab.dart` — current `admin_screen.dart` still does `import 'tabs/inventory_tab.dart';` at line 15. **NOT mounted.**
- All 26 distinct RPC names called from `inventory_purchase_service.dart` — every name is defined in tracked migrations under `supabase/migrations/2026050600*.sql` and `2026050601*.sql`. **DB-side present.**

→ Service-layer DB contracts already live in `main`. UI mount and provider wiring are missing.

**`admin_sidebar_signal_provider.dart`** — defines three providers (`adminQcSidebarSignalProvider`, `adminDeliverySidebarSignalProvider`, `adminInventoryAlertCountProvider`). These symbols are **not consumed anywhere else** in `lib/`. The file imports `../../inventory_purchase/inventory_purchase_service.dart`, so it transitively requires the inventory_purchase feature to be present at compile time.

→ Dangling provider; coupled to inventory_purchase commit.

### 3.4 Contract test path audit (per [[feedback_contract_test_audit_method]])

Extracted **77** distinct `(test_file, repo_path)` pairs from `readRepoFile(...)` calls across the 29 untracked tests. **Two pairs reference paths that do not exist on disk** — those tests cannot pass even if their feature counterparts were committed:

| Test | Missing path it reads |
|---|---|
| `test/qc_role_contract_test.dart` | `docs/qsc_v2_db_contract_draft.md` |
| `test/waiter_floor_layout_contract_test.dart` | `lib/features/table/floor_layout.dart` |

The other 27 tests reference only paths that exist on `main`, but most of them assert symbols not yet present on `main` (e.g. `FloorLayoutView(`, `_layoutEditMode`, `'/payments/:paymentId'`, `InventoryPurchaseScreen()`) — i.e. they are **red specs awaiting implementation** and would fail CI today.

### 3.5 Build / asset surface
- `.vercelignore` — first checkin; only excludes build artifacts and `.dart_tool` etc. from Vercel context. Pure deploy hygiene; no runtime impact.
- `assets/fonts/NotoSans*.ttf` — `pubspec.yaml` lines 74–86 keep the font declarations **commented out**. Even if committed, the fonts are inert until pubspec is updated. Adds ~12 MB to the repo with zero runtime effect today.

## 4. Classification table

| File | Class | Reason |
|---|---|---|
| `.vercelignore` | **SAFE_PHASE_NOW** | Single deploy-config file; first checkin; no DB / no UI / no router. |
| `assets/fonts/NotoSansKR-Regular.ttf` | **DO_NOT_TOUCH_YET** | `pubspec.yaml` does not enable the font; ~6 MB binary inert until pubspec change. Defer to a fonts-PR that also flips pubspec. |
| `assets/fonts/NotoSansKR-Bold.ttf` | **DO_NOT_TOUCH_YET** | Same as above. ~6 MB. |
| `supabase/migrations/20260428000002_vat_pricing_mode.sql` | **NEEDS_SCHEMA_PROVENANCE** | Adds `restaurants.vat_pricing_mode`; redefines `process_payment`, two `request_red_invoice` overloads, `search_b2b_buyers`, `admin_update_restaurant_settings(6-arg)`; touches RLS on 6 tables. Sandwiched between tracked siblings — must be reconciled with live DB before commit. |
| `supabase/migrations/20260428000004_disable_photo_objet_red_invoice.sql` | **NEEDS_SCHEMA_PROVENANCE** | Re-redefines both `request_red_invoice` overloads to add brand-id gate; depends on shape from `...02`. Re-derive from live DB. |
| `supabase/migrations/20260428000006_restore_wt03_feature_payload.sql` | **NEEDS_SCHEMA_PROVENANCE** | Re-redefines `process_payment` (the atomic anchor per CLAUDE.md §7) to add WT03-shape feature payload; possibly superseded by tracked `...07` / `...08`. Re-derive from live DB. |
| `supabase/snippets/vui_vui_food_inclusive_validation.sql` | **NEEDS_SCHEMA_PROVENANCE** | One-off seed + validation; depends on `vat_pricing_mode` column, hard-coded brand id `5f800f49-…`, hard-coded tax_entity id, and **`INSERT INTO auth.users`**. Office app sees the new restaurant row immediately via service_role; cross-boundary side effect. |
| `lib/features/payment/payment_detail_screen.dart` | **NEEDS_ROUTER_PROVIDER_PROVENANCE** | Screen complete; `app_router.dart` lacks `'/payments/:paymentId'`. Mount missing. |
| `lib/features/inventory_purchase/inventory_purchase_provider.dart` | **NEEDS_ROUTER_PROVIDER_PROVENANCE** | Riverpod notifier; coupled to screen + service; not referenced by any tracked file. |
| `lib/features/inventory_purchase/inventory_purchase_screen.dart` | **NEEDS_ROUTER_PROVIDER_PROVENANCE** | UI complete; `admin_screen.dart:15` still imports `tabs/inventory_tab.dart` and does not instantiate `InventoryPurchaseScreen()`. |
| `lib/features/inventory_purchase/inventory_purchase_service.dart` | **NEEDS_ROUTER_PROVIDER_PROVENANCE** | DB contracts (26 RPCs) **all exist** in tracked migrations `2026050600*` / `2026050601*`; mount missing. |
| `lib/features/admin/providers/admin_sidebar_signal_provider.dart` | **NEEDS_ROUTER_PROVIDER_PROVENANCE** | Dangling provider; imports inventory_purchase; not consumed anywhere. Must land with the consumer + the inventory_purchase mount. |
| `test/inventory_purchase_flutter_contract_test.dart` | **TEST_ONLY_CONTRACT** | Imports inventory_purchase as a Dart package; cannot compile without inventory_purchase commit. Also asserts `admin_screen.dart` mount that is not present. |
| `test/payment_detail_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads untracked `payment_detail_screen.dart`; asserts router route not present. |
| `test/remaining_i18n_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads untracked `payment_detail_screen.dart`. |
| `test/qc_role_contract_test.dart` | **DO_NOT_TOUCH_YET** | Reads `docs/qsc_v2_db_contract_draft.md` which **does not exist** on disk. Will fail unconditionally. |
| `test/waiter_floor_layout_contract_test.dart` | **DO_NOT_TOUCH_YET** | Reads `lib/features/table/floor_layout.dart` which **does not exist** on disk. Will fail unconditionally. |
| `test/admin_table_layout_editor_contract_test.dart` | **TEST_ONLY_CONTRACT** | All paths exist; asserts `FloorLayoutView(`, `_layoutEditMode`, `updateTableLayout(` — none present in `tables_tab.dart` on `main`. Red spec. |
| `test/admin_tables_order_workspace_contract_test.dart` | **TEST_ONLY_CONTRACT** | Red spec. |
| `test/admin_tables_payment_amount_contract_test.dart` | **TEST_ONLY_CONTRACT** | Red spec. |
| `test/app_nav_scope_contract_test.dart` | **TEST_ONLY_CONTRACT** | Red spec; per-assertion verification required. |
| `test/audit_findings_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads tracked migrations and services; some assertions may already be green. Per-assertion verification required before commit. |
| `test/cashier_receipt_contract_test.dart` | **TEST_ONLY_CONTRACT** | Red spec. |
| `test/daily_closing_role_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads tracked migration `20260414000019_*.sql`. Verify before commit. |
| `test/delivery_scope_reload_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads tracked `delivery_settlement_tab.dart`. Verify. |
| `test/einvoice_scope_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads tracked `einvoice_tab.dart`. Verify. |
| `test/inventory_scope_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads tracked migration. Verify. |
| `test/kitchen_cashier_i18n_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads tracked screens. Verify. |
| `test/kitchen_realtime_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads tracked provider. Verify. |
| `test/operational_offline_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads tracked screens/widgets. Verify. |
| `test/order_mutation_role_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads tracked migrations. Verify. |
| `test/order_total_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads many tracked files. Verify. |
| `test/order_workspace_realtime_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads tracked provider. Verify. |
| `test/photo_ops_role_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads tracked service + migrations. Verify. |
| `test/report_summary_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads tracked doc + tab. Verify. |
| `test/staff_account_role_guard_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads tracked migration. Verify. |
| `test/table_layout_model_contract_test.dart` | **TEST_ONLY_CONTRACT** | Verify. |
| `test/waiter_buffet_guest_count_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads tracked screen. Verify. |
| `test/waiter_i18n_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads tracked screens. Verify. |
| `test/waiter_table_realtime_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads tracked provider. Verify. |
| `test/wt08_reconciliation_contract_test.dart` | **TEST_ONLY_CONTRACT** | Reads tracked function + provider/tab. Verify. |

Summary by class:
- **SAFE_PHASE_NOW**: 1 (`.vercelignore`)
- **NEEDS_SCHEMA_PROVENANCE**: 4 (3 SQL migrations + 1 SQL snippet)
- **NEEDS_ROUTER_PROVIDER_PROVENANCE**: 5 (payment_detail_screen, 3 inventory_purchase files, admin_sidebar_signal_provider)
- **TEST_ONLY_CONTRACT**: 24 (red specs; case-by-case green-on-main verification needed)
- **DO_NOT_TOUCH_YET**: 4 (2 broken tests, 2 inert font binaries)

## 5. Recommended next phase

### Phase A — `chore: ignore Vercel build artifacts`

A single-PR, single-file phase. This is the only file in the working tree that has zero coupling to DB schema, router/provider mount, or feature work. It matches the proven small-PR cadence visible in PRs #59–#63 and fits [[feedback_pr_splitting_for_vercel_quota]] ("same-risk-class small UI/util PRs"). It does not block any other phase.

### 5.1 Files allowed for the next phase
- `.vercelignore`

### 5.2 Files explicitly excluded from the next phase
- `assets/fonts/NotoSansKR-Regular.ttf`, `assets/fonts/NotoSansKR-Bold.ttf` — ~12 MB binaries with no consumer in `pubspec.yaml`. Defer to a separate "feat(fonts): enable NotoSansKR" PR that updates `pubspec.yaml` in the same commit.
- `supabase/migrations/2026042800000{2,4,6}*.sql` — schema provenance unverified; potentially superseded by tracked siblings (`…05`, `…07`, `…08`).
- `supabase/snippets/vui_vui_food_inclusive_validation.sql` — depends on unverified schema and writes into `auth.users` + `public.restaurants` (Office boundary).
- `lib/features/payment/payment_detail_screen.dart` — router mount absent; do not commit unmounted screen.
- `lib/features/inventory_purchase/*.dart` — `admin_screen.dart` still mounts the legacy `tabs/inventory_tab.dart`; do not commit a parallel screen module without flipping the mount in the same PR.
- `lib/features/admin/providers/admin_sidebar_signal_provider.dart` — depends on inventory_purchase; no consumer.
- All 29 untracked contract tests — most are RED specs that would fail CI on first run; commit each paired with its feature implementation, not standalone. The two tests with broken `readRepoFile()` paths (qc_role, waiter_floor_layout) need their target files created first or the test rewritten.

### 5.3 Required validation commands

```bash
# 1. Confirm the working tree has only .vercelignore staged
git status --short
git diff --cached -- .vercelignore

# 2. Confirm no other files were inadvertently staged
git diff --cached --name-only | grep -v '^\.vercelignore$' && echo 'STAGED EXTRAS — abort' || echo 'clean stage'

# 3. Static analysis must remain clean
flutter analyze

# 4. Full test suite must remain green (.vercelignore does not affect tests)
flutter test

# 5. Confirm anchor is unchanged before push
git rev-parse HEAD       # expect: fbf8a7bdbc8d12a7ba32a30f47a986c2d43e0136
git branch --show-current  # expect: main (or the PR branch you cut)
```

No DB action required; no edge function deploy required; no Office app coordination required.

## 6. Risk notes against POS governance laws (Law 2.1 – Law 2.10)

The repo does not contain an enumerated `Law 2.1`–`Law 2.10` document. `docs/governance/` exists but is empty, and a `grep` for `Law 2\.[0-9]` returns zero matches in tracked files. The interpretation below maps the request to the **binding constraints documented in `CLAUDE.md` §3 / §4 / §5 / §6 / §7**, which are the de-facto laws of this project. If a separate enumeration exists outside the tracked repo, this mapping should be reconciled before merge.

| Law | Source in CLAUDE.md | Affected untracked files | Risk |
|---|---|---|---|
| **2.1** Scope v1.3 is authoritative; do not re-litigate v1.0/1.1/1.2 | §3 | None | LOW — no untracked file re-opens superseded scope. |
| **2.2** Phase 2 Steps 2–10 are complete; do not re-run | §3 | `…02_vat_pricing_mode`, `…06_restore_wt03_feature_payload` | **HIGH** — both touch Step 8 territory (`process_payment` extension + einvoice_jobs creation). Re-running risks RPC drift from live DB. |
| **2.3** Phase 3 verification PASS (11/11) | §3 | `…02`, `…04`, `…06` | **HIGH** — any of these landed without re-running Phase 3 invariants would invalidate the verification result of record. |
| **2.4** Claude Code prompts must be English only | §4 | n/a (this report is English) | OK. |
| **2.5** Do not rebuild what WeTax portal already provides (red invoice history etc.) | §4 | `payment_detail_screen.dart` shows portal-routing affordances (`lookup_url`, `Red Invoice: Portal Pending`) | LOW if shipped with the badge wiring; **MEDIUM** if shipped without the matching role-route + badge gates that `payment_detail_contract_test.dart` enforces. |
| **2.6** Payment completion must never depend on WeTax availability (Principle P6) | §4 + §7 | `…02`, `…06` | **HIGH** — both rewrite `process_payment`. Untracked drafts must be re-checked to confirm einvoice job INSERT remains best-effort and never blocks `payments` row insert / `orders.status='completed'`. The disk versions still attach `INSERT INTO einvoice_jobs` inside the same RPC after the `payments` row is created — review for ordering / failure-mode regression vs the tracked lineage. |
| **2.7** Both settlement edge functions are preserved (`generate-settlement` + `generate_delivery_settlement`) | §4 | None of the untracked files modify edge functions | OK. |
| **2.8** Office app coupling is hard at `restaurants` — do not rename, drop, or alter `restaurants.id`, `name`, `address`, `is_active` | §5 | `…02` adds `vat_pricing_mode` column (additive ALTER) and `admin_update_restaurant_settings(6-arg)` updates `restaurants` via SECURITY DEFINER. `vui_vui_food_inclusive_validation.sql` does **`INSERT INTO public.restaurants`** + **`INSERT INTO auth.users`** for fixed UUIDs. | MEDIUM — additive column is allowed in Expand stage, but the snippet's INSERT into `auth.users` and a real restaurant row crosses the POS↔Office boundary and is irreversible-flavored. Office repo will see the new restaurant row immediately via service_role. |
| **2.9** DB state (CLAUDE.md §6): dual-naming preserved (`restaurants`+`stores` view, `restaurant_settings`+`store_settings` view, `get_user_restaurant_id` legacy wrapper, `get_user_store_id` authoritative) — 33 RLS policies, 29 reference `get_user_store_id`, 0 reference legacy | §6 | `…02` redefines RLS policies on `brand_master`, `tax_entity`, `einvoice_shop`, `system_config`, `b2b_buyer_cache`, `store_tax_entity_history`, `einvoice_jobs`, `einvoice_events` — all using `get_user_store_id()` / `get_user_tax_entity_id()` / `is_super_admin()` | MEDIUM — naming is consistent with §6 on disk, but if these policies are already live with different DDL, applying the file would silently drift. Re-derive from live `pg_policies`. |
| **2.10** `einvoice_jobs.ref_id` MUST be UUIDv7; `process_payment` is the atomic anchor; daily close fixed 00:00 Asia/Ho_Chi_Minh; WeTax portal owns red-invoice lifecycle | §7 | `…02`, `…06` both call `generate_uuidv7()` for `v_ref_id` and INSERT into `einvoice_jobs` from inside the `process_payment` transaction; UUIDv7 helper exists per tracked `…03_fix_generate_uuidv7_pgcrypto_schema.sql` | OK on a read of the SQL — but again, only if the on-disk version is the version that is live. **Cannot confirm from disk alone.** |

### Cross-cutting governance reminders
- **DB is source of truth**: no untracked SQL should be committed without diffing against live `\df+` / `\d+` / `pg_policies` output. Trusting the disk file blindly is exactly what this rule forbids.
- **POS / Office separation** (CLAUDE.md §5): the Vui Vui seed snippet inserts a real restaurant row that the Office service-role connection will immediately see. This crosses the POS↔Office boundary and is not a pure POS-local change.
- **Atomic anchor preservation** (CLAUDE.md §7): `process_payment` is rewritten by **two** different untracked migrations (`…02` then `…06`). If both are applied in sequence the `…06` version wins; if only `…02` is applied the WT03 feature payload shape is missing. Either path is a meaningful behavioral change to the most sensitive RPC.

## 7. Final verdict

| Decision | Status |
|---|---|
| **Phase A — `chore: ignore Vercel build artifacts` (`.vercelignore` only)** | **GO** |
| Bundling fonts into Phase A | **NO-GO** — defer to a fonts-PR that also enables them in `pubspec.yaml`. |
| Committing any of the 3 SQL migrations or the snippet | **NO-GO** — schema provenance unverified; conflicts with §6 / §7 invariants until reconciled with live DB. |
| Committing `payment_detail_screen.dart` | **NO-GO** — router mount missing; would orphan the file and break `payment_detail_contract_test.dart`. |
| Committing `lib/features/inventory_purchase/*` | **NO-GO** — `admin_screen.dart` still mounts the legacy `inventory_tab.dart`; would create dead module. |
| Committing `admin_sidebar_signal_provider.dart` | **NO-GO** — depends on inventory_purchase; no consumer. |
| Committing the 2 broken contract tests (qc_role, waiter_floor_layout) | **NO-GO** — reference paths that do not exist on disk. |
| Committing the remaining 27 contract tests as a batch | **NO-GO** — most are red specs; commit each paired with its feature work, not en masse. |

**Overall: GO for Phase A only. NO-GO for everything else until provenance is established.**
