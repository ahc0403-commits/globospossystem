# Direct delivery Edge API and RPC contract

Authorities:

- Edge: `supabase/functions/direct-order-public/index.ts`
- SQL: `supabase/migrations/20260821130000_direct_delivery_ordering.sql`
  through
  `supabase/migrations/20260910130000_direct_order_customer_payment_and_status.sql`
- Flutter customer decode: `lib/features/direct_order/direct_order_models.dart`
- Catalog enforcement: `supabase/tests/direct_delivery_schema_contract_test.sql`

State: source contract only. It does not prove Edge deployment, migration
application, Google Maps project configuration, or production verification.

## Common HTTP contract

### 2026-10-07 stored customer details

`status_v4` uses the same owning-session inputs and 60/minute public rate boundary
as `status_v3`, calling service-only `direct_order_public_status_v4(uuid,text,uuid)`.
It adds nullable `customer` with exactly `customer_name`, `customer_phone`,
`formatted_address`, `detail_address`, `district`, `ward`, and `customer_note`.
The existing `delivery.diner_count` and item `note` snapshots remain intact.
PII is read only after v3 validates the secret and request ownership, with a second
session/request predicate. Purged PII returns null. No customer addresses or notes
enter the session-wide list or logs. V3 is unchanged for already loaded strict
clients; v4 rollback keeps the action readable with `customer: null`.

All customer detail fields come from persisted records for the selected order,
never the current form or today's menu. Opening details makes no additional
per-item or customer-information request.

- Endpoint: Supabase Edge Function `direct-order-public`.
- `OPTIONS` is accepted only for an exact configured origin and returns 204.
  All business calls are `POST`; other methods return 405
  `METHOD_NOT_ALLOWED`.
- `Content-Type` must resolve to `application/json`; otherwise 415
  `UNSUPPORTED_MEDIA_TYPE`. The body must be one JSON object and is limited to
  65,536 UTF-8 bytes by both `Content-Length` precheck and actual bytes read.
- Browser actions require an exact member of `ALLOWED_ORIGINS`; wildcard and
  reflected origins are forbidden. Internal cleanup is the only no-origin path.
- Successful response: exactly `{ "data": <action object> }`. Failed response:
  exactly `{ "error": "PUBLIC_CODE" }`. Cache is always `no-store`.
- Public actions require a valid client IP from the trusted forwarding headers.
  The address is HMACed with a server secret before the rate RPC; neither raw IP
  nor secret is stored. A rejected bucket returns 429 `TOO_MANY_REQUESTS` and
  `Retry-After: 60` before action execution.
- Public customer identity is an opaque `session_id` plus a 40–128 character
  random secret. Only its SHA-256 hash crosses the SQL boundary. Staff proof
  access requires a valid bearer JWT and the store-scoped staff detail RPC.
  Cleanup requires the dedicated constant-time environment secret boundary.
- Logs contain only a fixed operation label and JavaScript error class name.
  Request JSON, session secret/hash, IP/key, customer/contact/address, chat,
  proof path/bytes, bank data, Google payload/response, and signed/Grab URLs are
  prohibited.
- Unknown Edge or SQL errors are always sanitized to 503
  `DIRECT_ORDER_TEMPORARILY_UNAVAILABLE`.

## Edge actions

Rate is requests per 60-second HMAC bucket. `session` means the Edge validates
`session_id` and secret through a session-scoped SQL RPC.

### `storefront`

- Actor/rate: public, 60.
- Input: `slug`, lowercase slug pattern, 3–63 characters.
- Output required: `store_id`, `store_name`, `slug`, `paused`,
  `ordering_starts_at`, `ordering_cutoff_at`, `minimum_order_amount`, `bank`,
  `categories`, `items`; nullable: paired default coordinates and
  `google_maps_browser_key`. Menu/category snapshots require KO/VI/EN names.
- Side effect/idempotency: read-only and idempotent.
- Errors: invalid request; unavailable/not found; temporary backend failure.

### `create_session`

- Actor/rate: public, 60.
- Input: `slug`; optional locale exactly `ko`, `vi`, or `en` (default `vi`).
- Output: `session_id`, `store_id`, `expires_at`, and the one-time raw `secret`.
- Side effect/idempotency: creates a new 30-day session each call; not
  idempotent. Only the hash is persisted.
- Errors: invalid request/locale, storefront unavailable, temporary failure.

