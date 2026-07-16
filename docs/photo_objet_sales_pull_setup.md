# Photo Objet Moers sales collection

## Authority and immutability

Moers Excel is the immutable source for Photo Objet sales. The collector writes
canonical rows to `public.photo_objet_sales_raw`, records execution attempts in
`public.photo_objet_sales_pull_runs`, and rebuilds the daily dashboard aggregate
in `public.photo_objet_sales`. It never deletes or rewrites a raw source row.

The crawler does not call MISA. From the 22:20 single-slot cutover, new Photo
source rows also do not create MISA jobs; invoice issuance belongs to the
separate Windows portal automation. `payment_method = CASH`; VNPAY/QR wallet
data must not be mixed into this source.

## Exact collection interval

The scheduled workflow runs once at 22:20 HCM. It reads the complete half-open
business-day interval `00:00:00 <= sold_at < 22:20:00` for every configured
Photo store. Every source transaction remains a separate immutable row, so the
result can be listed by receipt and HCM sale time rather than only as a daily
total.

- A sale at 22:19:59 is included; a sale at exactly 22:20:00 is not.
- A delayed GitHub start retains the intended `slot_date_hcm` and
  `slot_time_hcm`; wall-clock `started_at` is not slot identity.
- Excel may contain the entire day, but only rows in the exact interval enter
  the immutable ledger. Previously stored source rows must still be present.

The collection workflow is
`.github/workflows/photo_objet_sales_collect.yml`. It never calls the missing
slot audit. Six successful configured stores therefore remain a successful
collection even if health monitoring or alert delivery has a separate error.
The collector probes the health tables only as best-effort observability. A
missing or unavailable health ledger emits `AUDIT_INFRA_FAILED` for the health
dimension but does not block the immutable sales pull.

## Authoritative expected-slot ledger

Migration `20260713120000_photo_objet_expected_slot_ledger.sql` adds:

- `photo_objet_monitoring_policies`: effective-dated monitoring configuration.
- `photo_objet_expected_slots`: one unique store/date/time scheduler identity.

Policy rows are not inferred from brand membership. Operations must configure
only the approved active collector mappings with an explicit `effective_from`.
This prevents D7, inactive stores, deleted stores, and environment-disabled
stores from silently entering monitoring. Historical time before
`effective_from` is never audited; there is no hardcoded rollout date or gap
count in JavaScript or SQL.

The database job `photo-objet-materialize-expected-slots` runs at 00:05 HCM and
calls `photo_objet_ensure_expected_slots` as the database owner. The service
role cannot insert, update, or delete policies or expected slots directly,
cannot read or mutate the rollback state table, and cannot execute the
materializer. Thus a collector outage cannot erase the
expected workload. Migration rollout must insert the approved policies and
materialize the first date in the same fail-fast transaction.

Migration `20260716160000_photo_objet_single_slot_2220.sql` effective-dates the
new schedule without rewriting the historical v1/v2 policies or their slots.
From its cutover date, every enabled active policy has one slot:

```text
22:20
```

The slot becomes due 90 minutes after its semantic collection time, at 23:50
HCM. This grace is longer than the observed GitHub scheduler delay and keeps a
late runner from being classified as missing while it is still within the
operating SLA. Status is one of
`expected`, `running`, `collected`, `collected_zero`, `missing`, `failed`, or
`recovered`. A later exact slot cannot satisfy an earlier one. Manual and
backfill runs cannot satisfy scheduled history.

Zero rows in the current interval is `collected_zero`, even when prior daily
intervals already have sales. The pull-run ledger stores `interval_rows`
separately from the daily aggregate device count, so health reconciliation
keeps this classification even if the completion RPC was temporarily
unavailable. A success after `missing` or `failed` is
`recovered`. Retries create separate pull-run attempts while the expected slot
remains unique.

## RLS and Office scope

Authenticated readers see only super-admin or
`user_accessible_stores(auth.uid())` scope. Anonymous access and authenticated
writes are denied. Service-role writes are allowed only through validating
RPCs. The Office read view joins
`v_office_eligible_stores.store_id`, so external legal entities are excluded
even though external Photo operators may be valid POS collectors.

## Legal-entity Excel download

The administrator web page `/photo-ops` is the Windows automation download
point. In the Sales section, **Download legal-entity Excel** creates one file
for all accessible, enabled 22:20 Photo collectors that share the same
`tax_entity_id`:

```text
photo_sales_YYYYMMDD.xlsx
```

The workbook contains `Sales` receipt-level rows ordered by HCM sale time,
`Hourly Summary`, and `Summary`. It refuses to combine stores from different
legal entities. No MISA job or red-invoice API call is created by collection or
export. Excel remains unavailable until every included store has a successful
scheduled 22:20 pull run, preventing Windows automation from downloading a
partial legal-entity file. The Windows task should retry the same button until
the file is available.

## Health monitoring and alert delivery

`.github/workflows/photo_objet_sales_health.yml` runs at 00:40 HCM, after the
22:20 collection's 90-minute deadline.
It needs only the POS Supabase URL and service key; it does not install Chromium
and receives no Moers credentials.

The monitor uses typed `run_source`, `slot_date_hcm`, and `slot_time_hcm`
columns. It never parses `error_message`. Health refresh reconciles exact
scheduled successes, marks due gaps, and lists unacknowledged failures. Alert
delivery follows this order:

```text
detect -> create or update exact store/slot/failure issue -> ACK in database
```

An API failure before issue delivery leaves the alert unacknowledged, so the
next health run retries it. The unique alert marker is
`store_id/slot_date_hcm/slot_time_hcm/failure_class`.

