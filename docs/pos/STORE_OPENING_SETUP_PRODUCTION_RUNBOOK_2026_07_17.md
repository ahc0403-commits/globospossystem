# Store Opening Setup Production Runbook

This runbook records the remaining exact-SHA production and physical evidence.
It must not be marked complete from local tests or simulated printer data.

## Release gates

1. Merge the reviewed PR only after the required GitHub checks pass on its
   exact head SHA.
2. Confirm the merge is on `origin/main` and the worktree is clean.
3. Build and download the Windows artifact whose name contains the exact main
   SHA; record its SHA-256 below.
4. Run the guarded SQL sequence against pinned POS project
   `ynriuoomotxuwhuxxmhj`:

   ```bash
   scripts/run_pos_production_sql.sh \
     scripts/preflight_store_opening_setup_wizard.sql \
     'Store opening setup preflight'

   scripts/run_pos_production_sql.sh \
     scripts/apply_store_opening_setup_wizard.sql \
     'Store opening setup apply'

   scripts/run_pos_production_sql.sh \
     scripts/verify_store_opening_setup_wizard.sql \
     'Store opening setup verification'
   ```

5. Keep `scripts/rollback_store_opening_setup_wizard.sql` ready. Use it only
   with explicit rollback authorization; it removes feature functions/index
   but never deletes store tables, destinations, orders, payments, or jobs.

## Exact-version evidence

- Main SHA:
- GitHub exact-head checks URL:
- Windows artifact name:
- Windows ZIP SHA-256:
- Production migration timestamp/operator:
- Verification output reference:

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