The persisted session/request locale is customer metadata only. It must never
be used to choose staff UI, menu, message, or alert language; those use the
staff viewer's current app locale. See `DIRECT_ORDER_LOCALE_CONTRACT.md`.

### `places_autocomplete`

- Actor/rate: public, 30.
- Input: `slug`, trimmed query 2–200, optional `ko/vi/en` locale, and required
  UUIDv4 `session_token`. One token is created at the start of a search, reused
  for its autocomplete keystrokes, and sent to the terminating details request.
- Output: exact `{suggestions: [{place_id, text}]}` with at most eight rows.
- Side effect/idempotency: Google read; repeated calls can be billed and are not
  treated as idempotent for usage accounting.
- Errors: invalid input, `MAP_TEMPORARILY_UNAVAILABLE`; an empty result is a
  successful empty list.

### `place_details`

- Actor/rate: public, 30.
- Input: `place_id` 5–255 safe characters, `ko/vi/en` locale, and the same
  required UUIDv4 `session_token` that began the autocomplete search.
- Output: `place_id`, `formatted_address`, numeric latitude/longitude; district
  and ward are nullable provider text.
- Side effect/idempotency: Google read; response is safe to retry but may be
  billed. No unconfirmed coordinate is persisted.
- Errors: invalid input/result or `MAP_TEMPORARILY_UNAVAILABLE`.

### `reverse_geocode`

- Actor/rate: public, 30.
- Input: finite latitude -90..90, longitude -180..180, locale `ko/vi/en`.
- Output: same strict place object as details; `place_id`, district, ward may be
  null. Provider place names are preserved, not machine-translated.
- Side effect/idempotency: Google read, safe to retry but potentially billed.
- Errors: invalid input, 404 `MAP_LOCATION_NOT_FOUND`, or temporary map error.

### `submit`

- Actor/rate: session, 60.
- Input: valid `session_id`, secret, UUID `client_request_id`, and object
  `payload`: locale `ko/vi/en`; 1–50 distinct item rows; each item UUID,
  quantity 1–50 and note <=300; total quantity <=100; optional customer note
  <=500; verified search/map-pin address with name, phone, formatted and detail
  address, finite coordinates, and optional place/district/ward.
- Output exactly: `request_id`, `reference_code`, persisted `state`, and boolean
  `idempotent`.
- Side effect/idempotency: creates only direct request/item/address/coarse fact
  and system message rows. It never creates a legacy order. Replay of the same
  owning-session `client_request_id` returns the existing identity. The browser
  persists that pending UUID before the first call and reuses it after a lost
  response. Another session cannot claim or inspect the UUID. Each new order
  draft receives a new UUID, and one session may own multiple simultaneous
  orders whose states remain independent.
- Availability rule: `is_paused=true` (cashier UI: `CLOSED`) rejects only a
  new, non-idempotent submission. It does not cancel or block an already
  submitted request.
- Errors: input/address/item/quantity, paused/hours/open request, menu
  unavailable, session/store unavailable, temporary failure.

### `status`

- Actor/rate: owning session, 60.
- Input: session ID, secret, request UUID.
- Output exact top-level fields: request/store/reference/state/created time,
  snapshotted items, nullable quote, chronological messages, nullable direct
  fulfillment and nullable dispatch. Proof paths are replaced by
  `has_attachment`; exact address is not returned by this action.
- Side effect/idempotency: updates session `last_seen_at`; otherwise read-only.
- Errors: unavailable session/request and temporary failure.

### `status_v2`

- Actor/rate: owning session, 60.
- Input: session ID, secret, request UUID.
- Output: the V1 status projection plus quote version, pretax and VAT amounts,
  `vat_total`, delivery payment mode, nullable open proof-review request, and
  fulfillment version/update/completion timestamps.
- Side effect/idempotency: updates session `last_seen_at`; otherwise read-only.
- Errors: unavailable session/request and temporary failure.

### `orders_v2`

- Actor/rate: owning session, 60.
- Input: session ID and secret. Edge uses the SQL maximum page size of 50.
- Output: newest-first summaries for only that session's orders, including
  reference, request and fulfillment states, item count, final total, completion
  time, and whether payment-proof reupload is pending.
- Side effect/idempotency: updates session `last_seen_at`; otherwise read-only.
- Errors: invalid limit, unavailable session, or temporary failure.

### `message`

