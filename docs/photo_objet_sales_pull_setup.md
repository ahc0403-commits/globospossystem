# Photo Objet Sales Pull Setup

This repository now includes the Photo Objet sales pull workflow and parser:

- `.github/workflows/photo_objet_sales.yml`
- `scripts/package.json`
- `scripts/pull_moers_sales.js`

The pull job reads sales from `moersinc.com`, stores raw rows first, and then
updates the dashboard aggregate:

- `public.photo_objet_sales_raw`
- `public.photo_objet_sales_pull_runs`
- `public.photo_objet_sales`
- `public.v_photo_objet_daily_summary`

New raw rows are queued into `public.meinvoice_jobs` as Photo Objet cash-register
invoice jobs. The crawler does not call MISA directly.

## Current schedule

The GitHub Actions workflow runs every 10 minutes:

```yaml
cron: '*/10 * * * *'
```

D7 is disabled by default because its Excel download path is expected to change.
Enable it only after the Korean-side Moers account behavior is corrected:

```bash
PHOTO_OBJET_D7_ENABLED=true
```

## Required GitHub Actions secrets

Set these in GitHub repository settings:

- `SUPABASE_URL`
- `SUPABASE_SERVICE_KEY`
- `MOERS_D7_PASS`
- `MOERS_BIENHOA_PASS`
- `MOERS_DIAN_PASS`
- `MOERS_LONGTHANH_PASS`
- `MOERS_THAODIEN_PASS`
- `MOERS_QUANGTRUNG_PASS`
- `MOERS_NOWZONE_PASS`

## Required store id secrets

Because the POS project does not currently expose a safe exact-name mapping
for the 7 Photo Objet stores, the workflow uses explicit store id secrets:

- `PHOTO_OBJET_D7_STORE_ID`
- `PHOTO_OBJET_BIENHOA_STORE_ID`
- `PHOTO_OBJET_DIAN_STORE_ID`
- `PHOTO_OBJET_LONGTHANH_STORE_ID`
- `PHOTO_OBJET_THAODIEN_STORE_ID`
- `PHOTO_OBJET_QUANGTRUNG_STORE_ID`
- `PHOTO_OBJET_NOWZONE_STORE_ID`

Each value must be the POS `public.restaurants.id` that should receive the
upserted Photo Objet sales rows.

Current linked-project mapping:

- `PHOTO_OBJET_D7_STORE_ID` → `77000000-0000-0000-0000-000000000101`
- `PHOTO_OBJET_BIENHOA_STORE_ID` → `77000000-0000-0000-0000-000000000102`
- `PHOTO_OBJET_DIAN_STORE_ID` → `77000000-0000-0000-0000-000000000103`
- `PHOTO_OBJET_LONGTHANH_STORE_ID` → `77000000-0000-0000-0000-000000000104`
- `PHOTO_OBJET_THAODIEN_STORE_ID` → `77000000-0000-0000-0000-000000000105`
- `PHOTO_OBJET_QUANGTRUNG_STORE_ID` → `77000000-0000-0000-0000-000000000106`
- `PHOTO_OBJET_NOWZONE_STORE_ID` → `77000000-0000-0000-0000-000000000107`

## Verified selectors

Based on the validated office-side implementation:

- Login URL: `http://moersinc.com/`
- Username selector: `#id`
- Password selector: `#pw`
- Daily sales URL: `http://moersinc.com/day.php`
- Date input selector: `#selDate`

The script supports both:

- Excel download path
- HTML table scrape fallback when a store account does not show a download button

## Current linked-environment note

As of 2026-04-17, the linked POS database does not yet contain the 7 Photo
Objet restaurants as exact-name rows. This setup now seeds a dedicated
`PHOTO OBJET` brand plus the 7 store anchors with deterministic ids, so the
workflow can avoid fragile name matching.

## Raw ledger behavior

The collector builds `source_hash` from store, date, device, time, amount, type,
row index, and raw row content. This makes the 10-minute pull idempotent:

- already-seen rows update `last_seen_at`
- newly-seen rows insert into `photo_objet_sales_raw`
- only newly inserted raw rows trigger meInvoice queue creation
- all Photo Objet rows are treated as `payment_method = CASH`
- VNPAY/QR wallet data must not be mixed into this ledger

The existing `photo_objet_sales` table remains a dashboard/day-machine
aggregate. It is not the tax-reporting source of truth.

## Current execution status

As of 2026-04-17:

- workflow file created
- script created
- linked DB `photo_objet_sales` / `v_photo_objet_daily_summary` created
- linked DB `PHOTO OBJET` brand + 7 stores seeded
- GitHub repository secrets registered:
  - `SUPABASE_URL`
  - all `MOERS_*_PASS`
  - all `PHOTO_OBJET_*_STORE_ID`

Remaining manual blocker:

- `SUPABASE_SERVICE_KEY` is still required before the workflow can be run
  successfully in GitHub Actions.
