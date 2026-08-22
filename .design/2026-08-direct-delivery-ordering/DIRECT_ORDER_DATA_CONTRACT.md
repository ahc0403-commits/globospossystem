# Direct delivery data contract

Authority: `supabase/migrations/20260821130000_direct_delivery_ordering.sql`
State: source contract only; not evidence of migration application or production deployment.

## Shared default-deny boundary

- Every table below has RLS enabled and no client policy.
- `PUBLIC`, `anon`, and `authenticated` have no table privileges.
- `service_role` is the Edge/public-session and retention writer. Staff reads and
  writes use only `SECURITY DEFINER` RPCs that validate role and store scope with
  `direct_order_require_actor` and `user_accessible_stores`.
- `direct-order-proofs` is private, limited to 5 MiB and JPEG/PNG/WebP, and has
  no client storage policy. Edge alone uploads, signs reads, and deletes objects.
- Signed uploads that never become a committed proof message are selected only
  after 24 hours by a bounded service-role function and removed by the same
  internal Edge cleanup. Committed proof paths are excluded.
- Exact address, phone, free text, proof path, bank reference, and signed/Grab
  URL are never permitted in event payloads or logs.

Notation: `N` = NOT NULL, `null` = nullable. The table-level writer, reader,
retention, PII, and legacy-reference rules apply to every listed column.

## Tables and columns

### `direct_order_storefronts`

Store ordering/bank/privacy config. Admin-config RPC writes; public projection
and scoped admin RPCs read. Retained with restaurant; restaurant delete CASCADE.
Bank fields are financial-sensitive; coordinates are location data; audit user
IDs are internal. Legacy refs: `restaurants`, `auth.users` only.

```text
restaurant_id uuid N PK, FK restaurants CASCADE
public_slug text N UNIQUE, lowercase 3..63 slug CHECK
is_enabled boolean N DEFAULT false, bank/accounting gate CHECK
is_paused boolean N DEFAULT false
ordering_starts_at time N DEFAULT 10:00, valid-window CHECK
ordering_cutoff_at time N DEFAULT 21:30, <=21:30 CHECK
minimum_order_amount numeric(15,2) N DEFAULT 0, >=0 CHECK
quote_ttl_minutes integer N DEFAULT 20, 5..120 CHECK
default_latitude numeric(9,6) null, paired coordinate CHECK
default_longitude numeric(9,6) null, paired coordinate CHECK
bank_bin text null, six digits when enabled
bank_account_number text null, 5..19 safe characters when enabled
bank_account_holder text null, trimmed 2..120 when enabled
bank_label text null
delivery_fee_vat_rate numeric(5,2) N DEFAULT 0, IN (0,8,10)
pii_retention_days integer N DEFAULT 90, 7..730 CHECK
analytics_min_cell_count integer N DEFAULT 3, 2..20 CHECK
accounting_approved_at timestamptz null, required when enabled
accounting_approved_by uuid null, FK auth.users SET NULL
created_by uuid null, FK auth.users SET NULL
updated_by uuid null, FK auth.users SET NULL
created_at timestamptz N DEFAULT now()
updated_at timestamptz N DEFAULT now()
```

### `direct_order_sessions`

Accountless session. Edge service only. Hash is secret; locale is request/client
preference metadata. Default expiry 30 days; expired sessions older than another
30 days are deleted by eligible cleanup when no unpurged request depends on
them. Legacy ref: restaurant CASCADE.

```text
id uuid N DEFAULT gen_random_uuid() PK
restaurant_id uuid N FK restaurants CASCADE
secret_hash text N UNIQUE, 64 lowercase hex CHECK
locale text N DEFAULT vi, IN (ko,vi,en)
expires_at timestamptz N DEFAULT now()+30 days, >created_at CHECK
revoked_at timestamptz null
last_seen_at timestamptz N DEFAULT now()
created_at timestamptz N DEFAULT now()
```

### `direct_order_public_access_limits`

Pseudonymous rate-limit security metadata. Rate RPC/service only. Windows older
than one day are deleted by cleanup. No legacy refs.

```text
request_key text N composite PK
window_started_at timestamptz N composite PK
request_count integer N DEFAULT 1, >0 CHECK
updated_at timestamptz N DEFAULT now()
```

### `direct_order_requests`