- Actor/rate: owning session, 60.
- Input: session ID, secret, request UUID, trimmed message 1–2,000.
- Output exactly `message_id`, `created_at`.
- Side effect/idempotency: one SQL write stores the exact author-entered body;
  non-idempotent. Free text is enqueued for asynchronous translation without changing the original body.
- Errors: invalid text, unavailable ownership, terminal-state conflict.

### `cancel`

- Actor/rate: owning session, 60.
- Input: session ID, secret, request UUID.
- Output exactly `request_id`, state `cancelled`.
- Side effect/idempotency: row-locks request; only awaiting-quote/quoted may
  cancel; expires active quote and writes a fixed system code. A terminal replay
  conflicts and does not add another message.
- Errors: unavailable ownership or not-cancellable conflict.

### `proof_upload_url`

- Actor/rate: owning session, 10.
- Input: session ID, secret, request UUID, MIME exactly JPEG/PNG/WebP, integer
  byte size 1..5,242,880.
- Output exact: store/request/random-object `path`, one-time upload `token`,
  `signed_url`, `max_bytes=5242880`, and echoed `mime_type`.
- Side effect/idempotency: validates current request status then reserves a
  random signed upload; non-idempotent and does not approve/lock the order.
- Errors: invalid proof, unavailable ownership, or temporary upload failure.

### `proof_upload_url_v2`

- Actor/rate: owning session, 10.
- Input/output: V1 fields plus the exact active/locked `quote_id` and nullable
  `review_request_id` from `status_v2`.
- Side effect/idempotency: reserves a random upload only after confirming the
  quote belongs to the request and either the first proof is allowed or the
  specified reupload request is still open.
- Errors: V1 proof errors plus quote/review ownership or state conflict.

### `proof_commit`

- Actor/rate: owning session, 60.
- Input: session ID, secret, request UUID, strict three-segment proof path whose
  store/request IDs match ownership.
- Edge validation: object exists at the exact name; download succeeds; bytes
  structurally match extension; 1..5 MiB; dimensions <=12,000 each and <=25M
  pixels. Spoofed invalid bytes are deleted.
- Output exactly `message_id`, state `awaiting_payment_review`.
- Side effect/idempotency: SQL row-locks request, locks unexpired quote, creates
  proof message, changes request state. It never approves or creates a legacy
  order. Repeating the exact owned storage path returns the existing proof
  message, and a partial unique index prevents duplicate proof rows.
- Errors: incomplete/missing/invalid proof, state conflict, expired quote,
  unavailable session, or temporary storage failure.

### `proof_commit_v2`

- Actor/rate: owning session, 60.
- Input: V1 ownership/path fields plus exact `quote_id` and nullable
  `review_request_id`.
- Output: `message_id`, state `awaiting_payment_review`, nullable review ID,
  and boolean `idempotent`.
- Side effect/idempotency: the first proof locks its exact quote. A requested
  replacement adds a new proof message and resolves that exact review request
  without charging or submitting a new order. Exact-path replay returns the
  same message.
- Errors: V1 proof errors plus stale or mismatched quote/review conflicts.

### `staff_proof_url`

- Actor/rate: authenticated store-scoped staff, no public rate bucket.
- Input: `store_id`, `request_id`, proof `message_id`, bearer JWT.
- Output exactly `signed_url`, `expires_in=300`.
- Side effect/idempotency: authenticates JWT, invokes scoped staff detail, then
  signs only the matching payment-proof object. Read-only and retry-safe.
- Errors: 401, forbidden/store mismatch, proof not found, temporary signing.

### `cleanup_expired_pii`

- Actor/rate: internal cleanup secret only; no browser origin/rate bucket.
- Input: no caller-supplied IDs. Server selects at most 100 eligible terminal
  requests and proof paths plus at most 100 proof objects older than 24 hours
  that have no matching committed proof message.
- Output: SQL cleanup counts, or `{requests: 0}`, plus `orphan_proofs`.
- Side effect/idempotency: deletes validated proof objects first, including
  abandoned signed uploads, then eligible exact address/chat/note PII and old
  session/rate rows. Coarse and financial facts remain. Retry converges and
  never approves or changes financial data.
- Errors: unauthorized, not eligible/too early, storage/SQL temporary failure.

## SQL RPC contracts

Every RPC is `SECURITY DEFINER` with a fixed search path. `S` means service role;
`C` cashier; `K` kitchen; `A` admin/store_admin/brand_admin/super_admin. Except
for super_admin, staff functions require the requested store in
`user_accessible_stores`.

