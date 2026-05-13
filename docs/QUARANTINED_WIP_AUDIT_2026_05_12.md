# ARCHIVE — Quarantined WIP Audit — 2026-05-12

This file is preserved as pre-lock recovery evidence only.

Do not use it as the current UI standard or redesign entry point.

Use these documents instead:

- [Toast Operational UI Source of Truth](office/TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md)
- [Office Operational UI Redesign Master Plan](office/OFFICE_OPERATIONAL_UI_REDESIGN_MASTER_PLAN.md)
- [Legacy UI Standards Re-Audit](office/LEGACY_UI_STANDARDS_REAUDIT.md)

Historical note:

- keep this file for provenance around the quarantined-WIP audit and handoff
  into redesign planning

## Verdict

The quarantined WIP set must remain outside the clean POS repository for now.

- `main` is currently clean and verified against `origin/main`.
- No quarantined runtime, SQL, snippet, or contract-test file is safe to restore in bulk.
- The quarantined set is still a provenance and integration backlog, not an open implementation phase.
- No files were restored.
- No files were staged.
- No commits were created.

## Truth Lock

- Repository truth: `/Users/andreahn/globos_pos_system`
- Quarantine truth: `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12`
- Current tracked baseline:
  - `HEAD = origin/main = 018f1490117af290a507325ddce96d4d2f807be5`
- Guardrail:
  - quarantined files are preserved artifacts, not active repo state
  - restoring any file requires a fresh scoped audit before it re-enters `main`

## Clean Main Verification

- `git status --short`
  - clean
- `flutter analyze`
  - PASS
- `flutter test`
  - PASS

This confirms the clean tracked repository is healthy after quarantining the untracked WIP.

## Quarantined Directory

- path:
  - `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12`
- file count:
  - `41`

## Grouped WIP Inventory

### 1. Runtime Flutter WIP

#### Files

- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/lib/features/admin/providers/admin_sidebar_signal_provider.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/lib/features/inventory_purchase/inventory_purchase_provider.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/lib/features/inventory_purchase/inventory_purchase_screen.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/lib/features/inventory_purchase/inventory_purchase_service.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/lib/features/payment/payment_detail_screen.dart`

#### Likely purpose

- `payment_detail_screen.dart`
  - payment detail and e-invoice follow-up console
- `inventory_purchase/*`
  - large inventory purchase, stock audit, supplier, product, recipe, and reporting workspace
- `admin_sidebar_signal_provider.dart`
  - QC, delivery, and inventory badge counts for admin shell

#### Dependency and risk notes

- `payment_detail_screen.dart`
  - depends on tracked `paymentService.fetchPaymentDetail(...)`
  - imports shared UI primitives and Toast-style operational surfaces
  - still requires route mount and cashier navigation provenance
- `inventory_purchase/*`
  - depends on `adminScopedStoreIdProvider`, shared app primitives, RPC compatibility, printing, PDF, and extensive inventory RPC contracts
  - `inventory_purchase_screen.dart` still references many UI primitives not available in tracked clean main if simply restored without its full dependency graph
- `admin_sidebar_signal_provider.dart`
  - depends on untracked `inventory_purchase_service.dart`
  - no tracked consumer exists in current clean main

#### Main restore assessment

- `Not safe`

#### Independent PR assessment

- `Not yet`

#### Preconditions required first

- router mount decision for payment detail
- cashier navigation provenance decision
- admin shell mount decision for inventory purchase
- consumer integration decision for sidebar signals
- compile-surface reconciliation for missing UI primitive dependencies

#### Analyze/test failure risk

- `High`

These files previously caused analyzer failures when present in the repo.

#### RLS/RPC/migration risk

- `Medium to High`

The service layer depends on unresolved SQL lineage and inventory RPC provenance.

### 2. SQL / Migration WIP

#### Files

- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/supabase/migrations/20260428000002_vat_pricing_mode.sql`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/supabase/migrations/20260428000004_disable_photo_objet_red_invoice.sql`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/supabase/migrations/20260428000006_restore_wt03_feature_payload.sql`

#### Likely purpose

- `20260428000002_vat_pricing_mode.sql`
  - adds `restaurants.vat_pricing_mode`
  - rewrites `process_payment`, `request_red_invoice`, buyer lookup, and admin settings update functions
- `20260428000004_disable_photo_objet_red_invoice.sql`
  - disables red invoice for Photo Objet lineage
  - rewrites `request_red_invoice`
- `20260428000006_restore_wt03_feature_payload.sql`
  - rewrites `process_payment`
  - restores WT03 payload fields such as `feature`, `seq`, `item_code`, `item_name`

#### Dependency and risk notes

- these files overlap with tracked migration history and previously observed reflected DB concepts
- the repo's tracked `supabase/schema.sql` baseline is not usable as trusted reflection because it was recorded as `0 bytes`
- these migrations touch core payment, invoice, and tenant data behavior

#### Main restore assessment

- `Not safe`

#### Independent PR assessment

- `Only after reconciliation planning`

#### Preconditions required first

- canonical schema reflection repair
- explicit migration ordering decision
- overlap resolution against tracked migration lineage
- function signature reconciliation for `process_payment(...)` and `request_red_invoice(...)`

#### Analyze/test failure risk

- `Low direct, High indirect`

These files do not directly break Flutter compilation, but they can invalidate contract assumptions and DB behavior if reintroduced carelessly.

#### RLS/RPC/migration risk

- `Critical`

These are the highest-risk files in the quarantined set.

### 3. Snippet WIP

#### Files

- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/supabase/snippets/vui_vui_food_inclusive_validation.sql`

#### Likely purpose

- validation / seed-style script for VAT-inclusive scenario testing
- inserts restaurants, tables, menu categories, menu items, users, and test operational data

#### Main restore assessment

- `Not safe`

#### Independent PR assessment

- `No`

#### Preconditions required first

- VAT-pricing migration lineage must be settled
- validation ownership must be clarified
- seed/fixture policy must be explicitly defined

#### Analyze/test failure risk

- `Low direct`

#### RLS/RPC/migration risk

- `High`

The snippet writes business data and calls payment paths, so it must not be treated as a harmless utility script.

### 4. Contract Test WIP

#### Files

- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/admin_table_layout_editor_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/admin_tables_order_workspace_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/admin_tables_payment_amount_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/app_nav_scope_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/audit_findings_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/cashier_receipt_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/daily_closing_role_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/delivery_scope_reload_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/einvoice_scope_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/inventory_purchase_flutter_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/inventory_scope_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/kitchen_cashier_i18n_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/kitchen_realtime_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/operational_offline_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/order_mutation_role_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/order_total_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/order_workspace_realtime_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/payment_detail_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/photo_ops_role_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/qc_role_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/remaining_i18n_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/report_summary_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/staff_account_role_guard_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/table_layout_model_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/waiter_buffet_guest_count_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/waiter_floor_layout_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/waiter_i18n_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/waiter_table_realtime_contract_test.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/wt08_reconciliation_contract_test.dart`

#### Likely purpose

- route parity and navigation scope
- admin table layout/editor behavior
- inventory purchase runtime and SQL contract expectations
- payment totals and VAT pricing expectations
- role / permission / realtime / i18n / reporting checks

#### Dependency and risk notes

- representative examples show direct drift against clean tracked main:
  - `payment_detail_contract_test.dart`
    - expects `/payments/:paymentId` route and `_lastPaymentId` in cashier flow
  - `inventory_purchase_flutter_contract_test.dart`
    - expects `inventory_purchase` runtime and RPC surfaces to be present in repo
  - `order_total_contract_test.dart`
    - expects `p_vat_pricing_mode` propagation in store settings service
  - `admin_table_layout_editor_contract_test.dart`
    - expects `FloorLayoutView` and layout-edit affordances not present in clean main

#### Main restore assessment

- `Not safe`

#### Independent PR assessment

- `Not yet`

#### Preconditions required first

- map each test to current tracked runtime and schema truth
- split valid contract candidates from stale assumptions
- avoid restoring tests that assert unmounted or unproven runtime features

#### Analyze/test failure risk

- `Very High`

These files were a direct source of failed `flutter test` runs before quarantine.

#### RLS/RPC/migration risk

- `Medium to High`

Some tests encode SQL and RPC assumptions that are currently unresolved.

### 5. Asset / Config WIP

#### Files

- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/.vercelignore`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/assets/fonts/NotoSansKR-Bold.ttf`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/assets/fonts/NotoSansKR-Regular.ttf`

#### Likely purpose

- `.vercelignore`
  - deployment hygiene for build/temp artifacts
- font files
  - Korean font asset support

#### Main restore assessment

- `.vercelignore`
  - `Possibly safe after light audit`
- font files
  - `Not safe alone`

#### Independent PR assessment

- `.vercelignore`
  - `Yes, tiny config-only PR candidate`
- font files
  - `No, unless paired with explicit asset wiring scope`

#### Preconditions required first

- `.vercelignore`
  - verify current deployment workflow actually wants these exclusions
- fonts
  - verify `pubspec` asset registration and active consumer requirements

#### Analyze/test failure risk

- `.vercelignore`
  - `Low`
- fonts
  - `Low direct`

#### RLS/RPC/migration risk

- `None`

## Unsafe-To-Restore List

The following must not be restored directly into clean `main`:

- all runtime Flutter WIP files under:
  - `.../lib/features/payment/`
  - `.../lib/features/inventory_purchase/`
  - `.../lib/features/admin/providers/admin_sidebar_signal_provider.dart`
- all SQL migration WIP files under:
  - `.../supabase/migrations/20260428000002_vat_pricing_mode.sql`
  - `.../supabase/migrations/20260428000004_disable_photo_objet_red_invoice.sql`
  - `.../supabase/migrations/20260428000006_restore_wt03_feature_payload.sql`
- snippet:
  - `.../supabase/snippets/vui_vui_food_inclusive_validation.sql`
- all quarantined contract tests
- font assets unless an explicit asset-enable change is planned

## Files That Must Remain Quarantined

These files should remain quarantined until a future scoped audit re-opens them:

- all runtime Flutter WIP files
- all SQL / migration WIP files
- the VAT-inclusive validation snippet
- all contract test WIP files
- the two font assets

`.vercelignore` is the only file that could be reconsidered as a tiny isolated PR, but it should stay quarantined until that PR is explicitly chosen.

## Likely PR Sequencing

1. Optional tiny config-only PR:
   - restore `.vercelignore` only
2. Schema baseline repair PR:
   - fix trusted schema reflection process before touching quarantined SQL
3. SQL lineage reconciliation planning PR:
   - document exact overlap and desired migration order
4. SQL reconciliation implementation PR:
   - only after provenance is explicit and reviewed
5. Runtime provenance decision PR:
   - decide whether `payment_detail` and `inventory_purchase` will become live runtime work
6. Contract test triage PR:
   - restore only tests that match tracked runtime and accepted schema

## Exact Next Recommended PR Scope

The safest next PR scope is:

- `.vercelignore` only

Why this is the narrowest safe candidate:

- it is isolated from runtime code
- it does not touch SQL lineage
- it does not reopen failing tests
- it does not change Flutter mount or provider wiring

If config-only cleanup is not needed, the next action should remain audit/planning only and no quarantined file should be restored.

## Final Recommendation

Keep the quarantined WIP set fully isolated.

- Do not restore runtime Flutter WIP yet.
- Do not restore SQL or snippet WIP yet.
- Do not restore contract tests yet.
- Do not restore fonts yet.
- Only consider `.vercelignore` as a narrow future PR candidate.

At this point:

- no files restored
- no files staged
- no commits created
