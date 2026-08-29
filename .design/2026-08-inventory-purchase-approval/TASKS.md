# Build Tasks: Inventory Purchase Approval and Receiving Verification

Generated from: `.design/2026-08-inventory-purchase-approval/DESIGN_BRIEF.md`
Date: 2026-08-27

## Implementation checkpoint — 2026-08-27

Core workflow implementation is complete in the working tree and has not been
deployed to production.

- [x] Dedicated `inventory_orderer` identity, route guards, fixed-account
  template, and shared responsive order/approval/receiving workspace.
- [x] Dedicated legal-entity-scoped `inventory_accounting` identity, one-time
  legal-entity provisioning, consolidated all-brand/all-store queue, and
  accounting-only final receipt confirmation gate.
- [x] Draft create/edit/delete/submit plus sequential Store Manager and Brand
  Manager approval with immutable approval snapshot and event history.
- [x] Approved PDF generation, private storage, download/print, and approval
  history layout. Email and Zalo are deferred and no dispatch worker ships.
- [x] Quantity-driven receipt draft auto-creation/autosave, private supplier
  statement upload, independent verifier confirmation, and stock mutation only
  inside the atomic final-verification RPC.
- [x] Quick supplier-price changes, effective-dated history, and previewed atomic
  Excel bulk updates.
- [x] Additive migration, SQL preflight/verification, Flutter contract tests,
  Edge Function type-check, and responsive workflow implementation.
- [ ] Production deployment, pilot-store execution, and operational recovery
  dashboards remain release
  activities and require an explicit deployment request.

## Foundation

- [ ] **Ship the draft-first state contract as an additive migration**: Add
  `store_approved` and `brand_approved`, row versioning, approval snapshot
  metadata, append-only approval events, server-calculated totals, and
  transition RPCs while preserving legacy `office_*` functions/statuses; prove
  invalid order, wrong-scope, self-approval, and stale-version transitions fail
  in SQL/preflight tests. _Modifies: `inventory_purchase_orders`, purchase RPCs,
  and existing contract tests; creates: approval-event contract._

- [ ] **Prove the approved-PDF artifact path early**: Generate one multilingual
  approved order PDF with bundled Pretendard font in a local Supabase Edge
  Function test, keep it below the planned provider limits, upload it to a
  private bucket, persist SHA-256/version metadata, and document the fallback if
  server generation is not viable. _Reuses: current PDF layout/content and font;
  modifies: `InventoryPurchaseDocumentService`; creates: document job/artifact
  proof-of-concept. Depends on: draft-first state contract._

- [ ] **Add the dedicated inventory-orderer identity end to end**: Add the
  store-scoped `inventory_orderer` role/account type, one default Bunsik Store
  Setup template, provisioning support, localized role labels, known-role/auth
  handling, and route tests; verify this identity cannot reach KDS, cashier,
  admin settings, supplier banking, another store, or manager approvals.
  _Modifies: Store Setup templates/components, fixed-account migration/function,
  provisioning Edge Function, auth/route/role utilities, localization, and role
  contract tests; creates: `/inventory-orders` authorization surface._

- [ ] **Add effective-dated supplier-price history and safe bulk contracts**:
  Append every manual/Excel supplier-item price change with actor, old/new
  price, tax, effective date, source, import ID, note, and timestamp; add a
  price-only dry-run/apply RPC that validates the full batch and commits
  atomically without mutating purchase-order snapshots. _Reuses: supplier-item
  scope checks and `bulk_upsert_inventory_ingredients` validation/audit
  patterns; creates: price-history table, preview/apply RPCs, SQL/preflight
  tests._

## Core Ordering Workflow

- [ ] **Build the orderer draft workspace**: Add a purpose-built
  `/inventory-orders` screen with Drafts and workflow-status filters, supplier
  and product selection, line add/remove, quantity/date/memo inputs, converted
  unit display, and server-refreshed totals; verify only the active store's
  data appears across desktop and tablet widths. _Reuses: `_PageShell`,
  `_DataCard`, Toast actions/metrics, supplier item queries, and manual order
  editor patterns; creates: `InventoryOrdererScreen`; modifies: service/providers
  to create recommendation/manual/repeat orders as `draft`._

- [ ] **Build one canonical responsive order detail for all three roles**:
  Create a reusable `/inventory-orders/:orderId` detail/read model showing
  supplier/store, lines, quantities, prices, totals, memo, approval timeline,
  PDF/delivery state, and receipt progress; render a desktop/tablet table and
  equivalent mobile cards, then inject only the actions authorized for the
  orderer, Store Manager, or Brand Manager. Verify copied deep links remain
  store/brand scoped. _Reuses: purchase history detail, `_DataCard`, current
  tables, and status components; modifies: orderer list and manager queues to
  open the shared detail. Depends on: orderer identity and state contract._