| Signature | Execute/scope | Lock, reads/writes, response, idempotency | Domain errors |
|---|---|---|---|
| `direct_order_require_actor(uuid,text[]) -> users` | internal helper | Reads active POS user/store access; no write | actor input, forbidden |
| `direct_order_consume_public_rate(text,int,int) -> bool` | S | Atomic bucket upsert; returns within-limit boolean; one increment/call | rate input |
| `direct_order_public_storefront(text) -> jsonb` | S | Read active enabled store/menu public projection; retry-safe | none/null |
| `direct_order_public_create_session(text,text,text) -> jsonb` | S | Reads storefront; inserts session; returns IDs/expiry; non-idempotent | session input, store not found |
| `direct_order_validate_session(uuid,text) -> session row` | S/helper | Reads valid hash/expiry, updates last_seen | session invalid |
| `direct_order_public_submit(uuid,text,uuid,jsonb) -> jsonb` | S/session | Validates session before idempotency lookup; store `FOR SHARE`; writes request/items/exact/coarse/message; owning client UUID replay returns same request | request/address/item/quantity, session, pause/hours/open/menu |
| `direct_order_public_message(uuid,text,uuid,text) -> jsonb` | S/session | Reads ownership/state; inserts one message; non-idempotent | session, not chatable, message invalid |
| `direct_order_public_cancel(uuid,text,uuid) -> jsonb` | S/session | Request `FOR UPDATE`; terminal transition/message; first call only | not found/not cancellable |
| `direct_order_public_commit_proof(uuid,text,uuid,text) -> jsonb` | S/session | Request `FOR UPDATE`; locks quote; exact path replay returns one proof message; no approval | proof state/path, quote expired |
| `direct_order_public_status(uuid,text,uuid) -> jsonb` | S/session | Owning request snapshot; only session last_seen write; retry-safe | session/request not found |
| `direct_order_public_commit_proof_v2(uuid,text,uuid,uuid,text,uuid) -> jsonb` | S/session | Binds proof to exact quote/review; resolves one requested reupload; exact-path replay is idempotent | proof/quote/review state or ownership |
| `direct_order_public_status_v2(uuid,text,uuid) -> jsonb` | S/session | Adds VAT, payment mode, open review, and versioned fulfillment to owning snapshot | session/request not found |
| `direct_order_public_orders_v2(uuid,text,int) -> jsonb` | S/session | Returns up to 50 independent summaries owned by the session; retry-safe | session, limit |
| `direct_order_admin_upsert_storefront(uuid,text,bool,bool,time,time,numeric,int,numeric,numeric,text,text,text,text,numeric,int,int,bool) -> jsonb` | A/store | Config upsert + audit; accounting gate in DB; idempotent for same values | actor/input/check violations |
| `direct_order_admin_get_storefront(uuid) -> jsonb` | A/store | Config read with null result object if absent; retry-safe | forbidden |
| `direct_order_staff_list(uuid,text[],timestamptz,uuid,int) -> jsonb` | C/A store | Cursor queue read, <=100; no proof path; retry-safe | forbidden, limit |
| `direct_order_staff_detail(uuid,uuid) -> jsonb` | C/A store | Exact address/items/quotes/chat/financial/dispatch read; attachment becomes boolean | forbidden, request not found |
| `direct_order_staff_list_v2(uuid,text[],int) -> jsonb` | C/A store | Current-day plus still-actionable queue with proof-review and fulfillment summary fields, <=200 | forbidden, limit |
| `direct_order_staff_detail_v2(uuid,uuid) -> jsonb` | C/A store | Adds full direct fulfillment and sanitized proof-review history to scoped detail | forbidden, request not found |
| `direct_order_staff_request_proof_resubmission(uuid,uuid,uuid,text,text) -> jsonb` | C/A store | Opens one quote/proof-bound review request and system message; identical open replay is idempotent; approval waits until replacement | proof/review/state conflict |
| `direct_order_staff_get_availability(uuid) -> jsonb` | C/A store | Returns exactly `configured`, `enabled`, `paused`, `updated_at`; no bank/accounting/map configuration is exposed; retry-safe | forbidden |
| `direct_order_staff_set_paused(uuid,bool) -> jsonb` | C/A store | Storefront `FOR UPDATE`; changes only pause/operator timestamp fields; actual changes write one old/new audit; same-value replay returns the current state without audit churn | forbidden, invalid input, storefront disabled/unconfigured |
| `direct_order_staff_quote(uuid,uuid,numeric,text) -> jsonb` | C/A store | Request `FOR UPDATE`; price/menu revalidation; supersedes quote, updates request/message; versioned; an existing request remains quotable while new intake is paused | quote input/state, store enabled/accounting/menu/minimum |
| `direct_order_staff_quote_with_payment_mode(uuid,uuid,numeric,text,text) -> jsonb` | C/A store | Delegates quote calculation to the existing quote RPC, then snapshots `customer_direct` or `store_prepaid`; customer-direct always stores zero delivery fee | quote/payment-mode input plus quote errors |
| `direct_order_staff_message(uuid,uuid,text) -> jsonb` | C/A store | Reads state; inserts one cashier message; non-idempotent | forbidden, invalid/not chatable |
| `direct_order_staff_reject(uuid,uuid,text) -> jsonb` | C/A store | Request `FOR UPDATE`; rejects, expires live quote, writes message/audit | reason, not found/not rejectable |
| `direct_order_staff_sepay_candidates(uuid,uuid) -> jsonb` | C/A store | Read-only time/amount candidate list; evidence only | forbidden, quote not found |
| `direct_order_staff_sepay_candidates_v2(uuid,uuid) -> jsonb` | C/A store | Lists recent exact-store/exact-amount matched incoming transactions, excluding a transaction consumed by another request | forbidden, quote not found |
| `direct_order_staff_link_sepay(uuid,uuid,uuid) -> jsonb` | C/A store | Locks the provider transaction, validates exact store/direction/status/amount/age, enforces one request per transaction, locks the quote and enters payment review; pair replay is idempotent and never approves | quote/candidate invalid, transaction already used |
| `direct_order_staff_verified_payment_evidence(uuid,uuid) -> jsonb` | C/A store | Returns only the linked transaction that still matches the locked quote; read-only and retry-safe | forbidden |
| `direct_order_approve_payment(uuid,uuid,numeric,text) -> jsonb` | C/A store | Atomic approval anchor; authenticated staff may confirm a customer photo belonging to the locked quote, without SePay. The optional legacy verified-transfer caller is preserved. Creates the financial/ticket graph and calls unchanged `process_payment` once | all approval preconditions; reconciliation is sanitized 503 |
| `direct_order_approve_photo_payment(uuid,uuid,numeric,uuid,uuid) -> jsonb` | C/A store | Staff confirm the displayed amount, quote ID and latest photo ID; validates under the request lock, invokes the common approval anchor, snapshots delivery mode, and returns the same payment/ticket IDs on retry. No bank API or SePay lookup | proof required, review changed, amount mismatch, resubmission pending, forbidden plus approval errors |
| `direct_order_approve_verified_payment(uuid,uuid) -> jsonb` | C/A store | Derives amount/reference from verified evidence, invokes the atomic approval anchor, snapshots delivery mode, and attempts the first customer Bill job without making payment depend on printing | verified payment required plus approval errors |
| `direct_order_customer_receipt_status(uuid,uuid) -> jsonb` | C/A store | Reads the latest customer receipt job and whether a completed first copy permits reprint | forbidden, request not approved |
| `enqueue_direct_order_customer_receipt(uuid,uuid,bool) -> jsonb` | C/A store | First-copy retries reuse batch 1; reprint requires a completed copy and creates explicit history | request not approved, reprint unavailable |
| `enqueue_direct_order_customer_receipt_after_payment() -> trigger` | S/trigger | Best-effort first customer Bill enqueue after the financial bridge insert; print failures are isolated from payment | none propagated to approval |
| `direct_delivery_ticket_list(uuid,text[],timestamptz,uuid,int) -> jsonb` | K/C/A store | Direct-only ticket/item cursor read <=200; retry-safe | forbidden, limit |
| `direct_delivery_ticket_transition(uuid,uuid,int,text) -> jsonb` | K/C/A store | Ticket `FOR UPDATE`; expected-version and allowed edge; increments once; kitchen cannot enter `completed` | ticket not found/version/transition |
| `direct_order_cashier_complete_delivery(uuid,uuid,int) -> jsonb` | C/A store | Confirms a dispatched Grab order completed, writes one customer-visible system message/audit, and returns idempotently on replay | ticket/version/not dispatched |
| `direct_order_set_dispatch(uuid,uuid,text,numeric) -> jsonb` | C/A store | Requires approved financial; dispatch upsert, ticket state update, fixed Grab-link message/audit; same URL/cost converges | invalid URL/cost, not approved |
| `direct_order_set_dispatch_with_payment_mode(uuid,uuid,text,numeric) -> jsonb` | C/A store | Store-prepaid delegates to the existing cash payout path; customer-direct stores no fee, variance, or cash-paid timestamp | mode conflict, invalid URL/cost, not approved |
| `direct_order_analytics(uuid,date,date) -> jsonb` | A/store | Read financial/dispatch/coarse facts <=366 days; privacy-suppressed regions | forbidden, range invalid |
| `direct_order_cleanup_expired_pii(uuid[]) -> jsonb` | S | Validates every ID terminal/old, deletes exact messages/address/note and old session/rate rows; transaction atomic | input/not eligible/too early |
| `direct_order_cleanup_candidates(int) -> jsonb` | S | Read-only eligible IDs/proof paths <=500 | limit invalid |
| `direct_order_orphan_proof_candidates(int) -> jsonb` | S | Read-only storage paths older than 24h with no committed proof message, <=500 | limit invalid |
| `direct_order_arrival_alerts_after(uuid,timestamptz,uuid,int) -> jsonb` | C/store | First null cursor returns no historical items and a server cursor; later calls return only ordered request ID/created/state rows, pending count, next cursor and has-more <=100; read-only and retry-safe | forbidden, limit/cursor input |
| `direct_order_driver_receipt_status(uuid,uuid) -> jsonb` | C/A store | Reads the approved order's latest driver-receipt job and safe status fields; retry-safe | forbidden, request not found |

