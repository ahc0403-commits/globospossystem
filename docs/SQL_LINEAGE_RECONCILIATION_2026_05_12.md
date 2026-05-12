# SQL Lineage Reconciliation — 2026-05-12

## Executive Verdict

The reflected schema baseline is now repaired, but SQL lineage still needed a provenance pass for quarantined local SQL artifacts. This reconciliation concludes that two missing historical migrations should be restored to tracked source control, while the remaining local SQL artifacts must stay out of tracked migration lineage for now.

## Current Repo Truth

- Branch during reconciliation: `codex/sql-lineage-provenance-repair`
- Baseline `schema.sql`: tracked and non-empty after PR `#105`
- Current HEAD before this slice: `f20868c602c11b84db289675b8ebb7abaf7bcdb8`
- Remote-linked migration ledger confirmed with `supabase migration list`

## Key Findings

### 1. `20260428000002_vat_pricing_mode.sql`

Verdict: `RESTORE_AS_TRACKED_HISTORICAL_MIGRATION`

Why:
- `supabase/schema.sql` contains `restaurants.vat_pricing_mode`.
- `supabase/schema.sql` contains the six-argument `admin_update_restaurant_settings(..., p_vat_pricing_mode text)` signature.
- The remote migration ledger contains `20260428000002`.
- The local tracked repo was missing the corresponding migration file.

Important nuance:
- The `process_payment` and `request_red_invoice` bodies inside this file are not the final active versions in current schema truth.
- However, this file still represents a real historical migration that contributed canonical schema state and exists in the remote ledger.

### 2. `20260428000004_disable_photo_objet_red_invoice.sql`

Verdict: `RESTORE_AS_TRACKED_HISTORICAL_MIGRATION`

Why:
- The remote migration ledger contains `20260428000004`.
- `supabase/schema.sql` contains `RED_INVOICE_DISABLED_FOR_PHOTO_OBJET`.
- The local tracked repo was missing the corresponding migration file.

Important nuance:
- The current tracked repo already includes `20260428000007_switch_red_invoice_to_request_einvoice_info.sql`, which also carries the Photo Objet red-invoice disable path in the active `request_red_invoice` function lineage.
- Even so, `20260428000004` still belongs in tracked history because it exists in the remote ledger and represents an intermediate canonical step.

### 3. `20260428000006_restore_wt03_feature_payload.sql`

Verdict: `DO_NOT_RESTORE_AS_TRACKED_MIGRATION`

Why:
- The remote migration ledger does **not** contain `20260428000006`.
- The schema traits it tries to restore, including `feature`, `seq`, and `item_code` inside the WT03 payload, are already reflected in current `supabase/schema.sql`.
- Those payload semantics are already represented through earlier tracked `process_payment` lineage, especially:
  - `20260413034142_phase_2_step_7_fix_wt03_payload_format.sql`
  - `20260414000022_contract_store_naming_buffet_order.sql`

Conclusion:
- This file is a local-only superseded artifact, not a missing canonical migration.
- Restoring it as a tracked migration would create a false lineage step because the remote ledger never accepted this version.

### 4. `vui_vui_food_inclusive_validation.sql`

Verdict: `KEEP_AS_SNIPPET_REFERENCE_ONLY`

Why:
- The file contains validation, seeding, and scenario-driving SQL for inclusive VAT checks.
- It is not a canonical migration step.
- It mixes fixture/bootstrap behavior with validation behavior, so it should not enter tracked migrations as-is.

Conclusion:
- Keep it outside migration lineage.
- Reuse only as reference material if a future deterministic validation harness is created.

## Classification Table

| Artifact | Current status | Reflection status | Remote ledger status | Recommended action |
| --- | --- | --- | --- | --- |
| `20260428000002_vat_pricing_mode.sql` | Missing from tracked repo | Reflected / partially superseded | Present | Restore as tracked historical migration |
| `20260428000004_disable_photo_objet_red_invoice.sql` | Missing from tracked repo | Reflected / later superseded in active function lineage | Present | Restore as tracked historical migration |
| `20260428000006_restore_wt03_feature_payload.sql` | Quarantined local-only WIP | Reflected elsewhere | Absent | Do not restore as migration |
| `vui_vui_food_inclusive_validation.sql` | Quarantined snippet | Reference-only | N/A | Keep as snippet only |

## Explicit No-Go Items

- Do not apply `20260428000002` or `20260428000004` again to any database.
- Do not restore `20260428000006` into `supabase/migrations/`.
- Do not promote `vui_vui_food_inclusive_validation.sql` into tracked migrations.
- Do not claim migration ledger parity is fully solved by this slice alone.

## Scope of This Reconciliation Slice

This slice is intentionally limited to:

- restoring missing historical migration source files that are already proven by remote ledger plus reflected schema truth
- documenting why the remaining quarantined SQL artifacts are not safe tracked-migration candidates

This slice does **not**:

- mutate runtime Flutter code
- mutate schema by hand
- apply migrations
- alter Supabase remote state

## Next Recommended Action

After this slice, the next SQL truth task should be a narrower follow-up audit that answers one remaining question:

- whether the broader local-vs-remote migration ledger drift outside these quarantined files should be normalized through documentation only, source restoration, or a formal migration lineage ADR

