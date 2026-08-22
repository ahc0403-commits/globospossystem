# Direct delivery persisted-state and concurrency contract

Authority: current direct migration and its RPCs. Conceptual UI labels do not
create additional database states.

## Request states

| Stored state | Entered by | Allowed next operation/state | Forbidden or important rule |
|---|---|---|---|
| `awaiting_quote` | successful public submit | cashier quote -> `quoted`; cashier reject -> `rejected`; customer cancel -> `cancelled`; chat | no legacy order/payment/ticket exists |
| `quoted` | first or replacement cashier quote | re-quote stays `quoted` with next version; proof commit -> `awaiting_payment_review`; reject/cancel; chat | only one active quote; old active quote becomes superseded |
| `awaiting_payment_review` | structurally validated proof commit | manual cashier approve -> `approved`; cashier reject -> `rejected`; chat | customer cancel and re-quote forbidden; proof/SePay never auto-approves |
| `approved` | successful atomic manual approval | chat; Grab dispatch and direct kitchen lifecycle | request remains approved while ticket progresses; approve replay returns same financial IDs |
| `rejected` | cashier rejection from any pre-approval state | no state transition | chat/cancel/quote/approve forbidden |
| `cancelled` | customer cancel from awaiting_quote/quoted | no state transition | chat/quote/approve/reject forbidden |
| `expired` | reserved terminal storage value | no V1 RPC enters it | quote time expiry is enforced by `expires_at`; it does not silently rewrite request state |

State names such as “proof submitted”, “payment review”, “preparing”, or
“delivery complete” in UI are viewer-locale labels. Only the values above are
stored in `direct_order_requests.state`.

## Locale is metadata, not state

`direct_order_sessions.locale` and `direct_order_requests.locale` accept only
`ko`, `vi`, or `en` and record the customer context. They do not transition a
request and never select cashier, kitchen, admin, or alert language. Every
viewer resolves labels, fixed system codes, and localized name snapshots from
that viewer's current app locale. Free-text chat/address/note remains original.
The full rule is `DIRECT_ORDER_LOCALE_CONTRACT.md`.

## Quote states

| Stored state | Transition |
|---|---|
| `active` | new quote; at most one active/locked quote per request |
| `superseded` | re-quote replaces an active quote and increments version |
| `locked` | proof commit locks the selected unexpired quote |
| `expired` | cancel/reject expires active or locked quote |

`expires_at <= now()` makes an active/locked quote unusable even before its
status column is normalized. Approval must reject it. Re-quote is allowed only
while the request is awaiting_quote/quoted, so a locked proof quote cannot be
silently replaced.

## Direct fulfillment ticket states

```text
pending -> preparing -> ready -> dispatched -> completed
    \-----------> cancelled <-----------/
```

- `pending -> cancelled`, `preparing -> cancelled`, and `ready -> cancelled`
  are allowed; dispatched cannot cancel.
- Every explicit transition row-locks the ticket, requires exact
  `expected_version`, increments version once, and sets only the matching
  lifecycle timestamp.
- Sending a valid Grab link automatically changes `ready -> dispatched` and
  increments the same version. Other ticket states are not silently changed.
- `completed` and `cancelled` are terminal.
- This is a direct-only ticket domain. Existing KDS state/providers/functions
  are never used or modified.

## Manual approval atomic boundary

Approval is the only direct-to-legacy write path:

1. Validate actor/input, acquire request-specific transaction advisory lock.
2. Return existing financial identity immediately on replay.
3. Row-lock request and locked quote; validate state, cutoff, storefront,
   fulfillment mode, emergency/promotion, exact amount, proof, quote expiry,
   and unchanged menu.
4. Insert one delivery order, menu lines, attributable delivery-fee line, one
   direct ticket and its item snapshots.
5. Call the unchanged `process_payment` exactly once.
6. Reconcile final order/payment totals.
7. Insert the unique direct financial bridge, set request approved, and write
   one fixed system message and audit record.

Every step is one PostgreSQL transaction. An exception at any step rolls back
orders, items, payment, inventory, meInvoice enqueue, ticket/items, financial
bridge, request/message/audit changes together.

## Concurrency outcomes

| Race | Required outcome |
|---|---|
| approve vs identical approve | advisory lock serializes; first creates graph, second returns the same request/order/payment/ticket identity and final amount with `idempotent=true`; exactly one graph |
| approve vs reject | request row lock serializes; whichever legal terminal operation commits first wins; loser receives its documented state conflict; no mixed graph |
| approve vs cancel | no state is eligible for both operations: approval requires payment-review while cancel allows only awaiting_quote/quoted. From payment-review, approval may win and cancel must return not-cancellable; no mixed graph |
| two ticket updates at same version | first increments version; second returns version conflict |
| dispatch vs explicit ready->dispatched | ticket row lock/version contract permits one state change; replay observes dispatched and must not regress |

## Failure-injection boundary

Failure triggers and waits exist only in rollback-safe test SQL or a database
whose name begins `codex_direct_`. They must never be included in a production
migration or Edge bundle. Tests inject after order insertion, after ticket/item
insertion, immediately before and after the financial bridge (therefore after
`process_payment`), and before the approval audit completes. Every failure must
leave the request in payment review with its locked quote/proof but zero legacy
or ticket/financial approval side effects; a trigger-free retry must create one
graph.
