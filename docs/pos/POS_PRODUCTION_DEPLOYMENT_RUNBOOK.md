# POS Production Deployment Runbook

Last updated: 2026-07-17

## Why pilot login can fail after a good deploy

The POS web deploy and Supabase Auth provisioning are separate systems.
Vercel deploys the Flutter web app; it does not create, restore, or reset
Supabase Auth users. If a pilot email exists in the spreadsheet but not in the
production Supabase project, Supabase Auth returns `Invalid login credentials`
even when the live app loads correctly.

For production POS, the expected Supabase project is `ynriuoomotxuwhuxxmhj`
and the expected Vercel project is `globospossystem`. A live URL HTTP 200 is
not enough to call the deploy login-ready.

## Why the 2026-06-17 deployment was slow

1. Raw `psql` could not connect with `supabase/.temp/pooler-url` because the
   local pooler URL did not include the database password.
2. `supabase db push` was not safe for this repo because the local and remote
   migration histories are divergent. A push could apply unrelated historical
   migrations.
3. The first direct migration apply failed because Postgres does not allow
   changing existing RPC argument names in-place. The fix was to drop the
   existing overloads before recreating them.
4. Running multiple Supabase verification queries in parallel triggered
   authentication throttling/circuit breaker behavior. Production DB checks
   should run sequentially.
5. Vercel uploaded about 135.9 MB because docs, screenshots, tests, Supabase
   sources, and platform folders were not excluded from the deploy upload.
6. Vercel remote builds cloned Flutter and downloaded the Dart SDK during the
   deployment. This is expected when the remote build cache is cold.
7. The Flutter web build warning about missing CupertinoIcons is non-fatal, but
   it is noisy and should be tracked separately if it keeps obscuring real
   build issues.

## Standard deployment path

Use the deployment script instead of manually chaining Supabase and Vercel
commands:

```bash
CONFIRM_PRODUCTION_DEPLOY=DEPLOY_GLOBOS_PROD \
scripts/deploy_pos_production.sh
```

This default path runs:

1. Clean Git worktree and freshly fetched `origin/main` ancestry preflight.
2. Production target preflight.
3. Required pilot Auth readiness check with
   `scripts/check_pilot_auth_accounts.sh`.
4. `dart analyze`.
5. Focused Flutter test target, currently
   `test/pilot_feedback_closure_contract_test.dart`.
6. Optional single Supabase migration apply with migration-history guards.
7. `vercel build --prod`.
8. `vercel deploy --prebuilt --prod --yes`.
9. Live HTTP check for `https://globospossystem.vercel.app`.
10. Pilot login smoke with `scripts/smoke_pilot_login.sh`.

Before any production database or Vercel mutation, the script fetches
`origin/main` into `refs/remotes/origin/main` and requires that freshly fetched
commit to be an ancestor of `HEAD`. A feature branch based on an older main
commit is rejected even when its local `origin/main` reference was stale.
There is no ancestry bypass environment variable.

The worktree must be clean by default (`REQUIRE_CLEAN_GIT=1`). The only
exception is an explicitly non-mutating inspection run:

```bash
REQUIRE_CLEAN_GIT=0 scripts/deploy_pos_production.sh --dry-run
```

`REQUIRE_CLEAN_GIT=0` exits nonzero without `--dry-run`.

The Auth readiness check verifies required pilot emails exist in production
`auth.users`, are confirmed, have active POS profiles in `public.users`, use a
supported POS role, and carry non-empty `app_metadata.accessible_store_ids`
claims whose referenced rows exist in `public.restaurants`. The profile link
must follow the app login path: `auth.users.email -> auth.users.id ->
public.users.auth_id`. Do not diagnose readiness with `public.users.id =
auth.users.id`; that is not the POS login lookup. The check never reads,
prints, creates, or resets passwords.

Provisioning and repair instructions live in:

```bash
docs/manual_test/pos_pilot_auth_provisioning_runbook.md
```

If the check reports `MISSING_AUTH`, `UNCONFIRMED_AUTH`,
`MISSING_POS_PROFILE`, `INACTIVE_POS_PROFILE`, `UNKNOWN_ROLE`,
`MISSING_STORE_SCOPE`, or `INVALID_STORE_SCOPE`, stop before Vercel deploy.
This is production account provisioning work. A frontend deploy cannot create,
confirm, restore, relink, reactivate, re-role, or repair Supabase Auth/POS
account scope.

The login smoke requires one assigned pilot credential supplied securely via
environment variables:

```bash
export PILOT_SMOKE_EMAIL=dung.cashier01@globos.test
read -r -s PILOT_SMOKE_PASSWORD
export PILOT_SMOKE_PASSWORD
```

Do not place the pilot password in the command line or in the required-email
file.

## Deploy with one Supabase migration

Use a single explicit migration file:

```bash
CONFIRM_PRODUCTION_DEPLOY=DEPLOY_GLOBOS_PROD \
scripts/deploy_pos_production.sh \
  --migration supabase/migrations/20260711090000_legal_entity_brand_store_hierarchy.sql
```

The script supports production apply only when that migration has an explicit
verification phase. It confirms the version is absent from remote migration
history before SQL, applies the file with the linked fail-fast `psql` runner,
runs verification, repairs history, and then requires the version to be
present:

```bash
supabase migration list
psql -X --no-psqlrc -v ON_ERROR_STOP=1 --single-transaction --file <migration>
supabase migration repair <version> --status applied --yes
supabase migration list
```

