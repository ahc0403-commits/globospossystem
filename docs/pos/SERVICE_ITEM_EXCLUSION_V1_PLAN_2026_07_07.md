# Service Item Exclusion V1 Plan — 2026-07-07

## Objective

Represent service-provided food as a line-level billing state so cooked/served menu items can be excluded from the customer bill without treating them as discounts, cancellations, or full-order SERVICE payments.

## Contract

- Add `order_items.is_service_item` plus `service_reason`, `service_marked_by`, and `service_marked_at`.
- Only real `item_type = 'menu_item'` lines in `ready` or `served` state can be marked. Synthetic `service_charge` lines are never service items.
- Keep at least one billable menu line. Full-order service remains the existing SERVICE payment path.
- Block mark/unmark for completed/cancelled orders, staff-meal orders, and orders with any existing payment row.
- Require admin-like permission or `discount_apply`, manager PIN verification, and a reason.
- Mark/unmark must auto-void any active order discount with the existing item-change reason.

## Payment Math

- Keep `process_payment(uuid, uuid, numeric, text)` signature unchanged.
- In the menu-line payment loop, service lines are skipped from customer payable total, discount base, service-charge base, and `payment_discount_lines`.
- Service lines are defensively written with zero VAT/payment residues: `vat_rate`, `vat_amount`, `total_amount_ex_tax`, and `paying_amount_inc_tax`.
- Split-payment math continues to use `payments.amount_portion` against the service-excluded payable total.
- Inventory deduction remains unchanged because service food is still real food.

## meInvoice

- `calculate_order_discountable_total` excludes service item lines.
- `enqueue_meinvoice_cash_register_job` excludes service item lines from `line_items_snapshot`.
- Payment completion remains independent of MISA meInvoice availability.

## Evidence

- Runtime DB contract: `supabase/tests/service_item_exclusion_contract_test.sql`.
- Flutter contract: `test/service_item_exclusion_contract_test.dart`.
- Calculator coverage: `test/payment_total_calculator_test.dart`.
- Receipt coverage: `test/receipt_builder_contract_test.dart`.

## Validation

Run before release:

```sh
flutter analyze
flutter test test/service_item_exclusion_contract_test.dart test/payment_total_calculator_test.dart test/receipt_builder_contract_test.dart
PGPASSWORD=postgres psql -h 127.0.0.1 -p 54322 -U postgres -d postgres -v ON_ERROR_STOP=1 -f supabase/tests/service_item_exclusion_contract_test.sql
```

## Status

DB DEPLOYED: `20260707010000_service_item_exclusion_v1` is applied in
production. Client rollout and Gate 3 evidence remain pending until the service
item cashier surface is committed, deployed, and smoke-tested.
