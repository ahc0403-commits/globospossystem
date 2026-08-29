# Design Brief: Inventory Purchase Approval, Receiving Verification, and Dispatch

Date: 2026-08-27
Source: User request and the current POS implementation

## Outcome

Create a store-scoped raw-material purchasing workflow in POS with a dedicated
inventory orderer login, sequential Store Manager and Brand Manager approval,
an immutable approved purchase-order PDF, draft-only edit/delete controls, and
a maker-checker receiving flow based on the supplier statement's final
quantities and amounts. The first valid received-quantity input automatically
creates and saves the receipt draft; there is no separate draft-creation step.

PDF is an export/delivery artifact, not the primary review surface. The orderer,
Store Manager, and Brand Manager all review the same canonical order data in an
authenticated responsive web/mobile detail view. Supplier prices can be
changed quickly one-by-one or through a dedicated bulk Excel price update.

The business approval must complete even when PDF generation, email, or Zalo
delivery is temporarily unavailable. Document generation and delivery are
tracked asynchronous side effects with retry and manual recovery.

## Current Implementation Baseline

The checked-out source already provides:

- A large `InventoryPurchaseScreen` under the admin shell with dashboard,
  recommendations, manual/repeat orders, purchase history, supplier/product
  catalogs, receiving, and a client-side PDF layout.
- `inventory_purchase_orders`, `inventory_purchase_order_lines`,
  `inventory_receipts`, and `inventory_receipt_lines` with store-scoped reads.
- Purchase creation RPCs for recommendation, manual, and repeat orders.
- Legacy Office review RPCs and statuses such as `office_approved`.
- Receipt idempotency and receipt-attempt observability.
- Existing `store_admin` and `brand_admin` roles and store/brand access models.
- A fixed-account provisioning system used by Store Setup.
- A supplier-item editor that already supports single unit-price changes.
- An ingredient Excel importer/exporter that already carries supplier and price
  fields, validates a workbook before mutation, and applies the import through
  `bulk_upsert_inventory_ingredients`. It is a full ingredient-master import,
  not a focused frequent-price-change workflow.
- An email-outbox schema and Resend-oriented delivery contracts, but no local
  `process-email-outbox` Edge Function in this repository. Source presence does
  not prove deployment or operational configuration.

The current implementation does not yet satisfy this brief because:

- Purchase creation immediately produces `submitted`, so there is no editable
  draft phase.
- A kitchen login cannot access the purchase workspace.
- POS has no Store Manager then Brand Manager approval path.
- The receipt dialog confirms all remaining quantity and does not capture a
  supplier statement, final line quantities, or final financial amounts.
- Stock can be mutated through the current confirmation RPC without a distinct
  maker-checker receipt draft.
- Receiving requires an explicit confirm-all-remaining interaction rather than
  automatically creating/resuming a draft when a line quantity is entered.
- Order data is spread across role-specific areas; there is no single
  deep-linkable responsive detail surface shared by all three actors.
- Single supplier-price editing is buried in supplier-item management, while
  the existing Excel flow requires the broader ingredient-master format and
  does not preserve an effective-dated supplier-price history.
- The PDF can be laid out/printed client-side, but there is no immutable
  approved document artifact with a persisted version/hash and delivery state.

## Actors and Permissions

| Actor | Existing role / new identity | Allowed actions |
| --- | --- | --- |
| Kitchen inventory orderer | New fixed account type and role `inventory_orderer`, store-scoped | Create/edit/delete draft, submit, view own store orders, record physical receiving draft |
| Store Manager | Existing `store_admin`; legacy `admin` may be temporarily mapped for single-store compatibility | Review, approve, or return submitted orders for accessible store |
| Brand Manager | Existing `brand_admin`, brand-scoped | Review, approve, or return Store-approved orders across accessible brand stores; download approved PDF |
| Purchasing/payment verifier | Dedicated legal-entity-scoped account type and role `inventory_accounting` | Review all brands and stores belonging to the legal entity, compare statement and physical receipt, enter final quantities/prices, then confirm receipt |
| Super Admin | Existing `super_admin` | Platform recovery; cannot replace the accounting receipt-confirmation role |

