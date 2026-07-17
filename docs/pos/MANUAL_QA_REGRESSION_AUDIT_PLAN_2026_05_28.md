# Manual QA Regression Audit Plan

Date: 2026-05-28
Scope: GLOBOS POS Flutter app, POS manual verification surface, and regression
contracts derived from repeated manual QA fixes.

## Source Rules

- `CLAUDE.md` remains binding.
- Do not rerun completed Phase -1, Phase 0, Phase 1, Phase 2, or Phase 3 work.
- Do not change POS/Office database coupling while auditing UI regressions.
- Payment completion must not depend on WeTax availability.
- Office accounts in the POS login flow are expected to be out of POS scope.

## Repeated Manual QA Fix Taxonomy

| ID | Pattern | Regression Signal | Required Audit Coverage | Severity |
|---|---|---|---|---|
| MQA-01 | Role routing and deep links | Wrong landing page, stale role menu after logout, unguarded `/payments/:id`, broken `/admin?tab=...` | `role_routes.dart`, `app_router.dart`, `navigation_surface_contract_test.dart`, multi-account smoke | CRITICAL |
| MQA-02 | Small viewport usability | Button unreachable, desktop shell on phone landscape, bottom content clipped, text overlap | scroll behavior, short-height layouts, compact shells, mobile/landscape screenshots | HIGH |
| MQA-03 | One primary job per screen | Screen mixes cashier, waiter, kitchen, admin, report, or raw diagnostic work as equal actions | POS primary-job contract, admin tab contracts, cashier/kitchen/waiter contracts | HIGH |
| MQA-04 | Cross-account order chain | Waiter order does not appear in Kitchen/Cashier, status handoff stale, manual refresh required | integration smoke order capture, realtime store filters, kitchen/cashier provider contracts | CRITICAL |
| MQA-05 | Payment action safety | Selecting order or method completes payment, proof/red invoice blocks completion, receipt not tied to completed payment | cashier contract, payment provider, payment detail, receipt builder | CRITICAL |
| MQA-06 | Live sync store scope | Brand/admin sees sibling store realtime data or stale active-store channels | `LiveSyncScope`, provider subscriptions, entity filters | HIGH |
| MQA-07 | i18n and font readiness | Missing ARB keys, duplicate ARB keys, hard-coded operational labels, Korean font flash | ARB parity, generated localizations, web font warm-up | MEDIUM |
| MQA-08 | Web photo compatibility | `dart:io File`, `Image.file`, or path-based image preview breaks web | payment proof, QC, super admin photo pickers and services | HIGH |
| MQA-09 | Operator numeric input | Comma-formatted numbers are rejected or parsed incorrectly | `parseDecimalInput`, `parseIntInput`, form source scan | MEDIUM |
| MQA-10 | Testable surfaces | Smoke/manual tests cannot locate nav/root/action widgets reliably | root keys, nav keys, activation caps, manual checklist parity | MEDIUM |

## Whole-App Audit Matrix

| Surface | MQA-01 | MQA-02 | MQA-03 | MQA-04 | MQA-05 | MQA-06 | MQA-07 | MQA-08 | MQA-09 | MQA-10 |
|---|---|---|---|---|---|---|---|---|---|---|
| Login/Auth/Consent | required | required | required | n/a | n/a | n/a | required | n/a | n/a | required |
| Waiter `/waiter` | required | required | required | required | must block | required | required | n/a | required | required |
| Order workspace | n/a | required | required | required | must block outside cashier | required | required | n/a | required | required |
| Kitchen `/kitchen` | required | required | required | required | n/a | required | required | n/a | n/a | required |
| Cashier `/cashier` | required | required | required | required | required | required | required | required | required | required |
| Payment detail `/payments/:id` | required | required | required | n/a | required | required | required | n/a | n/a | required |
| Admin shell/tabs | required | required | required | n/a | must block operator work | required | required | QC photo only | required | required |
| Super admin | required | required | required | n/a | n/a | required | required | required | required | required |
| QC check/review | required | required | required | n/a | n/a | required | required | required | required | required |
| Photo ops | required | required | required | n/a | n/a | required | required | required | n/a | required |

## Execution Plan

1. Run static regression audit:

   ```sh
   node scripts/manual_qa_regression_audit.js --markdown docs/pos/MANUAL_QA_REGRESSION_AUDIT_REPORT_2026_05_28.md
   ```

2. Run contract tests:

   ```sh
   flutter test test/navigation_surface_contract_test.dart test/role_routes_contract_test.dart test/web_scroll_contract_test.dart test/i18n_locale_contract_test.dart test/numeric_input_parsing_contract_test.dart test/live_sync_scope_contract_test.dart test/web_photo_upload_contract_test.dart test/cashier_waiter_workspace_i18n_contract_test.dart test/kitchen_operational_attention_contract_test.dart test/payment_detail_contract_test.dart test/pos_primary_job_contract_test.dart
   ```

3. Run app-level checks:

   ```sh
   flutter analyze
   flutter test
   ```

4. Run the multi-account smoke test only against an approved staging/preview
   environment with test data:

   ```sh
   flutter test integration_test/full_multi_account_smoke_test.dart
   ```

5. Complete manual viewport pass on at least:
   `1366x768`, `1024x768`, `844x390`, `390x844`.

## Failure Classification

| Severity | Definition | Stop Rule |
|---|---|---|
| CRITICAL | Order, payment, auth, role boundary, or cross-account chain can be wrong | Stop release |
| HIGH | Screen is usable only with workaround, leaks scope, or breaks web/mobile class | Stop release unless consciously deferred |
| MEDIUM | Repeated operator friction, missing localization, scan/testability drift | Fix before final manual pass |
| LOW | Documentation, polish, or non-blocking evidence gap | Track in follow-up |
| CONFIRMED | Expected constraint verified | No action |

## Completion Criteria

- Static audit has no CRITICAL or HIGH failures.
- `flutter analyze` passes.
- `flutter test` passes, or any failure is documented as unrelated existing WIP.
- Multi-account smoke either passes or records a concrete external blocker.
- Manual P0/P1 checklist items pass on desktop and compact viewport.
- The generated report lists the first blocking issue, if any.
