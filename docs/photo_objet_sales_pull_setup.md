# Photo Objet Sales Pull Setup

POS is the sole Photo Objet Moers sales collector. The collector writes raw sales
to `public.photo_objet_sales_raw`, records attempts in
`public.photo_objet_sales_pull_runs`, and updates the dashboard aggregate in
`public.photo_objet_sales`. `public.v_photo_objet_daily_summary` is the POS read
surface.

New raw rows are queued idempotently into `public.meinvoice_jobs` by the existing
database trigger. The crawler does not call MISA directly. The raw ledger and
`source_hash` are the invoice source of truth; the daily aggregate is not.

## Runtime and schedule

The workflow uses Node 22, `npm ci`, the committed `scripts/package-lock.json`,
and the Chromium revision pinned by the exact Puppeteer package. Chromium system
dependencies are installed before the collector preflight.
The patched SheetJS `0.20.3` tarball is vendored at
`scripts/vendor/xlsx-0.20.3.tgz`, so spreadsheet parsing does not depend on
the npm registry or SheetJS CDN being available during a scheduled run.

The schedule is 09:00 through 22:30 Asia/Ho_Chi_Minh: hourly through 22:00,
followed by the final sales collection and invoice queueing run at 22:30.

```yaml
cron: '0 2 * * *'   # 09:00 HCM
# One fixed cron entry per hourly slot through 0 15 (22:00 HCM).
cron: '30 15 * * *'
```

Fixed cron entries make `github.event.schedule` an explicit slot input. Each
pull-run row stores a `FLARE_RUN_METADATA` JSON envelope in the existing nullable
`error_message` compatibility field with `source`, `slot_id`, `slot_date_hcm`,
`slot_time_hcm`, and any actual failure message nested as `error`.
This is backward-compatible with the shipped schema and keeps a delayed run tied
to its intended HCM slot instead of deriving identity from `started_at`. Manual,
audit, and bounded-backfill invocations use distinct source and slot prefixes.

Workflow concurrency does not cancel an in-progress run. A failed run writes a
GitHub step summary and creates or comments on the single open
`[Photo Objet sales] Collector failure` issue, preventing duplicate escalation
issues while keeping repeated failures visible.

## Required configuration

Repository secrets:

- `SUPABASE_URL` for the pinned POS project `ynriuoomotxuwhuxxmhj`
- `SUPABASE_SERVICE_KEY`
- `MOERS_BIENHOA_PASS`, `MOERS_DIAN_PASS`, `MOERS_LONGTHANH_PASS`
- `MOERS_THAODIEN_PASS`, `MOERS_QUANGTRUNG_PASS`, `MOERS_NOWZONE_PASS`
- `PHOTO_OBJET_BIENHOA_STORE_ID`, `PHOTO_OBJET_DIAN_STORE_ID`
- `PHOTO_OBJET_LONGTHANH_STORE_ID`, `PHOTO_OBJET_THAODIEN_STORE_ID`
- `PHOTO_OBJET_QUANGTRUNG_STORE_ID`, `PHOTO_OBJET_NOWZONE_STORE_ID`

The workflow contains the corresponding Moers usernames. Store IDs must resolve
to unique, active POS `public.restaurants` rows with the exact expected store
name and Photo Objet brand ID `77000000-0000-0000-0000-000000000001`.
`store_type` may be `direct` or `external`; any other ownership value fails
closed. This permits hierarchy-approved external operators without accepting a
mapping outside the Photo Objet contract.

Optional repository variables named `PHOTO_OBJET_<STORE>_ENABLED` can be set to
`false` before a mapped store closes. Empty values default to enabled. D7 has no
collector mapping and is not hardcoded; its historical rows remain untouched.
Accepted boolean values are `true/false`, `1/0`, `yes/no`, `y/n`, and `on/off`
(case-insensitive). Any other value fails preflight rather than disabling a store.

Current linked-project mapping:

