# PR account release, 2026-10-07

The purchasing requester now opens the actual PR workspace, with stable creation-date pagination, scoped status counts, persistent exact-command retries, owner draft/returned edits, audited cancellation, beverage category support and KO/EN/VI A4 PDFs. Receiving, explicit PO links and existing Office updated-date pagination retain their contracts.

## Release scope and gates

Prepared from clean origin/main 73b47d90e67b59567b64c9ed4bf421e7397fd3ba in a separate worktree. Unrelated changes in the user's original POS and Office checkouts are excluded. Office requires the small companion beverage category/localization change before requester traffic.

The new migration is `20261007095000_procurement_pr_account.sql`. Version `20261007010000` already belongs to the unrelated direct-order customer-context migration and must never be repaired or replaced for this feature.

The migration repeats the production predecessor hashes and permission/index/category prerequisites inside its apply transaction. The matching read-only preflight and verification files run through the canonical production migration gate. The rollback restores the exact preceding functions, constraint and index state, and refuses if any beverage PR exists, including cancelled records. After beverage traffic, roll forward; never delete audit history to enable rollback. Migration history changes remain a separate gated operation.

Required checks: repository contract, existing procurement/Office/combined-receiving SQL regressions, exact predecessor rollback/reapply and rollback refusal, PR keyset query measurements, requester widget and PDF acceptance tests. Both PR and exact merged main CI must pass before canonical deployment. Deploy only through `scripts/deploy_pos_production.sh` against the fixed POS Supabase and Vercel projects. Verify migration history, web provenance, existing-account login, requester list/detail/edit/retry/cancel behavior and Office compatibility after release. Do not create or reset Auth accounts.

This checked-in document describes release scope and required gates. Actual deployment SHA, timestamps and operational results are recorded separately after deployment; source completion alone is not production completion.
