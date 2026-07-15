# Legacy payment-proof URL cleanup runbook

This runbook is deliberately disabled for mutation in the current release. `scripts/inventory_legacy_payment_proofs.sql` is the only prepared tool and is aggregate-only/read-only. It must not print signed URLs, object names, local paths, JWTs, credentials, or proof payloads.

## Preconditions

- Security audit, Expand, compatible Flutter, terminal refresh, and authenticated object-path viewing are verified in production.
- Contract is not required, but no supported client may depend on `proof_photo_url` for new evidence.
- A separately reviewed cleanup implementation, immutable backup manifest, canary approval, batch limit, owner, and maintenance window exist.
- Cleanup uses service-role access only in the bounded operator process; user-facing verification uses an authorized JWT subject from the affected tenant.

## Canary and batch sequence

Use one proof from one store as the first canary, then a maximum of 25 objects per batch. For each row, without logging identifiers or URLs:

1. Read the old object and copy it to the new compatible `tax-entity/store/YYYY-MM-DD/payment.jpg` path.
2. Compare exact byte size and a SHA-256 digest between old and new objects.
3. In one bounded database transaction, set `payments.proof_object_path` to the verified new path. Keep `proof_photo_url` until every verification below passes.
4. Authenticate as an authorized user for that store and download through the normal Storage JWT/RLS path; compare size and SHA-256 again.
5. Remove the legacy signed-URL database value and verify the payment detail still opens the proof through the object path.
6. Delete the old object only after copy, hash, database-path, and authenticated-read verification all pass. Preserve the new object and payment/audit evidence.

Wait and review error/download/audit signals after the canary and after every batch. Increase neither concurrency nor batch size automatically.

## Stop and rollback rules

- Stop immediately on size/hash mismatch, missing source, cross-store denial for a valid actor, unexpected object-path shape, database update mismatch, or any proof that cannot be read after update.
- Before old-object deletion, roll back by restoring the previous database reference from the protected manifest and delete only the failed new copy.
- After old-object deletion, fix forward from the verified backup/source copy; never blank or delete the payment evidence row.
- Do not use project-wide JWT secret rotation. It would affect unrelated sessions and does not safely preserve evidence.
- No operation may delete a queue file, old object, or URL reference merely because parsing or upload failed.
