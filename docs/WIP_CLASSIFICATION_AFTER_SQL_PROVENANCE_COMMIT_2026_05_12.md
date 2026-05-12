# WIP Classification After SQL Provenance Commit — 2026-05-12

## Current HEAD

- `47a7b66 docs(pos): record sql wip provenance audit after pr63`

## Current git status --short

```text
?? .vercelignore
?? assets/fonts/
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

## 1. Runtime Flutter WIP

### File paths

- `lib/features/payment/payment_detail_screen.dart`
- `lib/features/inventory_purchase/inventory_purchase_provider.dart`
- `lib/features/inventory_purchase/inventory_purchase_screen.dart`
- `lib/features/inventory_purchase/inventory_purchase_service.dart`
- `lib/features/admin/providers/admin_sidebar_signal_provider.dart`

### Likely domain

- payment detail / e-invoice follow-up
- inventory purchase and office-facing inventory workflows
- admin sidebar signal aggregation

### Safe to ignore for now?

- `Yes`

These files are currently safer left untouched than partially staged. They remain unmounted or unconsumed runtime WIP.

### Audit required before staging?

- `Yes, mandatory`

They require router, provider, and runtime provenance review before any staging decision.

### Recommended next PR boundary

- `Do not open a runtime PR yet`
- first complete SQL lineage reconciliation and mount provenance decisions

## 2. SQL / Migration WIP

### File paths

- `supabase/migrations/20260428000002_vat_pricing_mode.sql`
- `supabase/migrations/20260428000004_disable_photo_objet_red_invoice.sql`
- `supabase/migrations/20260428000006_restore_wt03_feature_payload.sql`

### Likely domain

- VAT pricing mode
- red invoice exception behavior
- WT03 payload restoration / `process_payment(...)` lineage

### Safe to ignore for now?

- `No`

These are the active blocker class. They should not be staged, but they also should not be treated as harmless background noise.

### Audit required before staging?

- `Yes, mandatory`

They require migration-order and schema-provenance reconciliation before any staging or acceptance.

### Recommended next PR boundary

- `schema-baseline repair or sql-lineage-reconciliation only`
- no runtime connection
- no migration apply

## 3. Snippets

### File paths

- `supabase/snippets/vui_vui_food_inclusive_validation.sql`

### Likely domain

- validation / seed-style inclusive VAT scenario testing

### Safe to ignore for now?

- `Yes`

It should remain untouched until the SQL lineage it depends on is proven.

### Audit required before staging?

- `Yes`

It touches seeded business data and depends on unresolved VAT-pricing lineage.

### Recommended next PR boundary

- `No standalone PR now`
- only revisit after migration lineage is settled

## 4. Contract Tests

### File paths

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

### Likely domain

- route parity
- role/permission guards
- i18n coverage
- realtime behavior
- payment / inventory / waiter / QC / reporting contracts

### Safe to ignore for now?

- `Yes`

They remain local-only contract/audit WIP and should not be used as current CI truth.

### Audit required before staging?

- `Yes`

Each test must be reconciled against tracked runtime reality before any staging decision.

### Recommended next PR boundary

- `test-gate-triage only, later`
- do not batch with runtime or SQL reconciliation

## 5. Assets / Config

### File paths

- `.vercelignore`
- `assets/fonts/NotoSansKR-Bold.ttf`
- `assets/fonts/NotoSansKR-Regular.ttf`

### Likely domain

- deploy hygiene
- font asset payload

### Safe to ignore for now?

- `.vercelignore`: `No, but low priority`
- `assets/fonts/*`: `Yes`

`.vercelignore` could become a tiny isolated PR later, but it is not required for current truth stabilization. Fonts should stay untouched until there is an explicit asset-enable scope.

### Audit required before staging?

- `.vercelignore`: `light audit`
- `assets/fonts/*`: `yes`

### Recommended next PR boundary

- `.vercelignore` only, if a tiny config-only PR is desired
- fonts only with matching `pubspec`/asset-consumer work, not alone

## Explicit conclusion

No staging or commit should happen yet from the current remaining untracked WIP set.

The next step must still be **WIP audit/classification before any staging**, with priority on:

1. SQL / migration provenance
2. runtime router/provider provenance
3. contract-test gate usability
4. only then any narrow, isolated staging decision