Failure to list history, a version unexpectedly present before apply, or a
version absent after repair stops the deployment with a nonzero exit. Migration
history confirmation never warns and continues, and there is no repair/history
bypass flag or environment variable. The destructive hierarchy rollback uses
the inverse contract: history must contain `20260711090000` before rollback and
must not contain it after the reverted repair.

Do not use `supabase db push` until the local and remote migration histories
are reconciled.

## Official DB-only production release

Use `--db-only` when the reviewed release changes only the production
database. This is a first-class release mode, not a combination of skip flags:

```bash
ENV_FILE=/Users/andreahn/.config/globos/pos-production.env \
TEST_TARGETS=all \
scripts/deploy_pos_production.sh \
  --migration supabase/migrations/20260717090000_store_opening_setup_wizard.sql \
  --mode prebuilt \
  --db-only \
  --dry-run \
  --yes
```

After the dry-run evidence is reviewed, remove only `--dry-run` and run the
same command from a clean worktree whose `HEAD` exactly equals the freshly
fetched `origin/main` SHA. Record the operator, Asia/Ho_Chi_Minh timestamp,
exact SHA, pinned project ref, sanitized command, preflight output, apply
output, migration-history confirmation, and verification output.

Before either command, link that clean exact-main worktree to production with
the official Supabase CLI:

```bash
supabase link --project-ref ynriuoomotxuwhuxxmhj
supabase migration list
```

Do not copy `supabase/.temp` from another worktree and do not use
`--skip-pooler`. The DB-only SQL runner obtains temporary linked credentials
through the official CLI and requires a Shared Session Pooler host on port
5432. Direct database credentials and transaction pooler port 6543 fail before
SQL. `supabase migration list` is the read-only connectivity and history check;
do not query or modify any pilot or real account for connectivity evidence.

DB-only requires `--migration`, locked dependency bootstrap, static analysis,
and tests. It rejects `--skip-db`, `--skip-checks`, `--no-tests`,
`--skip-auth-check`, `--skip-login-smoke`, `--skip-build`, `--skip-vercel`,
`--rollback-hierarchy`, and non-default deployment modes. The production env
file is loaded for Supabase CLI authentication and pinned-target validation;
pilot email/password variables and frontend anon-key readiness are not
required or inspected.

The following stages are explicitly N/A in DB-only output: pilot Auth/account
readiness, Vercel deployment, live HTTP check, and pilot login smoke. The mode
never invokes the account checker or login-smoke script, never creates,
recovers, resets, or mutates accounts, and must never be reported as evidence
that the POS login flow is production-ready.

## Faster or safer modes

Default, fast path:

```bash
scripts/deploy_pos_production.sh
```

The default `prebuilt` mode builds locally with Vercel and uploads the prebuilt
output, avoiding the repeated remote Flutter installation path.

Remote Vercel build path:

```bash
DEPLOY_MODE=remote scripts/deploy_pos_production.sh
```

Use this when you want Vercel to build in its remote Linux environment. The
script will run a local Flutter web build first unless `--skip-build` is set.

Dry run:

```bash
scripts/deploy_pos_production.sh --dry-run
```

Dry-run prints production mutation commands without executing them. It still
freshly fetches and validates `origin/main`, and it does not weaken the default
clean-tree rule unless `REQUIRE_CLEAN_GIT=0` is supplied explicitly.

Skip checks only when you have already run them in the same working tree:

```bash
SKIP_CHECKS=1 scripts/deploy_pos_production.sh
```

Skip Auth or login smoke only when explicitly diagnosing a non-login deploy
path. If either is skipped, report the result as a blocker-risk, not as
login-ready production. Do not use skip flags, direct `vercel deploy`, or a
manual live URL check to call pilot login PASS.

## Production rules

- Confirm the linked Supabase project is `ynriuoomotxuwhuxxmhj`.
- Confirm the linked Vercel project is `globospossystem`.
- Start from a clean committed worktree.
- Require `HEAD` to descend from freshly fetched `origin/main`; update the
  branch before retrying when this guard fails.
- Stop before deploying if required pilot emails are missing from production
  Auth or their POS profile rows are missing.
- After deploy, prove at least one assigned pilot account can log in and read
  its POS profile.
- Apply at most one production migration per run unless there is a written
  reason to do otherwise.
- Treat migration-list failures and expected version mismatches as deployment
  blockers before continuing to another mutation.
- Run Supabase DB operations sequentially.
- Do not print database URLs, service role keys, or anon keys in logs.
- Keep `.vercelignore` focused on web build inputs so deploy uploads stay small.

## Windows native print station

The Windows print station is the same Flutter POS source compiled as a native
desktop application. It is not a browser wrapper. The packaged executable is
`globos_print_station.exe`; all DLLs and the `data` directory beside it are
required and must be moved together.

Build on a Windows machine with Flutter 3.41.6 and Visual Studio Desktop
development with C++ installed:

```powershell
$env:SUPABASE_URL = '<production project URL>'
$env:SUPABASE_ANON_KEY = '<production anon key>'
.\scripts\build_windows_print_station.ps1
```

Never use `SUPABASE_SERVICE_KEY` or a database password in a client build. For
the reproducible build, run the `Windows Print Station Build` GitHub Actions
workflow and use only the artifact whose name contains the reviewed commit
SHA. After login on the station, open **Print Station**, confirm all five
destinations, print one test ticket per destination, then start polling. Do not
call the station operational until the physical tickets and retry queue have
been checked on the store network.
