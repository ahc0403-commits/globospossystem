# Stale Contract Truth Audit — 2026-05-12

## Verdict

Two remaining quarantined contract tests can be classified as stale against
tracked truth without restoring them into the repo:

- `test/staff_account_role_guard_contract_test.dart`
- `test/table_layout_model_contract_test.dart`

Neither file should be restored as a live test candidate in the current phase.

## Baseline

- Branch at time of audit: `audit/stale-contract-truth-audit`
- Tracked repo state:
  - `git status --short`: clean before this docs-only change
  - `flutter analyze`: PASS
  - `flutter test`: PASS
- Scope:
  - docs-only audit
  - no test restoration
  - no runtime Flutter changes
  - no SQL migration changes

## File 1: `test/staff_account_role_guard_contract_test.dart`

### Quarantined expectation

The test asserts that tracked SQL must contain:

```text
v_target.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin', 'photo_objet_master', 'photo_objet_store_admin')
```

### Tracked source of truth

Tracked SQL file:

- `/Users/andreahn/globos_pos_system/supabase/migrations/20260414000013_contract_store_naming_active_paths.sql`

Observed tracked condition:

```text
v_target.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin', 'photo_objet_master')
```

### Conclusion

The quarantined test is stale against tracked SQL.

Specifically:

- tracked SQL includes `photo_objet_master`
- tracked SQL does **not** include `photo_objet_store_admin` in the asserted guard

That means the test currently checks for a broader role set than the tracked
migration actually encodes.

### Restore decision

- `NO-RESTORE`
- classify as: `stale_against_tracked_sql`

## File 2: `test/table_layout_model_contract_test.dart`

### Quarantined expectation

The test expects tracked `PosTable` parsing support for layout fields:

- `layoutX`
- `layoutY`
- `layoutW`
- `layoutH`
- `layoutRotation`
- `layoutShape`
- `layoutSortOrder`

It also expects enum support such as `PosTableShape.round`.

### Tracked source of truth

Tracked model file:

- `/Users/andreahn/globos_pos_system/lib/core/models/pos_table.dart`

Observed tracked model:

- fields present:
  - `id`
  - `storeId`
  - `tableNumber`
  - `seatCount`
  - `status`
- helper present:
  - `isOccupied`
- layout fields:
  - **not present**
- layout enum:
  - **not present**

### Conclusion

The quarantined test is stale against the tracked model.

This is not an ambiguous runtime dependency question. The tracked model simply
does not expose the layout API the test expects.

### Restore decision

- `NO-RESTORE`
- classify as: `stale_against_tracked_model`

## Combined Interpretation

These two files should now move out of the “possible restore candidates” lane.

They are better treated as one of:

1. rewrite candidates
2. archive candidates
3. historical evidence of abandoned contract expectations

## Queue Impact

After this audit, the quarantined contract-test set has even fewer realistic
restore candidates.

Confirmed stale-against-tracked-truth files now include:

- `test/daily_closing_role_contract_test.dart`
- `test/order_mutation_role_contract_test.dart`
- `test/staff_account_role_guard_contract_test.dart`
- `test/table_layout_model_contract_test.dart`

## Next Safe Action

Stay in docs-only audit mode.

The next safest contract-test audit target is:

- `test/inventory_scope_contract_test.dart`

Reason:

- it is still unresolved on provenance grounds
- it should be classified explicitly as either
  `sql/runtime_lineage_blocked` or `stale_against_current_truth`

## Explicit Non-Action

- No quarantined test file was restored in this audit.
- No runtime Flutter file was restored.
- No SQL migration or snippet was restored.
- No asset or config file was restored.
- No commit was created from any quarantined test file in this step.
