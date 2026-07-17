# POS Operational Premium V2 Phase Gate

Date: 2026-06-11
Scope: Gate before Admin Tables Phase 1 and Inventory Phase 1.

## Gate Status

Admin Tables Phase 1 and Inventory Phase 1 may start only after the already
started V2 foundation slices satisfy these checks:

- Cashier consumes `PosAmountAnchor` with `PosNumericText.amountHero` for the
  dominant amount-due block.
- Cashier submit action consumes `PosActionTile` processing/offline states
  without changing `processPayment`, proof upload, receipt, red-invoice, or
  Office-related behavior.
- Waiter send-to-kitchen action consumes `PosActionTile` with processing and
  offline visual states while preserving the existing offline queue path.
- Kitchen remains on the approved bright high-contrast Option B, not a dark KDS
  board.
- VND remains the only currency symbol in runtime code.
- Fixed system copy remains l10n-backed. Registered menu/product/table names
  remain data-driven.

## Web Tabular-Figure Evidence

The Phase 0 numeric contract uses `FontFeature.tabularFigures` in
`PosNumericText`. Before continuing into the next visual slices, run the web
widget test so the same token contract is exercised by the Flutter web test
target:

```sh
flutter test --platform chrome test/pos_terminal_primitives_test.dart
```

Result on 2026-06-11: PASS, 22 tests.

This does not replace real screenshot closure. It is a phase gate that confirms
the web target accepts the tokenized numeric styles before Admin Tables and
Inventory add more dense numeric surfaces.

## Non-Goals

- No backend, Supabase schema, RLS, auth, payment RPC, WeTax, settlement, or
  Office coupling changes are authorized by this gate.
- Existing dirty-tree changes outside the V2 UI slices must be reviewed or
  split before a PR. They are not evidence that Admin Tables Phase 1 or
  Inventory Phase 1 is complete.

## Next Slices

1. Admin Tables Phase 1: floor map workstation.
2. Inventory Phase 1: purchase workstation.
