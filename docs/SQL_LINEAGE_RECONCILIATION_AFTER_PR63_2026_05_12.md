# SQL Lineage Reconciliation After PR63 — 2026-05-12

## 1. Executive verdict

Current phase remains **truth stabilization**.

Next implementation phase is **blocked** until SQL lineage is reconciled.

PR `#63` established only a tracked path for `supabase/schema.sql`; it did **not** establish a usable reflected schema baseline because the tracked file is currently `0 bytes`.

All currently untracked SQL artifacts in this report must be treated as:

- `DO NOT APPLY`
- `DO NOT CONNECT`
- `DO NOT TREAT AS CANONICAL`

unless and until their lineage is proven from tracked schema content or accepted tracked migration history.

Office project completion is **not** a dependency for POS phase start. POS is blocked by **POS SQL provenance only**.

## 2. Current repo truth

- Repo: `~/globos_pos_system`
- Branch: `main`
- HEAD: `fbf8a7bdbc8d12a7ba32a30f47a986c2d43e0136`
- Latest commit: `fbf8a7b chore(db): add reflected schema baseline (#63)`

Current untracked inventory still includes:

- untracked runtime WIP in `lib/features/payment/`, `lib/features/inventory_purchase/`, and `lib/features/admin/providers/`
- untracked SQL under `supabase/migrations/` and `supabase/snippets/`
- untracked contract/audit tests

Relevant current git state at report time:

```text
?? .vercelignore
?? assets/fonts/
?? docs/WIP_TRIAGE_AFTER_PR63_2026_05_12.md
?? lib/features/admin/providers/admin_sidebar_signal_provider.dart
?? lib/features/inventory_purchase/
?? lib/features/payment/payment_detail_screen.dart
?? supabase/migrations/20260428000002_vat_pricing_mode.sql
?? supabase/migrations/20260428000004_disable_photo_objet_red_invoice.sql
?? supabase/migrations/20260428000006_restore_wt03_feature_payload.sql
?? supabase/snippets/vui_vui_food_inclusive_validation.sql
?? test/admin_table_layout_editor_contract_test.dart
?? test/admin_tables_order_workspace_contract_test.dart
?? test/admin_tables_payment_amount_contract_test.dart
?? test/app_nav_scope_contract_test.dart
?? test/audit_findings_contract_test.dart
?? test/cashier_receipt_contract_test.dart
?? test/daily_closing_role_contract_test.dart
?? test/delivery_scope_reload_contract_test.dart
?? test/einvoice_scope_contract_test.dart
?? test/inventory_purchase_flutter_contract_test.dart
?? test/inventory_scope_contract_test.dart
?? test/kitchen_cashier_i18n_contract_test.dart
?? test/kitchen_realtime_contract_test.dart
?? test/operational_offline_contract_test.dart
?? test/order_mutation_role_contract_test.dart
?? test/order_total_contract_test.dart
?? test/order_workspace_realtime_contract_test.dart
?? test/payment_detail_contract_test.dart
?? test/photo_ops_role_contract_test.dart
?? test/qc_role_contract_test.dart
?? test/remaining_i18n_contract_test.dart
?? test/report_summary_contract_test.dart
?? test/staff_account_role_guard_contract_test.dart
?? test/table_layout_model_contract_test.dart
?? test/waiter_buffet_guest_count_contract_test.dart
?? test/waiter_floor_layout_contract_test.dart
?? test/waiter_i18n_contract_test.dart
?? test/waiter_table_realtime_contract_test.dart
?? test/wt08_reconciliation_contract_test.dart
```

## 3. Why PR #63 does not yet unlock next implementation

PR `#63` merged a tracked file at [supabase/schema.sql](/Users/andreahn/globos_pos_system/supabase/schema.sql), but the file is empty:

- `wc -c supabase/schema.sql` → `0`

That means:

1. the repo now tracks a schema-baseline filename
2. but the file contains no schema content
3. so it cannot be used as a trusted reflected baseline
4. and it cannot prove the lineage of untracked local SQL

Therefore PR `#63` does **not** unlock the next implementation phase. It only established a placeholder artifact path that still requires real reconciliation.

## 4. SQL artifact inventory table

| File path | Tracked status | Content type | Immediate posture |
|---|---|---|---|
| `supabase/schema.sql` | Tracked | Schema baseline placeholder | `DO NOT TRUST AS BASELINE YET` |
| `supabase/migrations/20260428000002_vat_pricing_mode.sql` | Untracked | Migration candidate | `DO NOT APPLY` |
| `supabase/migrations/20260428000004_disable_photo_objet_red_invoice.sql` | Untracked | Migration candidate | `DO NOT APPLY` |
| `supabase/migrations/20260428000006_restore_wt03_feature_payload.sql` | Untracked | Migration candidate | `DO NOT APPLY` |
| `supabase/snippets/vui_vui_food_inclusive_validation.sql` | Untracked | Validation / seed-like snippet | `DO NOT APPLY` |

## 5. Provenance status for each untracked SQL artifact

### `supabase/schema.sql`

Status:

- tracked
- empty
- unusable as trusted reflected baseline

Why:

- the tracked file contains `0` bytes
- there is no schema body to compare against untracked SQL
- the repo cannot currently use this file to prove or disprove SQL lineage

Verdict:

- `DO NOT TRUST AS BASELINE YET`

### `20260428000002_vat_pricing_mode.sql`

Observed contents:

- adds `restaurants.vat_pricing_mode`
- drops and recreates `process_payment(...)`
- drops and recreates `request_red_invoice(...)`
- changes `admin_update_restaurant_settings(...)`

What can be safely said from current repo state only:

- it is untracked
- it is substantial and touches core payment / invoice lineage
- it assumes `vat_pricing_mode` should exist in canonical DB state
- current tracked `schema.sql` cannot confirm that assumption because it is empty

What cannot be safely claimed in this report:

- whether the remote database already contains exactly this state
- whether this file was ever formally applied
- whether its content is superseded by another accepted migration path

Verdict:

- `provenance unknown`
- `local-only candidate`
- `DO NOT APPLY`

### `20260428000004_disable_photo_objet_red_invoice.sql`

Observed contents:

- recreates `request_red_invoice(...)`
- raises `RED_INVOICE_DISABLED_FOR_PHOTO_OBJET`
- appears to exist in two function-signature variants

What can be safely said from current repo state only:

- it is untracked
- it directly modifies red-invoice behavior
- it has no proven tracked baseline to reconcile against from `schema.sql`
- it sits inside a numbered sequence with gaps, suggesting partial WIP history rather than clean accepted lineage

Extra caution signal:

- this file does not present as a clearly self-contained canonical migration path

Verdict:

- `provenance unknown`
- `obsolete/unsafe candidate`
- `DO NOT APPLY`

### `20260428000006_restore_wt03_feature_payload.sql`

Observed contents:

- drops and recreates `process_payment(...)`
- uses `vat_pricing_mode`
- introduces WT03-style payload fields such as `feature`, `seq`, `item_code`, `item_name`
- includes `restore` in filename, which strongly suggests rollback/reconciliation history

What can be safely said from current repo state only:

- it is untracked
- it is a high-risk core payment lineage artifact
- its filename implies prior divergence rather than fresh canonical forward migration
- current tracked `schema.sql` is too weak to validate it

Verdict:

- `provenance unknown`
- `obsolete/unsafe candidate`
- `DO NOT APPLY`

### `vui_vui_food_inclusive_validation.sql`

Observed contents:

- updates `restaurants.vat_pricing_mode`
- inserts seed-like rows into `restaurants`, `tables`, `menu_categories`, `menu_items`, and `auth.users`
- behaves more like a test fixture / validation harness than a canonical migration

What can be safely said from current repo state only:

- it is untracked
- it depends on VAT-pricing lineage already being real
- it mutates business data and auth-space data
- it is not a safe starting point for reconciliation

Verdict:

- `local-only candidate`
- `obsolete/unsafe`
- `DO NOT APPLY`

## 6. Runtime safety status

Runtime safety status is currently **unsafe for connection**.

Reason:

- the SQL artifacts that appear to support VAT pricing, WT03 payload shape, and Photo Objet red-invoice exception are all untracked
- `supabase/schema.sql` cannot validate them because it is empty
- core functions touched by these SQL files are highly sensitive:
  - `process_payment(...)`
  - `request_red_invoice(...)`

Direct implication:

- no runtime feature may be connected on top of these SQL assumptions
- no UI WIP should be promoted based on these files
- no contract test should be upgraded to phase gate using these files as truth

## 7. Relationship to WIP app files

### `payment_detail_screen.dart`

Relationship:

- payment-detail behavior depends on payment / invoice lineage
- the underlying SQL provenance for payment and red-invoice behavior is unresolved
- tracked router wiring is also unresolved

Result:

- `DO NOT CONNECT`

### `inventory_purchase/`

Relationship:

- inventory purchase has tracked DB-side lineage elsewhere in `20260506*` migrations
- but the current requested SQL reconciliation scope does not prove runtime mount safety
- inventory WIP remains unmounted and separate from this SQL lineage closure

Result:

- `DO NOT CONNECT`

### `admin_sidebar_signal_provider.dart`

Relationship:

- imports untracked `inventory_purchase_service.dart`
- depends on an unmounted WIP surface
- cannot be separated from unresolved provider/runtime provenance

Result:

- `DO NOT CONNECT`

## 8. Explicit NO-GO / GO gates

### NO-GO gates

The next implementation phase remains blocked while any of the following are true:

- `supabase/schema.sql` remains empty
- untracked SQL artifacts remain unproven against tracked schema or accepted migration history
- `process_payment(...)` lineage is unresolved
- `request_red_invoice(...)` lineage is unresolved
- VAT-pricing lineage is unresolved
- WT03 payload lineage is unresolved
- red-invoice exception lineage is unresolved

### GO gate

Only after the following are true may the next implementation phase be opened:

1. `supabase/schema.sql` is replaced by a real, trusted reflected baseline or another accepted tracked schema reflection artifact
2. each untracked SQL artifact is explicitly resolved as one of:
   - accepted tracked migration lineage
   - rejected / archived non-canonical artifact
   - replaced by a tracked reconciliation migration
3. core function lineage for `process_payment(...)` and `request_red_invoice(...)` is unambiguous in tracked history
4. runtime WIP remains disconnected until the above are complete

## 9. Required next action

Required next action is:

**replace placeholder schema tracking with a real SQL lineage reconciliation step**

Concretely:

- do not implement features
- do not connect runtime WIP
- do not apply untracked SQL
- decide how `supabase/schema.sql` becomes a real baseline artifact
- reconcile the three untracked migration candidates against accepted tracked migration history
- classify `vui_vui_food_inclusive_validation.sql` as validation-only or archive-only, not runtime lineage

## 10. Final recommendation

Current phase remains **truth stabilization**.

Next implementation phase is **blocked until SQL lineage is reconciled**.

Office project completion is **not** a dependency for POS phase start.

POS is blocked by **POS SQL provenance only**.

Final decision:

- **NO-GO** for runtime implementation
- **NO-GO** for router/provider connection
- **NO-GO** for applying any untracked SQL artifact
- **GO** only for schema-baseline repair through proven lineage work
