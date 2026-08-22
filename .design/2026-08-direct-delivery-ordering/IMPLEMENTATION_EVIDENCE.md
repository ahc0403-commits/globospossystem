# Direct delivery implementation evidence

Date: 2026-08-21
Environment: local source tree and explicit disposable database `codex_direct_order_smoke_20260821`

## Implemented slices

- Public accountless storefront, dynamic menu/cart, KO/VI/EN copy, two address paths, real Google Map pin confirmation, detailed address/contact, consented store-scoped browser cache, and recoverable active request.
- Request-scoped polling chat, versioned cashier quote, VietQR, private proof upload, structural JPEG/PNG/WebP validation, and explicit non-automatic approval messaging.
- Separate cashier desk with manual Grab fee, proof viewer, SePay supporting evidence, mandatory approval acknowledgement, exact amount confirmation, rejection, Grab share link, and actual-cost variance.
- Atomic approval that calls the unchanged `process_payment` once and creates one completed delivery financial order plus a separate PII-free direct kitchen ticket.
- Separate direct kitchen board and state machine; no existing KDS provider or mutation is shared.
- Direct-only financial/hour/region analytics with minimum-cell privacy suppression, and service-role retention cleanup for expired exact PII.
- Disabled-by-default storefront settings with a database-enforced accounting approval gate.

## Verification evidence

- Frozen legacy hashes: QR, cashier, KDS provider/screen, payment service/calculator, report provider, print agent, effective payment/KDS/promotion migrations unchanged.
- Focused Flutter contracts: direct UI/model/role/isolation tests pass.
- Responsive storefront widget: 390×844, 768×1024, 1024×768, and 1440×900 pass without overflow; both address entry controls render at phone width.
- Actual 390×844 storefront screenshot: `screenshots/customer-menu-actual-390x844.png`.
- Edge tests: 9 passed, including origin/method/rate-limit/failure sanitization, modern secret selection, and spoofed/oversized image rejection.
- SQL migration applied successfully in the explicit disposable database. The following unrelated later migration fails there because `pg_cron` is restricted to the local `postgres` database; the direct migration was already committed before that independent failure.
- Direct SQL contract: 12 scenarios passed inside a rollback transaction:
  - zero legacy writes before approval;
  - proof locks quote without creating an order;
  - amount mismatch rolls back all legacy/direct financial writes;
  - one completed delivery order/payment/ticket;
  - idempotent approval replay;
  - separately attributable delivery-fee service item;
  - higher actual Grab fee records a negative variance without changing customer charge;
  - non-Grab HTTPS link rejected;
  - direct table/RPC boundary denied to public/authenticated clients;
  - enabled storefront requires accounting approval.
  - retention dry-run selects eligible terminal requests without mutation;
  - cleanup removes exact address/chat PII while preserving coarse location and financial audit.
- `flutter analyze`: pass.
- `flutter build web --release`: pass. Existing dependency WASM/font warnings remain informational; the JavaScript web build completed.
- `bash scripts/check_repo.sh`: pass end-to-end, including the full Flutter suite, Node contracts/audit/security scan, deployment and production-gate shell contracts, Photo Objet migration contract, release web build, and Git whitespace checks.

## Not executed by design

- No production database migration or Edge deployment.
- No production secret or Google API configuration.
- No storefront enablement or Google Business Profile link.
- No 20-order live store pilot.
- No production release or GitHub exact-SHA evidence.

These are operational release gates, not source implementation steps, and require explicit authorization.

## H1 database hardening evidence

Captured: 2026-08-21 21:11:52 +07

- Added `DIRECT_ORDER_DATA_CONTRACT.md`, covering all 14 direct tables,
  168 columns, PK/FK/UNIQUE/CHECK/delete behavior, defaults, readers, writers,
  PII/retention classes, legacy references, and all 19 business indexes.
- Added `supabase/tests/direct_delivery_schema_contract_test.sql`. On a clean
  application of the current direct migration it passed contracts for 168
  columns, 40 single-column foreign keys, 19 business indexes, 26 direct RPC
  signatures/privilege profiles, all direct-table RLS flags, absence of client
  policies/table grants, and the private proof-bucket limits.
