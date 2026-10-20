# Restaurant finalization repair

Two forward migrations decouple reporting from optional cutoff-policy rows and repair only the empty-scope finalized results dated 2026-10-05 through 2026-10-18. They do not alter order cutoff settings, workforce/login mappings, actual payments or Photo collection.

The source includes completed revenue payments (using amount_portion for split payments) and completed external sales at direct Restaurant stores. Photo Objet, external stores, non-revenue payments and incomplete orders are excluded. Existing valid snapshots remain immutable. No eligible stores raises an error; genuine zero-sales days remain valid when eligible stores exist. The 21:45 HCM integrity boundary and 22:20 finalization gate are retained.

The recovery migration locks the finalization table and records original/corrected row images in an append-only audit table. Only finalized rows with store_count=0, receipt_count=0 and gross_sales=0 are touched. Trigger suspension, updates, audit inserts and trigger restoration are atomic. Repeating the SQL does not duplicate corrections.

Read-only production preview on 2026-10-19 found 14 affected days, 224,367,789.93 VND of source sales, and 12 days with post-cutoff receipts. Only 2 days qualify for finalized amounts (35,781,436.17 VND total). Other days become data_integrity_failed with no applied amount; a separate business decision is needed to resolve those source exceptions.

Validation:

```sh
bash scripts/test_restaurant_finalizations.sh
```

This creates and destroys a disposable PostgreSQL 17 Docker container, applies the exact migrations, and checks scope, portions, cutoff boundaries, real zero, zero-scope rejection, idempotence, privileges, audited recovery and trigger/audit immutability. A 10,006-payment local sample returns 14 aggregate days (2,126 bytes) with a 20-call mean of approximately 11ms; production policy/network/concurrency costs are unmeasured. Production mutations have not been performed.

Release both files in order with scripts/deploy_pos_production.sh --db-only --migration <file>, after explicit approval and clean exact-origin/main source and successful required CI checks. Then release the linked Office exception/finance SQL, pos-bridge and web changes. Verify the actual production snapshot statuses and audit records after deployment. Do not turn data-integrity failures into sales or change cutoff policy merely to make the dashboard nonzero.
