# Direct delivery hardening harness report

Date: 2026-08-21 22:35 +07
Scope: local source, disposable database, and isolated-worktree preflight only
Base Git HEAD: `fcd12e4d34317d2fb2717d2a94c60bc513590592`
Runtime manifest: 53 files, SHA-256
`3b89425829b225e27ec69a156b877b157b7dde50fd4dfef061a7978a352da669`

The direct-delivery source hardening review passes with no unresolved
CRITICAL, HIGH, or MEDIUM finding. This is not a production release approval:
the source is not committed or pushed, required GitHub checks have not run on
an exact pushed SHA, Google project/browser/cost gates are incomplete, and no
storefront, deployment, Google Business Profile link, or live pilot was
enabled.

## 1. Loaded design documents

The review used `DESIGN_BRIEF.md`, `ADR-001_ISOLATED_FINANCE_AND_FULFILLMENT.md`,
`REGRESSION_SAFETY.md`, `DIRECT_ORDER_DATA_CONTRACT.md`,
`DIRECT_ORDER_API_CONTRACT.md`, `DIRECT_ORDER_STATE_CONTRACT.md`,
`DIRECT_ORDER_LOCALE_CONTRACT.md`, `DIRECT_ORDER_ALERT_CONTRACT.md`,
`GOOGLE_MAPS_SPIKE_EVIDENCE.md`, `UI_SPEC.md`, `ROLLOUT_RUNBOOK.md`, and
`TASKS.md` as the source contract. `CLAUDE.md` and the checked-out runtime were
treated as higher authority when release-state terminology was evaluated.

## 2. Loaded code structure

- Flutter direct feature: 24 direct-only files. Customer storefront, cashier,
  kitchen, analytics, settings, locale copy, accountless service/cache, Google
  adapters, and isolated arrival alert are under `lib/features/direct_order/`.
- Integration surface: additive route, role-route, navigation, dependency,
  Supabase function config, web map-loader, and repository-gate wiring only.
- Server boundary: one `direct-order-public` Edge Function with 13 exact
  actions; two additive migrations; seven SQL suites plus two guarded fixtures
  and one two-connection concurrency runner.
- Data boundary: 14 RLS-enabled, policy-free direct tables; one private proof
  bucket; 28 catalog-contracted direct functions; no renamed Office coupling
  object.
- Frozen legacy boundary: existing QR, cashier, KDS, payment, report, print,
  bank-transfer, SePay, kitchen, and emergency-alert source remains hash-bound.

## 3. Checks by category

### Security and privacy — CONFIRMED

- Catalog test passed 170 columns, 40 single-column FKs, 20 indexes, and 28
  exact functions. `anon` and ordinary authenticated table access remains
  denied; service/staff access is only through the contracted boundaries.
- Edge tests passed exact origin, POST/JSON/body-size rules, client-address
  fail-closed behavior, explicit error sanitization, named modern Supabase
  secret selection, proof path/image validation, and internal cleanup auth.
- Proof upload reservations are limited to 10 per minute. Abandoned proof
  objects are eligible only after 24 hours, only when no committed proof
  message references them, and only through a bounded service-role lookup plus
  validated Storage removal.
- Repository secret scan passed. Customer/session/address/chat/proof/bank/Grab
  data is absent from alert payloads and metrics.

### Tenant, data, and retention — CONFIRMED

- Cross-session submit idempotency keys and cross-store approval replay are
  rejected. Same-store replay returns the original financial identity.
- Exact address/chat/proof PII is separated from coarse location facts and
  permanent financial audit. Retention deletes exact PII only after the store
  window; abandoned uploads are separately bounded.
- Runtime orphan-proof test proved that an old uncommitted object is returned
  and that adding the matching proof message immediately excludes it.

### State, payment, and failure atomicity — CONFIRMED

- Proof and SePay evidence never approve. Only explicit cashier approval from
  `awaiting_payment_review` can enter the financial transaction.
