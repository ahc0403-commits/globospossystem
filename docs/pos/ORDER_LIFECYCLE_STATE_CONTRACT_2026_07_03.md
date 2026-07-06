# Order Lifecycle State Contract

Date: 2026-07-03
Status: DRAFT — pending review
Source: Harness audit 2026-07-03 (defects C1, C2, H2, H3)
Supersedes: inline status logic scattered across `add_items_to_order`,
`update_order_item_status`, `cancel_order`, `cancel_order_item`, and
client-side payability filtering in `payment_provider.dart`.

## Problem Statement

Order status is interpreted differently per screen. `add_items_to_order`
never recalculates order status, so orders with mid-service additions
disappear from the cashier queue. `cancel_order` releases the table without
cancelling in-progress items. `process_payment` accepts orders with pending
items. There is no single derivation function; each RPC and each screen
applies its own rule.

## Design Decision: Two-Level State Model

**Item status is the physical truth. Order status is derived** (except the
two terminal states, which are set only by their owning RPCs).

The DB enums are NOT changed (no CHECK-constraint migration):

- `order_items.status`: `pending | preparing | ready | served | cancelled`
- `orders.status`: `pending | confirmed | serving | completed | cancelled`
- `tables.status`: `available | occupied`

> Note: the requested state list (`pending/preparing/ready/served/...`)
> mixes the two levels. `preparing/ready/served` are ITEM states;
> `confirmed/serving` are ORDER states. This contract keeps both sets as-is
> and fixes the derivation between them.

## State Machine

### Item States (physical, kitchen-owned except cancel)

| State | Description | Set By | Valid Transitions |
|-------|-------------|--------|-------------------|
| `pending` | Sent to kitchen, not started | `create_order`, `add_items_to_order` | → preparing, → cancelled |
| `preparing` | Kitchen cooking | Kitchen (`update_order_item_status`) | → ready, → cancelled |
| `ready` | Cooked, awaiting serve | Kitchen | → served, → cancelled |
| `served` | Delivered to table | Kitchen/Waiter | (terminal; reversal = post-payment void/refund path) |
| `cancelled` | Removed before serve | Waiter/Cashier (`cancel_order_item`), `cancel_order` cascade | (terminal) |

**Change vs current code (H2):** `cancel_order_item` currently allows only
`pending|preparing`. This contract extends it to `pending|preparing|ready`.
`served` items are never cancellable — that is the refund/void domain.

### Order States (derived + terminal)

| State | Meaning | Set By |
|-------|---------|--------|
| `pending` | All active items pending | derived |
| `confirmed` | Kitchen started (≥1 item preparing/ready/served, not all done) | derived |
| `serving` | ALL active items ready or served → payable | derived |
| `completed` | Paid | `process_payment` ONLY |
| `cancelled` | Cancelled | `cancel_order` ONLY (or derivation when all items cancelled) |

"Active items" = `status <> 'cancelled'`.

### `recalc_order_status(p_order_id uuid)` — single derivation function

```
IF order.status IN ('completed','cancelled') THEN no-op (terminal guard)
active := items WHERE status <> 'cancelled'
IF active IS EMPTY:
    order → 'cancelled'; release table; audit 'order_auto_cancelled_all_items'
ELSIF every active item IN ('ready','served'):
    order → 'serving'
ELSIF any active item IN ('preparing','ready','served'):
    order → 'confirmed'
ELSE:
    order → 'pending'
```

Must run inside the same transaction, after the row lock on `orders`
(`FOR UPDATE`), in ALL of:

1. `add_items_to_order` (C1 fix — currently only touches `updated_at`)
2. `update_order_item_status` (replaces its inline partial logic at
   `20260703000000:75-87`)
3. `cancel_order_item` (currently never recalcs)

## Transition Rules (order level)

| From → To | Trigger | Actor | Side Effects | Notes |
|-----------|---------|-------|--------------|-------|
| (none) → pending | `create_order` | Waiter | table → occupied | unchanged |
| pending → confirmed | first item → preparing/ready | Kitchen (via recalc) | — | |
| confirmed → pending | not reachable | — | — | items never go backwards |
| serving → confirmed | `add_items_to_order` adds pending item | Waiter (via recalc) | order drops OUT of cashier queue — correct and intentional; kitchen must finish new items first | C1: today order silently never ENTERS the queue |
| confirmed/pending → serving | last active item → ready/served | Kitchen (via recalc) | order ENTERS cashier queue | |
| serving → completed | `process_payment` | Cashier | payments row, table → available, e-invoice job async | H3: RPC must REJECT if any active item NOT IN ('ready','served') → `ORDER_NOT_PAYABLE` |
| pending/confirmed → cancelled | `cancel_order` | Waiter/Admin | see cancel contract below | |
| serving → cancelled | `cancel_order` | Admin only | see cancel contract below | new: today serving orders are stuck (not cancellable, not always payable) |
| any → cancelled (derived) | last active item cancelled | via recalc | table → available | |