Request identity/state. Edge session RPCs and scoped staff RPCs write/read.
`customer_note` is exact free-text PII and is cleared after the terminal-request
retention window; state/coarse/financial audit is retained. Legacy ref:
restaurant CASCADE; session CASCADE until restrictive downstream links exist.

```text
id uuid N DEFAULT gen_random_uuid() PK
restaurant_id uuid N FK restaurants CASCADE
session_id uuid N FK direct_order_sessions CASCADE
client_request_id uuid N UNIQUE (idempotency)
reference_code text N UNIQUE, D+8 uppercase/digits CHECK
state text N DEFAULT awaiting_quote, IN awaiting_quote/quoted/awaiting_payment_review/approved/rejected/cancelled/expired
locale text N DEFAULT vi, IN (ko,vi,en); request metadata only
customer_note text null, <=500 CHECK; exact PII
approved_at timestamptz null
rejected_at timestamptz null
cancelled_at timestamptz null
pii_purged_at timestamptz null
created_at timestamptz N DEFAULT now()
updated_at timestamptz N DEFAULT now()
```

### `direct_order_request_items`

Immutable request-time menu/locale snapshot. Submit writes; owning session and
scoped staff detail read. Retained for financial audit. `item_note` is exact
free-text PII. Legacy refs: menu item RESTRICT, restaurant/request CASCADE.

```text
id uuid N DEFAULT gen_random_uuid() PK
request_id uuid N FK requests CASCADE
restaurant_id uuid N FK restaurants CASCADE
menu_item_id uuid N FK menu_items RESTRICT
display_name text N (submitted-locale compatibility snapshot)
name_ko text N
name_vi text N
name_en text N
vat_category text N IN (food,alcohol)
unit_price numeric(15,2) N >=0 CHECK
quantity integer N 1..50 CHECK
item_note text null <=300 CHECK; exact PII
sort_order integer N DEFAULT 0
created_at timestamptz N DEFAULT now()
UNIQUE (request_id,menu_item_id)
```

### `direct_order_request_addresses`

Exact contact/location PII. Submit writes; owning-session status and scoped
staff detail read. The complete row is deleted after the configured terminal
PII window. Legacy refs: request/restaurant CASCADE.

```text
request_id uuid N PK, FK requests CASCADE
restaurant_id uuid N FK restaurants CASCADE
customer_name text N trimmed 1..100 CHECK
customer_phone text N validated phone CHECK
formatted_address text N trimmed 3..500 CHECK
detail_address text N trimmed 1..300 CHECK
latitude numeric(9,6) N -90..90 CHECK
longitude numeric(9,6) N -180..180 CHECK
google_place_id text null <=255 CHECK
district text null
ward text null
address_source text N IN (search,map_pin)
location_verified boolean N DEFAULT false
created_at timestamptz N DEFAULT now()
updated_at timestamptz N DEFAULT now()
```

### `direct_order_location_facts`

PII-minimized analytics fact. Submit writes; admin analytics RPC reads only with
minimum-cell suppression. Retained after exact PII purge. Legacy ref:
restaurant/request CASCADE until restrictive downstream graph exists.

```text
request_id uuid N PK, FK requests CASCADE
restaurant_id uuid N FK restaurants CASCADE
district text null
ward text null
coarse_latitude numeric(6,3) N
coarse_longitude numeric(6,3) N
requested_at timestamptz N
created_at timestamptz N DEFAULT now()
```

### `direct_order_messages`

Customer/cashier chat, fixed system code, quote/proof/Grab record. Session/staff
RPCs write/read; proof bytes require an Edge signed URL. Body, metadata, and
attachment path are sensitive/PII. Rows and Edge proof objects are deleted after
the terminal PII window. Legacy ref: auth sender SET NULL; request/restaurant
CASCADE.

```text
id uuid N DEFAULT gen_random_uuid() PK
request_id uuid N FK requests CASCADE
restaurant_id uuid N FK restaurants CASCADE
sender_type text N IN (customer,cashier,system)
sender_auth_id uuid null FK auth.users SET NULL
message_type text N IN (text,payment_proof,quote,grab_link,system)
body text null length 1..2000 CHECK; exact free text/system code/secret link
attachment_storage_path text null strict store/request/UUID image-path CHECK
metadata jsonb N DEFAULT {}, object CHECK
created_at timestamptz N DEFAULT now()
content CHECK: proof requires attachment; every other type requires body
partial UNIQUE: each non-null attachment_storage_path can create one proof message
```

