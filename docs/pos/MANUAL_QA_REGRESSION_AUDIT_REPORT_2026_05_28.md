# Manual QA Regression Audit Report

Generated: 2026-05-28

## Summary

- Total checks: 77
- Failures: 0
- Blocking failures: 0
- Severity totals: CRITICAL=0, HIGH=0, MEDIUM=0, LOW=0, CONFIRMED=77

## Findings

No FAIL findings.

## Confirmed Coverage

| ID | Category | File | Evidence |
|---|---|---|---|
| MQA-00 | audit inputs | CLAUDE.md | Required audit input exists |
| MQA-00 | audit inputs | docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md | Required audit input exists |
| MQA-00 | audit inputs | docs/manual_test/GLOBOS_POS_manual_verification_checklist_2026-05-19.md | Required audit input exists |
| MQA-00 | audit inputs | integration_test/full_multi_account_smoke_test.dart | Required audit input exists |
| MQA-01 | role routing | lib/core/utils/role_routes.dart | lib/core/utils/role_routes.dart:20 |
| MQA-01 | role routing | lib/core/router/app_router.dart | lib/core/router/app_router.dart:133 |
| MQA-10 | testable surfaces | lib/features/waiter/waiter_screen.dart | lib/features/waiter/waiter_screen.dart:796 |
| MQA-10 | testable surfaces | lib/features/kitchen/kitchen_screen.dart | lib/features/kitchen/kitchen_screen.dart:225 |
| MQA-10 | testable surfaces | lib/features/cashier/cashier_screen.dart | lib/features/cashier/cashier_screen.dart:490 |
| MQA-10 | testable surfaces | lib/features/admin/admin_screen.dart | lib/features/admin/admin_screen.dart:252 |
| MQA-10 | testable surfaces | lib/features/payment/payment_detail_screen.dart | lib/features/payment/payment_detail_screen.dart:239 |
| MQA-10 | testable surfaces | lib/features/qc/qc_check_screen.dart | lib/features/qc/qc_check_screen.dart:232 |
| MQA-10 | testable surfaces | lib/features/qc/qc_review_screen.dart | lib/features/qc/qc_review_screen.dart:73 |
| MQA-10 | testable surfaces | lib/features/photo_ops/photo_ops_screen.dart | lib/features/photo_ops/photo_ops_screen.dart:56 |
| MQA-02 | viewport usability | lib/main.dart | lib/main.dart:89 |
| MQA-02 | viewport usability | lib/main.dart | lib/main.dart:110 |
| MQA-02 | viewport usability | lib/core/ui/toast/toast_primitives_extended.dart | lib/core/ui/toast/toast_primitives_extended.dart:518 |
| MQA-02 | viewport usability | lib/core/ui/toast/toast_sidebar.dart | lib/core/ui/toast/toast_sidebar.dart:92 |
| MQA-02 | viewport usability | lib/features/admin/admin_screen.dart | lib/features/admin/admin_screen.dart:59 |
| MQA-03 | primary job | docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md | Gate documented: Primary Job Gate |
| MQA-03 | primary job | docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md | Gate documented: Supporting Actions Gate |
| MQA-03 | primary job | docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md | Gate documented: Separate Workflow Gate |
| MQA-03 | primary job | docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md | Gate documented: Secondary Detail Gate |
| MQA-03 | primary job | docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md | Gate documented: Role Boundary Gate |
| MQA-03 | primary job | docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md | Gate documented: 3-Second Operator Gate |
| MQA-03 | primary job | docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md | Gate documented: Action Hierarchy Gate |
| MQA-03 | primary job | docs/pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md | Gate documented: Workflow Safety Gate |
| MQA-03 | primary job | lib/features/admin/tabs/tables_tab.dart | Forbidden marker absent: OrderWorkspace( |
| MQA-03 | primary job | lib/features/admin/tabs/tables_tab.dart | Forbidden marker absent: onProcessPayment: |
| MQA-03 | primary job | lib/features/admin/tabs/tables_tab.dart | Forbidden marker absent: onCycleSentItemStatus: |
| MQA-03 | primary job | lib/features/payment/payment_detail_screen.dart | lib/features/payment/payment_detail_screen.dart:899 |
| MQA-04 | cross-account chain | integration_test/full_multi_account_smoke_test.dart | integration_test/full_multi_account_smoke_test.dart:36 |
| MQA-04 | cross-account chain | integration_test/full_multi_account_smoke_test.dart | integration_test/full_multi_account_smoke_test.dart:40 |
| MQA-04 | cross-account chain | integration_test/full_multi_account_smoke_test.dart | integration_test/full_multi_account_smoke_test.dart:44 |
| MQA-04 | cross-account chain | integration_test/full_multi_account_smoke_test.dart | integration_test/full_multi_account_smoke_test.dart:60 |
| MQA-04 | cross-account chain | integration_test/full_multi_account_smoke_test.dart | integration_test/full_multi_account_smoke_test.dart:58 |
| MQA-04 | cross-account chain | integration_test/full_multi_account_smoke_test.dart | integration_test/full_multi_account_smoke_test.dart:1253 |
| MQA-05 | payment safety | lib/features/cashier/cashier_screen.dart | lib/features/cashier/cashier_screen.dart:1218 |
| MQA-05 | payment safety | lib/features/cashier/cashier_screen.dart | lib/features/cashier/cashier_screen.dart:1220 |
| MQA-05 | payment safety | lib/features/cashier/cashier_screen.dart | lib/features/cashier/cashier_screen.dart:1217 |
| MQA-05 | payment safety | lib/features/cashier/cashier_screen.dart | lib/features/cashier/cashier_screen.dart:1230 |
| MQA-05 | payment safety | lib/features/cashier/cashier_screen.dart | lib/features/cashier/cashier_screen.dart:377 |
| MQA-05 | payment safety | lib/features/cashier/cashier_screen.dart | lib/features/cashier/cashier_screen.dart:416 |
| MQA-05 | payment safety | lib/features/cashier/cashier_screen.dart | lib/features/cashier/cashier_screen.dart:424 |
| MQA-05 | payment safety | lib/features/payment/payment_provider.dart | Selecting a cashier order does not complete payment |
| MQA-06 | live sync scope | lib/features/kitchen/kitchen_provider.dart | lib/features/kitchen/kitchen_provider.dart:220 |
| MQA-06 | live sync scope | lib/features/payment/payment_provider.dart | lib/features/payment/payment_provider.dart:286 |
| MQA-06 | live sync scope | lib/features/table/table_provider.dart | lib/features/table/table_provider.dart:124 |
| MQA-06 | live sync scope | lib/features/order/order_provider.dart | lib/features/order/order_provider.dart:209 |
| MQA-06 | live sync scope | lib/features/payment/payment_detail_screen.dart | lib/features/payment/payment_detail_screen.dart:138 |
| MQA-07 | i18n | lib/l10n/app_en.arb | ARB file has no duplicate top-level keys |
| MQA-07 | i18n | lib/l10n/app_ko.arb | ARB file has no duplicate top-level keys |
| MQA-07 | i18n | lib/l10n/app_vi.arb | ARB file has no duplicate top-level keys |
| MQA-07 | i18n | lib/l10n/app_ko.arb | ARB key set matches English baseline |
| MQA-07 | i18n | lib/l10n/app_vi.arb | ARB key set matches English baseline |
| MQA-07 | i18n | lib/main.dart | lib/main.dart:43 |
| MQA-08 | web photo compatibility | lib/features/cashier/payment_proof_modal.dart | Forbidden marker absent: import 'dart:io'; |
| MQA-08 | web photo compatibility | lib/features/cashier/payment_proof_modal.dart | Forbidden marker absent: Image.file( |
| MQA-08 | web photo compatibility | lib/features/cashier/payment_proof_modal.dart | Forbidden marker absent: File(picked.path) |
| MQA-08 | web photo compatibility | lib/features/cashier/payment_proof_modal.dart | lib/features/cashier/payment_proof_modal.dart:234 |
| MQA-08 | web photo compatibility | lib/features/admin/tabs/qc_tab.dart | Forbidden marker absent: import 'dart:io'; |
| MQA-08 | web photo compatibility | lib/features/admin/tabs/qc_tab.dart | Forbidden marker absent: Image.file( |
| MQA-08 | web photo compatibility | lib/features/admin/tabs/qc_tab.dart | Forbidden marker absent: File(picked.path) |
| MQA-08 | web photo compatibility | lib/features/admin/tabs/qc_tab.dart | lib/features/admin/tabs/qc_tab.dart:722 |
| MQA-08 | web photo compatibility | lib/features/super_admin/super_admin_screen.dart | Forbidden marker absent: import 'dart:io'; |
| MQA-08 | web photo compatibility | lib/features/super_admin/super_admin_screen.dart | Forbidden marker absent: Image.file( |
| MQA-08 | web photo compatibility | lib/features/super_admin/super_admin_screen.dart | Forbidden marker absent: File(picked.path) |
| MQA-08 | web photo compatibility | lib/features/super_admin/super_admin_screen.dart | lib/features/super_admin/super_admin_screen.dart:604 |
| MQA-08 | web photo compatibility | lib/core/services/payment_proof_service.dart | lib/core/services/payment_proof_service.dart:43 |
| MQA-09 | numeric input | lib/ | No direct controller numeric parse patterns found |
| MQA-09 | numeric input | lib/core/utils/number_input_utils.dart | lib/core/utils/number_input_utils.dart:2 |
| MQA-04 | kitchen handoff | lib/features/kitchen/kitchen_screen.dart | lib/features/kitchen/kitchen_screen.dart:49 |
| MQA-04 | kitchen handoff | lib/features/kitchen/kitchen_screen.dart | lib/features/kitchen/kitchen_screen.dart:90 |
| MQA-04 | kitchen handoff | lib/features/kitchen/kitchen_screen.dart | lib/features/kitchen/kitchen_screen.dart:138 |
| MQA-04 | kitchen handoff | lib/features/kitchen/kitchen_screen.dart | lib/features/kitchen/kitchen_screen.dart:585 |
| MQA-04 | kitchen handoff | lib/features/kitchen/kitchen_screen.dart | lib/features/kitchen/kitchen_screen.dart:963 |
| MQA-10 | testable surfaces | integration_test/full_multi_account_smoke_test.dart | integration_test/full_multi_account_smoke_test.dart:10 |
