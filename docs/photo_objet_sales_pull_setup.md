# Photo Objet Moers sales collection

## Authority and immutability

Moers Excel is the immutable source for Photo Objet sales. The collector writes
canonical rows to `public.photo_objet_sales_raw`, records execution attempts in
`public.photo_objet_sales_pull_runs`, and rebuilds the daily dashboard aggregate
in `public.photo_objet_sales`. It never deletes or rewrites a raw source row.

The crawler does not call MISA directly. MISA queueing and receipt automation
are separate dimensions: payment completion, collection success, invoice
dispatch, and receipt automation must not overwrite one another's result.
`payment_method = CASH`; VNPAY/QR wallet data must not be mixed into this source.

## Exact collection interval

The scheduled workflow runs at 10:00, 12:00, 14:00, 16:00, 18:00, 20:00,
and 23:00 HCM. Each run reads one half-open interval without overlap:

- 10:00 collects `09:00:00 <= sold_at < 10:00:00`.
- 12:00 through 20:00 collect the preceding two hours.
- 23:00 is the final run and collects `20:00:00 <= sold_at < 23:00:00`.
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

Every day has these seven slots per enabled active policy:

```text
10:00, 12:00, 14:00, 16:00, 18:00, 20:00, 23:00
```

Every slot becomes due 90 minutes after its semantic collection time. This
90-minute grace is longer than the observed GitHub scheduler delay and keeps a
late runner from being classified as missing while it is still within the
operating SLA. The final 23:00 slot becomes due at 00:30 HCM. Status is one of
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

## Health monitoring and alert delivery

`.github/workflows/photo_objet_sales_health.yml` runs ten minutes after each
90-minute deadline: 11:40, 13:40, 15:40, 17:40, 19:40, 21:40, and 00:40 HCM.
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

Required replay evidence:

```bash
bash test/photo_objet_expected_slot_ledger_test.sh
```

This validates replay, rollback, policy effective time, inactive exclusion,
10:00-23:00 slots, the 90-minute grace boundary, zero sales, retry/recovery,
backfill isolation, alert delivery-before-ACK, RLS, 60 stores/420 slots, and preservation
of the immutable raw ledger. Separate catalog fixtures cover an absent column,
a pre-existing column, a compatible pre-existing constraint, and incompatible
type or constraint fail-fast paths.
