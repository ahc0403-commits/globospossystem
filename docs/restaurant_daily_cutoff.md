# Restaurant daily cutoff

Restaurant sales use one server-authoritative operating cutoff in
`Asia/Ho_Chi_Minh`. The legal business date remains the HCM calendar date; the
operating cutoff does not move receipts to another date.

## Scope and activation

`public.restaurant_cutoff_policies` is the only Restaurant discriminator for
this workflow. An enabled row opts a store into the cutoff. Absence is the safe
default, so Photo stores and future stores remain unchanged until an explicit
owner-approved configuration is applied. The production configuration refuses
any store that overlaps an active Photo monitoring policy.

## Daily sequence

- Before 21:30: new orders, item additions, quantity increases, and payments
  follow the existing POS contracts.
- From 21:30: new orders, new order lines, price increases, and quantity
  increases fail with `RESTAURANT_KITCHEN_CLOSED`. Existing orders remain
  visible and may be paid.
- From 21:45: payment completion and all other sale-producing mutations fail
  with `RESTAURANT_DAILY_SALES_CLOSED`. Cancellation, quantity reduction, and
  kitchen status cleanup remain available.
- At 22:20: `restaurant-daily-sales-finalize-2220-hcm` executes once. There is
  no later fallback execution.

All mutation decisions use PostgreSQL `statement_timestamp()`. The browser and
Windows clocks are advisory only. The waiter and cashier poll the read-only
server state for button behavior, while database triggers on `orders`,
`order_items`, `payments`, and `external_sales` remain authoritative for direct
RPC and offline replay traffic.

## Finalization and reporting

`public.restaurant_daily_sales_finalizations` has one row per HCM business
date. A second invocation returns the existing immutable result. If any
Restaurant receipt is timestamped at or after 21:45, finalization records
`data_integrity_failed`, leaves the receipt total and gross sales unfinalized,
and records only offending store IDs and counts.

`public.v_restaurant_sales_receipts` retains one row per POS payment or delivery
receipt, including its source timestamp and HCM hourly bucket. No receipt is
backdated, cancelled, excluded, or moved to the next date by finalization.

This workflow does not call MISA or any red-invoice API. It does not modify the
Photo 22:20 collector, Photo legal-entity Excel export, or Photo MISA-trigger
removal.

## Verification and rollback

Production deployment must use the pinned runner with an explicit
comma-separated Restaurant UUID list:

```bash
RESTAURANT_CUTOFF_STORE_IDS='<approved-restaurant-uuid>' \
CONFIRM_PRODUCTION_DEPLOY=DEPLOY_GLOBOS_PROD \
scripts/deploy_pos_production.sh --yes \
  --migration supabase/migrations/20260716190000_restaurant_daily_cutoff.sql \
  --test test/restaurant_daily_cutoff_contract_test.dart
```

The runner executes the preflight, schema migration, explicit activation, and
verification scripts. `scripts/rollback_restaurant_daily_cutoff.sql` removes
the four enforcement triggers, disables all policy rows, and unschedules the
22:20 job while retaining receipt and finalization evidence.
