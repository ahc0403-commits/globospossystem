# CLAUDE.md — GLOBOSVN POS System

> Inherits global behavioral guidelines from `~/.claude/CLAUDE.md`.
> Project-specific rules below override or supplement those.

## 1. Behavioral guidelines

See `~/.claude/CLAUDE.md`. Four principles:
1. Think before coding — surface assumptions, ask when uncertain
2. Simplicity first — minimum code, no speculative features
3. Surgical changes — touch only what's needed, don't improve adjacent code
4. Goal-driven execution — verifiable success criteria, loop until verified

## 2. Project context

GLOBOSVN POS is a multi-tenant F&B point-of-sale product for Vietnam.
Stack: Flutter + Supabase (Postgres + RLS + Edge Functions + Storage + pg_cron).

- **Codebase**: `~/globos_pos_system`
- **Obsidian vault**: `~/Documents/restaurant-ops-vault/GLOBOSVN POS/`
- **Authoritative scope**: `Stage 1/stage1_scope_v1.4.md` (in vault)
- **Current e-invoice vendor**: MISA meInvoice. See
  `docs/MEINVOICE_IMPLEMENTATION_HANDOFF_2026_06_30.md`.
- **Historical vendor docs**: `docs/vendor/` (WeTax API, closed/read-only)
- **Historical sample API responses**: `docs/vendor/samples/`

## 3. Authority and scope rules

- **Scope v1.4 is authoritative.** v1.0/v1.1/v1.2/v1.3 are superseded but
  preserved for history. Do not re-litigate decisions already in v1.4.
- **Do not re-run Phase -1, Phase 0, or Phase 1.** They are complete and
  documented in the vault. Same for Phase 2 Step 1.
- **Phase 2 Steps 2–10 are complete** as of 2026-04-13.
  DB is in expand-migrate state with dual naming (Step 2).
  11 historical WeTax tables added (Step 4). WeTax is now closed.
  process_payment was extended with VAT + legacy einvoice_jobs (Step 8).
  Do not re-run any completed step.
- **WeTax is permanently closed as of 2026-06-30.** Treat all WeTax code,
  tables, cron jobs, docs, and API samples as historical audit material only.
  Do not create, restore, schedule, dispatch, poll, or extend WeTax flows.
- **MISA meInvoice is the active e-invoice path.** New first-issuance
  cash-register invoices use `public.meinvoice_jobs` and
  `supabase/functions/meinvoice-dispatcher`. Follow
  `docs/MEINVOICE_IMPLEMENTATION_HANDOFF_2026_06_30.md` for current state,
  blockers, activation steps, runtime secrets, and validation commands.
- **Phase 3 verification complete.** 11/11 invariants PASS. E2E PASS.
- **bytea decode:** Supabase returns bytea as `\x313233...` hex — use
  `decodeByteaToString()` helper in edge functions, not `atob()`.
  See ADR-014 in vault.

## 4. Hard constraints (binding)

- **Claude Code prompts must be English only.** Chat with Hyochang can
  be Korean, but prompts to Claude Code are strictly English.
- **All Claude Code commands follow the harness skill format**
  (`/mnt/skills/user/harness/SKILL.md`):
  Load Design Documents → Load Code Structure → Run Checks by Category
  → Generate Harness Report with severity classification (CRITICAL /
  HIGH / MEDIUM / LOW / CONFIRMED) and Priority Fix List.
- **Do not rebuild what the vendor already provides.** MISA meInvoice portal
  handles post-issuance exception workflows: replacement invoices, adjustment
  invoices, incorrect-invoice notifications, cancellations, and manual portal
  review. POS marks manual action and does not duplicate those workflows.
- **Payment completion must never depend on e-invoice vendor availability.**
  MISA meInvoice dispatch is always async through `meinvoice_jobs`.
- **Both existing settlement edge functions are preserved.**
  `generate-settlement` (dine-in) and `generate_delivery_settlement`
  (Deliberry) serve distinct business domains. Do not flag as duplicates.

## 5. Office app coupling (do not break)

The Office Supabase project (`raghsbaxcwrxlsacaoau`,
`~/Documents/restaurant_office_app`) connects to POS Supabase
(`ynriuoomotxuwhuxxmhj`) directly via service_role key. The single
hard coupling point is:

```
restaurant_office_app/lib/features/master_admin/data/master_admin_repository.dart:48
    .from('restaurants').select('id, name, address, is_active')
```

This means:
- POS `restaurants` table name MUST stay (cannot rename to `stores` physically).
- POS `restaurants.id`, `name`, `address`, `is_active` columns MUST stay.
- `stores` exists as a view on top of `restaurants` (Expand stage).
- `restaurant_id` FK columns on POS side may be aliased via views to
  `store_id` but the physical column name is preserved.
- Office app must NOT be modified to follow POS renames unless
  explicitly instructed.

## 6. Database state (as of 2026-04-12)

- `restaurants` (table), `stores` (view) — both work, dual naming
- `restaurant_settings` (table), `store_settings` (view) — both work
- `get_user_restaurant_id()` — preserved as legacy wrapper
- `get_user_store_id()` — current authoritative RLS helper
- 33 RLS policies, 29 reference `get_user_store_id`, 0 reference legacy
- `v_store_daily_sales`, `v_store_attendance_summary` etc. expose `store_id`

## 7. Critical invariants

- `einvoice_jobs` is legacy WeTax audit state only. Do not insert new rows or
  build new behavior on it.
- `meinvoice_jobs` is the current queue for first-issuance cash-register
  invoices.
- `process_payment` RPC at
  `supabase/migrations/20260409000000_dine_in_sales_contract_closure.sql`
  is the atomic payment anchor. E-invoice dispatch must remain async.
- Daily close is fixed 00:00 Asia/Ho_Chi_Minh, not per-store
- MISA meInvoice portal handles post-issuance exception lifecycle. POS does
  not duplicate.

## 8. Workflow

Hyochang runs Claude Code, Claude (the assistant) designs and reviews.
The assistant writes English Claude Code commands in harness format,
Hyochang executes them in his environment, shares results, the
assistant reviews and responds.