- [ ] **Complete draft edit, delete, and submit interactions**: Add Save Draft,
  Delete Draft, and Confirm/Submit actions with dirty-state protection,
  confirmation dialogs, optimistic-lock conflict recovery, and empty/error/
  loading states; soft-delete only before submit and hide edit/delete for every
  later state. _Modifies: draft workspace, purchase service/providers, and
  creation RPCs; creates: draft update/delete/submit RPCs. Depends on: orderer
  draft workspace._

- [ ] **Make frequent unit-price changes fast and explicit**: Promote the
  existing supplier-item unit-price editor into a `가격 수정` quick action and
  add inline draft-line price editing with an opt-in `future supplier default`
  update; show a stale-price badge plus per-line/all-line application when the
  default changes, never silently recalculate an open draft. _Reuses: current
  supplier-item editor and totals logic; modifies: supplier price list, draft
  editor, service/providers, and audit writes. Depends on: price history and
  orderer draft workspace._

- [ ] **Add a focused supplier-price Excel workflow**: Export/import a
  `거래처단가` workbook containing stable supplier/product identifiers, human
  labels, order unit/conversion, current/new price, tax, effective date, and
  note; show added/changed/unchanged/error preview, block duplicate/invalid/
  out-of-scope rows, and apply all valid changes atomically. Keep the existing
  full ingredient-master workbook unchanged. _Reuses: `excel`,
  `ingredient_excel_import.dart`, current preview UI, and bulk RPC patterns;
  creates: price-only template/parser/result UI and targeted unit/widget/SQL
  tests. Depends on: price history._

- [ ] **Add the Store Manager approval vertical slice**: Add an Awaiting Store
  Approval queue and order detail/timeline to the existing admin inventory
  surface, with Approve and Return actions, mandatory return reason, role/scope
  enforcement, and realtime refresh that does not dismiss open dialogs.
  _Reuses: `InventoryPurchaseScreen`, current order detail table, live refresh,
  and Toast status components; creates: Store approval decision card; modifies:
  providers and status helpers. Depends on: draft submit._

- [ ] **Add the Brand Manager approval vertical slice**: Add a brand-scoped
  Awaiting Brand Approval queue with store identity, prior Store decision,
  final amount review, Approve and Return actions, mandatory return reason, and
  cross-brand denial tests; Brand approval must atomically freeze an immutable
  snapshot and enqueue document generation. _Reuses: Store approval timeline
  and admin store switcher; creates: Brand approval action; modifies: approval
  RPC/provider. Depends on: Store approval and PDF proof-of-concept._

## Approved PDF and Supplier Dispatch

- [ ] **Expose approved PDF generation and download states**: Show Preparing,
  Ready, and Failed status, download with the order number as filename, hash/
  version metadata, and authorized retry; disable official PDF for drafts and
  make local client layout a clearly labeled preview/fallback. _Reuses/modifies:
  `InventoryPurchaseDocumentService`, current Print/PDF actions, FileSaver, and
  purchase history detail; creates: document status panel. Depends on: Brand
  approval._

- [ ] **Implement provider-neutral dispatch tracking**: Create one idempotent
  delivery row per approved document/channel/recipient with claim, retry,
  backoff, dead-letter, provider ID, and manual resend contracts; keep dispatch
  status separate from order approval and move to `ordered` only on successful
  delivery or an audited manual supplier-dispatch acknowledgement. _Creates:
  purchase delivery outbox and admin delivery-status panel; reuses: existing
  outbox/idempotency patterns. Depends on: approved document artifact._

- [ ] **Deliver the approved order by email**: Resolve the supplier email,
  enqueue only after PDF readiness, send through a server-side Resend
  dispatcher with attachment or short-lived signed link, and verify duplicate
  triggers do not duplicate email; confirm the owner/deployment of the existing
  `system.email_outbox` before extending it, otherwise keep this domain in a
  separate outbox. _Reuses: supplier email and existing Resend-oriented outbox
  contracts; creates/modifies: local dispatcher, email template, retry tests,
  and runtime verification. Depends on: dispatch tracking._

- [ ] **Run the Zalo OA compatibility spike behind a feature flag**: With a
  sandbox OA/app, validate access-token refresh, recipient identity/consent,
  current V3 transactional template rules, PDF-link CTA, quotas, retry error
  mapping, and whether direct PDF file delivery is still supported; ship the
  adapter only if the official sandbox passes, otherwise retain the signed-link
  template fallback. _Creates: Zalo adapter spike evidence and optional delivery
  adapter; reuses: provider-neutral dispatch tracking. Depends on: dispatch
  tracking. No personal-account automation._

## Receiving and Financial Double Check

