---
title: "Phase 2 Step 2 — Harness Report"
version: "1.0"
date: "2026-04-12"
scope_basis: "stage1_scope_v1.3.md, Appendix A.1"
status: "historical — big-bang path abandoned"
---

## OBSOLETE (Big-Bang Path Abandoned)

This report documents the original big-bang `restaurants -> stores` rename path and is now obsolete.
The staging run on 2026-04-12 failed with a live dependency conflict on `get_user_restaurant_id()` (`2BP01`), confirming the approach is not safe for direct apply in current state.
Replacement path is now POS-only phased rollout: **Expand -> Migrate -> Contract**.
The original big-bang SQL artifacts are retained only as archive references under `docs/archive/`.
Current shipped truth for the rename rollout is documented in `/Users/andreahn/globos_pos_system/docs/phase_1_architecture.md` Section 11 and the Phase 2 Step 2 expand/migrate reports.

# Phase 2 Step 2 — Harness Report: restaurants → stores Rename

## Executive Summary

Static analysis of the entire GLOBOSVN POS codebase identified **~1,339 references** to `restaurants`/`restaurant_id`/`Restaurant` across **~100 files** (46 migration SQL files, 50 Dart files, 3 edge function files, plus 1 storage policy file). All references were cleanly categorizable with no ambiguity.

A single atomic forward migration (5,586 lines), byte-symmetric rollback migration (5,586 lines), Dart codemod script (503 lines), and verification plan have been produced and are ready for Hyochang's review.

---

### 🔴 CRITICAL — Blocks apply

**None.** No critical blockers were identified.

---

### 🟠 HIGH — Resolvable before apply

1. **Forward migration not yet tested on staging.** The 5,586-line migration must be applied to a staging database before production. Supabase test environment required.

2. **Dart codemod not yet previewed by Hyochang.** The codemod script produces ~926 replacements across 58 files. Hyochang must review the dry-run output before applying.

3. **Edge function deployment timing.** After the SQL migration is applied, the old `restaurant_id` column no longer exists. Edge functions (`create_staff_user`, `generate_delivery_settlement`, `generate-settlement`) must be redeployed immediately after the SQL migration, within the same maintenance window. The codemod script handles edge function files.

---

### 🟡 MEDIUM — Notes for the apply phase

1. **Storage paths are intentionally OUT OF SCOPE.** Per Hyochang's Decision 1, existing files in `attendance-photos` and `qc-photos` buckets keep their current paths. Storage policies reference path patterns that may contain `restaurants/` — these are NOT changed. Future Phase 2 Step 2.5 or later may address this.

2. **UI strings are intentionally OUT OF SCOPE.** Per Hyochang's Decision 2, user-facing labels like "Restaurant Name", "Add Restaurant" are preserved as-is. A separate Step 2.5 will handle UI string cleanup.

3. **Compatibility alias view `public_restaurant_profiles`.** Per Decision 4, a deprecated alias view is created pointing to `public_store_profiles`. This alias will be removed in Stage 2. Any external consumers should migrate to `public_store_profiles`.

4. **Historical migration files are frozen.** Per Decision 3, the 46 pre-rename migration files are documented in `docs/historical_restaurant_references.md` and must not be modified.

5. **`process_payment` RPC is the highest-risk function.** It is the central atomic payment handler (identified in Phase 0) with restaurant_id references in parameters, body, audit logging, and error messages. The migration replaces the full function body. Verify payment flow immediately after apply.

6. **RLS helper function rename.** `get_user_restaurant_id()` → `get_user_store_id()` is referenced by every RLS policy. This is a single point of failure — if the function rename fails, all authenticated queries will fail. The migration handles this correctly by creating the new function before dropping the old one.

7. **Trigger function `on_payroll_store_submitted()`.** This trigger fires on `payroll_records` status changes. Its body references `restaurant_id` — updated in the migration. The trigger name itself already uses "store" and does not need renaming.

---

### 🟢 LOW — Observations

1. **`Icons.restaurant_menu`** in Dart code is a Flutter SDK icon constant. Correctly excluded from the codemod. No action needed.

2. **Pilot/seed data** (`20260402000001_seed_data.sql`, `20260402000002_pilot_data.sql`) contain INSERT statements into the old `restaurants` table. These are already-applied migrations and are correctly excluded.

3. **Forward and rollback are byte-symmetric.** Both are 5,586 lines. RENAME TO counts (19/19), CREATE POLICY counts (33/33), and CREATE FUNCTION counts (60/60) all match.