The new orderer is a separate login rather than broadening the existing shared
kitchen-device account. This keeps ordering activity attributable and prevents
the KDS login from gaining supplier, price, or approval access.

## Order State Contract

New POS orders use the following active path:

| From | Action | Actor | To |
| --- | --- | --- | --- |
| none | Create from recommendation/manual/repeat | Inventory orderer | `draft` |
| `draft` | Edit lines, supplier, date, memo | Inventory orderer | `draft` |
| `draft` | Delete | Inventory orderer | `cancelled` with `deleted_before_submit` audit reason |
| `draft` | Confirm/submit | Inventory orderer | `submitted` |
| `submitted` | Approve | Store Manager | `store_approved` |
| `submitted` | Return with reason | Store Manager | `draft` |
| `store_approved` | Final approve and generate PDF | Brand Manager | `ordered` |
| `store_approved` | Return with reason | Brand Manager | `draft` |
| `ordered` | Verified partial receipt | Purchasing/payment verifier | `partially_received` |
| `ordered` or `partially_received` | Verified complete receipt | Purchasing/payment verifier | `received` |

Rules:

- Only `draft` can be edited or deleted from the UI or mutation RPCs.
- Returns preserve every prior decision in an append-only approval-event table.
- Every mutation carries an expected row version; stale edits/approvals fail and
  force a refresh.
- Server-side RPCs recalculate all amounts. Client-supplied totals are never
  trusted.
- `office_approved` remains a legacy-compatible final approval state for
  existing Office callers and historical data. Existing `office_*` RPCs are not
  renamed or silently repurposed. New POS records use the new states.
- Brand approval persists an immutable approved snapshot. Later receipt data
  never changes the approved purchase-order snapshot.
- Email and Zalo supplier delivery are deferred and do not affect the current
  approval state machine.

## Receiving Maker-Checker Contract

Receiving has two controlled stages, but draft creation is implicit:

1. From an `ordered` or `partially_received` purchase order, the physical
   receiver clicks an ingredient and enters the first valid quantity. The
   server idempotently creates or resumes that delivery cycle's open receipt
   draft and upserts the line. Further edits auto-save after a short debounce.
   The receiver may then add the supplier statement number/date, private
   attachment, rejected quantities, and discrepancy notes. No stock or payable
   amount changes while the receipt remains a draft.
2. A different authenticated user with the legal-entity-scoped
   `inventory_accounting` role reviews statements across every brand and store
   belonging to that legal entity, then enters/confirms final accepted
   quantities, actual unit prices, supply amount, tax, and final total. Only
   this atomic confirmation increases stock and produces the payable-basis
   snapshot.

Additional rules:

- Merely opening the receiving screen does not create an empty database row.
  Quantity `0` removes that draft line; removing the last line cancels the empty
  draft so empty receipt records do not accumulate.
- Only one open receipt draft exists for a purchase order and delivery cycle.
  An idempotency key plus a database uniqueness guard prevents double creation;
  after a partial receipt is confirmed, the next delivery can start a new
  cycle.
- The UI always exposes `Saving`, `Saved`, and `Retry` states. Navigating away
  with an unsaved or failed write requires an explicit warning.
- Statement reference/date and the required evidence/notes can be completed
  after the first quantity entry, but must pass server validation before final
  verification.
- The draft creator cannot be the final verifier.
- Confirmation is idempotent and locks both the purchase order and receipt.
- Accepted stock quantity and payable amount are server-derived from final line
  inputs and the supplier unit-conversion snapshot.
- Quantity/price differences from the approved order are highlighted and
  require a reason. Over-delivery can be recorded only by the verifier and must
  remain visible as a discrepancy, rather than being silently capped.
- Confirmed receipts are immutable. Corrections use a reversal/adjustment path
  with a reason and linked audit event.
- The old direct “confirm all remaining” call must not remain an authenticated
  bypass. During rollout it is changed to require a valid receipt draft, then
  revoked or retired after cached-client compatibility is closed.

