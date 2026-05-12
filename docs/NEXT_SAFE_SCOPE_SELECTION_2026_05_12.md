# Next Safe Scope Selection — 2026-05-12

## Baseline

- branch: `audit/next-quarantined-wip-slice`
- clean repo status: `PASS`
- tracked baseline health:
  - `flutter analyze`: `PASS`
  - `flutter test`: `PASS`
- quarantined WIP root:
  - `/Users/andreahn/globos_pos_system_untracked_wip_2026_05_12`

## Selected Scope

- `docs-only`

## Why This Scope Was Selected

- It is the only scope that can move forward without reintroducing quarantined runtime, SQL, or test drift into the clean tracked repository.
- It preserves the current `main` health guarantees while still producing a complete, reviewable PR candidate.
- It records the next recovery decision explicitly, which reduces ambiguity before any future restore attempt.

## Restored / Applied Files

- `docs/NEXT_SAFE_SCOPE_SELECTION_2026_05_12.md`

No quarantined files were restored for this scope.

## Why Other Scopes Were Excluded

### Config-only

- `.vercelignore` has already been restored, merged, and validated.
- There is no remaining config-only slice that is equally low risk.

### Contract-test-only

- Contract tests still need dependency-class review before restoration.
- Many tests assert behavior that depends on quarantined runtime files or unresolved SQL lineage.
- Restoring them now risks turning a clean baseline red again.

### SQL-only

- Quarantined SQL migrations remain provenance-sensitive.
- They touch `process_payment(...)`, `request_red_invoice(...)`, VAT mode, and WT03 payload behavior.
- They must not be restored without schema reflection and migration-order reconciliation.

### Flutter-runtime-only

- Quarantined runtime files remain unmounted or unresolved.
- Their provider, router, admin-shell, and shared UI primitive boundaries are not yet proven safe.

### Asset-only

- Remaining font files are not safe as a standalone restore slice.
- They need explicit asset wiring and consumer scope before re-entry.

## Validation Commands

```bash
flutter analyze
flutter test
```

## Commit Boundary

This scope is safe as a single docs-only commit because it:

- does not modify runtime Flutter code
- does not modify SQL migrations or snippets
- does not restore quarantined tests
- does not touch assets/fonts
- does not reopen implementation work

## Result

- selected scope: `docs-only`
- restore performed: `no`
- safe to commit after validation: `yes`

## Next Action After This PR

Return to audit mode for the quarantined `CONTRACT_TEST_AUDIT` slice.

That next step should:

1. split quarantined contract tests by dependency class
2. identify tests that depend on quarantined runtime files
3. identify tests that depend on unresolved SQL / RPC / RLS lineage
4. restore nothing until those classes are separated
