# POS local verification contract

This candidate migrates execution, not the scope of verification. GitHub stores
and reviews source. No runner, runner registration token, paid CI, production
credential, production business fixture or Office modification is required.

## Candidate and exact-main runs

Commit the candidate locally, then run from its clean checkout:

```bash
python3 -B scripts/pos_local_release_gate.py run \
  --kind candidate --output /absolute/new/private/candidate-evidence
python3 -B scripts/pos_local_release_gate.py verify \
  --kind candidate --evidence /absolute/new/private/candidate-evidence
```

An output directory must be new and outside the source checkout. Keep the full
directory together. `receipt.json` records source SHA/tree/all tracked input
hashes, environment/tool/package versions, the local image ID, recipe/runner
hashes, UTC start/end times, real process exit codes, counts and log/artifact
hashes. Counts distinguish visible Flutter tests, Deno/Node tests, Python assertions,
completed repository stages and SQL commands. SQL assertions and performance measurements
remain in the complete logs; a command count is not an SQL assertion count.

The official `scripts/deploy_pos_production.sh` preflight always executes a new
`run --kind exact-main` before production mutation. It requires a clean checkout,
fresh canonical `origin/main == HEAD` before and after validation, and directly
calls the committed verifier. It does not accept a receipt, alternate recipe,
resume flag or PASS environment variable. Existing production flags cannot
skip this recipe. `--dry-run` prints the path and explicitly reports NOT RUN.

`verify` checks integrity and completeness for review. Receipts are not signed;
an operator who can replace every file can forge a self-consistent bundle.
Therefore an independently supplied receipt cannot authorize production or
replace a GitHub security principal. The trusted local execution is the
deployer's fresh process invocation, tied to its reviewed exact-main source.

## Preserved checks

The machine-readable recipe is `scripts/local_verification/recipe.json`:

1. Local evidence/process/fixture-ownership regression tests, followed by the
   independent-result metadata verifier security suite. This extra local step
   does not enable a remote trust root or attest the submitting operator.
2. The entire `bash scripts/check_repo.sh`: locked Flutter dependencies, fatal
   analysis, full Flutter tests, security/role/tenant SQL and Edge tests, format,
   lint and type checks, all procurement/inventory and API fixtures, repository
   secret scan, npm audit, production deploy/migration regressions, web worker
   compilation and complete Flutter web release build, Git whitespace checks.
3. The official deployer's additional password-lifecycle, SePay webhook,
   emergency-fulfillment and public-receipt Edge security test suites. Each
   requires a nonempty complete Deno summary with no failures or ignored tests.
4. Real Linux Chrome independent-terminal authentication tests.
5. The former restaurant-finalization workflow's isolated regression script.

The inventory and procurement workflow commands already run in check_repo and
are not omitted. All five original workflows, including their SDK hashes and
Action commit pins, remain under `legacy-github-workflows/` as provenance. There
are no active test workflows in `.github/workflows/` in this candidate. This
does not mutate the existing remote branch's workflows or protection settings.

Flutter emits machine events in the full suite and both SQL/PostgREST suites.
The verifier requires three successful complete suites, visible nonempty test
assertions and complete stage markers. Tests initially excluded because they
need SQL fixture environment must later succeed under exactly the same names
in the real SQL/API suites. Any other skipped mandatory test fails. The former CI's optional Office-checkout
static test remains explicitly unavailable when that separate checkout is not
provided; it is recorded as an optional cross-repository exclusion, never PASS.
Its POS-side immutable history/read-fence assertions now run independently on
every full suite, so external checkout absence no longer hides POS assertions. The two
existing Windows-only probes are recorded as not applicable on Linux; they
are not counted as passes. The separate browser suite permits no skips.
Deno and Node summaries must also contain nonempty completed tests and no
failure, cancellation, ignored, skipped or pending cases.

The existing optional `STORE_OPERATING_UPGRADE_SCHEMA` export test is outside
the former required workflow and is not fabricated. This recipe copies no
production schema export or business data. Run an approved, sanitized export
upgrade check separately when the release's migration scope requires it.

## Local environment and fixture ownership