- [ ] **Auto-create and auto-save physical receiving drafts without stock
  mutation**: From an `ordered` or `partially_received` purchase order, let the
  inventory orderer click an ingredient and enter quantity; on the first valid
  input, idempotently create/resume the delivery cycle's single open receipt
  draft, then debounce-upsert later line edits. Quantity zero removes a line,
  the last removal cancels the empty draft, and visible Saving/Saved/Retry plus
  navigation protection handles failed writes. Also capture statement
  number/date, private PDF/image, accepted/rejected quantities, and notes, while
  proving drafts never change inventory or payable totals. _Reuses: purchase
  detail, receipt tables, private Storage upload patterns, and receipt history;
  creates: open-draft uniqueness guard, receipt line upsert RPC, and auto-save
  controller tests; modifies: receipt detail provider._

- [ ] **Build the purchaser/payment verifier comparison screen**: Show approved
  order, supplier statement, and proposed final values side-by-side; allow a
  designated Store/Brand manager to enter final accepted quantity, actual unit
  price, tax, and final amount; highlight quantity/price/amount discrepancies
  and require reasons. _Creates: statement comparison editor and
  `inventory_receipt_verify` capability; reuses: Toast data tables and numeric
  input utilities. Depends on: physical receiving draft._

- [ ] **Make final receipt confirmation atomic and maker-checker safe**: Require
  a different verifier, expected receipt/order versions, and an idempotency key;
  recalculate amounts server-side, freeze the payable-basis snapshot, increase
  stock by accepted quantity exactly once, set partial/received state, append
  audit/attempt rows, and fail closed when the legacy direct-confirm client has
  no valid draft. _Modifies: effective receipt-confirm RPC and receiving runtime;
  creates: verification/reversal contract and SQL concurrency tests. Depends on:
  verifier comparison screen._

- [ ] **Complete receipt history and correction UX**: Display statement
  reference, recorder, verifier, final quantities/amounts, discrepancy reasons,
  stock transaction reference, and linked reversals; confirmed receipts are
  read-only and correction requires a reason and authorized adjustment flow.
  _Modifies: purchase history/receipt detail and observability summaries;
  creates: correction/reversal action. Depends on: atomic verification._

## Interactions, States, and Observability

- [ ] **Unify status labels, action guards, and realtime behavior**: Replace the
  user-facing Office-only blocker copy on the new POS path, add Korean/English/
  Vietnamese strings for every new state and reason, update status helpers,
  action queues, dashboard metrics, and live-event domain revisions without
  leaking supplier/statement payloads. _Modifies: ARB localization, status
  helpers, dashboards, action queue, and live-event migration; reuses: current
  live refresh and localization generation._

- [ ] **Add operational recovery panels**: Show stuck document jobs, failed/dead
  channel deliveries, stale approvals, draft receipts awaiting verification,
  and duplicate/no-op confirmation attempts with authorized retry and clear next
  action. _Reuses: current receiving observability/runtime result patterns;
  creates: purchase workflow operational summary. Depends on: document,
  dispatch, and receiving slices._

## Responsive, Accessibility, and Review

- [ ] **Verify responsive and accessible operation**: Exercise orderer, manager,
  Brand, shared order detail, price import, document, and auto-save receipt
  flows at phone/tablet/desktop widths; ensure
  keyboard traversal, visible focus, semantic labels, contrast, scroll-safe
  dialogs, localized long text, numeric input behavior, and disabled-action
  explanations. _Reuses: Toast responsive shells and existing web-scroll/dialog
  coverage; modifies/creates: focused widget and golden/visual checks._

- [ ] **Run the production-gated migration and release harness**: Add preflight
  and verification scripts for role constraints, state migration, legacy Office
  compatibility, private Storage/RLS, cached-client fail-closed behavior,
  document generation, email configuration, and pilot-account readiness; run
  format, targeted Flutter/SQL/Edge tests, `flutter analyze`, `flutter test`, and
  `bash scripts/check_repo.sh`, then deploy only through
  `scripts/deploy_pos_production.sh` and require GitHub checks on the exact
  pushed SHA. _Modifies: production gate scripts/tests/workflows only as needed;
  reuses: repository production-gate support. Depends on: all release slices._

## Review

- [ ] **Design review**: Review the built role surfaces, approval timeline,
  shared web/mobile detail, quick/Excel price changes, approved PDF, dispatch
  status, and auto-created maker-checker receipt flow against this brief and the
  attached reference screen; record any intentional deviations.

- [ ] **Operational pilot**: Execute one order through draft → Store approval →
  Brand approval → PDF → email → quantity-triggered receipt draft → independent
  verification in a pilot store; verify all three roles can use the canonical
  detail on mobile and web, then repeat with single/Excel price change, stale
  open-draft price, Store return, Brand return, email failure/retry, partial
  receipt, discrepancy, auto-save retry, stale approval, and duplicate
  confirmation.
