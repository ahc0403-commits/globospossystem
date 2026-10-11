# CLAUDE.md — GLOBOSVN POS System

Read `/Users/andreahn/.claude/CLAUDE.md` first and apply its shared rules,
including N+1 prevention and performance verification. This file adds
project-specific rules under platform instruction precedence; explicit user
requests and higher-priority instructions take precedence.

## Project and sources

- GLOBOSVN POS is a multi-tenant F&B POS for Vietnam, built with Flutter and
  Supabase (Postgres, RLS, Edge Functions, Storage, and pg_cron).
- Confirm current behavior from `lib/`, `supabase/`, `scripts/`,
  `.github/workflows/`, and `test/`. When documentation and implementation differ,
  identify the discrepancy and use the user request and business invariants to
  determine intended behavior; existing code may contain bugs.
- The system map is `00_HOME.md` in
  `~/Documents/restaurant-ops-vault/GLOBOSVN POS/`. `99_ARCHIVE/` is historical
  provenance, not an active specification.
- Keep source implementation, applied migrations, production deployment, and
  operational verification distinct. Source evidence proves only implementation.

## Data and Office compatibility

- Preserve the physical `restaurants` table and its `id`, `name`, `address`,
  and `is_active` columns: the Office app reads them directly. `stores` is the
  compatibility view; preserve physical `restaurant_id` foreign-key columns
  even when views expose `store_id` aliases.
- The Office app is `~/Documents/restaurant_office_app`. Modify it only when
  explicitly requested; POS schema changes must preserve its read contract.
- Brand, legal-entity, and store access uses `user_accessible_stores` and related
  RPCs. Preserve tenant and store access boundaries when changing data access.
- Authentication users and workforce employees are separate concepts;
  preserve their explicit mappings where required.

## Payments and operating times

- `process_payment` is the atomic single-order payment entry point. Determine
  its effective definition by migration order, not a fixed historical filename.
- `einvoice_jobs.ref_id` must be UUIDv7 with version 7 and proper variant bits.
- Payment completion must never depend on MISA availability; dispatch is async.
  MISA/meInvoice is the active e-invoice contract. Its portal handles invoice
  history, corrections, cancellations, and PDFs; POS opens `lookup_url`.
  Do not duplicate these portal features in POS.
  WeTax material in `docs/vendor/` and `docs/vendor/samples/` is historical.
- Supabase bytea values use `\x...` hex. Use `decodeByteaToString()` in Edge
  Functions, not `atob()`; see the vault's
  `90_REFERENCE/04_DECISIONS_AND_INVARIANTS.md` for the contract.
- General daily cash close is 23:00 Asia/Ho_Chi_Minh. Restaurant order cutoff
  is 21:30, grace ends at 21:45, and finalization is 22:20; these are separate
  operating contracts.

## Retired integrations

- **Deliberry is retired by the owner's 2026-10-05 decision.** Do not accept,
  dispatch, reprocess, or generate new Deliberry settlements. Preserve historical
  sales/settlement records and their read contracts. `generate-settlement` and
  `generate_delivery_settlement` return HTTP 410; retain those endpoints.
  Reactivation requires a new explicit owner decision and migration.
- **Photo Objet automatic sales collection is permanently retired.** No active
  collection schedule, backfill, recovery, slot-health monitor, collection alert,
  or Photo-specific release gate is permitted. Preserve historical data and
  migrations; current Photo sales enter only through Super Admin Excel import.
  Missing historical Photo collection slots are not release failures and must
  not create alerts or block POS deployment. Reintroduction requires an explicit
  new user decision, a migration removing the retirement guard, and a new ADR.

## Verification and release

- Run checks relevant to the change and its risk. Documentation-only edits need
  document and diff validation; a full app build is not required.
- Full repository verification: `bash scripts/check_repo.sh`.
- Static analysis used by that script: `dart analyze --fatal-infos`.
- Flutter tests: `flutter test` (or the relevant test files for focused checks).
- Format changed Dart files: `dart format <files>`.
- Production release must use `scripts/deploy_pos_production.sh`; do not bypass
  it. Local checks and reviews are preflight evidence. The release gate passes
  only when required GitHub Actions checks succeed on the exact pushed head SHA.
- Deployment procedure: `docs/pos/POS_PRODUCTION_DEPLOYMENT_RUNBOOK.md`.
- For a requested Claude Code handoff, write the prompt in English with the goal,
  relevant files, and verification steps. Apply a requested harness when available.
