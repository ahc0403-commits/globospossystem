# POS cloud release execution

`scripts/deploy_pos_production.sh` remains the only production entrypoint.
`--supabase-backend mcp` uses the existing connected Supabase tool runtime;
it does not require a CLI personal token or copy credentials between runtimes.
The default CLI path remains available unchanged.

The cloud backend supports the existing `--db-only --migration FILE` and
`--web-only` phases with all applicable checks enabled. It rejects combined
unplanned Edge/secret releases and skip flags, apart from an explicit owner-approved
`--web-only --skip-login-smoke` waiver. An unchanged Edge source tree must be
compared with the verified deployed source; changing Edge code requires its
own supported release path and validation. The committed coordinated plan below
provides that path for the reviewed direct-order update. Neither a successful read nor an
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

## Coordinated attendance / order release (2026-10-29)

Use the sole entrypoint with `--supabase-backend mcp --cloud-release-plan
scripts/cloud_deployment/plans/20261029_attendance_orders.json
--skip-login-smoke --yes`. This scope is incompatible with the other release
modes. It still executes a fresh exact-main full recipe and production Auth,
locked SDK analysis/tests, Firebase names, existing Edge origin/retirement and
unauthorized dispatcher checks. All non-login skip flags remain rejected.

The committed plan binds exact paths and SHA256 values for purchasing adjustment,
order amendments and attendance recovery, in that order, then the exact
`direct-order-public` index/import map, followed by prebuilt web. Before the
first write, the adapter verifies that existing versions form an ordered prefix
with exact source bytes, dependency metadata and transport statement hashes. Only
that verified prefix is retained without reexecution; missing versions remain
pending. The current ACTIVE Edge source must equal the recorded predecessor. Each migration
retains the existing atomic/source-version/history/hash checks. Any failure stops
before subsequent stages. A concurrent Edge version/source change also stops
before replacement. The mutation transport accepts only exact prepared planned
SQL and the exact planned Edge payload. Existing `verify_jwt=false` is verified
before and after, never newly disabled. Other handlers and secret settings are
not redeployed or configured. The handler's environment input names must match
its predecessor; actual OPTIONS initialization/CORS and dispatcher checks remain
required. This is scoped readiness, not a claim to have inventoried every Edge
secret through an unavailable secrets API.

The remote deployed index is compared byte-for-byte by SHA256 after replacement.
The exact import-map upload bytes are bound to the request; if the remote tool
omits that file from the returned bundle, independent import-map readback is
explicitly unverified. The release receipt records this distinction. Remote
migration history retains both original source rows and Supabase transport rows.
The web remains PENDING until the official deployer completes build/deploy/HTTP.
A successful DB/Edge result alone is not a completed release.

Rollback readiness is the verified prior web deployment and the saved predecessor
Edge source. Both new migrations add functions/schema and retain old contracts;
do not drop amendment history or modify real attendance/orders to roll back UI.
An error after any write requires reading actual remote versions/source first,
then a reviewed forward fix or restoration of the previous web/Edge. Never retry
an uncertain mutation or blindly rerun a plan with an already-applied version.
No automatic destructive DB rollback is authorized.

The attached source archive SHA256 is
`829dccf3c1ca8dfeae37f29818941ebb5425584c13fd0f6ec2e955b3e8116ce4`;
its implementation patch SHA256 is
`f9af4176d9ccedb222178c33114a8458e31403e7a1452f0df64f7c6136c49ebd`.
Historical attached test results are provenance, not final-candidate PASS evidence.
Photo store manager PIN setup remains a separate settings-screen action. No PIN
is generated, exposed, reset or bypassed; inactive stores are not reactivated.
Production attendance/order writes are not test fixtures. Assigned-account login
and actual manual attendance submission remain unverified under the owner waiver.

## Recovery after an interrupted tool approval

The first purchasing migration was durably applied in release source
`5e6b7452ef348dfd466e9570a918f3ac70ea28db`; its original version and transport
`20261029112749` are retained. The later order migration request expired before
the tool error returned. No order, attendance, Edge or web application was
confirmed by that invocation. Inspect actual current history/source before
another request; a timeout is neither success nor proof of user denial.

The plan now freezes `migrationSourceSha` to that original SQL intent. Every SQL
input and companion must match that ancestor commit. This preserves the exact
original query, including source provenance metadata, even when the recovery
adapter has a newer verified release SHA. The order query is 37,156 bytes with
SHA256 `2b60c9139e8569e9e695683eec63e4966f531a73ef2be8f278b2b542c66197c6`.
The release SHA and original migration-intent SHA remain distinct in evidence.
Changed SQL or dependencies require a new reviewed plan; an old approval cannot
be repurposed. Reused original/transport history must match exact SQL hashes,
metadata, names, versions and statement counts. A missing/duplicated/tampered
row or an applied nonprefix version stops before any new mutation. Reuse is
reported as `ALREADY_APPLIED_VERIFIED_NOT_REEXECUTED`, never a newly applied PASS.

Unclaimed requests still expire. Once a mutation is claimed by the connected
tool, its official owner remains alive until the actual tool result, including
while user approval is pending. The bridge records `awaiting-result` after the
queue deadline; it never approves, resubmits or replaces the tool request.
Explicit user denial or tool error stops the release. A later attempt requires
reconciliation and the appropriate approval, not an automatic retry. Safe error
classification distinguishes explicit user/automatic-review denial and approval
expiry when those are actually reported; it stores no raw private error text.
A fresh official invocation still runs a new exact-main gate. The preserved
prior receipt is not accepted as a substitute. Candidate and exact-main checks
are repeated for a changed recovery adapter before production execution.
