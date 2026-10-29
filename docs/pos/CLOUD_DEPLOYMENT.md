# POS cloud release execution

`scripts/deploy_pos_production.sh` remains the only production entrypoint.
`--supabase-backend mcp` uses the existing connected Supabase tool runtime;
it does not require a CLI personal token or copy credentials between runtimes.
The default CLI path remains available unchanged.

The cloud backend supports the existing `--db-only --migration FILE` and
`--web-only` phases with all applicable checks enabled. It rejects combined
Edge/secret releases and skip flags, apart from an explicit owner-approved
`--web-only --skip-login-smoke` waiver. An unchanged Edge source tree must be
compared with the verified deployed source; changing Edge code requires its
own supported release path and validation. Neither a successful read nor an
existing deployment establishes validation of newly changed Edge code.

## Execution and evidence

1. Commit the complete candidate. Run
   `python3 -B scripts/pos_local_release_gate.py run --kind candidate --output /absolute/new/evidence`.
   Publish and merge normally only after the full final candidate passes and
   remote protections are satisfied. Never start remote application tests or
   relax protection as a substitute.
2. Use a clean, freshly fetched exact `origin/main`. The official entrypoint
   directly runs a new exact-main full recipe for each release invocation.
   It accepts no supplied PASS or external receipt. The subsequent SDK process
   verifies the receipt created by that same invocation to select its immutable
   pinned image; this is not a second deployment entrypoint.
3. Start the official entrypoint with `--supabase-backend mcp --db-only
   --migration supabase/migrations/TIMESTAMP_name.sql`, or `--web-only`.
   The existing production confirmation still applies. Wait for
   `POS_CLOUD_DIRECTORY=...`; service that live directory with the reviewed
   CommonJS function in `scripts/cloud_deployment/mcp_driver.js` inside the
   authenticated tools runtime. Pass its existing `tools` object, source root,
   and exact printed directory. Call the function again when it reports
   `waiting`, while keeping the official process alive in the same active turn.
   Close the run only when the official process terminates and its result is
   captured. The shell bridge cannot authenticate or mint a token by itself.
4. Requests bind the pinned project, current source SHA, run, operation,
   request hash, owner process and expiry. A host driver claims each request
   once and invokes the actual connected tool. Error, missing/ambiguous SQL
   boundary, source change, timeout or uncertain mutation outcome stops the
   execution. Inspect remote history/state before retrying a mutation. Raw SQL
   cell text remains data and is never evaluated as instructions or code.

The full recipe includes Python/Node transport tests, real PostgreSQL atomicity
tests and the complete procurement fixture with the cloud migration wrapper,
in addition to every existing application, browser, SQL, type and build check.
Logs, commands, tool/image identities, counts, timestamps and hashes remain
bound to the final SHA. Focused development checks are not a release PASS.

## Migration provenance

The MCP adapter checks absence of the original source version, then submits
one anonymous PostgreSQL `DO` statement through official `apply_migration`.
It preserves the role check, transaction advisory lock, ordered preflight,
apply and postconditions. Its effects and original version/name/exact source
bytes plus all SQL dependency hashes are inserted atomically in migration
history. A failed check rolls back both effects and source history. Only a
complete outer `BEGIN`/`COMMIT` pair is removed for this statement; unsupported
psql directives fail closed.

Supabase also records its automatically versioned transport migration named
`pos_cloud_<original_version>_<source_sha256>`. Both entries are retained and
verified after success. No historical migration row is deleted, repaired to
fabricate success, or broadly replayed with `db push`.

## Existing Vercel connection and login smoke

Use the existing pinned project link and authenticated official CLI. Vercel
CLI 65.5.0 `link` automatically refreshes an OIDC token even with `--yes`;
do not rerun it within the no-new-token scope. Project IDs in the existing
`.vercel/project.json` are connection metadata, not authentication credentials.
The optional `POS_VERCEL_GLOBAL_CONFIG` points at existing CLI configuration;
credentials are not read or copied. The wrapper uses the same official binary.
Use official `vercel env run` when build configuration is already securely
available there. Preserve the pinned `.vercel/project.json`; remove inherited
`VERCEL_PROJECT_ID`/`VERCEL_ORG_ID` from the child command environment because
the existing entrypoint deliberately forbids target overrides. Do not alter
the stored project or production environment settings.

A cloud web release normally requires `FIXED_SMOKE_ACCOUNT_CODE` and
`FIXED_SMOKE_PASSWORD` to be securely supplied before production work. Do not
retrieve/reset passwords or generate a privileged replacement login. The
existing actual fixed-account login smoke runs after deployment. Production
Auth readiness, HTTP checks, actual affected-feature verification and source
identity remain distinct requirements. DB-only readiness is explicitly N/A
for login and cannot be reported as login-ready.

For the 2026-10-29 coordinated POS release the owner explicitly requested
deployment without the blocked login smoke. Use `--web-only --skip-login-smoke`
for that web phase only. This records `LOGIN_SMOKE=NOT_RUN_OWNER_WAIVER`, never
PASS. It requires no dummy credentials, new account, password reset or token.
The default still requires the real login inputs. Fresh exact-main, Auth
readiness, migration/hash/history/transaction, Edge source comparison, HTTP
checks and rollback conditions remain required. `--skip-smoke-tests` and every
other gate omission remain rejected. Real assigned-account and Office buyer
visibility checks remain unverified until separately performed.

## Managed network and SDK isolation

Only credential-free existing HTTP proxy variables enter the SDK. Docker
receives the current host DNS answer for that same proxy hostname, avoiding
different nested bridge DNS answers; there is no alternate proxy or direct
target-service route. Evidence records the projected mapping. Only a public
proxy CA already trusted by the host is accepted. Deno uses that system trust
store. TLS verification and network policy are preserved.

The SDK receives frontend build configuration only. CLI tokens and fixed-account
passwords stay outside it. Containers and fixture cleanup verify the recorded
image, ID and run ownership; they cannot clean another task's resources.