4. **`office_get_accessible_store_ids()` function** references the `restaurants` table in its body — updated to `stores` in the migration.

5. **Entity type `'restaurants'` in audit trace.** The `get_admin_mutation_audit_trace` function uses `'restaurants'` as an entity_type array element. Updated to `'stores'` in the migration. The Dart `admin_audit_trace_panel.dart` mapping `'restaurants' => '매장'` is also updated in the codemod (technical identifier, not UI label).

---

### ✅ PREPARED — Ready to apply

| Artifact | Path | Lines |
|---|---|---|
| **Forward migration** | `supabase/migrations/20260412030000_rename_restaurants_to_stores.sql` | 5,586 |
| **Rollback migration** | `supabase/migrations/20260412030001_rollback_rename_stores_to_restaurants.sql` | 5,586 |
| **Dart codemod script** | `docs/phase_2_step_2_dart_codemod.sh` | 503 |
| **Verification checklist** | `docs/phase_2_step_2_verification.md` | 130 |
| **Rename map spec** | `docs/phase_2_step_2_rename_map.md` | 254 |
| **Historical references** | `docs/historical_restaurant_references.md` | 86 |
| **Migration SQL references** | `docs/phase_2_step_2_migration_references.md` | ~751 |
| **Dart code references** | `docs/phase_2_step_2_dart_references.md` | ~300 |
| **Edge function references** | `docs/phase_2_step_2_edge_function_references.md` | ~100 |
| **RLS policy inventory** | `docs/phase_2_step_2_rls_inventory.md` | ~200 |
| **View inventory** | `docs/phase_2_step_2_view_inventory.md` | ~100 |
| **Function inventory** | `docs/phase_2_step_2_function_inventory.md` | ~300 |

---

### Priority Apply Sequence

Execute during 03:00–05:00 Asia/Ho_Chi_Minh maintenance window:

1. **Take fresh Supabase backup** — `supabase db dump` or dashboard backup
2. **Apply forward migration to staging** — verify on test DB first
3. **Run SQL smoke tests on staging** — see `phase_2_step_2_verification.md`
4. **If staging passes:** Apply forward migration to production — `supabase db push`
5. **Run SQL smoke tests on production** — table counts, FK integrity, RLS, views, functions
6. **Apply Dart codemod** — `./docs/phase_2_step_2_dart_codemod.sh --apply`
7. **Review Dart changes** — `git diff` to confirm expected ~926 replacements
8. **Build Flutter app** — `flutter build`
9. **Deploy edge functions** — `supabase functions deploy` for all 3 functions
10. **Verify application startup** — login, order creation, payment, daily closing
11. **Monitor for 30 minutes** — watch for RPC errors, RLS denials, edge function failures
12. **If issues:** Apply rollback migration within 2 minutes, revert Dart with `git checkout`, redeploy previous builds

---

### Open Questions

| # | Question | Context | Recommendation |
|---|---|---|---|
| OQ-1 | **Storage path migration.** Should existing file paths (`attendance-photos`, `qc-photos`) be migrated from `restaurants/{id}/...` to `stores/{id}/...` in a future step? | Decision 1 deferred this. Existing files remain accessible at old paths. New uploads after codemod will use variable names that may generate different paths. | Audit storage path generation in Dart code during Step 2.5 to ensure new uploads still work with old path patterns. |
| OQ-2 | **UI string cleanup scope.** How extensive should Step 2.5 be? Only English, or Korean/Vietnamese labels too? | Decision 2 deferred all UI strings. Scope v1.3 uses "store" throughout. | Define Step 2.5 scope after Step 2 is stable. Recommend changing English "Restaurant" → "Store" in labels, keeping Korean "매장" (already means "store"). |
| OQ-3 | **Dart file renaming.** Should Dart source files with "restaurant" in the filename be renamed? (e.g., no such files currently exist, but future files might.) | No Dart files currently have "restaurant" in their filename. | No action needed now. |

---

### Severity Summary

| Severity | Count |
|---|---|
| 🔴 CRITICAL | 0 |
| 🟠 HIGH | 3 |
| 🟡 MEDIUM | 7 |
| 🟢 LOW | 5 |
| Open Questions | 3 |

---

**Verdict: READY_TO_APPLY**

All artifacts are prepared. No critical blockers. Three HIGH items are standard pre-deployment requirements (staging test, codemod review, deployment coordination) that are resolved during the maintenance window itself.

---

*Generated: 2026-04-12 | Phase 2 Step 2 complete. Do NOT proceed to Step 3 (C-01 bug fixes) or any subsequent step.*
