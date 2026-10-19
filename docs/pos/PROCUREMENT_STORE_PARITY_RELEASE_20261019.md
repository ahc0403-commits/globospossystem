# Procurement store policy parity — 2026-10-19

Release scope: database configuration only. JeonGabok Binh Thanh has no procurement
policy, while the two BunsikClub stores have an enabled policy-3 purchasing flow.
The migration aligns every active store with an active ordering-account requirement
to BunsikClub BT, including all eight policy settings. Accounts, native role/receiver
assignments, access scopes, stock and historical documents stay unchanged.

The original workspace is based on September 17 and contains later work from many
tasks. Release preparation starts from current `origin/main` and includes only the
parity migration, its verification/rollback and the isolated regression harness.
Do not deploy the old workspace's application snapshot or supersede later fixes.
The existing production frontend keeps its PR-account/receiving-account distinction;
the same roles across the brands must have equal policy/capability behavior.

Local validation: the full procurement SQL harness, including historical approval,
receiving, retry identity, role scope, bounded reads, shortage concurrency, migration
reapplication and pre-traffic rollback. The rollback restores the previous settings
from immutable audit evidence, checks policy version/state and refuses after new
PR/PO activity. It is idempotent and does not rewrite historical documents.

Apply only through `scripts/deploy_pos_production.sh --db-only --migration
supabase/migrations/20261019081922_procurement_all_store_parity.sql` on clean,
exact-main source after the required CI check succeeds for that SHA. Do not use
`supabase db push` or direct production SQL mutation. Run the companion verification,
read actual scoped catalog/workspace responses, and perform the existing fixed-account
login smoke. A DB-only release is separate from a frontend deployment.

If post-apply verification requires rollback before new purchasing traffic, the
reviewed restore file is
`scripts/rollback/20261019100141_restore_procurement_all_store_parity.sql`.
Pass that explicit file to the same official DB-only deployment script; never run
it through an unguarded SQL path. Apply/check failures inside the migration transaction
leave the preceding configuration intact.

The last known production frontend before this release is deployment
`dpl_29VfEgMDTCShDkz85x4yfLpFyHwu`, source SHA
`1420cc1285ce2a233d93a9c254fc183bf1ce57b4`. DB-only does not replace it.
Record actual release SHA, CI result, migration-history evidence and operational
verification separately after execution; preparation is not deployment proof.
