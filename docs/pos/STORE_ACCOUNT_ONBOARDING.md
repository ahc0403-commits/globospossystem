# Store abbreviations and automatic accounts

Master admins set a brand and store abbreviation (2–6 uppercase letters/digits,
starting with a letter). Existing internal brand codes and store slugs remain
stable. New store slugs are generated from the registration request UUID.
A previously unset abbreviation may be configured without renaming issued IDs;
subsequent changes are locked while account requirements exist.

Before registration, Preview automatic IDs shows the server-generated templates.
Default store roles: SM, cashier, tablet, kitchen, tray, selected floors,
requester, receiver, print station and customer display. Photo Objet also receives
a store operator. Existing brand manager IDs are reused across the brand. A new
brand receives `<brand>_bm1`; login addresses use `@globos.world`.

The configured initial password is server-only `STORE_ONBOARDING_INITIAL_PASSWORD`.
No password enters the Flutter payload, database job, response, audit or log.
The same server setting applies to new manual fixed accounts. Existing passwords
are preserved, inactive identities are not reactivated, and first-login password
change remains required. Explicit password-rotation flows remain separate.

## Processing and access

`admin_create_store_onboarding_v1` atomically creates the physical restaurant,
legal relationship/history, approved requirements and durable job. Replaying the
same UUID/input returns the same store; a different input is rejected. Preview
and insertion use the same template function. New registrations preserve the
existing Office store-linking contract.

The job freezes the master-approved identity/role/scope manifest. Later workforce
edits cannot broaden a background job; reconciliation locks the store and its
requirements and rejects a changed manifest.

The Edge worker leases one job, creates missing Auth identities with server-only
ownership metadata, then reconciles profiles/access in one SQL transaction.
Unrelated Auth emails, mismatched roles, disabled profiles and disabled grants
are not adopted or reset. SQL derives roles and scope from approved requirements;
clients cannot submit Auth IDs, grants or roles. Only active masters can start or
retry a job, and only the service role can lease/finalize one.

A lease expires after 120 seconds. Auth creation has a 65-second work budget,
12-second per-request timeout, concurrency 2 and at most 50 identities. The Auth
admin API has no bulk creation method: N missing users require N Auth writes.
Database preparation and reconciliation are two bounded RPCs independent of N;
there is no per-account database lookup or refresh call. Additional master Auth,
status and catalog refresh calls are constant per operation. A minute cron job
continues interrupted work, up to three leases; partial jobs can be retried from
Edit store → Automatic account creation. Responses lost after store creation are
recovered through the persisted job. A lost Auth create response is recovered by
exact indexed email plus trusted app metadata, without rotating a password.

Public profile insertion preserves station assignment triggers, extended through
3F. Existing floor-display conversion remains intact. The existing procurement
statement trigger connects requester/SM/receiver, shared legal accounting and
native Office buyers. Policy 3 remains requester → Store Manager → buyer → PO.
Missing shared accounting or Office scope is displayed as Needs configuration;
account creation alone does not claim procurement readiness.

Brand-derived store grants retain `brand_inherited` and their originating brand
access ID, so the existing revocation sync can remove them. Direct store grants
remain separate.

Claims are refreshed in a set-based statement with explicit, legal-entity and
fallback scopes matching the existing accessible-scope contracts. Auth metadata
outside the affected claim keys is preserved.

## Verification and limits

- SQL fixture executes actual migrations twice, actual procurement connector,
  idempotency, exclusive leases, lost acknowledgments, shared brand manager,
  untrusted Auth rejection, first-password gate and 3F assignment checks.
- KDS predecessor contract tests execute the actual floor extension and verify
  3F allocation, stale selection, deduplication and rejection across floors.
- Flutter tests cover abbreviation validation, nested brand registration,
  EN/KO/VI narrow layouts, preview invalidation, duplicate-click protection,
  partial retry, lost store response and resume after page reload.
- Worker fixture: 50 Auth writes, peak concurrency 2, approximately 12.7 KB total
  mock request payload and 59 ms with an artificial 1 ms Auth delay. These are
  local mock measurements, not production latency or a throughput guarantee.
  SQL/Auth sizes are capped; production latency depends on Auth service response.
- Full release gate: `bash scripts/check_repo.sh` and exact-main successful
  `POS release contract`. Production evidence must be recorded separately.

## Production release

Use only `scripts/deploy_pos_production.sh`, on clean exact origin/main with the
required successful CI on that SHA. Release phases:

1. `--db-only --migration supabase/migrations/20261015150000_store_account_onboarding.sql`
2. `--onboarding-edge-only` with `STORE_ONBOARDING_SECRET_ENV_FILE` pointing to a
   dedicated operator-owned mode-0600 env file containing only the initial-password
   secret. Never commit it. This scoped mode deploys just the onboarding and
   fixed-account provisioning endpoints, preserving unrelated Edge functions.
3. `--web-only --mode prebuilt`, including operational login smoke.

Preflight verifies migration dependencies, abbreviation uniqueness, the Auth
email index and existing Vault cron secret. Structural verification runs before
migration commit and again through the external production gate. Runtime worker
readiness and actual account login checks are separate release evidence.
The existing CRON_SECRET Edge setting must match the existing Vault cron secret.

`rollback_store_account_onboarding.sql` is an emergency stop, preserving issued
stores/accounts/history. It stops the schedule and new onboarding RPCs, without
silently deleting or revoking employees. It is not an account-revocation tool.