### `direct_order_quotes`

Versioned financial quote. Scoped staff writes; session/staff read; proof RPC
locks. Retained for audit. `cashier_note` is exact free-text PII. Legacy ref:
creator auth user; direct request/restaurant.

```text
id uuid N DEFAULT gen_random_uuid() PK
request_id uuid N FK requests CASCADE
restaurant_id uuid N FK restaurants CASCADE
version integer N >0 CHECK
menu_pretax numeric(15,2) N >=0 CHECK
menu_vat numeric(15,2) N >=0 CHECK
menu_total numeric(15,2) N >=0 CHECK
service_charge_pretax numeric(15,2) N >=0 CHECK
service_charge_vat numeric(15,2) N >=0 CHECK
service_charge_total numeric(15,2) N >=0 CHECK
delivery_fee_pretax numeric(15,2) N >=0 CHECK
delivery_fee_vat numeric(15,2) N >=0 CHECK
delivery_fee_total numeric(15,2) N >=0 CHECK
final_total numeric(15,2) N >0 CHECK
delivery_fee_vat_rate numeric(5,2) N IN (0,8,10)
status text N DEFAULT active IN (active,superseded,locked,expired)
cashier_note text null <=500 CHECK; exact PII
created_by uuid N FK auth.users
expires_at timestamptz N >created_at CHECK
locked_at timestamptz null
created_at timestamptz N DEFAULT now()
UNIQUE (request_id,version); partial UNIQUE request_id WHERE active/locked
```

### `direct_order_sepay_candidates`

Optional cashier-linked evidence, never an approval trigger. Scoped cashier
RPCs write/read. Retained as financial audit. Legacy refs: SePay transaction
RESTRICT and auth user.

```text
id uuid N DEFAULT gen_random_uuid() PK
request_id uuid N FK requests CASCADE
restaurant_id uuid N FK restaurants CASCADE
sepay_transaction_id uuid N FK sepay_transactions RESTRICT
linked_by uuid N FK auth.users
linked_at timestamptz N DEFAULT now()
UNIQUE (request_id,sepay_transaction_id)
```

### `direct_order_financials`

Immutable one-to-one bridge written only by manual approval and read by scoped
staff/admin analytics. Permanent financial audit. All request, quote, order,
payment, delivery-fee item, and restaurant FKs are RESTRICT; linked financial
IDs are UNIQUE. Bank reference is sensitive financial PII.

```text
request_id uuid N PK, FK requests RESTRICT
restaurant_id uuid N FK restaurants RESTRICT
quote_id uuid N UNIQUE FK quotes RESTRICT
order_id uuid N UNIQUE FK orders RESTRICT
payment_id uuid N UNIQUE FK payments RESTRICT
delivery_fee_item_id uuid N UNIQUE FK order_items RESTRICT
menu_total numeric(15,2) N >=0 CHECK
service_charge_total numeric(15,2) N >=0 CHECK
delivery_fee_total numeric(15,2) N >=0 CHECK
final_total numeric(15,2) N >0 CHECK
confirmed_bank_reference text null <=200 CHECK; sensitive financial PII
approved_by uuid N FK auth.users
approved_at timestamptz N DEFAULT now()
```

### `direct_delivery_fulfillment_tickets`

Direct-only kitchen lifecycle, isolated from existing KDS. Approval creates;
direct ticket RPC reads/transitions. Permanent operational record. Request and
restaurant FKs RESTRICT; updater auth ID SET NULL.

```text
id uuid N DEFAULT gen_random_uuid() PK
request_id uuid N UNIQUE FK requests RESTRICT
restaurant_id uuid N FK restaurants RESTRICT
status text N DEFAULT pending IN (pending,preparing,ready,dispatched,completed,cancelled)
pickup_code text N, D+8 uppercase/digits CHECK
version integer N DEFAULT 1, >0 CHECK
accepted_at timestamptz null
ready_at timestamptz null
dispatched_at timestamptz null
completed_at timestamptz null
cancelled_at timestamptz null
updated_by uuid null FK auth.users SET NULL
created_at timestamptz N DEFAULT now()
updated_at timestamptz N DEFAULT now()
```