- Expanded `direct_delivery_ordering_contract_test.sql` from 12 to 18 scenarios.
  The added matrix proves ordinary authenticated rejection, cross-store cashier
  rejection, kitchen ticket-only access, same-store cashier proof-path hiding,
  same-store admin settings/analytics/detail access, and default-deny coverage
  across every direct table.
- Reapplied `20260821130000_direct_delivery_ordering.sql` to the explicitly named
  disposable database `codex_direct_h1_20260821_2140`, after cloning the known
  effective precondition database and removing only its direct objects. Both SQL
  suites passed inside rollback transactions. The disposable database was then
  deleted and its absence verified; the pre-existing
  `codex_direct_order_smoke_20260821` database was preserved.
- Frozen database fingerprints were identical before and after direct migration:
  `process_payment(uuid,uuid,numeric,text)` definition MD5
  `570613b4a89070ff292c5d0ccd3f6ce9`; combined `orders`, `order_items`,
  `payments`, `inventory_transactions`, and `meinvoice_jobs` column-contract MD5
  `38f46769c105fb48402a528f89cba825`.
- The older preserved smoke database contains a stale 17-argument
  `direct_order_admin_upsert_storefront` overload. The new schema contract
  correctly rejects it as uncontracted. A clean application of the current
  migration contains only the contracted 18-argument function and passes.

This evidence is local source/disposable-DB verification only. No production
migration or deployment was performed.

## H2 Edge/API hardening evidence

Captured: 2026-08-21

- Added `DIRECT_ORDER_API_CONTRACT.md` as the authority for the common HTTP
  boundary, all 13 Edge actions, all 26 SQL RPCs, public error mapping, strict
  Flutter decode fields, side effects, locks, idempotency, and redaction.
- Replaced fuzzy SQL-error substring classification with an explicit 56-entry
  `sqlDomainErrorRegistry`. A Flutter source contract compares every direct SQL
  `RAISE EXCEPTION` code to the registry, so a new unregistered code fails CI.
  Unknown and integrity errors return only the sanitized 503 code.
- Added an exact 13-action actor/rate registry. The handler now requires JSON,
  enforces 65,536 actual UTF-8 bytes, preserves exact-origin/no-store envelopes,
  and fails closed when the client address cannot be derived.
- Google failures, proof path ownership, structural proof image limits, modern
  Supabase secret selection, internal cleanup authorization, and sanitized logs
  have injectable pure seams and tests. Reverse geocode now sends the current
  customer KO/VI/EN locale instead of forcing Vietnamese.
- Customer models now reject missing required fields, wrong types/timestamps,
  and uncontracted fields. Submit/message/cancel/upload/commit responses use
  exact field sets. `DirectOrderCopy.errorMessage` renders every public code in
  KO/VI/EN and uses a localized safe fallback for unknown codes.
- Added the direct Edge format/lint/type/test gate to `scripts/check_repo.sh`,
  which is invoked by the repository workflow. Existing legacy test
  expectations were not changed.
- Verification passed: Deno format check, lint, type check, 15 Edge tests,
  focused Flutter direct tests, focused Flutter analysis, shell syntax, and
  `REPOSITORY_SECRET_SCAN_PASS`.

No Edge Function was deployed and no production secret was read or changed.

## H3 state, concurrency, and rollback evidence

Captured: 2026-08-21 21:39:17 +07

- Added `DIRECT_ORDER_STATE_CONTRACT.md` as the persisted request, quote, and
  direct-ticket state authority. It documents the single PostgreSQL approval
  transaction, advisory/request/quote locks, terminal outcomes, optimistic
  ticket versioning, and failure-injection boundary without inventing new
  stored state names.
- Added rollback-safe state, precondition, and approval-failure SQL suites. On
  the clean current migration they passed 11 state scenarios, 17 amount and
  operational guard scenarios, and 8 injected rollback stages plus 8
  trigger-free retries. The rollback snapshot includes request/quote/proof,
  financial/order/item/payment/ticket/item, approval message/audit, inventory
  stock and transaction count, and meInvoice job count.
