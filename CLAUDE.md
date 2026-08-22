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
- **Authoritative system truth**: the checked-out implementation under `lib/`,
  `supabase/`, `scripts/`, `.github/workflows/`, and `test/`
- **Canonical system map**: `00_HOME.md` in the Obsidian vault
- **E-invoice authority**: the implemented MISA/meInvoice contract
- **Historical vendor docs**: `docs/vendor/` (WeTax API, reference only)
- **Sample API responses**: `docs/vendor/samples/`

## 3. Authority and scope rules

- **The current implementation is authoritative.** When older Obsidian scope,
  phase, ADR, or vendor notes conflict with the checked-out code, migrations,
  tests, or workflows, follow the implementation and update the documentation.
- The active vault starts at `00_HOME.md`. Content under `99_ARCHIVE/` is
  provenance only and must not be used as an active specification.
- Keep four states separate: implemented in source, migration applied,
  deployed to production, and operationally verified. Source evidence alone
  proves only the first state.
- MISA/meInvoice is the active e-invoice path. WeTax artifacts remain only for
  compatibility and history unless the implementation is explicitly changed.
- **bytea decode:** Supabase returns bytea as `\x313233...` hex — use
  `decodeByteaToString()` helper in edge functions, not `atob()`.
  See `90_REFERENCE/04_DECISIONS_AND_INVARIANTS.md` in the vault.

## 4. Hard constraints (binding)

- **Claude Code prompts must be English only.** Chat with Hyochang can
  be Korean, but prompts to Claude Code are strictly English.
- **All Claude Code commands follow the harness skill format**
  (`/mnt/skills/user/harness/SKILL.md`):
  Load Design Documents → Load Code Structure → Run Checks by Category
  → Generate Harness Report with severity classification (CRITICAL /
  HIGH / MEDIUM / LOW / CONFIRMED) and Priority Fix List.
- **Do not rebuild what the vendor already provides.** The MISA portal
  handles red invoice history, corrections, cancellations, PDF
  downloads. POS opens `lookup_url` — does not duplicate.
- **Payment completion must never depend on MISA availability.**
  MISA dispatch is always async. The implemented MISA contract is
  authoritative; WeTax remains historical only.
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

## 6. Current structural state

- `restaurants` remains the physical table and `stores` the compatibility view.
- Brand/legal-entity/store hierarchy and multi-store access are implemented;
  effective access is represented by `user_accessible_stores` and related RPCs.
- Authentication users and workforce employees are separate concepts connected
  by explicit mappings where required.
- Fulfillment has both standard POS/print flows and paperless emergency/KDS flows.
- Photo Objet collection uses the implemented 22:00 Asia/Ho_Chi_Minh schedule.
- The current login surface defines 12 roles and the repository contains 16
  Supabase Edge Functions. Recount from source whenever this changes.

## 7. Critical invariants

- `einvoice_jobs.ref_id` must be UUIDv7 (version nibble 7, proper variant bits)
- `process_payment(order, store, amount, method)` is the atomic single-order
  payment anchor. Its latest effective definition is currently in
  `supabase/migrations/20260707010000_service_item_exclusion_v1.sql`; determine
  effective SQL by migration order rather than relying on an older phase file.
- General daily cash close runs at 23:00 Asia/Ho_Chi_Minh. Restaurant order
  cutoff/finalization is a separate contract: 21:30 cutoff, 21:45 grace end,
  and 22:20 finalization. Photo Objet collection is another separate 22:00
  contract. Do not collapse these schedules into one "daily close" rule.
- MISA portal handles red invoice lifecycle. POS does not duplicate.

## 8. Workflow

Hyochang runs Claude Code, Claude (the assistant) designs and reviews.
The assistant writes English Claude Code commands in harness format,
Hyochang executes them in his environment, shares results, the
assistant reviews and responds.

For release work, local validation and an independent Judge are preflight
evidence only. Do not report the release gate as PASS until the required
GitHub Actions checks succeed on the exact pushed head SHA. Cross-platform
shell fixtures must explicitly create every required Git state and must not
depend on Bash-version-specific `errexit` behavior.

## 9. Common verification commands

- Full repository verification: `bash scripts/check_repo.sh`
- Static analysis: `flutter analyze`
- Full Flutter tests: `flutter test`
- Format changed Dart files: `dart format <files>`
- Production release: use `scripts/deploy_pos_production.sh`; do not bypass it.