Docker uses a pinned Ubuntu 24.04 amd64 base and checksum-verified official
Flutter 3.41.6 / Dart 3.11.4, Node 22.22.0, Deno 2.7.13 and Chrome for Testing
156.0.8078.47 archives. The image build is local and its full log and actual
image/tool/package identities are recorded. Package repository updates are
recorded rather than claimed byte-for-byte reproducible. A missing or wrong
required OS/tool, failed image build or timeout blocks verification.

The runner creates a private temporary Git clone containing committed source
only. Ignored `.env`, Supabase links, production credentials and user changes
are not copied. The test process receives fixed fixture settings, not the host
environment. The host must use an existing local Unix-socket Docker context.
The tool container shares that local engine so existing SQL fixtures can run;
this is not a security sandbox for malicious repository code.

The fixture Docker wrapper labels every new test container/network with the
unique run ID. It rejects collisions, unowned execution/removal and unreviewed
Docker operations. Cleanup selects only the current run's label; it never
prunes the engine or stops another task's DB. Existing test scripts retain
their fail-fast SQL and cleanup behavior. Actual fixture image IDs, registry
digests and OS/architecture are recorded in addition to the tool image; Linux
DB images may be native arm64 on an Apple host and are not mislabeled x64.

Linux amd64 VFS engines use the explicitly verified, single-layer representation
of the same pinned Supabase filesystem. Source/config/rootfs/derived image
digests and run/SHA-bound provenance are validated, with no change to SQL/API
coverage or the other PostgreSQL versions. See
[Efficient database fixtures](EFFICIENT_DATABASE_FIXTURES.md). The runner also
retains one-second disk samples and the observed peak for the full invocation.

The tool container uses its own bridge namespace. A loopback-only TCP proxy
connects to the verified owned fixture's private IP; it does not assume Docker
Desktop host-loopback publishing is reachable. The tool joins only networks
labeled for its current run and disconnects before their cleanup. Existing
fixtures may connect/disconnect their DB to a second network only after both
network and container ownership labels match; unowned links are rejected. Existing
fixture ports stay bound to host loopback. No public listener is added.
Unexpected fixture operations fail
closed and require a reviewed wrapper update.

## Windows and operational scope

Run `scripts/build_windows_print_station.ps1` on local Windows x64 with the
documented Flutter/MSVC dependencies. Preserve its fatal analysis, all 20
focused test files (including native process-error and connection probes),
actual Windows compilation, required runtime DLLs, whole package and source
SHA in `INSTALL.txt`. Keep full logs/tool versions/UTC times/process status and
the ZIP's SHA-256. Installation, assigned-account login and actual printer
output remain operational gates. Linux is not a Windows substitute.

This release-tooling change does not alter native app implementation, its SDK
lockfile or the native packaging command. A Windows package is not produced by
the web/server recipe and cannot be reported as verified by it. If native
source/dependencies/packaging change, obtain native final-SHA evidence before
calling that native release complete. No Windows machine/VM is provisioned by
this script.

Production targets, Auth readiness, migration-history guards, the official
deployment path, assigned operational login and affected-feature verification
remain unchanged. Deterministic local verification does not perform an actual
sale, tax transmission, production fixture write or operational login.

## Remote boundary

The remote main rule still requires an Actions-app-bound `POS release contract`.
Do not publish fake statuses or remove that protection to make this candidate
mergeable. See `REMOTE_PROTECTION_DECISION_KO.md`. Until the separate protection
decision and authorized remote steps are complete, this is a local candidate,
not a completed transition or production release.

## Metadata-only GitHub verifier proposal (not activated)

The owner approved design and local implementation of a minimal GitHub result
verification procedure. All application tests and builds stay local. See
`INDEPENDENT_RESULT_VERIFICATION_KO.md` for the disabled verifier, independent
executor/key custody prerequisites, workflow identity/event-policy restrictions,
exact unchanged branch-protection fields, cost bounds and unapproved remote
settings proposal. No active workflow, new production key, remote status, push,
PR, merge or deployment is created by this proposal. The previous eight-step
403ec1e5 evidence remains tied to that SHA; the additional verifier step belongs
to the new candidate and cannot inherit the old receipt as a final release PASS.
