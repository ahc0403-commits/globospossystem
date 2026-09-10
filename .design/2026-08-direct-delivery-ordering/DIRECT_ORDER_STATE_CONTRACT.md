# Direct delivery persisted-state and concurrency contract

Authority: current direct migration and its RPCs. Conceptual UI labels do not
create additional database states.

## Intake availability (not a request state)

`direct_order_storefronts.is_paused` is the manual new-intake switch shown as
`OPEN`/`CLOSED` on the cashier main screen. `CLOSED` blocks only a new public
submit. Requests that already exist remain visible and can continue through
quote, proof review, manual approval, chat, fulfillment, dispatch, and status
polling. It never rewrites a request state, cancels an order, or reopens
automatically.

Cashier and admin roles may read the four-field availability projection and set
the pause value only for an accessible store. Kitchen, waiter, anonymous, and
cross-store actors cannot read or change it. The setter row-locks the storefront;
actual changes write one old/new audit, while a same-value replay is idempotent.

## Request states

| Stored state | Entered by | Allowed next operation/state | Forbidden or important rule |
|---|---|---|---|
| `awaiting_quote` | successful public submit | cashier quote -> `quoted`; cashier reject -> `rejected`; customer cancel -> `cancelled`; chat | no legacy order/payment/ticket exists |
| `quoted` | first or replacement cashier quote | re-quote stays `quoted` with next version; proof commit -> `awaiting_payment_review`; reject/cancel; chat | only one active quote; old active quote becomes superseded |
| `awaiting_payment_review` | structurally validated proof commit or verified SePay link | cashier requests proof replacement while state remains unchanged; replacement proof resolves the request; verified cashier approve -> `approved`; cashier reject -> `rejected`; chat | approval is blocked while a proof replacement request is open; customer cancel and re-quote forbidden; an image alone cannot authorize approval and SePay never auto-approves |
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
that viewer's current app locale. Free-text chat preserves the original and
selects its server-generated KO/VI/EN copy by viewer locale; address/note
remains original.
The full rule is `DIRECT_ORDER_LOCALE_CONTRACT.md`.

## Quote states

| Stored state | Transition |
|---|---|
| `active` | new quote; at most one active/locked quote per request |
| `superseded` | re-quote replaces an active quote and increments version |
| `locked` | proof commit or verified SePay link locks the selected unexpired quote |
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
- Only cashier/admin may confirm `dispatched -> completed`, after checking the
  Grab delivery result. The operation writes one customer-visible completion
  message and is idempotent on replay. Kitchen cannot enter `completed`.
- `completed` and `cancelled` are terminal.
- This is a direct-only ticket domain. Existing KDS state/providers/functions
  are never used or modified.

## Manual approval atomic boundary

Approval is the only direct-to-legacy write path:

1. Validate actor/input, acquire request-specific transaction advisory lock.
2. Return existing financial identity immediately on replay.
3. Row-lock request and locked quote; validate state, cutoff, enabled storefront,
   fulfillment mode, emergency/promotion, quote expiry, unchanged menu, and a
   linked incoming SePay transaction with the exact store and final amount. An
   uploaded image is supporting evidence only. The new-intake pause value is
   not an existing-request approval precondition.
4. Insert one delivery order, menu lines, attributable delivery-fee line, one
   direct ticket and its item snapshots.
5. Call the unchanged `process_payment` exactly once.
6. Reconcile final order/payment totals.
7. Insert the unique direct financial bridge, set request approved, and write
   one fixed system message and audit record.
8. Enqueue the first customer Bill once. Missing destinations or print failures
   remain visible and retryable without rolling back the completed payment.

Every step is one PostgreSQL transaction. An exception at any step rolls back
orders, items, payment, inventory, meInvoice enqueue, ticket/items, financial
bridge, request/message/audit changes together.

## Concurrency outcomes

| Race | Required outcome |
|---|---|
| approve vs identical approve | advisory lock serializes; first creates graph, second returns the same request/order/payment/ticket identity and final amount with `idempotent=true`; exactly one graph |
| same SePay transaction vs two requests | transaction advisory lock plus the unique transaction index allows one request link; the loser receives `DIRECT_ORDER_SEPAY_TRANSACTION_ALREADY_USED` and cannot approve |
| approve vs reject | request row lock serializes; whichever legal terminal operation commits first wins; loser receives its documented state conflict; no mixed graph |
| approve vs cancel | no state is eligible for both operations: approval requires payment-review while cancel allows only awaiting_quote/quoted. From payment-review, approval may win and cancel must return not-cancellable; no mixed graph |
| two ticket updates at same version | first increments version; second returns version conflict |
| dispatch vs explicit ready->dispatched | ticket row lock/version contract permits one state change; replay observes dispatched and must not regress |
| proof reupload vs approval | the open review row blocks approval; only a replacement bound to that exact quote/review resolves it, after which approval may continue |
| two completion confirmations | the first moves dispatched to completed and writes one message/audit; replay returns the same completed ticket without duplicate messages |
| OPEN vs CLOSED from two cashier terminals | storefront row lock serializes both set-to-value calls; each caller uses the returned server state and the last committed call becomes the persisted state |
| public submit vs cashier CLOSED | storefront share/update locks serialize the boundary; a submit that observes CLOSED creates no request, while a request committed first is an existing request and remains processable |

## Failure-injection boundary

Failure triggers and waits exist only in rollback-safe test SQL or a database
whose name begins `codex_direct_`. They must never be included in a production
migration or Edge bundle. Tests inject after order insertion, after ticket/item
insertion, immediately before and after the financial bridge (therefore after
`process_payment`), and before the approval audit completes. Every failure must
leave the request in payment review with its locked quote/proof but zero legacy
or ticket/financial approval side effects; a trigger-free retry must create one
graph.
