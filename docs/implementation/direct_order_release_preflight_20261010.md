# Delivery reconciliation, translation and cash closing release preflight

The owner authorized production DB, Edge and web deployment on 2026-10-10.
This candidate was prepared in an isolated managed worktree from
`91e4c9175a67624d1dd12db16304a52d1f53ffcb` (fresh origin/main). The original
checkout and its unrelated user changes were preserved.

## Scope and behavior

- Record actual receipts separately from applied revenue; request the exact
  outstanding food balance and refund excess with a scoped evidence photo.
- Keep prior-day completed orders visible while excess remains outstanding.
  Preserve customer access while refunds are due and for the server-controlled
  seven-day refund-evidence window. Explicit support closure still wins.
- Record immutable driver cash payouts/recoveries and customer cash refunds.
  Deduct them correctly in closing previews and confirmed snapshots. Bank
  recovery does not increase safe cash.
- Translate free text asynchronously in same-order batches, preserving original
  text, numbers, signs and currency literals. Valid results survive a malformed
  sibling result. Retry only failed jobs and serve waiting orders fairly.
- Preserve public status v3–v6 and add VOLATILE v7 for translation and session
  activity. Preserve the canonical `process_payment` definition.

## Verification recorded before commit

- Full Flutter run: **1,894 passed, 94 skipped**.
- Isolated PostgreSQL integration: PASS, including underpayment/top-up,
  overpayment/cancellation refunds, immutable cash movements and closing,
  original pickup refund duplicate rejection, prior-day list LIMIT handling,
  privacy/retention, legacy status contracts, long multibyte notes, queue
  fairness, and actual v7 PostgREST HTTP 200.
- Cashier/kitchen list sizes 1/50/100/200: **zero per-row detail calls**.
- Customer Edge: 24 tests passed; translation Edge: 6 tests passed.
- Completed-order access regression reproduced on old behavior; fixed route
  tests passed. Independent reviewer also passed eight completion/evidence cases.
- No-smoke deployment contract passed with both raw-origin and digest CLI
  responses. Only the selected origin digest can reach a temporary file.
- Deep specialist and adversarial review findings were reproduced and fixed;
  final security, architecture and completion-path re-reviews returned no
  remaining confirmed findings.
- Full `scripts/check_repo.sh` remains in progress at this commit. Its final
  result and exact-SHA GitHub Actions success are required before production.

## Production gates and secret handling

Run only `scripts/deploy_pos_production.sh`, using a clean checkout whose HEAD
exactly equals freshly fetched origin/main and whose exact SHA has a successful
GitHub Actions **POS release contract** check. Apply money migration
`20261010010000`, then translation migration `20261010020000`, with their
read-only preflight and verification SQL. Deploy Edge and web through the same
release runner.

`OPENAI_API_KEY` has already been registered only as a Supabase server secret.
The release runner synchronizes a dedicated translation scheduler secret with
the existing Vault scheduler value, without changing the shared `CRON_SECRET`.
Values remain in pipes/memory and are never written to local secret files,
command arguments, source or logs. Translation uses `store:false`.

At this preflight snapshot the new migrations, Edge and web are **not deployed**.
Production rollout and live checks must be reported separately with their exact
SHA, deployment metadata, migration history and verification results. Financial
ledger deletion is not a rollback strategy. Deliberry and Photo Objet automatic
collection remain retired.

The older implementation report and compressed logs are historical evidence
from the initial user checkout; they do not represent the final release gate.
