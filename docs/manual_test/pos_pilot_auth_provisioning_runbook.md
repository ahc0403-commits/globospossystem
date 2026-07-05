# POS Pilot Auth Provisioning Runbook

Last updated: 2026-06-25

## Purpose

Production POS deployments are only login-ready when the required pilot
accounts exist in production Supabase Auth and have POS profiles linked by
`public.users.auth_id`.

This runbook is for provisioning or repairing those identities. It is not a
frontend deploy procedure.

## Root Cause Pattern

The repeated `Invalid login credentials` issue happens when the deployed
Flutter app is healthy but the pilot email is absent or incomplete in
production Supabase Auth.

Vercel deploys the frontend only. It cannot create, confirm, restore, relink,
or reset Supabase Auth users.

The app login path is:

```text
auth.users.email -> auth.users.id -> public.users.auth_id
```

Do not judge POS profile readiness with `public.users.id = auth.users.id`.

## Required Check

Run this before production deploy:

```bash
scripts/check_pilot_auth_accounts.sh
```

Expected statuses:

- `OK`: Auth user exists, email is confirmed, and POS profile is linked.
- `MISSING_AUTH`: the email does not exist in production `auth.users`.
- `UNCONFIRMED_AUTH`: the Auth user exists but email is not confirmed.
- `MISSING_POS_PROFILE`: Auth user exists but no POS `public.users` row is
  linked by `auth_id`.

Any non-`OK` status blocks login-ready deployment.

## Repair Actions

For `MISSING_AUTH`:

1. Confirm the target Supabase project is `ynriuoomotxuwhuxxmhj`.
2. Create the production Supabase Auth user with the assigned pilot credential
   from the approved secure source.
3. Mark the email confirmed.
4. Create or link the POS `public.users` row with `auth_id = auth.users.id`.
5. Preserve the agreed pilot password; do not rotate unrelated accounts.

For `UNCONFIRMED_AUTH`:

1. Confirm the existing Auth user belongs to the intended pilot account.
2. Mark the email confirmed in production Auth.
3. Re-run `scripts/check_pilot_auth_accounts.sh`.

For `MISSING_POS_PROFILE`:

1. Find the existing production `auth.users.id` for the email.
2. Create or repair the POS profile row in `public.users`.
3. Ensure the role and store match the pilot assignment.
4. Re-run `scripts/check_pilot_auth_accounts.sh`.

## Safety Rules

- Do not store passwords in this repository.
- Do not print passwords in shell commands, logs, tickets, or reports.
- Do not reset all Auth passwords to fix one missing pilot account.
- Do not bypass the deploy Auth gate with `--skip-auth-check`, direct Vercel
  deploys, or manual URL checks and call the result login-ready.
- Deployment automation must verify identity state, not create or mutate pilot
  credentials.

## After Repair

Run:

```bash
scripts/check_pilot_auth_accounts.sh
```

Then deploy through:

```bash
CONFIRM_PRODUCTION_DEPLOY=DEPLOY_GLOBOS_PROD \
scripts/deploy_pos_production.sh
```

After deploy, run the pilot login smoke with one assigned pilot credential
provided through environment variables, never in the command line.