### `direct_delivery_fulfillment_ticket_items`

Approval-time kitchen snapshot. Approval writes; direct ticket RPC reads.
Retained with ticket. `item_note` is free-text PII. Menu/restaurant refs RESTRICT
and ticket ref CASCADE. All three localized names are copied from the immutable
request snapshot at manual approval; the kitchen never re-reads the live menu.
`display_name_vi` is preserved unchanged for compatibility.

```text
id uuid N DEFAULT gen_random_uuid() PK
ticket_id uuid N FK direct tickets CASCADE
restaurant_id uuid N FK restaurants RESTRICT
menu_item_id uuid N FK menu_items RESTRICT
display_name_ko text N
display_name_vi text N
display_name_en text N
quantity integer N 1..50 CHECK
item_note text null <=300 CHECK; exact PII
sort_order integer N DEFAULT 0
created_at timestamptz N DEFAULT now()
```

### `direct_order_dispatches`

Manual Grab share link and fee variance. Scoped cashier writes; owning session
and staff detail read. Retained as financial/delivery audit. Grab URL is a
secret customer-specific link. Request/restaurant RESTRICT; sender auth user.

```text
request_id uuid N PK, FK requests RESTRICT
restaurant_id uuid N FK restaurants RESTRICT
grab_tracking_url text N <=2000, HTTPS Grab host CHECK
customer_delivery_fee numeric(15,2) N >=0 CHECK
actual_grab_fee numeric(15,2) null >=0 CHECK
fee_variance numeric(15,2) null
sent_by uuid N FK auth.users
sent_at timestamptz N DEFAULT now()
updated_at timestamptz N DEFAULT now()
```

## Index-to-query contract

| Index | Required query/invariant |
|---|---|
| `direct_order_requests_one_open_per_session` | One open quote/review request per session |
| `direct_order_requests_store_state_created` | Store/state cashier queue and alert catch-up |
| `direct_order_requests_session_created` | Restore latest owning-session request |
| `direct_order_request_items_store_request` | Store-scoped request detail |
| `direct_order_request_items_menu` | Menu reference/audit lookup |
| `direct_order_request_addresses_store` | Store-scoped exact-address join |
| `direct_order_location_facts_store_time` | Hour/day direct analytics |
| `direct_order_location_facts_region_time` | District/ward/time aggregation |
| `direct_order_messages_request_created` | Stable chronological chat cursor |
| `direct_order_messages_store_created` | Store retention/audit scan |
| `direct_order_messages_attachment_unique` | Idempotent proof commit after a lost HTTP response |
| `direct_order_quotes_one_live` | One active/locked quote per request |
| `direct_order_quotes_store_created` | Store quote audit |
| `direct_order_sepay_candidates_store` | Store-linked SePay evidence |
| `direct_order_sepay_candidates_transaction` | Reverse SePay audit lookup |
| `direct_order_financials_store_approved` | Direct sales/time reporting exactly once |
| `direct_delivery_tickets_store_status_created` | Direct kitchen queue |
| `direct_delivery_ticket_items_ticket` | Stable ticket item order |
| `direct_delivery_ticket_items_store` | Store-scoped ticket detail |
| `direct_order_dispatches_store_sent` | Delivery/variance reporting |

PK and UNIQUE constraints also create their standard backing indexes.

## Role/RPC matrix

| Actor | Direct table access | Allowed boundary |
|---|---|---|
| `anon` | none | Edge HTTP only; no direct RPC execute |
| ordinary `authenticated` | none | actor guard rejects staff RPCs |
| same-store `cashier` | none | queue/detail/quote/chat/reject/SePay/approve/dispatch, arrival cursor, and direct ticket RPCs |
| other-store `cashier` | none | accessible-store guard rejects |
| same-store `kitchen` | none | direct ticket list/transition only |
| scoped admin roles | none | settings/analytics and documented staff/ticket RPCs |
| `super_admin` | none | same RPC families, explicit scope exception |
| `service_role` | all direct tables | Edge public-session and retention workflows only |

No grant adds direct client access to legacy orders, payments, inventory,
meInvoice, print, or existing KDS. The sole direct-to-legacy write boundary is
manual `direct_order_approve_payment`, which calls unchanged `process_payment`
inside the same transaction.
