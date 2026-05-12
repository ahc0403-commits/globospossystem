# Quarantined SQL / Snippet Status — 2026-05-12

## Verdict

No quarantined SQL or snippet file is approved for restore or apply.

At the current tracked `main` truth boundary, all four remaining SQL-adjacent
quarantined files must stay outside the repo runtime path:

- `20260428000002_vat_pricing_mode.sql`
- `20260428000004_disable_photo_objet_red_invoice.sql`
- `20260428000006_restore_wt03_feature_payload.sql`
- `vui_vui_food_inclusive_validation.sql`

## Baseline

- Branch at time of audit: `audit/quarantined-sql-snippet-status`
- Tracked repo state:
  - `git status --short`: clean before this docs-only change
  - `flutter analyze`: PASS
  - `flutter test`: PASS
- Scope:
  - docs-only audit
  - no SQL restoration
  - no SQL execution
  - no runtime Flutter restore

## Inventory

Quarantined files:

- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/supabase/migrations/20260428000002_vat_pricing_mode.sql`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/supabase/migrations/20260428000004_disable_photo_objet_red_invoice.sql`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/supabase/migrations/20260428000006_restore_wt03_feature_payload.sql`
- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/supabase/snippets/vui_vui_food_inclusive_validation.sql`

## File 1: `20260428000002_vat_pricing_mode.sql`

### What it tries to do

- add `restaurants.vat_pricing_mode`
- rewrite `process_payment`
- rewrite `request_red_invoice`
- rewrite admin restaurant settings functions

### Why it is blocked

- it is untracked local-only SQL
- it touches central payment/einvoice lineage
- it overlaps with tracked payment contract history rather than extending it in a
  clearly incremental way
- restoring it without a trusted reflected schema / accepted migration history
  would be a blind lineage fork

### Current classification

- `NO-RESTORE`
- `NO-APPLY`
- `local_only_core_payment_lineage`

## File 2: `20260428000004_disable_photo_objet_red_invoice.sql`

### What it tries to do

- rewrite `request_red_invoice`
- hard-disable red invoice requests for a specific `Photo Objet` brand path

### Why it is blocked

- it is untracked local-only SQL
- it overlaps with tracked red-invoice behavior already discussed in prior
  provenance audits
- it changes central invoice request behavior without establishing precedence
  against tracked migration history

### Current classification

- `NO-RESTORE`
- `NO-APPLY`
- `overlap_with_tracked_red_invoice_lineage`

## File 3: `20260428000006_restore_wt03_feature_payload.sql`

### What it tries to do

- rewrite `process_payment`
- restore WT03-style product payload fields such as:
  - `feature`
  - `seq`
  - `item_code`
  - `item_name`

### Why it is blocked

- it is untracked local-only SQL
- it rewrites the same payment anchor touched by file `00002`
- it sits in the most sensitive part of the POS-WeTax integration boundary
- restoring it would implicitly choose one payload lineage without resolving the
  larger provenance dispute

### Current classification

- `NO-RESTORE`
- `NO-APPLY`
- `wt03_payload_lineage_conflict`

## File 4: `vui_vui_food_inclusive_validation.sql`

### What it tries to do

- mutate restaurant VAT pricing mode
- insert/update demo restaurant data
- insert/update tables, menu categories, menu items, and auth users
- act as a validation / seed scenario for VAT-inclusive behavior

### Why it is blocked

- it is a snippet, not a tracked migration
- it is not a safe baseline artifact
- it performs direct data mutation and environment seeding
- it depends on the broader `vat_pricing_mode` lineage question already being
  settled

### Current classification

- `NO-RESTORE`
- `NO-APPLY`
- `validation_seed_snippet_only`

## Relationship To Current Tracked Truth

The tracked repo remains healthy:

- `flutter analyze`: PASS
- `flutter test`: PASS

That healthy state does **not** prove these quarantined SQL files are correct.
It only proves the tracked runtime is stable without them.

The quarantined SQL set therefore remains an external lineage concern, not an
implementation-ready slice.

## Consequence

After the contract-test queue audits, the remaining substantive unresolved WIP
axis is now concentrated here:

1. quarantined SQL migration provenance
2. quarantined runtime Flutter provenance

The SQL side is still the riskier of the two because it touches payment,
e-invoice, VAT, and seeded data behavior.

## Next Safe Action

Stay in docs-only / provenance mode.

The safest next step is not to restore these files. Instead:

1. keep them quarantined
2. treat them as reference-only lineage artifacts
3. if future work is needed, design a fresh tracked reconciliation plan rather
   than restoring any of these files verbatim

## Explicit Non-Action

- No quarantined SQL file was restored.
- No snippet was restored.
- No migration was applied.
- No data mutation was executed.
- No runtime Flutter file was restored.
- No commit was created from any quarantined SQL file in this step.
