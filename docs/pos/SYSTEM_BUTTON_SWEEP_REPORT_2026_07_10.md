# POS System Button Sweep Report - 2026-07-10

## Verdict

PASS. The final macOS integration run completed all 18 seeded role and work
routes without a Flutter exception, unexpected logout, missing action, or
failed assertion.

- Discovered active controls: 396
- Executed clicks: 231
- Failed actions: 0
- Environment-blocked actions: 3
- Duplicate data-row actions represented by the Gate3 fixture: 2
- Final sweep duration: 12m 34s

## Coverage

The sweep used the dedicated local Gate3 Supabase fixture and covered:

- Public login utilities and all three language choices
- Public QR ordering: add, remove, submit, cancel, and confirm
- Waiter, kitchen, cashier, and payment detail surfaces
- Admin tables, menu, staff, reports, attendance, inventory, QC, settings,
  inactive Deliberry settlement, and MISA e-invoice tabs
- Standalone QC check and QC review surfaces
- Super admin and Photo Ops surfaces
- Global back, forward/home where enabled, and role logout controls
- One-level dialogs, popup menus, date pickers, and bottom-sheet actions opened
  by reachable controls

This is a runtime sweep of active controls reachable with the Gate3 fixture.
It is not a claim that hidden or disabled controls requiring absent business
states were activated. Repeated store-row actions were executed against the
dedicated Gate3 store rather than mutating every local data row.

## Environment Blocks

- Inventory `Print/PDF`: native/file output requires a host destination.
- QC `Attach photo`: requires a camera or interactive file picker.
- Super admin `Open Office system`: launches an external application/browser.

The print-station and attendance-kiosk entry paths were clicked, but macOS
correctly applies the platform guard. Physical printer output, kiosk camera
capture, and external Office navigation remain hardware/environment checks.
Print-job queue creation and DELIVERY payload identity were verified in the
delivery pilot smoke test.

## Defects Fixed

- Admin query-tab deep links now update the selected tab in an existing
  session, and URI changes remount route state consistently.
- Photo Ops now has a Material ancestor for interactive controls.
- QC draft preview no longer overflows; complete/save controls are stable and
  the off-screen save action is revealed before clicking.
- Report download permission failures are caught and shown as localized user
  errors instead of escaping as unhandled exceptions.
- Admin/super-admin logout keys, app navigation keys, language menu keys, QR
  submit keys, and store-row action keys now reach the actual controls.
- Super-admin `Go to Admin` no longer causes a 27px top-bar RenderFlex overflow.
- The kitchen smoke test searches for the order it created before asserting
  ticket visibility.
- Gate3 seeding resets today's daily close, restores the fixture store after
  destructive button checks, and works even when no store is currently active.

## Verification

- `integration_test/system_button_sweep_test.dart`: PASS, 396 discovered / 231
  clicked / 0 failed
- `integration_test/full_multi_account_smoke_test.dart`: PASS, 6 accounts,
  end-to-end waiter -> kitchen -> cashier flow
- `integration_test/manual_delivery_order_smoke_test.dart`: PASS; kitchen,
  tray, and receipt payloads retained `DELIVERY`, with payment and delivery
  revenue recorded
- `flutter test`: PASS, 461/461
- `flutter analyze`: PASS
- `flutter build web`: PASS

## Operational Follow-up

Run the remaining hardware checks on the pilot devices: physical kitchen/tray/
receipt printing, print-station recovery, attendance kiosk camera capture, QC
photo attachment, and the external Office link.
