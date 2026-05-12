# Contract Test Drift Matrix — 2026-05-12

## Verdict

No safe quarantined contract-test restore slice has been identified yet.

The tracked POS baseline remains healthy, but every restore candidate attempted
so far either failed against current tracked runtime expectations or depends on
quarantined runtime / unresolved SQL provenance.

## Baseline

- Branch at time of audit: `audit/contract-test-safe-slice`
- Repository baseline before and after restore attempts:
  - `flutter analyze`: PASS
  - `flutter test`: PASS
  - `git status --short`: clean
- Scope of this audit:
  - quarantined `test/*contract_test.dart` only
  - no runtime Flutter restore
  - no SQL migration restore
  - no snippet restore

## Restore Attempts Already Tried

The following quarantined contract tests were restored into the repo and then
removed again after validation failure:

| File | Result | Primary reason |
| --- | --- | --- |
| `test/admin_table_layout_editor_contract_test.dart` | Failed | Expects floor-layout editor contract not present in tracked `tables_tab.dart` |
| `test/app_nav_scope_contract_test.dart` | Failed | Expects scoped-store nav contract not present in tracked `app_nav_bar.dart` |
| `test/report_summary_contract_test.dart` | Failed | Expects report summary/i18n strings not present in tracked `reports_tab.dart` |
| `test/waiter_i18n_contract_test.dart` | Failed | Expects waiter/order workspace localization strings not present in tracked files |
| `test/waiter_buffet_guest_count_contract_test.dart` | Failed | Expects no fallback guest-count path, but tracked `waiter_screen.dart` still contains `_selectedGuestCount ?? 1` |

## Drift Matrix

| File | Classification | Primary blocker | Safe next action |
| --- | --- | --- | --- |
| `test/admin_table_layout_editor_contract_test.dart` | tracked_runtime_drift | Floor-layout editor contract differs from tracked admin tables UI | Keep quarantined; document drift only |
| `test/admin_tables_order_workspace_contract_test.dart` | tracked_runtime_drift | Order item cancel/edit hooks differ from tracked admin tables flow | Keep quarantined; review against current `tables_tab.dart` |
| `test/admin_tables_payment_amount_contract_test.dart` | tracked_runtime_drift | Payment amount expectation does not match tracked code shape | Keep quarantined |
| `test/app_nav_scope_contract_test.dart` | tracked_runtime_drift | Scoped-store nav provider contract differs from tracked `app_nav_bar.dart` | Keep quarantined |
| `test/audit_findings_contract_test.dart` | sql_or_backend_provenance_required | References SQL / backend findings outside tracked proven baseline | Keep quarantined until SQL provenance closes |
| `test/cashier_receipt_contract_test.dart` | tracked_runtime_drift | Receipt state/fields differ from tracked cashier/runtime code | Keep quarantined |
| `test/daily_closing_role_contract_test.dart` | manual_review_required | Role gating assertions need direct comparison against tracked daily closing flow | Keep quarantined |
| `test/delivery_scope_reload_contract_test.dart` | tracked_runtime_drift | Scoped reload contract differs from tracked provider/UI flow | Keep quarantined |
| `test/einvoice_scope_contract_test.dart` | tracked_runtime_drift | Scoped einvoice expectations differ from tracked `einvoice_tab.dart` | Keep quarantined |
| `test/inventory_purchase_flutter_contract_test.dart` | quarantined_runtime_required | Imports quarantined inventory runtime files directly | Keep quarantined until runtime slice is proven |
| `test/inventory_scope_contract_test.dart` | manual_review_required | Inventory backend contract depends on unresolved SQL/runtime provenance | Keep quarantined |
| `test/kitchen_cashier_i18n_contract_test.dart` | tracked_runtime_drift | Expected kitchen/cashier localized copy differs from tracked files | Keep quarantined |
| `test/kitchen_realtime_contract_test.dart` | tracked_runtime_drift | Realtime event expectations differ from tracked provider logic | Keep quarantined |
| `test/operational_offline_contract_test.dart` | tracked_runtime_drift | Offline behavior expectations differ from tracked operational flow | Keep quarantined |
| `test/order_mutation_role_contract_test.dart` | manual_review_required | Role mutation assertions depend on current backend/runtime contract | Keep quarantined |
| `test/order_total_contract_test.dart` | sql_or_backend_provenance_required | Order total contract references unresolved tax / payment lineage | Keep quarantined |
| `test/order_workspace_realtime_contract_test.dart` | tracked_runtime_drift | Realtime insert/delete expectations differ from tracked order provider | Keep quarantined |
| `test/payment_detail_contract_test.dart` | quarantined_runtime_required | Depends on quarantined `payment_detail_screen.dart` runtime slice | Keep quarantined |
| `test/photo_ops_role_contract_test.dart` | sql_or_backend_provenance_required | Role/service expectations require unresolved backend provenance | Keep quarantined |
| `test/qc_role_contract_test.dart` | sql_or_backend_provenance_required | QC/admin role expectations differ from tracked contract/provenance | Keep quarantined |
| `test/remaining_i18n_contract_test.dart` | quarantined_runtime_required | Includes `payment_detail` localization expectations tied to quarantined runtime | Keep quarantined |
| `test/report_summary_contract_test.dart` | tracked_runtime_drift | Report summary card expectations differ from tracked reports UI | Keep quarantined |
| `test/staff_account_role_guard_contract_test.dart` | manual_review_required | Role guard assertions need direct tracked-flow comparison | Keep quarantined |
| `test/table_layout_model_contract_test.dart` | manual_review_required | Model-level contract needs direct tracked model comparison | Keep quarantined |
| `test/waiter_buffet_guest_count_contract_test.dart` | tracked_runtime_drift | Tracked waiter flow still contains synthetic guest-count fallback | Keep quarantined |
| `test/waiter_floor_layout_contract_test.dart` | tracked_runtime_drift | Expects floor-layout file/contract not present in tracked waiter flow | Keep quarantined |
| `test/waiter_i18n_contract_test.dart` | tracked_runtime_drift | Waiter/workspace localization expectations differ from tracked runtime | Keep quarantined |
| `test/waiter_table_realtime_contract_test.dart` | tracked_runtime_drift | Realtime table event contract differs from tracked table provider | Keep quarantined |
| `test/wt08_reconciliation_contract_test.dart` | sql_or_backend_provenance_required | WT08 reconciliation assertions depend on unresolved backend lineage | Keep quarantined |

## What This Means

- No quarantined contract test is currently approved for restore as-is.
- The dominant failure mode is not compile breakage from the tests
  themselves; it is expectation drift against tracked runtime behavior.
- A smaller subset additionally depends on quarantined runtime files or
  unresolved SQL / backend provenance, which makes restore unsafe even before
  asserting behavior.

## Recommended Next Action

Stay in audit mode.

The next safe move is not another blind test restore attempt. Instead:

1. Use this matrix to select one tracked-runtime drift target area.
2. Compare the quarantined test against the current tracked implementation.
3. Decide one of:
   - rewrite test to match tracked truth
   - archive test as obsolete
   - defer test until matching runtime / SQL lineage is intentionally restored

## Explicit Non-Action

- No quarantined test file was kept restored after this audit.
- No runtime Flutter file was restored.
- No SQL migration or snippet was restored.
- No commit was created from any quarantined contract test in this step.
