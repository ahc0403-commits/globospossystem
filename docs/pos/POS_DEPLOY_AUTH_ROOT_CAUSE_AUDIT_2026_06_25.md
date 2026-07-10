# POS Deploy Auth Root Cause Audit

Date: 2026-06-25

## Summary

Scope audited:

- Production deploy readiness for pilot POS login.
- Required pilot Auth account list.
- App profile lookup path.
- Deployment guard scripts.

Documents reviewed:

- `CLAUDE.md`
- `/Users/andreahn/.claude/CLAUDE.md`
- `.flare_memory.md`
- `docs/pos/POS_PRODUCTION_DEPLOYMENT_RUNBOOK.md`
- `docs/manual_test/pos_required_pilot_auth_emails.txt`
- `docs/ADR-014-Brand-Store-Multi-Access-Model.md`

Implementation areas reviewed:

- `scripts/deploy_pos_production.sh`
- `scripts/check_pilot_auth_accounts.sh`
- `scripts/smoke_pilot_login.sh`
- `lib/features/auth/auth_provider.dart`
- `supabase/functions/create_staff_user/index.ts`
- `supabase/migrations/20260414000006_add_multi_access_auth_hook.sql`
- `test/pos_deploy_auth_guard_contract_test.dart`

Confirmed issues by category:

- Schema violations: 0
- RPC violations: 0
- Rules violations: 0
- Role and permission violations: 0
- ADR compliance issues: 0
- Missing implementation: 0
- Stale deployment fixture: 1

## Hunt Evidence

Symptom:

- Production deploy request stops before Vercel because
  `dung.cashier01@globos.test` returns `MISSING_AUTH`.

Repro:

```bash
CONFIRM_PRODUCTION_DEPLOY=DEPLOY_GLOBOS_PROD \
scripts/deploy_pos_production.sh
```

Observed result before fixture repair:

```text
BLOCKER: dung.cashier01@globos.test MISSING_AUTH
ERROR: Required POS pilot Auth accounts are not ready.
```

Expected result:

- Required pilot emails all return `OK`.
- Deployment proceeds to checks, Vercel build/deploy, live URL check, and pilot
  login smoke.

Blast radius:

- Any production deploy that honestly claims pilot login readiness.
- The frontend app itself is not the failing layer.

## Findings

[High] [Rules] Missing production Auth identity is being mistaken for deploy failure

Spec: `docs/pos/POS_PRODUCTION_DEPLOYMENT_RUNBOOK.md`, "Why pilot login can fail after a good deploy" and "Production rules"

Code: `scripts/check_pilot_auth_accounts.sh`; `scripts/deploy_pos_production.sh`

Why it matters: Re-running Vercel deploy cannot create the missing Auth user, so the same login error repeats until the production identity is provisioned.

Evidence: The deploy rail targets Supabase `ynriuoomotxuwhuxxmhj` and Vercel `globospossystem`, then blocks on `dung.cashier01@globos.test MISSING_AUTH` before build/deploy.

Recommended fix: Provision the missing production Supabase Auth user, confirm email, and link the POS profile via `public.users.auth_id`; keep the deploy Auth gate enabled.

[High] [Rules] Stale required pilot email blocked deployment readiness

Spec: `docs/manual_test/pos_required_pilot_auth_emails.txt`; pilot spreadsheets under `docs/manual_test/`

Code: `scripts/check_pilot_auth_accounts.sh`; `test/pos_deploy_auth_guard_contract_test.dart`

Why it matters: A required-auth fixture must represent the actual pilot account list. Requiring an email absent from the pilot spreadsheets blocks deployment for an account that is not part of the current pilot pack.

Evidence: The local pilot spreadsheets list `waiter@globos.test`, `kitchen@globos.test`, `cashier@globos.test`, `admin@globos.test`, `superadmin@globos.test`, and `pos.validation.codex@globos.test`. They do not list `dung.cashier01@globos.test`; Dung is assigned to `admin@globos.test`.

Recommended fix: Remove `dung.cashier01@globos.test` from the required production Auth list and keep the deploy guard checking the authoritative pilot emails.

[Medium] [Documented But Not Implemented] Provisioning repair path was not first-class enough

Spec: `docs/pos/POS_PRODUCTION_DEPLOYMENT_RUNBOOK.md`, Auth readiness and skip-flag rules

Code: previous `scripts/check_pilot_auth_accounts.sh` output only listed blocker rows and a generic failure message.

Why it matters: Operators could see the deploy stop and still treat it as a deploy problem instead of a production identity provisioning problem.

Evidence: The checker detected `MISSING_AUTH`, but did not print status-specific next actions or point to a provisioning runbook.

Recommended fix: Emit a provisioning-oriented blocker report and add a dedicated repair runbook.

## Missing Evidence

- The approved secure source for the assigned pilot password is outside this
  repository and was not inspected.
- No production password value was read, printed, or tested in this audit.

## Missing Implementation

Required now:

- Keep `docs/manual_test/pos_required_pilot_auth_emails.txt` aligned with the
  authoritative pilot account spreadsheets.

Planned / later phase:

- None for the deploy guardrail. Account lifecycle ownership may be moved to a
  separate secure operations workflow, but deployment automation should remain
  verification-only.

## Open Questions

- Which secure operational system is authoritative for the pilot password
  assigned to `dung.cashier01@globos.test`?
- Which operator owns production Auth provisioning for pilot accounts?
