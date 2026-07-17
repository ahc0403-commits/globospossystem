# Store Opening Setup Production Runbook

This runbook records the remaining exact-SHA production and physical evidence.
It must not be marked complete from local tests or simulated printer data.

## Release gates

1. Merge the reviewed PR only after the required GitHub checks pass on its
   exact head SHA.
2. Confirm the merge is on `origin/main` and the worktree is clean.
3. Build and download the Windows artifact whose name contains the exact main
   SHA; record its SHA-256 below.
4. Link this clean worktree to pinned POS project
   `ynriuoomotxuwhuxxmhj` with the official Supabase CLI. Do not copy stale
   `supabase/.temp` state and do not use `--skip-pooler`:

   ```bash
   supabase link --project-ref ynriuoomotxuwhuxxmhj
   supabase migration list
   ```

   The read-only history command must connect through the Shared Session
   Pooler. The official DB-only runner rejects direct database credentials and
   transaction pooler port 6543; it requires a pooler host on port 5432.
5. From that clean exact-main worktree, capture a dry-run of the one official
   release command:

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

6. After reviewing the dry-run gates, remove only `--dry-run` and execute the
   same official command. Do not invoke preflight/apply/verification SQL files
   directly. The script requires migration-history absence, rollback readiness,
   dedicated preflight, atomic apply, verification, history repair, and final
   history presence; any failure stops the sequence.
7. Keep `scripts/rollback_store_opening_setup_wizard.sql` ready. Use it only
   with explicit rollback authorization; it removes feature functions/index
   but never deletes store tables, destinations, orders, payments, or jobs.

DB-only does not invoke or require the pilot account checker, pilot account
files, pilot email/password credentials, login smoke, Vercel tools/project
files, or frontend anon-key readiness. It never creates, recovers, modifies,
deletes, resets, or validates accounts. Auth, Vercel, live HTTP, and login
readiness are N/A, and this database release is not POS login-ready evidence.

## Exact-version evidence

- Main SHA:
- Operator:
- Production timestamp (Asia/Ho_Chi_Minh):
- Supabase project ref: `ynriuoomotxuwhuxxmhj`
- Sanitized DB-only dry-run command/output reference:
- Sanitized DB-only apply command/output reference:
- Migration history before/after reference:
- Preflight/apply/verification output reference:
- GitHub exact-head checks URL:
- Windows artifact name:
- Windows ZIP SHA-256:

## Four-printer rehearsal — actual store LAN only

Never enter invented IPs or simulated output confirmation here.

| Physical printer | Model | Static IP | Port | Paper width | Location |
|---|---|---|---:|---:|---|
| Cashier |  |  | 9100 |  |  |
| Kitchen |  |  | 9100 |  |  |
| 2F |  |  | 9100 |  |  |
| 3F |  |  | 9100 |  |  |

| Test | Queue job ID | Queue status | Expected printer | Operator physical confirmation |
|---|---|---|---|---|
| TEST-RECEIPT |  |  | Cashier |  |
| TEST-KITCHEN |  |  | Kitchen |  |
| TEST-1F |  |  | Cashier |  |
| TEST-2F |  |  | 2F |  |
| TEST-3F |  |  | 3F |  |

## Operational failure checks

- [ ] Admin enables the agent on the designated Windows PC.
- [ ] Admin logs out; cashier logs in; agent returns to running.
- [ ] A 1F order prints kitchen + cashier-floor output.
- [ ] A 2F order prints kitchen + 2F output.
- [ ] A 3F order prints kitchen + 3F output.
- [ ] Payment completes and the cashier receipt prints.
- [ ] With one printer powered off, order and payment still complete.
- [ ] After printer recovery, retry/durable queue output is confirmed.
- [ ] After Windows app restart, queued jobs remain available.

Final operator:

Rehearsal date/time (Asia/Ho_Chi_Minh):

Result: `PENDING` (change to `PASS` only after every physical check above)
