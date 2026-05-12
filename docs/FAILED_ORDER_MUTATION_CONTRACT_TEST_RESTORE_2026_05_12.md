# Failed Order Mutation Contract Test Restore — 2026-05-12

## Verdict

FAIL — `test/order_mutation_role_contract_test.dart` is not safe to restore yet.

This file appeared to be the second-best quarantined tracked-SQL-only contract
candidate, but the assertions are stale against current tracked migration
content.

## Attempted Scope

- restored file:
  - `/Users/andreahn/globos_pos_system/test/order_mutation_role_contract_test.dart`
- source quarantine:
  - `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/order_mutation_role_contract_test.dart`

## Validation Result

- `flutter analyze`: PASS
- targeted test:
  - `flutter test test/order_mutation_role_contract_test.dart`: FAIL
- full baseline after removal:
  - `flutter analyze`: PASS
  - `flutter test`: PASS

## Failure Summary

The test expects tracked SQL to contain broader role gates including
`brand_admin`, for example:

```text
v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'brand_admin', 'super_admin')
```

Observed tracked SQL instead contains narrower order-mutation role gates such as:

```text
IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
```

The targeted test failed on the first such expectation.

## Tracked SQL Evidence

Order mutation migration:

- `/Users/andreahn/globos_pos_system/supabase/migrations/20260414000015_contract_store_naming_order_mutations.sql`

Buffet mutation migration:

- `/Users/andreahn/globos_pos_system/supabase/migrations/20260414000022_contract_store_naming_buffet_order.sql`

Static scan results during the restore attempt showed:

- `20260414000015` contains repeated waiter/admin/store_admin/super_admin gates
- it does **not** contain the expected waiter/admin/store_admin/brand_admin/super_admin gate
- `20260414000022` does include a broader `cashier/admin/store_admin/brand_admin/super_admin` gate in one path, but not the exact order-mutation gate asserted by the test

## Interpretation

This is not a runtime or dependency failure.

It is another tracked-SQL expectation drift failure:

- the test restores cleanly
- the repo still analyzes cleanly
- the assertion does not match tracked migration truth

## Recovery

The restored test file was moved back out of the repo.

Failed-restore quarantine path:

- `/Users/andreahn/globos_pos_system_failed_contract_test_slice_2026_05_12/test/order_mutation_role_contract_test.dart`

Original quarantine copy remains preserved at:

- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/order_mutation_role_contract_test.dart`

## Baseline After Recovery

- `git status --short`: clean
- `flutter analyze`: PASS
- `flutter test`: PASS

## Consequence For The Queue

This result closes the two smallest tracked-SQL-only restore candidates as
immediate restore options:

- `test/daily_closing_role_contract_test.dart` → stale against tracked SQL
- `test/order_mutation_role_contract_test.dart` → stale against tracked SQL

That means the remaining quarantined contract-test queue should now be treated
primarily as:

1. rewrite candidates
2. archive candidates
3. runtime / SQL lineage dependent candidates

## Next Safe Action

Do not continue blind restore trials from the quarantined contract-test set.

The safer next move is docs-only again:

- update the contract-test drift evidence to reflect that both tracked-SQL-only
  candidates have now failed isolated restore validation
- then choose whether to audit `staff_account_role_guard` or
  `table_layout_model` as explicit stale-against-tracked-truth cases