Function signatures and grants are executable catalog contracts. Adding an
overload, changing argument identity, exposing an uncontracted execute grant, or
adding a direct function makes `direct_delivery_schema_contract_test.sql` fail.
The current exact catalog contains 44 `direct_order_*`/`direct_delivery_*`
functions, including the isolated cashier arrival cursor, verified-payment,
customer Bill, delivery-mode, driver-receipt, cashier availability, customer
order-history, proof-review, and cashier completion RPCs.
None of these staff RPCs is an Edge public action.

## Explicit SQL error registry

`sqlDomainErrorRegistry` is the only SQL-to-HTTP mapping. All SQL `RAISE
EXCEPTION` codes are enumerated; the Flutter regression contract compares the
migration's raised-code set with the registry's key set.

- 400: actor/rate/session/request/address/item/quantity/message/quote/approval,
  dispatch/analytics/cleanup input errors. Safe specific customer codes are
  retained where the UI can correct input; other input errors become
  `INVALID_REQUEST` or `INVALID_PROOF`.
- 403: actor/store role failure becomes `REQUEST_FORBIDDEN`.
- 404: session/store/request/quote/ticket absence becomes
  `DIRECT_ORDER_UNAVAILABLE`, preventing existence disclosure.
- 409: paused/hours/open-request/menu/state/quote/proof/payment/operational/
  version/cleanup conflicts retain the explicit registered public code.