## Canonical Web/Mobile Order Detail Contract

- One reusable order-detail component and read model serves the inventory
  orderer, Store Manager, and Brand Manager. The PDF is generated from the same
  immutable approved snapshot but is never required to review or approve.
- Authenticated deep links open `/inventory-orders/:orderId`; manager queues may
  link into the same detail component from the existing admin shell.
- The view shows supplier/store, requested delivery date, lines, units,
  quantities, unit prices, supply/tax/total amounts, memo, approval timeline,
  PDF/delivery state, and receiving progress. Actions are injected according to
  the signed-in role and current state rather than duplicating three screens.
- Desktop/tablet uses a comparison table; narrow mobile widths use equivalent
  cards with sticky primary actions and no hidden financial or approval data.
- Scope remains strict: the orderer sees only its assigned store, the Store
  Manager only assigned stores, and the Brand Manager only stores in the
  accessible brand. A copied link never widens authorization.

## Supplier Unit-Price Contract

Price has three deliberately separate meanings:

1. `inventory_supplier_items.unit_price` is the current supplier default used
   when a future order draft line is created.
2. `inventory_purchase_order_lines.unit_price` is the order-line snapshot. It
   can be edited only while the order is `draft` and becomes immutable on
   submission/approval.
3. The confirmed receipt stores the supplier statement's actual unit price and
   payable-basis amount. A difference from the approved order is visible and
   requires a verifier reason; it never rewrites the approved-order snapshot.

Price-management rules:

- Surface the existing supplier-item price edit as a quick action in the
  supplier price list and allow inline price correction in a draft order.
- A draft-line edit changes only that order by default. An explicit
  `Also update future supplier default` choice updates the supplier item; there
  is no silent cross-record mutation.
- Add a focused `거래처단가` Excel template separate from the existing full
  ingredient import. It includes supplier ID/name, ingredient ID/code/name,
  supplier SKU/order unit, conversion quantity, current price, new price, tax
  rate, effective date, and note. Stable IDs/codes drive matching; names are for
  human verification.
- Export current prices, preview added/changed/unchanged/error rows, reject
  duplicate supplier-product-unit keys or invalid scope/values, then apply the
  entire workbook atomically. Reuse the current Excel parser, preview,
  validation, and bulk-RPC patterns.
- Bulk changes update supplier defaults and append an effective-dated price
  history with actor, source (`manual` or `excel`), import ID, old/new price,
  tax, note, and timestamp. They never rewrite submitted, approved, ordered, or
  received order lines.
- Existing open drafts retain their price to prevent an unnoticed total change.
  A `Supplier price changed` badge offers explicit per-line or all-line
  application of the latest default, followed by server total recalculation.

## Approved Document Contract

- Brand approval creates a document-generation job from the immutable approval
  snapshot.
- The generated PDF includes order number, brand/store, supplier, delivery
  date, line quantities and units, unit prices, supply/tax/total amounts, Store
  and Brand approval identities/timestamps, and the snapshot version/hash.
- The PDF is stored in a private Supabase Storage bucket. The database stores
  storage path, SHA-256 hash, snapshot version, generation status, and creation
  time. `pdf_url` must not contain a permanent public URL.
- The POS exposes `Preparing`, `Ready`, and `Failed` states plus download and
  authorized retry actions.
- The current Flutter `InventoryPurchaseDocumentService`, `pdf`, `printing`,
  and bundled Pretendard font are reused for local preview/fallback. A short
  proof-of-concept must validate server-side font embedding and PDF generation
  within Supabase Edge Function limits before it becomes the email/Zalo source.

## Deferred Supplier Delivery Channels

Email and Zalo are intentionally outside the current release. The following
notes are retained only as future integration guidance; no dispatch table,
worker, provider secret, or send button is shipped now.

### Email (phase 1)

- Use the supplier email already stored in `inventory_suppliers`.
- Enqueue an idempotent `inventory_purchase_approved` delivery row after the
  approved PDF artifact is ready.
