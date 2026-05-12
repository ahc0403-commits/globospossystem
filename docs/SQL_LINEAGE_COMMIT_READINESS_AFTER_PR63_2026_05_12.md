# SQL Lineage Commit Readiness After PR63 — 2026-05-12

## Executive verdict

The two existing documentation reports are **safe to commit as evidence-only documentation**.

They are internally consistent on the points that matter for phase gating:

- `supabase/schema.sql` is tracked but `0 bytes`
- current phase is still **truth stabilization**
- next implementation phase is still **NO-GO**
- untracked SQL artifacts are **not proven**
- runtime WIP must **not** be connected yet

The documentation can be committed.

The untracked runtime WIP, SQL WIP, snippet WIP, asset WIP, and contract-test WIP must remain **uncommitted**.

## Report consistency check

Reviewed reports:

- [WIP_TRIAGE_AFTER_PR63_2026_05_12.md](/Users/andreahn/globos_pos_system/docs/WIP_TRIAGE_AFTER_PR63_2026_05_12.md)
- [SQL_LINEAGE_RECONCILIATION_AFTER_PR63_2026_05_12.md](/Users/andreahn/globos_pos_system/docs/SQL_LINEAGE_RECONCILIATION_AFTER_PR63_2026_05_12.md)

### Consistent findings

Both reports agree that:

1. `main` is at `fbf8a7bdbc8d12a7ba32a30f47a986c2d43e0136`
2. `supabase/schema.sql` is tracked but empty
3. `payment_detail_screen.dart` is not safe to connect
4. `inventory_purchase/*` is not safe to mount
5. `admin_sidebar_signal_provider.dart` is not safe to connect
6. the three untracked migration files are not safe to apply
7. `vui_vui_food_inclusive_validation.sql` is not safe to apply
8. current phase is still truth stabilization
9. next implementation phase remains blocked

### Non-conflicting differences

The two reports differ in emphasis, not in conclusion:

- the WIP triage report covers the whole untracked working tree, including assets, runtime WIP, and tests
- the SQL lineage report narrows to SQL provenance and runtime safety implications
- the WIP triage report marks `.vercelignore` as potentially safe for its own small PR
- the SQL report does not discuss `.vercelignore` because it is outside SQL lineage scope

This is not a contradiction. It is a scope difference.

### Consistency verdict

The reports are **internally consistent enough to commit as documentation evidence**.

## Current GO / NO-GO state

Current state is **NO-GO** for the next implementation phase.

Why the NO-GO remains valid:

- `supabase/schema.sql` is still `0 bytes`
- untracked SQL artifacts are still unproven
- there is still no trusted tracked schema content that proves those SQL artifacts
- runtime WIP is still unmounted / unconnected
- contract tests are still local-only and not reliable tracked phase gates

This means no runtime feature phase should begin yet.

## Safe-to-commit documentation list

These files are safe to commit as documentation-only evidence:

- [WIP_TRIAGE_AFTER_PR63_2026_05_12.md](/Users/andreahn/globos_pos_system/docs/WIP_TRIAGE_AFTER_PR63_2026_05_12.md)
- [SQL_LINEAGE_RECONCILIATION_AFTER_PR63_2026_05_12.md](/Users/andreahn/globos_pos_system/docs/SQL_LINEAGE_RECONCILIATION_AFTER_PR63_2026_05_12.md)
- [SQL_LINEAGE_COMMIT_READINESS_AFTER_PR63_2026_05_12.md](/Users/andreahn/globos_pos_system/docs/SQL_LINEAGE_COMMIT_READINESS_AFTER_PR63_2026_05_12.md)

Why these are safe:

- they do not modify runtime behavior
- they do not modify SQL
- they do not change schema
- they do not connect WIP
- they preserve the current truth-stabilization posture

## Must-not-commit WIP list

These files must remain uncommitted for now:

### Runtime / UI WIP

- [payment_detail_screen.dart](/Users/andreahn/globos_pos_system/lib/features/payment/payment_detail_screen.dart)
- [inventory_purchase_provider.dart](/Users/andreahn/globos_pos_system/lib/features/inventory_purchase/inventory_purchase_provider.dart)
- [inventory_purchase_screen.dart](/Users/andreahn/globos_pos_system/lib/features/inventory_purchase/inventory_purchase_screen.dart)
- [inventory_purchase_service.dart](/Users/andreahn/globos_pos_system/lib/features/inventory_purchase/inventory_purchase_service.dart)
- [admin_sidebar_signal_provider.dart](/Users/andreahn/globos_pos_system/lib/features/admin/providers/admin_sidebar_signal_provider.dart)

### SQL lineage-risk artifacts

- [20260428000002_vat_pricing_mode.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260428000002_vat_pricing_mode.sql)
- [20260428000004_disable_photo_objet_red_invoice.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260428000004_disable_photo_objet_red_invoice.sql)
- [20260428000006_restore_wt03_feature_payload.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260428000006_restore_wt03_feature_payload.sql)
- [vui_vui_food_inclusive_validation.sql](/Users/andreahn/globos_pos_system/supabase/snippets/vui_vui_food_inclusive_validation.sql)

### Contract / audit tests

- all current untracked `test/*contract_test.dart`
- [audit_findings_contract_test.dart](/Users/andreahn/globos_pos_system/test/audit_findings_contract_test.dart)

### Asset / tooling WIP not part of this documentation-evidence commit

- [.vercelignore](/Users/andreahn/globos_pos_system/.vercelignore)
- all files under [assets/fonts/](/Users/andreahn/globos_pos_system/assets/fonts)

Why these must not be committed now:

- they either need schema provenance
- or need router/provider/runtime provenance
- or are test-only local contracts
- or are unrelated WIP that would dilute the evidence-only commit

## Next gate after documentation commit

After the documentation-only commit, the next gate is still:

**SQL lineage reconciliation with a real trusted schema baseline**

That next gate must answer:

1. how `supabase/schema.sql` becomes a real reflected baseline instead of a `0-byte` placeholder
2. whether the three untracked migration files are:
   - canonical but missing from tracked history
   - superseded by tracked migration lineage
   - obsolete local artifacts that should be archived
3. whether `vui_vui_food_inclusive_validation.sql` should remain validation-only or be archived

Only after that gate can runtime provenance be reopened.

## Exact recommended git add command

```bash
git add docs/WIP_TRIAGE_AFTER_PR63_2026_05_12.md \
  docs/SQL_LINEAGE_RECONCILIATION_AFTER_PR63_2026_05_12.md \
  docs/SQL_LINEAGE_COMMIT_READINESS_AFTER_PR63_2026_05_12.md
```

## Exact recommended commit message

```text
docs(pos): add WIP and SQL lineage evidence after PR #63
```

## Final git status --short snapshot

```text
?? .vercelignore
?? assets/fonts/
?? docs/SQL_LINEAGE_RECONCILIATION_AFTER_PR63_2026_05_12.md
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
