# POS Production Auth Operations Runbook

## Scope

Production POS uses approved operational identities only. Email domains ending
in `.test`, fixture restaurants, smoke stores, and pilot-only identities are
forbidden in the production Supabase project `ynriuoomotxuwhuxxmhj`.

The authoritative required-account list is:

```text
docs/pos/pos_required_production_auth_emails.txt
```

Deployment checks are read-only. They must never create, reactivate, reset,
re-role, or reassign an identity.
Deployment automation must verify existing operational identities, never
provision them. Do not store passwords in the repository, commands, or logs.

The production database also rejects these artifacts at write time through
`20260719013000_production_test_entity_guard.sql`:

- Auth emails ending in `.test`;
- the five legacy `office.*@globos.vn` POS boundary-test emails;
- brand or restaurant names/codes/slugs marked test, fixture, smoke, or pilot;
- reactivation of a historical marked restaurant.

Historical inactive rows are retained only for foreign-key integrity and
audit evidence. The guard prevents them from becoming operational again.

## Required check

```bash
scripts/check_pilot_auth_accounts.sh
```

The checker first blocks any of the following production hygiene violations:

- an unbanned `.test` Auth identity;
- an active `.test` POS profile, store access, or brand access;
- an active restaurant whose name or brand code is marked test, fixture,
  smoke, or pilot;
- active access to an inactive restaurant.

It then verifies every approved operational email through the application
lookup path:

```text
auth.users.email -> auth.users.id -> public.users.auth_id
```

Each account must be confirmed, active, assigned a supported role, and carry
valid `app_metadata.accessible_store_ids` claims.

## Repair rules

- Never create or reactivate a `.test` identity or test restaurant in
  production.
- Never use deployment automation to mutate passwords, roles, or store
  assignments.
- For `MISSING_AUTH`, provision only an identity already approved in the
  authoritative operational account list.
- For `MISSING_POS_PROFILE`, link only the approved Auth identity and its
  approved operating assignment.
- For `MISSING_STORE_SCOPE` or `INVALID_STORE_SCOPE`, verify the assigned store
  is an active real operating store before changing access or claims.
- Do not bypass the gate with `--skip-auth-check` and call the release ready.

After an approved repair, rerun the checker and deploy only through
`scripts/deploy_pos_production.sh`.

## Approved initial-password reset

Never use a broad Auth reset against production. The legacy
`scripts/reset_all_auth_passwords.js` entry point is intentionally blocked.
For an explicitly approved initial-password assignment, use only:

```bash
CONFIRM_PRODUCTION_PASSWORD_RESET=RESET_GLOBOS_PROD_OPERATIONAL_PASSWORDS \
POS_EXPECTED_CREATED_DATE_VN=YYYY-MM-DD \
scripts/reset_production_operational_passwords.sh
```

The date is the expected Auth creation date in `Asia/Ho_Chi_Minh`. The script
requires a clean exact `origin/main`, the pinned production project, the
authoritative operational email list, and a mode-600 secure environment file.
It runs the normal Auth/data-hygiene check before prompting for the password
without terminal echo. It then resets only the approved operational identities
whose creation date, confirmation, active profile, role, fixed account code,
active store access, and claims all match. It verifies every new login and
proves that profile, role, access, and claim state did not change.

Do not put the password in a command, repository file, account list, or log.
Run the same command with `--preflight-only` first to exercise the exact live
account, profile, store-access, and claim reads without prompting for a
password or changing Auth state.