- `PHOTO_OBJET_BIENHOA_STORE_ID` -> `77000000-0000-0000-0000-000000000102`
- `PHOTO_OBJET_DIAN_STORE_ID` -> `77000000-0000-0000-0000-000000000103`
- `PHOTO_OBJET_LONGTHANH_STORE_ID` -> `77000000-0000-0000-0000-000000000104`
- `PHOTO_OBJET_THAODIEN_STORE_ID` -> `77000000-0000-0000-0000-000000000105`
- `PHOTO_OBJET_QUANGTRUNG_STORE_ID` -> `77000000-0000-0000-0000-000000000106`
- `PHOTO_OBJET_NOWZONE_STORE_ID` -> `77000000-0000-0000-0000-000000000107`

## Preflight and failures

`node pull_moers_sales.js --preflight-only` validates all of these before any
browser launch:

- Node major version 22 and the Node WebSocket global
- required Supabase, Moers credential, and store mapping environment values
- an executable absolute `PUPPETEER_EXECUTABLE_PATH`
- the exact POS Supabase project URL
- unique, active, exact-name Photo Objet store mappings and ownership type
- availability of `photo_objet_sales_pull_runs`, `photo_objet_sales_raw`, and
  `photo_objet_sales`, including service-role read and constraint-safe insert
  permission probes used before launch

Startup/configuration errors emit `FLARE_FAILURE_CLASS=deterministic` and are
never retried. Network, timeout, and missing-run failures are transient. A store
pull receives at most one retry, and deterministic failures receive none. The
summary and deduplicated issue escalation run under `always()` and include npm
setup and Chromium outcomes even when no collector log could be created.

## Health audit

Run the missing schedule-slot audit with:

```bash
node pull_moers_sales.js --audit-missing-runs --audit-lookback-days 2
```

The lookback is bounded to 1-31 HCM calendar days. The audit checks every
completed 09:00-22:00 hourly slot and the 22:30 slot for every enabled store
using successful `photo_objet_sales_pull_runs` rows whose explicit metadata
contains the expected scheduled `slot_id`. `started_at` is not used as slot
identity. The scheduled workflow runs this audit after normal collection;
missing runs use the same failure summary and deduplicated escalation path.

## Bounded backfill

Backfill accepts at most seven inclusive dates and is dry-run by default:

```bash
node pull_moers_sales.js --backfill-from 2026-07-01 --backfill-to 2026-07-03
node pull_moers_sales.js --backfill-from 2026-07-01 --backfill-to 2026-07-03 --execute
```

The dry run performs preflight and prints the planned store-days without browser
or database writes. `--execute` reuses the normal parser, `source_hash` upsert,
raw insert trigger, and invoice idempotency semantics. Aggregate rows use
`pull_source = manual`.

## Data safety

The collector builds `source_hash` from store, date, device, time, amount, type,
row index, and raw row content. Already-seen rows update `last_seen_at`; only new
raw inserts trigger invoice queue creation. All rows use
`payment_method = CASH`; VNPAY/QR wallet data must not be mixed into this ledger.

An empty recognized table records a successful zero-sales run only when no
aggregate exists for that store-day, and it does not write aggregate rows.
Existing device totals are compared with every new snapshot. An empty snapshot,
missing device, or lower gross/transaction total is classified as a transient
partial response, and existing aggregates are preserved. Other stores and dates
continue independently.

## Verification

```bash
cd scripts
npm ci
npm test
cd ..
flutter test test/photo_objet_meinvoice_raw_contract_test.dart test/photo_ops_sales_aggregation_test.dart
dart analyze
git diff --check -- .github/workflows/photo_objet_sales.yml scripts/package.json scripts/package-lock.json scripts/pull_moers_sales.js scripts/tests/photo_objet_sales_health.test.js docs/photo_objet_sales_pull_setup.md test/photo_objet_meinvoice_raw_contract_test.dart
```

Scheduled workflows use the workflow definition on the default branch. No
schedule or escalation change takes effect until this revision is merged there.