Alert acknowledgement suppresses duplicate delivery only. It never changes
the health result: an acknowledged missing or failed slot keeps every health
run red until an exact scheduled success recovers it, even after the normal
healthy-history lookback window. The monitor also compares
every enabled policy with its complete materialized slot set. One missing
policy-day or inactive enabled policy is `AUDIT_INFRA_FAILED`, even when all
other stores are healthy.

## Independent failure dimensions

Operational evidence preserves separate results for:

- collection execution: `COLLECTION_FAILED`
- data completeness: `DATA_INCOMPLETE`
- scheduler reliability: `SLOT_MISSING`
- release SHA drift: `RELEASE_SHA_DRIFT`
- audit infrastructure: `AUDIT_INFRA_FAILED`
- receipt automation: `RECEIPT_AUTOMATION_FAILED`

A health or release failure cannot rewrite a successful collection result.
Receipt automation cannot rewrite payment or collection success.

## Backfill boundary

`.github/workflows/photo_objet_sales_backfill.yml` is manual only. It is
dry-run by default and accepts at most seven inclusive dates. Execution requires the
protected `production-backfill` environment and the exact confirmation
`EXECUTE_IMMUTABLE_BACKFILL`. Backfill may add missing immutable source rows and
recompute daily completeness, but its `run_source = backfill` never rewrites
scheduler history.

## Main release proof

`.github/workflows/photo_objet_sales_contract.yml` runs the complete frozen
validation suite for every `main` SHA. Only after that exact main push run
completes successfully does `.github/workflows/photo_objet_release_proof.yml`
start. The release proof has no manual dispatch path. Operational retries use
GitHub's **Re-run jobs** action on the original main validation run. It records
this state chain:

```text
CODE_VALIDATED
-> MERGED_TO_MAIN
-> PRODUCTION_DEPLOYED
-> MAIN_AUDIT_PASS
-> PRODUCTION_OBSERVED
```

The gate rejects absent, failed, PR-only, or stale-SHA validation evidence. Before
the first repository checkout, it reads the current `main` ref through the GitHub
API and requires an exact match with the successful validation event SHA. It then
requires the validated SHA, checked-out SHA, and fetched `origin/main` to remain
exact, confirms the approved SHA is an ancestor of main, polls the Vercel
production alias until its metadata reports that exact main SHA and `READY`, runs
the read-only slot audit, and requires HTTP 200 from
`https://globospossystem.vercel.app`.
PR checks and Preview deployments are never operational PASS evidence.

The artifact `release-proof-evidence.json` contains the main, validated, and
Vercel-confirmed deployment SHA, validation run identity, deployment state,
audit result, latest due slot, HTTP observation, and observation time. All
three SHA fields must be identical.

## Fail-fast migration rollout

Do not run this migration through a multi-statement client that can continue
after an error. The secure POS production environment must contain the six
approved store IDs and one explicit effective timestamp:

```bash
PHOTO_OBJET_MONITORING_EFFECTIVE_FROM
PHOTO_OBJET_BIENHOA_STORE_ID
PHOTO_OBJET_DIAN_STORE_ID
PHOTO_OBJET_LONGTHANH_STORE_ID
PHOTO_OBJET_THAODIEN_STORE_ID
PHOTO_OBJET_QUANGTRUNG_STORE_ID
PHOTO_OBJET_NOWZONE_STORE_ID
```

Use the pinned deployment path with
`--migration supabase/migrations/20260713120000_photo_objet_expected_slot_ledger.sql`.
It runs preflight, then executes
`scripts/apply_photo_objet_expected_slot_ledger.sql` with
`ON_ERROR_STOP=1 --single-transaction`. That wrapper applies the schema,
inserts only those six explicit policies, and materializes the first monitored
date atomically. Store IDs and credentials are never printed. Verification
then fails closed on a missing policy, inactive store, broad service-role
write privilege, or incomplete first-day materialization. Rollback is provided by
`scripts/rollback_photo_objet_expected_slot_ledger.sql`; it removes only the
new monitoring objects and never changes `photo_objet_sales_raw`,
`photo_objet_sales`, MISA jobs, payments, or receipts. If `interval_rows`
existed before the migration, rollback restores its original type, nullability,
default, comment, and named constraint definition exactly. If the migration
created the column, rollback removes it completely.

Apply the one-slot cutover with the pinned deployment path:

```bash
scripts/deploy_pos_production.sh \
  --migration supabase/migrations/20260716160000_photo_objet_single_slot_2220.sql
```

The cutover defaults to the migration execution timestamp, so completed legacy
slots remain historical while only unattempted future v2 slots are replaced.
An operator may pin an exact instant with
`app.photo_objet_single_slot_cutover_at` (or an HCM midnight with the legacy
test setting `app.photo_objet_single_slot_cutover_date`). Its preflight refuses
to replace future v2 slots that have already started, verification requires
exactly one 22:20 slot per policy, and
`scripts/rollback_photo_objet_single_slot_2220.sql` refuses to discard an
attempted v3 slot.

Required replay evidence for the foundational ledger and both effective-dated
schedule transitions:

```bash
bash test/photo_objet_expected_slot_ledger_test.sh
```

This validates replay, rollback, policy effective time, inactive exclusion,
historical 10:00-22:30 slots, the current single 22:20 slot, the 90-minute grace
boundary, zero sales, retry/recovery, backfill isolation,
alert delivery-before-ACK, RLS, 60 stores/60 current slots, and preservation
of the immutable raw ledger. Separate catalog fixtures cover an absent column,
a pre-existing column, a compatible pre-existing constraint, and incompatible
type or constraint fail-fast paths.
