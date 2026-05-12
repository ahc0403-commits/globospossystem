# Contract Test Manual Review Queue — 2026-05-12

## Verdict

No quarantined `manual_review_required` contract test is approved for restore yet.

This subgroup is still safer than the quarantined runtime and SQL slices, but it
must be split further before any test file is restored into the tracked repo.

## Baseline

- Branch at time of review: `audit/manual-review-contract-tests`
- Tracked repo state before review:
  - `git status --short`: clean
  - `flutter analyze`: PASS
  - `flutter test`: PASS
- Scope of this review:
  - manual-review subset from
    [CONTRACT_TEST_DRIFT_MATRIX_2026_05_12.md](/Users/andreahn/globos_pos_system/docs/CONTRACT_TEST_DRIFT_MATRIX_2026_05_12.md)
  - no runtime Flutter restore
  - no SQL migration restore
  - no snippet restore

## Manual Review Subset

| Quarantined file | Dependency class | Current finding | Restore status |
| --- | --- | --- | --- |
| `test/daily_closing_role_contract_test.dart` | tracked SQL only | Reads tracked migration `20260414000019_contract_store_naming_daily_closing_admin_audit.sql`; likely valid static contract candidate | Hold pending direct isolated restore |
| `test/inventory_scope_contract_test.dart` | SQL/runtime provenance | Inventory scope assertions sit too close to unresolved SQL/runtime lineage | Keep quarantined |
| `test/order_mutation_role_contract_test.dart` | tracked SQL only | Reads tracked migrations `20260414000015` and `20260414000022`; plausible static contract candidate | Hold pending direct isolated restore |
| `test/staff_account_role_guard_contract_test.dart` | tracked SQL drift | Expects role strings not fully aligned with tracked `20260414000013_contract_store_naming_active_paths.sql` | Keep quarantined |
| `test/table_layout_model_contract_test.dart` | tracked model drift | Expects `PosTable` layout fields that current tracked `/lib/core/models/pos_table.dart` does not expose | Keep quarantined |

## Evidence

### `test/daily_closing_role_contract_test.dart`

- Reads only tracked SQL:
  - `/Users/andreahn/globos_pos_system/supabase/migrations/20260414000019_contract_store_naming_daily_closing_admin_audit.sql`
- Does not import quarantined runtime files.
- Main risk:
  - still unverified as an isolated restore, so it remains a candidate, not an approved slice.

### `test/inventory_scope_contract_test.dart`

- Classified as manual review earlier, but inventory scope remains tied to unresolved
  inventory runtime and SQL provenance.
- Main risk:
  - false confidence if restored before the inventory lineage question is settled.

### `test/order_mutation_role_contract_test.dart`

- Reads only tracked SQL:
  - `/Users/andreahn/globos_pos_system/supabase/migrations/20260414000015_contract_store_naming_order_mutations.sql`
  - `/Users/andreahn/globos_pos_system/supabase/migrations/20260414000022_contract_store_naming_buffet_order.sql`
- Does not import quarantined runtime files.
- Main risk:
  - role-string expectations still need an isolated real test run before approval.

### `test/staff_account_role_guard_contract_test.dart`

- Reads tracked SQL:
  - `/Users/andreahn/globos_pos_system/supabase/migrations/20260414000013_contract_store_naming_active_paths.sql`
- Drift already visible from static comparison:
  - quarantined test expects `photo_objet_store_admin`
  - tracked SQL contains `photo_objet_master` but not the wider role set asserted by the test
- Conclusion:
  - treat as stale against tracked SQL until rewritten or archived.

### `test/table_layout_model_contract_test.dart`

- Imports tracked model:
  - `/Users/andreahn/globos_pos_system/lib/core/models/pos_table.dart`
- Drift already visible from static comparison:
  - quarantined test expects `layoutX`, `layoutY`, `layoutW`, `layoutH`,
    `layoutRotation`, `layoutShape`, and `layoutSortOrder`
  - tracked `PosTable` exposes none of those layout fields
- Conclusion:
  - treat as stale against tracked model until rewritten or archived.

## Safe Split Recommendation

Do not restore all five files together.

Split them into two follow-up lanes:

1. Static tracked-SQL candidates
   - `test/daily_closing_role_contract_test.dart`
   - `test/order_mutation_role_contract_test.dart`
   - These are the smallest plausible restore candidates because they read only
     tracked migration files.

2. Hold / rewrite / archive candidates
   - `test/inventory_scope_contract_test.dart`
   - `test/staff_account_role_guard_contract_test.dart`
   - `test/table_layout_model_contract_test.dart`
   - These already show unresolved provenance or direct drift against tracked truth.

## Next Safe Action

Stay in audit mode.

The next safest technical step is a one-file or two-file isolated restore trial
for the static tracked-SQL candidates only:

- `test/daily_closing_role_contract_test.dart`
- `test/order_mutation_role_contract_test.dart`

Everything else in this subgroup should remain quarantined until it is either:

- rewritten to match tracked truth
- archived as obsolete
- or unblocked by an explicit future runtime / SQL lineage decision

## Explicit Non-Action

- No quarantined file was restored in this review.
- No runtime Flutter file was restored.
- No SQL migration or snippet was restored.
- No asset or config file was restored.
- No commit was created from any quarantined test file in this review.
