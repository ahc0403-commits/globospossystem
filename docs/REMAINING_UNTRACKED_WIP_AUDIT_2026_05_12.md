# Remaining Untracked WIP Audit — 2026-05-12

## Current HEAD

- `25f8a07 docs(pos): classify wip after sql provenance commit`

## Commit 25f8a07 confirmation

Commit `25f8a07` is clean and documentation-only.

- committed file:
  - `docs/WIP_CLASSIFICATION_AFTER_SQL_PROVENANCE_COMMIT_2026_05_12.md`
- no runtime Flutter files were included
- no SQL migrations were included
- no snippets were included
- no tests were included
- no assets or config files were included

## Remaining untracked WIP

### 1. Runtime Flutter WIP

#### File paths

- `lib/features/admin/providers/admin_sidebar_signal_provider.dart`
- `lib/features/inventory_purchase/inventory_purchase_provider.dart`
- `lib/features/inventory_purchase/inventory_purchase_screen.dart`
- `lib/features/inventory_purchase/inventory_purchase_service.dart`
- `lib/features/payment/payment_detail_screen.dart`

#### Risk classification

- `requires code audit before staging`

#### Notes

- These files are still local runtime WIP.
- They should remain unstaged until mount, routing, provider, and feature-boundary provenance are explicitly reviewed.

### 2. SQL / migration WIP

#### File paths

- `supabase/migrations/20260428000002_vat_pricing_mode.sql`
- `supabase/migrations/20260428000004_disable_photo_objet_red_invoice.sql`
- `supabase/migrations/20260428000006_restore_wt03_feature_payload.sql`

#### Risk classification

- `requires provenance + DB safety audit before staging`

#### Notes

- These files are not safe to treat as normal backlog noise.
- They remain blocked by migration lineage, schema reflection trust, and DB safety review.

### 3. Snippets

#### File paths

- `supabase/snippets/vui_vui_food_inclusive_validation.sql`

#### Risk classification

- `reference only, not migration candidate yet`

#### Notes

- This file should be treated as supporting validation material only.
- It must not be promoted as a migration candidate until the underlying SQL lineage is settled.

### 4. Contract tests

#### File paths

- `test/admin_table_layout_editor_contract_test.dart`
- `test/admin_tables_order_workspace_contract_test.dart`
- `test/admin_tables_payment_amount_contract_test.dart`
- `test/app_nav_scope_contract_test.dart`
- `test/audit_findings_contract_test.dart`
- `test/cashier_receipt_contract_test.dart`
- `test/daily_closing_role_contract_test.dart`
- `test/delivery_scope_reload_contract_test.dart`
- `test/einvoice_scope_contract_test.dart`
- `test/inventory_purchase_flutter_contract_test.dart`
- `test/inventory_scope_contract_test.dart`
- `test/kitchen_cashier_i18n_contract_test.dart`
- `test/kitchen_realtime_contract_test.dart`
- `test/operational_offline_contract_test.dart`
- `test/order_mutation_role_contract_test.dart`
- `test/order_total_contract_test.dart`
- `test/order_workspace_realtime_contract_test.dart`
- `test/payment_detail_contract_test.dart`
- `test/photo_ops_role_contract_test.dart`
- `test/qc_role_contract_test.dart`
- `test/remaining_i18n_contract_test.dart`
- `test/report_summary_contract_test.dart`
- `test/staff_account_role_guard_contract_test.dart`
- `test/table_layout_model_contract_test.dart`
- `test/waiter_buffet_guest_count_contract_test.dart`
- `test/waiter_floor_layout_contract_test.dart`
- `test/waiter_i18n_contract_test.dart`
- `test/waiter_table_realtime_contract_test.dart`
- `test/wt08_reconciliation_contract_test.dart`

#### Risk classification

- `requires mapping to existing runtime/schema before staging`

#### Notes

- These tests are not current CI truth.
- They require explicit mapping to tracked runtime behavior and accepted schema lineage before any staging decision.

### 5. Assets / config

#### File paths

- `.vercelignore`
- `assets/fonts/`

#### Risk classification

- `requires separate asset/config policy decision`

#### Notes

- These files are outside the current truth-stabilization scope.
- Any future staging should happen only in a narrow asset/config policy PR.

## Explicit conclusion

- There is `no current safe stage candidate` among the remaining untracked WIP.
- `No implementation phase is open`.
- The `next safe action is audit, not commit`.
