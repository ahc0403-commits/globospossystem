# Customer progress, confirmed requests and mobile payment amount

Release scope combines the previously implemented customer improvements and the
mobile quote/underpayment chat card from the owner's screenshot. It starts from
clean main 4d581aa5 and preserves the newer pickup, money reconciliation and
translation contracts. Original checkout work is not staged or reset.

Customers see cooking, packed, handed to driver and completed progress based on
persisted events. Delivery links open and copy. Diner count starts at one and is
independent of the explicit no-disposable-utensils choice; food containers remain
included. Existing kitchen/packing/dispatch/completion actions drive progress.

Each order/menu request has a custom cashier reply and optional customer
acceptance of the exact reply/version. General chat does not resolve it. Both UI
and SQL block quotes while requests remain unresolved. Confirmed reviewed
Vietnamese wording is included in new receipt snapshots; later confirmations
create separate addenda without changing issued receipts or payments.

Final amount and any outstanding deposit appear in a pinned summary and chat
cards. The payment QR uses the server-calculated remaining amount. Submitted
proof switches to confirmation pending and hides the QR.

## Release order

1. Independent source review and local check_repo are preflight only. Require
   the POS release contract GitHub Action on the exact pushed SHA.
2. Merge and use clean, freshly fetched exact origin/main. Require its Action.
3. Use deploy_pos_production.sh to update Edge before applying progress migration
   20261010030000, with Vercel skipped. Apply requirements migration
   20261010040000 through its DB-only gate. Release web only after both exist.
4. Verify exact production deployment SHA, Edge metadata, both migration history
   entries, scoped status/list reads and unchanged legacy/payment functions.

The native print station uses claim_print_jobs_v2. Old stations can still claim
normal compatible jobs but leave request-update and utensil-optout jobs pending.
The Windows package must be installed on physical stations before they can print
those new jobs. Package build/backend tests do not prove on-site installation or
physical paper output.

## Evidence available before production

- Integrated SQL: quote gate, ownership/version boundaries, confirmation retries
  and simultaneous decisions, immutable originals, routing and PII purge.
- Real old/new queue functions: memos, utensil optout, paperless receipt versus
  preparation routing and reprint mode preservation.
- 1/10/50 requests: one snapshot read, zero per-row detail calls. Memo destinations
  1/10/50: one related-table scan. Printer destinations use two batched reads.
- PostgREST v8/v9: HTTP 200, session activity renewed, no payment/order/inventory
  writes. Production candidate DDL and scoped reads passed inside ROLLBACK.
- Flutter regressions retain native pickup code, refund access, old QR/payment
  rules and custom-reply retry drafts.

Production status and exact Action/deployment URLs are recorded separately after
release; this source document does not claim deployment or physical print success.