- Added `scripts/test_direct_delivery_concurrency.sh`. Against the explicitly
  named disposable database `codex_direct_h3_20260821_final`, 50 real
  two-connection identical approval races returned one common
  request/order/payment/ticket/final-total identity, first-call
  `idempotent=false`, replay `idempotent=true`, and zero duplicate graphs.
- The same runner passed approve-vs-reject and approve-vs-cancel with approval
  winning and the documented loser conflict, plus reject-vs-approve with
  rejection winning, `DIRECT_ORDER_REQUEST_NOT_APPROVABLE`, and an empty
  financial/legacy/ticket graph.
- Fixed the direct-only idempotent approval response to include the existing
  `ticket_id`, matching the first approval response and the API/state contract.
  The state suite now asserts identical order, payment, and ticket IDs on
  replay.
- The binding 21:30 behavior is tested deterministically through a guarded
  `codex_direct_*`-only clock fixture. Test clock substitutions, sleep triggers,
  and failure triggers exist only under `supabase/tests` or the runner; a source
  scan confirmed none exists in the production migration or Edge bundle, and
  the disposable database contained zero pause triggers after the runner.
- The clean disposable run passed schema/RLS, ordering, state, precondition,
  and failure suites before concurrency. The unchanged `process_payment`
  definition remained MD5 `570613b4a89070ff292c5d0ccd3f6ce9`; the disposable
  database was deleted and the pre-existing
  `codex_direct_order_smoke_20260821` database remained present.

This is local disposable-database evidence only. No production migration,
deployment, storefront enablement, or live order was performed.

## H4 Google address source evidence

Captured: 2026-08-21

- Added an explicit, web/stub browser-location adapter. Location permission is
  requested only after the customer presses the current-location control.
  Success moves the direct map and requires reverse geocoding; denial,
  unsupported, timeout, and unavailable results preserve the manual-pin
  fallback without confirming an address.
- Added one UUIDv4 Places session token per search. Autocomplete and its
  terminating details request receive the same token; selection, clearing, and
  abandonment rotate/discard it. Stale async responses are generation-guarded.
- Google provider parsing is fail-closed for invalid place/detail/coordinate
  data. Missing server key fails before traffic, and 400/429/5xx/timeout/
  malformed responses use safe map errors.
- Deno format/lint/type check and 19 Edge tests passed. Focused Flutter analysis
  and 23 direct UI/regression tests passed, covering four required viewport
  sizes, semantic map/location controls, location success/failure, token
  lifecycle, stale response suppression, cached-address reconfirmation, and
  map-loader failure.
- `GOOGLE_MAPS_SPIKE_EVIDENCE.md` separates completed source/no-traffic evidence
  from the unexecuted Google project, real-browser, usage, latency, and cost
  gates.

No Google project, key, billing setting, quota, browser/device run, production
deployment, storefront enablement, or Google Business Profile link was created
or changed.

## H4A viewer-locale evidence

Captured: 2026-08-21

- Added `DIRECT_ORDER_LOCALE_CONTRACT.md`. Every customer, cashier, kitchen,
  analytics, and settings surface now exposes the existing device-persisted
  KO/VI/EN switch even at compact widths. Staff rendering reads only the
  current viewer locale; request/session locale remains customer metadata.
- Added the direct-only localized snapshot/message helper. Cashier request
  items and kitchen ticket items select KO/VI/EN from immutable snapshots;
  recognized fixed system codes localize per viewer while text chat,
  rejection reason, provider address, detailed address, and notes remain exact.
- Added `display_name_ko` and `display_name_en` alongside the preserved
  `display_name_vi`. Approval copies all three request-time names, and the
  ticket RPC returns them without reading the live menu.
- Edge and SQL reject supplied locale values outside exact `ko`, `vi`, `en`.
  The Edge contract now has 20 passing tests. The SQL locale suite passed six
  scenarios, including all three session/request values, invalid values before
  writes, exact free-text retention, and ticket snapshot output.