### `cancel_order` contract (C2 fix)

Current defect: sets order → cancelled and table → available but leaves
items in `preparing/ready`.

New behavior, single transaction:

1. Lock order. Reject if `completed|cancelled` (`ORDER_NOT_CANCELLABLE`).
2. Cancel ALL items with status IN (`pending`,`preparing`,`ready`),
   each with an item-level audit row (`cancelled_via_order_cancel`).
3. If any item is `served` and `p_allow_served := false` (default) →
   RAISE `ORDER_HAS_SERVED_ITEMS`. Caller (admin UI only) may pass
   `p_allow_served := true`, which cancels the order but leaves served
   items' audit trail intact.
4. Order → `cancelled`.
5. Release table ONLY IF the table's current occupying order is this order
   (guard: no other order on that table in `pending|confirmed|serving`).
6. Audit `order_cancelled`.

## Screen Visibility Contract

| Screen | Loads Orders With Status | Payable/Actionable Rule | Can Trigger | Must NOT See |
|--------|--------------------------|-------------------------|-------------|--------------|
| Waiter | `pending, confirmed, serving` (own store) | edit qty: item `pending`; cancel item: item `pending/preparing/ready` | create_order, add_items_to_order, cancel_order_item, cancel_order | completed, cancelled |
| Kitchen | active lanes: `pending, confirmed, serving`; optional read-only completed-history panel may query `completed` separately | act on items `pending/preparing/ready` | update_order_item_status | completed/cancelled orders in active lanes |
| Cashier | `serving` ONLY — **replace client-side `_isCashierPayableItemRows` every() check with the single order-status criterion** (`payment_provider.dart:348`) | payable ⇔ `status = 'serving'` | process_payment, cancel_order (admin) | pending, confirmed (kitchen not done) |
| Tables map | table `occupied` ⇔ ∃ order in `pending/confirmed/serving` | — | — | — |

The cashier rule is the core simplification: **payability is an order-status
fact computed server-side, never a client-side item scan.** All three
screens then read the same column with the same meaning.

## Invariants

1. `orders.status` ∈ {completed, cancelled} is terminal; no RPC may mutate
   the order or its items afterward (`ORDER_NOT_MUTABLE`).
2. An order is in `serving` ⇔ every active item is `ready|served` and
   ≥1 active item exists.
3. `process_payment` succeeds ⇒ order was `serving` at lock time.
4. No item may be `preparing|ready` while its order is `cancelled`
   (cancel cascades to items).
5. A table is `available` ⇒ no order on it is in `pending|confirmed|serving`.
6. Table release happens ONLY inside `process_payment` or `cancel_order`
   (never from Flutter — existing CLAUDE.md payment rule).
7. Every item status change and every derived order transition writes an
   audit_logs row.
8. Item transitions are forward-only except `→ cancelled`;
   `served` is irreversible.

## Non-Goals

- No change to the order/item status enum values (no constraint migration).
- No refund/void redesign (`served` reversal stays in the existing
  refund path from commit 43ca5a6).
- No realtime latency work (15s fallback poll) — separate concern.
- No buffet/delivery-channel special-casing beyond what the RPCs already do.

## Migration / Rollout Steps

1. One migration: create `recalc_order_status`; rewrite `cancel_order`;
   patch `add_items_to_order` + `update_order_item_status` +
   `cancel_order_item` to call it; add `ORDER_NOT_PAYABLE` guard to
   `process_payment`. (1-PR-1-risk: this is the single DB-risk slice.)
2. Flutter follow-up PR: kitchen filter drops `completed`; cashier payable
   check becomes `status == 'serving'`; waiter cancel-item UI enables
   `ready` items.
3. Contract test: SQL-level test driving one order through
   happy path + add-mid-service path + cancel paths, asserting
   invariants 1–5 after every step.

## Breaking Changes / Compatibility Notes

- Orders currently stuck invisible (mixed pending+ready) become visible
  again once recalc runs; a one-time backfill
  (`SELECT recalc_order_status(id) FROM orders WHERE status NOT IN
  ('completed','cancelled')`) must ship in the same migration.
- Cashier UI that displayed pending/confirmed orders in the queue (loaded
  then client-filtered) will now not receive them — intended.
- `cancel_order` on orders with served items now fails without
  `p_allow_served` — admin screen must pass the flag.

## Open Questions

1. Should kitchen show just-cancelled `preparing` items (strike-through
   acknowledgment) instead of them vanishing? → UX decision, Hyochang.
   (P1; not required for the state contract itself.)
2. `serving → cancelled` for admin: confirm this is wanted vs forcing
   refund-after-payment flow. → Hyochang.
