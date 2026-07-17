# Credential Cleanup Report

**Date:** 2026-06-10
**Status:** Action items identified — manual execution required

## Accounts requiring rotation (POS Supabase Auth: ynriuoomotxuwhuxxmhj)

| Account | Current password | Action |
|---------|-----------------|--------|
| superadmin@globos.test | [REDACTED — shared weak password] | Rotate to strong unique password |
| admin@globos.test | [REDACTED — shared weak password] | Rotate to strong unique password |
| cashier@globos.test | [REDACTED — shared weak password] | Rotate or disable |
| waiter@globos.test | [REDACTED — shared weak password] | Rotate or disable |
| kitchen@globos.test | [REDACTED — shared weak password] | Rotate or disable |
| pos.validation.codex@globos.test | (in xlsx) | Rotate or disable |

## Accounts requiring rotation (Office Supabase Auth: raghsbaxcwrxlsacaoau)

| Account | Action |
|---------|--------|
| super@globos.vn | Rotate [REDACTED] |
| brand.mk@globos.vn | Rotate |
| brand.kn@globos.vn | Rotate |
| store@globos.vn | Rotate |
| staff@globos.vn | Rotate |
| office.store@globos.vn | Rotate |
| office.brand.kn@globos.vn | Rotate |
| office.brand.mk@globos.vn | Rotate |
| office.staff@globos.vn | Rotate |
| office.super@globos.vn | Rotate [REDACTED — shared weak password] |

## XLSX file

- **File:** `GLOBOS_POS_화면플로우_계정정보_2026-05-25.xlsx`
- **Contains:** Working login credentials with live POS URL
- **Does NOT contain:** API keys, service_role keys, connection strings
- **Action:** `git rm --cached` then relocate to `~/Documents/restaurant-ops-vault/`

## CRON_SECRET

- **Current value:** hardcoded in `supabase/migrations/20260413001843:28,43,58,73`
- **Used by:** 4 WeTax cron jobs + settlement functions
- **Action:** Migration `20260610000003` rotates to Vault-based lookup
- **Manual step:** Insert new secret into Vault + edge function env BEFORE applying migration

## Vendor samples

- **File:** `docs/vendor/samples/01_auth_login_plaintext.json`
- **Action:** Redact password/token fields (test-only, P3)

## Steps to execute (manual, in order)

1. Generate new strong passwords for all accounts listed above
2. Store new passwords in `~/Documents/restaurant-ops-vault/` (never in git)
3. Rotate passwords via Supabase dashboard (Auth → Users)
4. `git rm --cached 'GLOBOS_POS_화면플로우_계정정보_2026-05-25.xlsx'`
5. Move xlsx to vault directory
6. Update `integration_test/full_multi_account_smoke_test.dart` credential source
7. Verify old passwords fail on the live URL
8. Generate new CRON_SECRET value
9. Set it in edge function env (Supabase dashboard → Functions → Secrets)
10. Insert into Vault: `INSERT INTO vault.secrets (name, secret) VALUES ('cron_secret', '<new>')`
11. Apply migration `20260610000003_rotate_cron_secret_to_vault.sql`
12. Verify next cron tick succeeds

## Not done (requires manual execution)

This report identifies what to change. The actual password rotation, xlsx removal,
and Vault secret insertion must be performed manually via the Supabase dashboard
and git commands. No credentials are committed in this report.
