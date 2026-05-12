# Inventory Scope Contract Truth Audit — 2026-05-12

## Verdict

`test/inventory_scope_contract_test.dart` should not be restored.

It is stale against the currently tracked inventory active-path migration.

This file was previously left in a `manual_review_required` / provenance-gray
area, but direct comparison against tracked SQL shows that its core expectation
is already false in the current repo truth.

## Baseline

- Branch at time of audit: `audit/inventory-scope-provenance`
- Tracked repo state:
  - `git status --short`: clean before this docs-only change
  - `flutter analyze`: PASS
  - `flutter test`: PASS
- Scope:
  - docs-only audit
  - no test restoration
  - no runtime Flutter restore
  - no SQL migration restore

## Quarantined Test Expectation

Quarantined source:

- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/inventory_scope_contract_test.dart`

The test expects both of the following to be true for:

- `/Users/andreahn/globos_pos_system/supabase/migrations/20260414000017_contract_store_naming_inventory_active_paths.sql`

Expected assertions:

1. legacy direct scope check must be absent

```text
v_actor.restaurant_id <> p_store_id
```

2. accessible-store scope path must appear at least 10 times

```text
FROM public.user_accessible_stores(auth.uid()) s(store_id)
```

## Tracked SQL Evidence

Direct scan of tracked `20260414000017_contract_store_naming_inventory_active_paths.sql`
showed:

- `accessible_store_matches = 0`
- `legacy_restaurant_scope_matches = 10`

Observed legacy matches include lines such as:

```text
AND v_actor.restaurant_id <> p_store_id THEN
```

at multiple positions in the tracked migration.

## Interpretation

This is not merely “inventory provenance is unresolved.”

For this specific test, tracked repo truth is already enough to classify it:

- the test expects the legacy `restaurant_id` direct-scope guard to be gone
- the tracked migration still contains that legacy guard many times
- the test expects broad `user_accessible_stores(...)` usage
- the tracked migration contains zero matches for that exact path

So the test is stale against tracked SQL truth.

## Relationship To Broader Inventory Provenance

Inventory lineage is still a sensitive area overall:

- quarantined inventory-purchase runtime files remain outside the repo
- inventory purchase migrations in the quarantined set remain unresolved
- newer tracked inventory purchase migrations do exist in `20260506*`

However, those broader lineage questions are not needed to classify this file.

This test already fails at the level of tracked migration content.

## Restore Decision

- `NO-RESTORE`
- classification: `stale_against_tracked_inventory_sql`

## Queue Impact

After this audit, the previously ambiguous contract-test queue is narrower.

Confirmed stale-against-tracked-truth files now include:

- `test/daily_closing_role_contract_test.dart`
- `test/order_mutation_role_contract_test.dart`
- `test/staff_account_role_guard_contract_test.dart`
- `test/table_layout_model_contract_test.dart`
- `test/inventory_scope_contract_test.dart`

## Next Safe Action

Stay in docs-only audit mode.

The next best move is not another contract-test restore trial. Instead:

1. update the higher-level contract-test queue evidence to reflect that the
   remaining obvious restore candidates have collapsed into stale/drift status
2. shift focus to unresolved quarantined SQL/snippet provenance or to explicit
   archive/rewrite planning for the remaining tests

## Explicit Non-Action

- No quarantined test file was restored in this audit.
- No runtime Flutter file was restored.
- No SQL migration or snippet was restored.
- No asset or config file was restored.
- No commit was created from any quarantined test file in this step.