- 503: reconciliation, schema/RLS/privilege/bucket/payment-anchor preflight, and
  every unknown error become `DIRECT_ORDER_TEMPORARILY_UNAVAILABLE`.

Every documented public error is rendered through
`DirectOrderCopy.errorMessage` in the current viewer's KO/VI/EN locale. Unknown
codes use the same localized unavailable fallback and are never shown raw.

## Flutter compatibility boundary

- Success envelope must contain only `data`; error envelope must contain only a
  string `error`.
- Customer storefront/session/place/status/quote/message models reject missing
  required fields, wrong primitive/container types, invalid timestamps, and
  fields outside their documented required/nullable set.
- Submit, message, cancel, upload-reservation, and proof-commit response fields
  are exact-set checked by the service. Cache decode uses the same strict model;
  corrupt or old cache is deleted instead of being submitted.
- User-entered address/note and chat remain exact original data. UI labels,
  fixed system codes, status, and errors still render in the current viewer's
  selected KO/VI/EN locale. Optional `metadata.translations` and `translation_status` render translated free text while preserving the original.
- Cashier detail returns request-time `name_ko/name_vi/name_en`; direct ticket
  list returns approval-time `name_ko/name_vi/name_en`. Staff Flutter selects
  among these using its current viewer locale and never request locale.

## 2026-10-06 proof recovery and receipt packing

