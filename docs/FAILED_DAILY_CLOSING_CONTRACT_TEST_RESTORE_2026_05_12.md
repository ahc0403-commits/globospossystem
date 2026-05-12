# Failed Daily Closing Contract Test Restore — 2026-05-12

## Verdict

FAIL — `test/daily_closing_role_contract_test.dart` is not safe to restore yet.

This file looked like the smallest quarantined contract-test candidate because
it reads only a tracked migration file, but the actual assertion is stale
against current tracked SQL.

## Attempted Scope

- restored file:
  - `/Users/andreahn/globos_pos_system/test/daily_closing_role_contract_test.dart`
- source quarantine:
  - `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/daily_closing_role_contract_test.dart`

## Validation Result

- `flutter analyze`: PASS
- targeted test:
  - `flutter test test/daily_closing_role_contract_test.dart`: FAIL
- full baseline after removal:
  - `flutter analyze`: PASS
  - `flutter test`: PASS

## Failure Summary

The test expects this exact SQL role gate string to appear four times:

```text
v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
```

Observed result during the targeted test:

- expected matches: `4`
- actual matches: `0`

## Tracked SQL Evidence

Test target:

- `/Users/andreahn/globos_pos_system/supabase/migrations/20260414000019_contract_store_naming_daily_closing_admin_audit.sql`

Current tracked SQL in that migration uses narrower gate checks such as:

```text
IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
```

That means the quarantined test is asserting a broader `store_admin` /
`brand_admin` contract than the tracked migration currently encodes.

## Interpretation

This is not a runtime dependency failure.

It is a tracked-SQL expectation drift failure:

- the test restores cleanly
- the repo still analyzes cleanly
- the targeted assertion is simply not true against tracked SQL

## Recovery

The restored test file was moved back out of the repo.

Failed-restore quarantine path:

- `/Users/andreahn/globos_pos_system_failed_contract_test_slice_2026_05_12/test/daily_closing_role_contract_test.dart`

Original quarantine copy remains preserved at:

- `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12/test/daily_closing_role_contract_test.dart`

## Baseline After Recovery

- `git status --short`: clean
- `flutter analyze`: PASS
- `flutter test`: PASS

## Next Safe Action

Do not retry this file immediately.

The next safer move is to test the other tracked-SQL-only candidate instead:

- `test/order_mutation_role_contract_test.dart`

This daily-closing test should stay out until one of the following happens:

1. the test is rewritten to match tracked SQL truth
2. the underlying SQL contract is intentionally changed in a separate audited SQL scope
3. the test is archived as obsolete
