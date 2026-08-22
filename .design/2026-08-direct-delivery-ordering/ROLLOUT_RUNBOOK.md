# Direct delivery rollout runbook

Date: 2026-08-21
Scope: source-complete feature; production remains disabled

## Release invariants

- Do not mutate the frozen QR, cashier, legacy KDS, payment, print, report, or effective `process_payment` implementation.
- Apply `20260821130000_direct_delivery_ordering.sql` and then
  `20260821140000_direct_delivery_arrival_alerts.sql` only through the normal
  guarded deployment workflow.
- Do not enable a storefront until accounting approval, a real Google Maps check, and a controlled store pilot are recorded.
- Rollback is link removal plus `is_enabled=false`. Do not roll back the additive migration after orders exist.

## Required Edge secrets

Configure the `direct-order-public` function without committing values:

- `SUPABASE_URL`: project HTTPS URL.
- `SUPABASE_SECRET_KEYS`: JSON object containing a modern `sb_secret_...` project key.
- `DIRECT_ORDER_SUPABASE_SECRET_KEY_NAME`: the key name inside that JSON object.
- `DIRECT_ORDER_RATE_LIMIT_SECRET`: random secret of at least 32 characters.
- `DIRECT_ORDER_CLEANUP_SECRET`: independent random secret for the retention job.
- `ALLOWED_ORIGINS`: comma-separated exact POS web origins; no wildcard.
- `GOOGLE_MAPS_SERVER_API_KEY`: server-side Places Details, Places Autocomplete, and Geocoding key.
- `GOOGLE_MAPS_BROWSER_KEY`: browser Maps JavaScript key, restricted to the exact POS referrers.

Restrict each Google Maps key to only the APIs it needs and set quotas/alerts.
The browser key is returned only by the enabled storefront response and is
loaded dynamically; it is not embedded in `web/index.html`. Chat does not use
Google Cloud Translation or require a translation credential.

## Configuration order

1. Deploy the additive database migration with the normal production gate.
2. Deploy `direct-order-public`; confirm unknown origins, missing map
   configuration, and direct table access fail closed.
3. Open `/direct-delivery/settings` as an existing admin account.
4. Save slug, bank BIN/account/holder/label, map center, minimum order, and pause state with storefront disabled.
5. Have accounting approve the delivery-fee service-line treatment. Record that approval through the settings checkbox; the database prevents enablement without it.
6. Verify both address paths on real Android/iOS browsers: paste/search then map confirmation, and direct pin then reverse geocode. Verify location denial and quota failure remain fail closed.
7. Run the 20-order internal pilot and reconcile request, order, payment, inventory/MISA enqueue, direct financial snapshot, and ticket.
8. Rehearse arrival alerts with cashier viewer KO/VI/EN against different
   customer locales. Confirm one Realtime banner/chime, 10-second disconnected
   catch-up, reconnect/app-restart dedupe, storefront OFF silence, and unchanged
   simultaneous bank-transfer alert behavior.
9. Only after the exact pushed SHA passes required GitHub Actions, enable one storefront. Add its `/order/:slug?source=google_maps` URL to Google Business Profile last.

### Arrival-alert telemetry

Collect only `initialize/drain/display/chime`, success, batch count, and latency.
Never record request ID, customer/request locale, address, phone, chat, proof,
bank, or Grab data. Rehearsal failure keeps the storefront disabled. Exact copy,
cursor rules, frozen hashes, and stop conditions are in
`DIRECT_ORDER_ALERT_CONTRACT.md`.

## Staff routes

- Cashier/admin: `/cashier/direct-orders`
- Kitchen/admin: `/kitchen/direct-orders`
- Admin analytics: `/direct-delivery/analytics`
- Admin configuration: `/direct-delivery/settings`

No new employee identity is created. Initial pilot discovery is by direct URL/bookmark, preserving the frozen cashier and KDS screens.

## Retention job

Invoke `direct-order-public` with action `cleanup_expired_pii` and header
`x-direct-order-cleanup-secret` from the approved scheduler. The job selects at
most 100 proof uploads older than 24 hours that were never committed to a proof
message, plus terminal requests older than the store retention policy. It
validates and removes those proof objects before deleting exact
address/chat/session PII. Coarse location facts and financial audit remain.

## Emergency stop

1. Remove the Google Business Profile order link.
2. Set the affected storefront to disabled (or paused for a short operational interruption).
3. Keep cashier/kitchen direct routes available for already approved orders.
4. Reconcile outstanding requests before any further change.

Never compensate by editing an approved customer's quote or payment. A higher Grab cost is the store's cost; a lower cost remains the already accepted customer charge under the approved policy.