- Send through a server-side dispatcher using Resend, attaching the PDF or a
  short-lived signed download URL.
- Track `pending`, `processing`, `sent`, `failed`, and `dead`, provider message
  ID, attempts, last error, and manual resend.
- Extend or isolate the existing email outbox only after confirming which
  deployed runtime currently owns `system.email_outbox`; the local repository
  does not contain its referenced dispatcher.

### Zalo (phase 2, optional adapter)

- Support Zalo only through an authorized Zalo Official Account / approved
  business messaging path. Do not automate a personal Zalo account or scrape
  the consumer app.
- Store supplier Zalo recipient identity separately from phone/email and record
  consent/verification status.
- Prefer a transactional template containing a short-lived signed PDF link.
  Direct PDF upload/send is allowed only after a sandbox spike confirms the
  currently supported OA endpoint, quota, recipient rules, and file lifetime.
- Keep Zalo credentials and refresh tokens in server-side secrets. Never expose
  them to Flutter or store them in supplier rows.
- Zalo uses the same provider-neutral delivery outbox, retry, and audit model as
  email.

## UX Surfaces

### Inventory Orderer workspace (`/inventory-orders`)

- Store-scoped, purpose-built screen rather than the full admin inventory area.
- Tabs/filters: Drafts, Awaiting Store Approval, Awaiting Brand Approval,
  Approved/Ordered, Receiving, Completed.
- Draft editor supports product search, line add/remove, quantity, delivery
  date, memo, live totals, Save Draft, Delete Draft, and Confirm/Submit.
- After submission, edit/delete disappear and the approval timeline becomes
  read-only.
- Each row opens the shared responsive detail view used by both manager roles;
  no PDF download is needed to inspect the complete order.

### Store/Brand approval queue

- Reuse the existing admin shell and inventory purchase detail layout.
- Show only actions valid for the signed-in role and current state.
- Display approved-order versus edited draft values and require a return reason.
- Brand approval shows final totals and explicitly states that supplier delivery
  happens asynchronously.
- Both queues deep-link to the canonical responsive order detail, with only the
  current actor's valid approval actions added.

### Receiving verification

- The receiver clicks a raw material and enters quantity; the first valid entry
  automatically creates/resumes the receipt draft and every subsequent change
  auto-saves. The screen also accepts supplier-statement PDF/image, reference,
  date, accepted/rejected quantities, and notes.
- Verifier screen shows approved vs statement vs final values side-by-side,
  discrepancy badges, computed financial totals, and a final confirmation.
- The confirmation dialog names the stock and payable effects before commit.

### Supplier price management

- Add a prominent `가격 수정` quick action for a single supplier item and a
  separate `거래처 단가 Excel` export/import action for bulk changes.
- Excel import always presents a dry-run preview and blocks apply until all
  errors are resolved. Its result links to the price-change history and any
  affected open drafts, without silently updating those drafts.

## Reuse and Modification Map

| Existing element | Classification | Planned use |
| --- | --- | --- |
| `InventoryPurchaseScreen` | Modify | Add role-aware approval queues, document state, and receiving entry points |
| Shared purchase detail components/read model | Create | Canonical authenticated web/mobile review for all three roles and PDF snapshot source |
| `_PageShell`, `_DataCard`, `_SimpleDataTable`, Toast metrics/actions | Reuse as-is where possible | Common visual language for orderer and manager surfaces |
| `InventoryPurchaseDocumentService` | Modify | Approved snapshot, approval metadata, deterministic download/fallback |
| `InventoryService` and inventory Riverpod providers | Modify | Draft, transitions, approvals, documents, receipt draft/verify APIs |
| `ingredient_excel_import.dart` and `bulk_upsert_inventory_ingredients` patterns | Reuse/extend | Keep full master import; add focused supplier-price workbook parsing, preview, and atomic apply |
| Existing supplier-item unit-price editor | Modify | Promote to quick edit and record effective-dated price history |
| `role_routes.dart`, `permission_utils.dart`, auth state | Modify | New orderer route and receipt-verifier capability |
| Store Setup fixed-account components and provision Edge Function | Modify | Configure/provision one dedicated orderer ID per store |
| Approval timeline / decision card | Create | Append-only Store/Brand decision history |
| Receipt statement comparison editor | Create | Maker-checker final quantity and amount verification |
| Receipt line auto-save controller/RPC | Create | Idempotently create/resume an open receipt draft on first quantity and upsert later edits |
| Supplier price history and price-only import RPC | Create | Audit manual/Excel changes without mutating order snapshots |
| Purchase document/delivery status panel | Create | PDF readiness, download, channel status, retry |
| Provider-neutral purchase dispatch outbox/worker | Create | Email first, Zalo adapter later |