- Flutter direct suites passed 26 pre-alert tests plus the locale matrix:
  customer x cashier 9 pairs, fixed/free message boundary, kitchen/admin three
  locales, selector wiring, responsive address paths, and legacy isolation.

## H4B cashier arrival-alert evidence

Captured: 2026-08-21

- Added `DIRECT_ORDER_ALERT_CONTRACT.md` and a 17-file SHA-256 stop manifest for
  existing cashier/kitchen/bank-transfer/SePay/emergency alert source, tests,
  and generated localization. The frozen hash test passes; none was edited.
- Added an INSERT-only `direct_orders` trigger through the existing payload-free
  `pos_live_events` mechanism and a cashier/store-scoped cursor RPC. It exposes
  only request ID, creation time, state, pending count, next cursor, and
  has-more; no customer locale or PII is present.
- Added a store-persisted cursor service, 500ms burst coalescing, Realtime drain,
  independent 10-second safety poll, route-local host for exactly `/cashier`
  and `/cashier/direct-orders`, localized banner/chip/action, and a separate
  non-verbal web/IO chime. Navigation never approves or mutates an order.
- Ten Flutter alert tests passed: exact frozen hashes, 3x3 customer/cashier
  locale independence, immediate viewer-locale banner rendering, strict cursor
  decode/persistence, burst plural, save-before-display, reconnect/route/app
  restart dedupe, first-baseline INSERT-race recovery, polling recovery,
  network/storage/audio containment,
  domain/store/logout isolation, and direct-only imports.
- The disposable SQL alert suite passed seven scenarios for first-device
  baseline, single INSERT event, replay zero, payload-minimal catch-up, update
  zero, rollback zero, cashier-only scope, and INSERT-only trigger definition.
  The full disposable database rerun passed schema 170/40/20/28, ordering 22,
  state 11, preconditions 17, failure/retry 16, locale 6, alert 7, and 50+3
  concurrency races. The disposable database was deleted; the prior smoke
  database was preserved.

No production migration, Realtime change, release, storefront enablement,
Google link, or live cashier rehearsal was performed.

## H5 final local hardening and harness evidence

Captured: 2026-08-21 22:35:00 +07

- The uncommitted implementation is anchored to base HEAD
  `fcd12e4d34317d2fb2717d2a94c60bc513590592`. Its 53 runtime files, excluding
  user-owned `CLAUDE.md` and design evidence, have manifest SHA-256
  `3b89425829b225e27ec69a156b877b157b7dde50fd4dfef061a7978a352da669`.
- A fresh disposable clone `codex_direct_h5_final_20260821` received the
  effective `pos_live_events` prerequisite followed by both direct migrations.
  It passed schema 170/40/20/28, ordering 22, state 11, preconditions 17,
  failure/retry 16, locale 6, and alert 7. The ordering suite creates an old
  uncommitted Storage row and proves that a matching proof message excludes it
  from orphan candidates.
- The concurrency runner passed 50 identical approval races and three terminal
  races with zero duplicate graphs. The unchanged `process_payment` definition
  remained MD5 `570613b4a89070ff292c5d0ccd3f6ce9`, and zero direct test triggers
  remained. The disposable database was deleted and the prior smoke database
  was preserved.
- Deno format, lint, type check, and 20 Edge tests passed. The final local
  `bash scripts/check_repo.sh` passed static analysis, 1,158 Flutter tests with
  two existing skips, 20 Edge tests, 59 Node tests, repository secret scan,
  deployment/SQL/Photo Objet contracts, release web build, and whitespace.
- The same 53-file runtime manifest was copied over detached base HEAD into a
  temporary isolated Git worktree. The manifest hash matched exactly and the
  complete repository gate passed again. The temporary worktree and log were
  deleted.
- `HARDENING_HARNESS_REPORT.md` records zero unresolved CRITICAL/HIGH/MEDIUM
  findings and one LOW maintainability item for the two large direct-only UI
  files. All security/state/retry/alert issues found during review were fixed
  and covered before this final run.

No commit, push, GitHub exact-SHA run, production migration, Edge deployment,
secret/Google project change, storefront enablement, Google Business Profile
publication, or live-store pilot was performed.
