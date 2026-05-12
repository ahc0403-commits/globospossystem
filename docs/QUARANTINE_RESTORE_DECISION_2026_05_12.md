# Quarantine Restore Decision — 2026-05-12

## Current Conclusion

- `NO-RESTORE / HOLD`

The quarantined WIP set must remain outside the clean POS repository for now.

## Safest Candidate Identified

- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/.vercelignore`

## Decision

- `.vercelignore` is the lowest-risk candidate, but it is still `held`.

## Reason

- the current phase goal is provenance reconciliation, not implementation restart
- clean `main` already passes `flutter analyze` and `flutter test`
- Vercel deployment relevance is not yet confirmed
- there is no operational need to reopen quarantined config just because it is low risk

## Grouped Quarantined Inventory

### Contract Tests

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

### SQL / Migration

- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/supabase/migrations/20260428000002_vat_pricing_mode.sql`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/supabase/migrations/20260428000004_disable_photo_objet_red_invoice.sql`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/supabase/migrations/20260428000006_restore_wt03_feature_payload.sql`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/supabase/snippets/vui_vui_food_inclusive_validation.sql`

### Flutter Runtime

- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/lib/features/admin/providers/admin_sidebar_signal_provider.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/lib/features/inventory_purchase/inventory_purchase_provider.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/lib/features/inventory_purchase/inventory_purchase_screen.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/lib/features/inventory_purchase/inventory_purchase_service.dart`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/lib/features/payment/payment_detail_screen.dart`

### Assets / Config

- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/.vercelignore`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/assets/fonts/NotoSansKR-Bold.ttf`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/assets/fonts/NotoSansKR-Regular.ttf`

## Explicit Non-Restore List

- all SQL / migration files
- all Flutter runtime files
- all contract tests
- `assets/fonts`
- `.vercelignore`

## Next Safe Action

- continue `WIP audit / provenance reconciliation` only
- do not restore quarantined files yet
- do not reopen implementation from quarantined runtime or SQL surfaces