V1/V2 proof commit share `verifyProofUpload`. A successful empty exact-name list
returns 409 `PROOF_UPLOAD_INCOMPLETE`; list/download/blob-read failures return
503 `PROOF_TEMPORARILY_UNAVAILABLE` and never remove the file. Only bytes read
successfully and rejected by existing image validation are removed. Existing
private Storage, MIME/5 MiB/dimension limits and SQL ownership checks remain.

Flutter keeps a `DirectOrderProofAttempt` per order in screen memory. Lost Storage
or commit responses reuse its original path/quote/review and call commit before
uploading again. Only a definite missing object permits retransmitting to the same
signed path. SDK `FunctionException` envelopes are normalized to the public code.
Commit responses do not overwrite request state; current status is fetched with
request/revision guards, so an approved order cannot regress to payment review.

`direct_order_receipt_packing_context(p_store_id uuid,p_order_id uuid)` is an
additive authenticated staff RPC, allowing cashier/admin/store_admin/brand_admin/
super_admin with existing store authorization. It validates order/store ownership,
returns SQL NULL for ordinary POS orders, and returns exactly `diner_count`
(nullable integer 1..100), `fulfillment_method` and `direct_order_reference` for a
linked direct order. It returns no customer/financial information and creates no
job/payment. Flutter uses `DirectOrderStaffService.fetchOrderPackingContext` only
at native print time; the atomic `PaymentService` file remains unchanged.

Migration `20261006020000_direct_order_receipt_packing_context.sql` enriches new
print payloads with the reference and new direct digital snapshots with the three
packing fields. Combined digital snapshots are excluded. Print enrichment applies
to all copy types for a linked direct order. BEFORE INSERT triggers do not update issued snapshots or jobs in
pending/failed/printing/done states. New dedicated reprints capture current counts.
The migration does not redefine `process_payment`, financial calculations or
approval, and is source-only until separately applied through the release gate.

## Customer experience additions — 2026-10-06

- Public Edge action `push_subscription`: session-owned, rate limit 10 per minute. Input: `session_id`, `session_secret`, UUID `device_id`, `locale` in KO/VI/EN, boolean `enabled`, and FCM `token` only when enabled. The Edge hashes the secret and calls service-only `direct_order_public_push_subscription`. Output is exactly `{enabled: boolean}` inside the existing data envelope. Raw tokens and secrets never cross staff/public read APIs or logs. Up to five device identities are allowed per session; unsubscribe sends no token.
- Authenticated `direct_order_staff_list_v3(p_store_id,p_states,p_limit,p_fulfillment_type)` retains the queue row shape and adds `display_stage` and `refund_pending`; the optional fulfillment filter is applied before the limit and retains native and converted pickup orders. Filters accept customer stage keys or existing request/ticket state keys before the server limit (1..200). Store/role boundaries stay identical to the cashier list. Existing v2 endpoints remain available.
- Existing public status `created_at` and `items` are now retained in the Dart model for details; no extra public item endpoint is added. Existing submit item `note` persists menu requests.
- Internal `direct-order-notification-dispatcher`: POST authenticated by CRON_SECRET or service role; claims at most 50 deliveries once, runs at most eight FCM workers, and acknowledges each lease. Claims/acknowledgements and all three push tables are unavailable to anonymous/authenticated clients. No customer address, phone, bank data or session secret appears in the FCM payload.
- Migration `20261006030000_direct_order_customer_experience.sql` adds tables/RPCs/triggers and schedules the dispatcher every minute with the existing Vault cron secret when pg_cron/pg_net are available. Existing Firebase browser build definitions/VAPID and FIREBASE_SERVICE_ACCOUNT_JSON are reused. Cron availability and physical device receipt must be checked during release.

## 2026-10-10 reconciliation and translation additions

- `refund_details` (owning session, rate 20) accepts request ID and
  `refund_details:{bank,account,holder}`; the server rejects other fields, foreign
  orders, and orders without an eligible refund. Public support returns only
  this owner's account, refund amount/method, and scoped evidence message ID.
  `refund_evidence_available` keeps completed-order links/polling open for the
  server-controlled seven-day refund-photo window, unless support is closed or
  personal data was purged. `status_v7` exposes translations while v3–v6 retain
  their previous response contracts.
- `direct_order_record_receipt` keeps `actual_amount` separate from applied
  `amount`. Excess becomes `overpayment_due`, never order revenue. Food-balance
  charges must equal the server-calculated balance. Receipt proof and bank
  reference retries cannot duplicate a receipt.
