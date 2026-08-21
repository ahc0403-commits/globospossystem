# Direct delivery Edge API and RPC contract

Authorities:

- Edge: `supabase/functions/direct-order-public/index.ts`
- SQL: `supabase/migrations/20260821130000_direct_delivery_ordering.sql`
- Flutter customer decode: `lib/features/direct_order/direct_order_models.dart`
- Catalog enforcement: `supabase/tests/direct_delivery_schema_contract_test.sql`

State: source contract only. It does not prove Edge deployment, migration
application, Google project configuration, or production verification.

## Common HTTP contract

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
  response. Another session cannot claim or inspect the UUID; a second open
  request for the owning session conflicts.
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

### `message`

- Actor/rate: owning session, 60.
- Input: session ID, secret, request UUID, trimmed message 1–2,000.
- Output exactly `message_id`, `created_at`.
- Side effect/idempotency: creates one customer chat row; non-idempotent.
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
| `direct_order_admin_upsert_storefront(uuid,text,bool,bool,time,time,numeric,int,numeric,numeric,text,text,text,text,numeric,int,int,bool) -> jsonb` | A/store | Config upsert + audit; accounting gate in DB; idempotent for same values | actor/input/check violations |
| `direct_order_admin_get_storefront(uuid) -> jsonb` | A/store | Config read with null result object if absent; retry-safe | forbidden |
| `direct_order_staff_list(uuid,text[],timestamptz,uuid,int) -> jsonb` | C/A store | Cursor queue read, <=100; no proof path; retry-safe | forbidden, limit |
| `direct_order_staff_detail(uuid,uuid) -> jsonb` | C/A store | Exact address/items/quotes/chat/financial/dispatch read; attachment becomes boolean | forbidden, request not found |
| `direct_order_staff_quote(uuid,uuid,numeric,text) -> jsonb` | C/A store | Request `FOR UPDATE`; price/menu revalidation; supersedes quote, updates request/message; versioned | quote input/state, store/accounting/menu/minimum |
| `direct_order_staff_message(uuid,uuid,text) -> jsonb` | C/A store | Reads state; inserts one cashier message; non-idempotent | forbidden, invalid/not chatable |
| `direct_order_staff_reject(uuid,uuid,text) -> jsonb` | C/A store | Request `FOR UPDATE`; rejects, expires live quote, writes message/audit | reason, not found/not rejectable |
| `direct_order_staff_sepay_candidates(uuid,uuid) -> jsonb` | C/A store | Read-only time/amount candidate list; evidence only | forbidden, quote not found |
| `direct_order_staff_link_sepay(uuid,uuid,uuid) -> jsonb` | C/A store | Validates candidate then request+transaction upsert; pair-idempotent; never approves | quote/candidate invalid |
| `direct_order_approve_payment(uuid,uuid,numeric,text) -> jsonb` | C/A store | Advisory transaction lock + request/quote row locks; validates proof/amount/menu/operations; creates one legacy graph, calls unchanged `process_payment` once, writes financial/ticket/message/audit atomically; same-store replay returns the same `request_id`, `order_id`, `payment_id`, `ticket_id`, and `final_total` with `idempotent=true`; cross-store replay returns nothing | all approval preconditions; reconciliation is sanitized 503 |
| `direct_delivery_ticket_list(uuid,text[],timestamptz,uuid,int) -> jsonb` | K/C/A store | Direct-only ticket/item cursor read <=200; retry-safe | forbidden, limit |
| `direct_delivery_ticket_transition(uuid,uuid,int,text) -> jsonb` | K/C/A store | Ticket `FOR UPDATE`; expected-version and allowed edge; increments once | ticket not found/version/transition |
| `direct_order_set_dispatch(uuid,uuid,text,numeric) -> jsonb` | C/A store | Requires approved financial; dispatch upsert, ticket state update, fixed Grab-link message/audit; same URL/cost converges | invalid URL/cost, not approved |
| `direct_order_analytics(uuid,date,date) -> jsonb` | A/store | Read financial/dispatch/coarse facts <=366 days; privacy-suppressed regions | forbidden, range invalid |
| `direct_order_cleanup_expired_pii(uuid[]) -> jsonb` | S | Validates every ID terminal/old, deletes exact messages/address/note and old session/rate rows; transaction atomic | input/not eligible/too early |
| `direct_order_cleanup_candidates(int) -> jsonb` | S | Read-only eligible IDs/proof paths <=500 | limit invalid |
| `direct_order_orphan_proof_candidates(int) -> jsonb` | S | Read-only storage paths older than 24h with no committed proof message, <=500 | limit invalid |
| `direct_order_arrival_alerts_after(uuid,timestamptz,uuid,int) -> jsonb` | C/store | First null cursor returns no historical items and a server cursor; later calls return only ordered request ID/created/state rows, pending count, next cursor and has-more <=100; read-only and retry-safe | forbidden, limit/cursor input |

Function signatures and grants are executable catalog contracts. Adding an
overload, changing argument identity, exposing an uncontracted execute grant, or
adding a direct function makes `direct_delivery_schema_contract_test.sql` fail.
The current exact catalog contains 28 direct functions, including the isolated
cashier arrival cursor RPC; it is not an Edge public action.

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
- User-entered address/chat/note remains original data. No response decoder or
  error renderer invokes translation APIs.
- Cashier detail returns request-time `name_ko/name_vi/name_en`; direct ticket
  list returns approval-time `name_ko/name_vi/name_en`. Staff Flutter selects
  among these using its current viewer locale and never request locale.
