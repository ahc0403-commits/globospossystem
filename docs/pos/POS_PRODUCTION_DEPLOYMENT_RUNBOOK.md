# POS Production Deployment Runbook

Last updated: 2026-06-25

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

1. Production target preflight.
2. Required pilot Auth readiness check with
   `scripts/check_pilot_auth_accounts.sh`.
3. `dart analyze`.
4. Focused Flutter test target, currently
   `test/pilot_feedback_closure_contract_test.dart`.
5. Optional single Supabase migration apply.
6. `vercel build --prod`.
7. `vercel deploy --prebuilt --prod --yes`.
8. Live HTTP check for `https://globospossystem.vercel.app`.
9. Pilot login smoke with `scripts/smoke_pilot_login.sh`.

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
  --migration supabase/migrations/20260616000000_pos_pilot_feedback_closure.sql
```

The script applies the file with `supabase db query --linked -f`, then runs:

```bash
supabase migration repair <version> --status applied --yes
```

Do not use `supabase db push` until the local and remote migration histories
are reconciled.

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
- Stop before deploying if required pilot emails are missing from production
  Auth or their POS profile rows are missing.
- After deploy, prove at least one assigned pilot account can log in and read
  its POS profile.
- Apply at most one production migration per run unless there is a written
  reason to do otherwise.
- Run Supabase DB operations sequentially.
- Do not print database URLs, service role keys, or anon keys in logs.
- Keep `.vercelignore` focused on web build inputs so deploy uploads stay small.