- Refund support actions require operation UUID, eligible amount, method
  `CASH|BANKTRANSFER`, reference, and a store-uploaded image message ID.
  `refund_overpayment` reverses unallocated money without reversing POS revenue.
  Customer evidence URLs retain the existing scoped, private signed URL flow.
- `direct_order_set_dispatch_v4` requires positive store cash payouts to include
  `p_cash_confirmed`, `p_evidence_message_id`, `p_operation_id`, and
  `p_cash_reference`. Immutable
  movement history preserves payout time; administrator correction/recovery
  references its original payout. Bank recovery does not change store cash.
- Closing preview/history separately expose `delivery_cash_paid`,
  `delivery_cash_recovered`, and `direct_order_cash_refunds`.
  Expected cash = opening cash + cash sales - paid + cash recovered - cash refunds.
- `status_v7` messages optionally include `metadata`; item and quote notes
  optionally include `note_translations` and `translation_status`. Quote notes
  optionally include `cashier_note`. Existing responses remain accepted by the
  additive Dart parsers. System codes, attachments, accounts, and amounts are
  never translated as separate structured fields.

### 2026-10-10 customer progress and utensil choice (source implementation)

`status_v8` / `direct_order_public_status_v8` retain v7 authorization, money,
message and proof IDs. Delivery adds `utensils_requested` (boolean, legacy true)
and `cooking_complete` (boolean, all noncancelled KDS items/components at their
required quantities, no unresolved review). No KDS quantities means false.
Support adds `access_open`, the canonical post-completion refund/evidence access
predicate. Fulfillment completion remains the existing cashier confirmation.

`orders_v4` / `direct_order_public_orders_v4` add `quote_id`, `quote_version`,
`proof_review_id`, `fulfillment_method`, `has_dispatch`, and `cooking_complete`
to each summary. `has_dispatch` comes from the existing dispatch record; legacy
KDS `dispatched` alone does not establish a driver handoff.
Selected-page item/review/quote/progress aggregation uses set operations. Existing v2/v3 keys remain compatible; only v4 exposes the new summary fields. Customer multi-order refresh makes one list and one selected
status request; changed alerts make zero detail requests. Scoped links derive
summaries locally from one status request, bypassing the list endpoint.

Cooking/packing notices use statement transition tables. The existing atomic
`kds_complete_kitchen_batch_v1` retains its authorization and mutation response;
its new wrapper defers customer aggregation during individual quantity events
and aggregates affected requests once after successful completion.

`submit_v3` accepts optional boolean `payload.utensils_requested`, default true.
Diners remain 1..100; false means omit disposable cutlery, never food containers.
Replay retains the original choice. Staff diner edits preserve it. Staff detail,
kitchen list, entire KDS kitchen/tray snapshot, compatible native/queued/driver paper prints,
and digital receipt/PDF carry the same value. Saved print/receipt snapshots are
not rewritten. Payment items and the process_payment anchor are unchanged.

Versioned reads require the additive migration and Edge update before clients
using the new versions are released. This section describes source behavior;
DB application and production deployment require separate evidence.


### 2026-10-10 confirmed customer requirements

`status_v9` wraps v8 and adds scoped `requirements`; `direct_order_staff_detail_v5`
wraps the existing v4 detail and adds the same request list. Both owning-session
status wrappers are VOLATILE because the existing status renews session activity.
The four-argument `direct_order_staff_list_v4` adds set-based pending counts and
preserves native/converted pickup filtering before LIMIT.

Cashier `direct_order_staff_reply_requirement` requires an exact source version,
mutation UUID, custom reply, reviewed Vietnamese print wording, confirmation flag
and preparation/delivery/both scope. Public `decide_requirement` requires the
owning session, request, requirement version and exact reply message. Confirmation
and retries are atomic; general chat never resolves requests. Source edits or a
linked customer clarification reopen only that requirement. The quote RPC and
cashier controls both block unresolved requirements.

Confirmed wording enters new immutable receipt snapshots. Later confirmations
create separate `request_update` addenda without changing payments or original
receipts. Paperless preparation memos remain digital; receipt memos can print.
Reprints retain their original routing and paperless context. `claim_print_jobs_v2`
is required by compatible native stations; old claims leave memos and utensil
opt-out jobs pending so old software cannot print an incorrect packing slip.