- Approval holds an advisory lock and row locks, verifies exact amount and
  operating preconditions, calls the unchanged `process_payment` once, and
  reconciles one order/payment/ticket before commit.
- The disposable database passed ordering 22, state 11, precondition 17,
  rollback/retry 16, locale 6, and alert 7 scenarios. Fifty identical approval
  races and three competing terminal races produced zero duplicate graphs.
- `process_payment(uuid,uuid,numeric,text)` remained MD5
  `570613b4a89070ff292c5d0ccd3f6ce9`; no test trigger remained.

### Customer, staff UI, maps, and locale — CONFIRMED

- Customer, cashier, kitchen, analytics, and settings surfaces use the current
  viewer's selected KO/VI/EN locale. Request locale never controls a staff
  screen. User/provider free text remains unchanged.
- Both address routes exist: paste/search followed by map confirmation, and
  direct map pin/reverse geocode. Detail address stays mandatory; cached
  addresses require reconfirmation.
- Four viewport contracts, current-location permission/fallback, Places token
  lifecycle, stale responses, map load failure, and nine customer/cashier
  locale pairs passed without Google traffic.
- A real restricted Google project, physical browser/device matrix, and usage,
  latency, and cost reconciliation remain external H4 gates.

### Arrival alert and legacy regression — CONFIRMED

- The direct alert is INSERT-only, payload-free, cashier/store scoped, and
  route-local to `/cashier` and `/cashier/direct-orders`. It only displays,
  chimes, and navigates; it cannot quote, approve, or create a kitchen ticket.
- Cursor save-before-display, burst coalescing, polling recovery, route/restart
  dedupe, and the first-baseline INSERT race passed. Copy follows the receiving
  viewer; English title is exactly `Delivery order`.
- Ten direct alert tests include the frozen 17-file alert manifest. Existing
  bank-transfer, SePay, kitchen, and emergency alert source/copy/sound/cursor/
  acknowledgement behavior was not modified.
- Local and isolated `bash scripts/check_repo.sh` both passed: static analysis,
  1,158 Flutter tests with two existing skips, 20 Edge tests, 59 Node tests,
  security/deployment/Photo Objet contracts, release web build, and whitespace.

## 4. Findings

### CRITICAL

None.

### HIGH

None.

### MEDIUM

None.

### LOW — DDO-H5-001: direct UI files are concentrated

`direct_order_storefront_screen.dart` is 1,687 lines and
`direct_order_cashier_screen.dart` is 1,025 lines. The feature is isolated and
tested, so this is not a release correctness defect, but later changes will be
harder to review. Decompose them by address/cart/status and queue/detail/action
panels after the controlled pilot, when behavior can be held by the current
tests. A pre-pilot refactor would add unnecessary regression surface.

### CONFIRMED fixes made during review

- Session/store scope is checked before submit/approval idempotent replay.
- The browser persists a pending submit UUID before network I/O and clears it
  only after the active request identity is safely cached.
- Exact proof-commit replay is idempotent and storage paths are unique.
- Cashier actions force an immediate post-action refresh.
- An INSERT received during the first alert baseline cannot be swallowed.
- Uncommitted proof uploads older than 24 hours are bounded and cleaned; upload
  reservation rate is reduced to 10 per minute.

## 5. Priority fix and release list

1. Complete the restricted Google test project, real-browser matrix, and
   address-quality/usage/cost evidence while the storefront stays disabled.
2. Obtain accounting, operations, privacy, security, support, and emergency
   stop approvals; then commit and push a reviewed exact SHA and require the
   repository GitHub checks on that SHA.
3. Use the guarded deployment workflow only after separate authorization, run
   the private 20-order one-store pilot, and publish the Google Business Profile
   link last.
4. After pilot stability, address LOW DDO-H5-001 without changing behavior.

Review-harness note: local Waza 3.31.2 reported 3.34.0 available. It was not
updated during this review so the verification environment remained stable.
