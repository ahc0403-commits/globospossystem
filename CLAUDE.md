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

## Procurement owner contract (2026-10-13)

- New PRs use policy 3: requester -> Store Manager review/quantity adjustment/
  approval -> buyer final approval -> PO. BM approval is removed. Preserve
  historical policy-1/2 approvals and issued documents.
- PRs show the registered raw-material code as text below the item name.
  Procurement QR and automatic menu QR generation are not requested.
- Policy-3 receiving confirms inspected accepted quantities and posts stock
  atomically. Complete delivery is determined per original PO line and cumulative
  accepted receipts, never from a cancelled/transferred balance or header total.
- Generate immutable, price-free complete-delivery or discrepancy PDFs for
  suppliers. File creation/download does not establish supplier transmission;
  record the actual channel, recipient/evidence and file hash separately.
- Reserve shortages in the next PR, list them first with quantities and original
  PO references, and transfer the original unreceived balance only on new PO
  issuance. Preserve lineage and prevent duplicate reservations/stock/payment.

## Registered menu choices (owner correction 2026-10-20)

- JeonGabok registers one dish with S/L prices inside that menu. Customers tap
  that dish, then choose S or L. Admin, QR and direct-order catalogs show one
  dish, never two independently registered size menus.
- A parent owns `size_prices`; internal size-price projections retain existing
  sellable IDs solely for order/invoice/recipe compatibility and history.
  Changing the menu and its prices is one atomic registration operation.
- Preserve original prices, translations, VAT and immutable order snapshots.
  Never invent spice choices, prices or recipe multipliers. Unknown spiciness
  remains distinct from not spicy. Other stores keep their existing behavior.
- Menus may require noodles/rice selection (`meal_choices`). The parent and
  internal choice projections keep stable sellable IDs for each size/meal
  combination. Register choices through a real authenticated administrator so
  the existing approved invoice policy records the actual registering actor.
- Customer carts keep distinct choices, permit option/quantity edits and removal,
  and send orders only after explicit checkout.
- JeonGabok's QR active-order history keeps all current unpaid order lines,
  including served dishes, until payment closes the order. A ten-minute display
  version reset must not hide those lines during additional ordering.
- Carry the selected price's `menu_option_key` through carts and offline drafts;
  validate the complete batch and require reselection after a price edit.

## Payments and operating times

- **JeonGabok Binh Thanh has no checker (owner decision 2026-10-20).**
  the default for store `273b057e-3b69-46e3-93c1-6194c2802849` is kitchen completion ->
  assigned floor readiness -> customer service. Retire `jgbt_tray1`; do not
  provision or reactivate a checker for this store. Preserve its audit history,
  distinct stored floors 1F/2F/3F, and other stores' checker workflows. Queue
  `kitchen_direct_to_floor` is the source snapshot; tray quantity fields are
  compatibility projections, not evidence of a checker actor.
- BunsikClub defaults to kitchen -> tray -> floor. Store opening setup saves
  `restaurant_settings.kds_workflow` independently of paperless/printing mode.
  Only a super administrator can change it, after open orders and handoffs drain.
  Existing queue snapshots and JeonGabok's retired checker/floor labels remain intact.
- JeonGabok guest 1F/2F tables retain stored 2F/3F labels. Owner confirmed
  `jgbt_floor_1f` serves stored 2F and `jgbt_floor_2f` serves stored 3F.
  Keep this mapping after profile edits; render guest floor labels on KDS.
  Floor-direct beverages are enabled for this store.
- JeonGabok uses the active KDS revision/broadcast rollout. Kitchen completion
  invalidates the assigned stored floor directly; floor timers start at
  `kitchen_done`. Delivery/pickup preparation must not notify a table floor.
- JeonGabok kitchen item taps record cooking start only. The explicit floor
  handoff selection records `kitchen_done` and makes only that quantity ready
  and blinking on the assigned floor. Never alias cooking start to handoff.

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
- **Owner correction 2026-10-21:** completed actual sales remain reportable
  regardless of payment time. The owner decides final sales confirmation;
  legacy scheduled finalization results must not block reporting or claim an
  owner confirmation. Do not reactivate automatic 22:20 sales finalization.
  Daily cash closing and configured ordering hours are separate workflows;
  this reporting fix does not change their runtime behavior.
- **Customer delivery fees are disabled by the owner's 2026-10-12 decision.**
  Do not create delivery fee quotes, invoice mappings, order items (including
  zero-value placeholders), or supplemental delivery sales. New fee-free
  financials have no delivery fee item ID. Keep issued history and actual
  courier handoff records auditable; courier fares are outside POS sales.
  Invoice mappings with `effective_to = NULL` remain valid indefinitely.

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
  it. Complete local verification on the final candidate SHA and again on the
  clean freshly fetched exact `origin/main` release SHA, verify the remote push,
  and retain production Auth, migration, login and affected-feature checks.
  The official preflight directly runs `scripts/pos_local_release_gate.py`
  with `--kind exact-main`. It never accepts a supplied PASS receipt. The local
  Linux recipe preserves the full repository, browser authentication and SQL
  regression checks. See `docs/pos/local-verification/LOCAL_VERIFICATION.md`.
  Remote branch protection still requiring the Actions-app-bound
  `POS release contract` is a separate unresolved security-policy dependency;
  do not change it, publish substitute statuses, force merge or push a PR that
  starts remote tests without explicit authorization.
- Deployment procedure: `docs/pos/POS_PRODUCTION_DEPLOYMENT_RUNBOOK.md`.
- For a requested Claude Code handoff, write the prompt in English with the goal,
  relevant files, and verification steps. Apply a requested harness when available.

## Local verification and source storage (owner decision 2026-10-24)

GitHub stores commits and pushed source. Run automated verification locally,
including an isolated local container/VM when the required OS differs. Apply
`/Users/andreahn/.claude/CLAUDE.md` → “GitHub 저장과 로컬 자동 검증”.
GitHub Actions success and runner availability are not required evidence.
Keep all relevant tests, type checks, lint/analysis, builds, security/permission/
DB isolation, regressions and actual affected-feature checks. Bind commands,
environment, timestamps, exit codes and complete logs to the final code SHA;
distinguish candidate validation from a clean freshly fetched exact-main release.
Verify the remote pushed SHA and retain the official deployment and operational
checks. A missing/failed/skipped check is not PASS. Report remaining executable
or remote GitHub-check dependencies; do not bypass gates or provision CI runners.