## Security and Audit Requirements

- Every write RPC resolves the authenticated `public.users` row and validates
  store/brand scope and exact action permission server-side.
- RLS read access is least-privilege: the orderer sees only its store and does
  not gain supplier banking/admin settings beyond what ordering requires.
- Approval and receipt event records are append-only to authenticated users.
- Supplier statement and approved PDFs are private; downloads use short-lived
  signed URLs after authorization.
- Secrets for Resend/Zalo stay in Supabase secrets or Vault.
- All create/edit/delete/submit/approve/return/document/dispatch/receipt events
  write actor, timestamp, before/after state, reason, and correlation ID.
- Realtime events contain identifiers/revisions only, not supplier banking,
  statement, or document payloads.

## Rollout and Compatibility

1. Deploy additive schema, read models, and shadow observability first.
2. Provision a pilot orderer account for one non-production/pilot store.
3. Enable draft-first order creation, shared role detail, and Store approval for
   the pilot.
4. Enable supplier price quick edit/history and the price-only Excel import;
   verify existing drafts and submitted snapshots are not silently rewritten.
5. Enable Brand approval and PDF artifact generation after the PDF/font spike.
6. Enable auto-created receipt drafts and verifier-only stock mutation; verify
   old clients fail closed rather than bypassing maker-checker.
7. Enable email delivery and validate provider/runtime configuration.
8. Pilot Zalo separately behind a feature flag after OA credentials, recipient
   identity, templates, quota, and current API path are approved.
9. Promote through `scripts/deploy_pos_production.sh`; report PASS only after
   required GitHub checks succeed on the exact pushed head SHA and production
   operational checks confirm each workflow stage.

## Acceptance Criteria

- A dedicated orderer account can create, save, edit, delete, and submit a draft
  for only its assigned store.
- The orderer, Store Manager, and Brand Manager can open the same complete order
  detail on phone, tablet, and desktop without generating or downloading a PDF;
  role/store/brand authorization still applies.
- No actor can edit or delete after submission.
- Store approval must precede Brand approval; invalid or stale transitions fail.
- Brand approval produces a versioned downloadable PDF without depending on a
  delivery provider.
- Email delivery can be retried without sending duplicates.
- Zalo is optional and cannot block approval or PDF download.
- The first valid received-quantity entry automatically creates/resumes and
  auto-saves one receipt draft; opening the page alone does not create one.
- Creating or editing a physical receipt draft never increases stock. Inventory
  increases only when a different authorized verifier confirms the receipt.
- A different authorized verifier can enter final statement quantities and
  amounts; confirmation atomically increases stock and persists the payable
  basis exactly once.
- Every transition, discrepancy, document, and dispatch attempt is auditable.
- A supplier price can be changed through prominent single edit or the focused
  Excel workflow. Previewed Excel changes apply atomically, append price
  history, affect future defaults, and never rewrite submitted/approved orders
  or silently alter open drafts.
- Existing Office integration contracts and the physical `restaurants` table
  remain intact.

## Explicit Non-Goals

- Paying the supplier or integrating internet banking.
- OCR/AI extraction of supplier statements in the first release.
- Automatic supplier-price scraping or supplier-portal synchronization.
- Automating personal Zalo accounts or Zalo desktop/web UI.
- Replacing the current supplier/product/recommendation domain.
- Renaming `restaurants` or changing the Office app's hard coupling.
