# Mobile Scroll Ownership Audit - 2026-06-01

## Problem

Manual QA showed that phone and tablet users can get trapped between two
vertical scroll owners:

- the full page scroll created by the responsive body when the viewport is
  shorter than the desktop minimum height
- the internal scroll inside cards, lanes, lists, and panels

On touch devices this makes simple downward scrolling feel unreliable because
the gesture target changes depending on which box the finger starts over.

## Contract

1. Narrow stacked layouts should have one primary vertical scroll owner.
2. Desktop split panes may keep internal scroll panes where the panes are
   clearly bounded.
3. Compact stacked cards must disable their internal vertical list scrolling
   when they are inside a parent vertical list.
4. Horizontal navigation scroll is allowed and is separate from this contract.

## Applied Changes

- `ToastResponsiveBody` no longer viewport-locks narrow layouts by default.
  It reserves a taller 1600px compact page height so phone/tablet users always have
  a real page scroll target instead of being trapped inside cards.
- It still supports explicit viewport-fitted task screens through
  `fitToViewportWhenNarrow`, while screens that read better as stacked mobile
  documents now switch to `ToastResponsiveScrollBody` explicitly.
- Admin menu, staff, settings, e-invoice, reports, attendance, and
  inventory-purchase compact layouts now promote the whole tab to
  `ToastResponsiveScrollBody` where the header, controls, and stacked panels
  move together under one vertical scroll owner.
- Kitchen compact lanes now use the parent lane stack as the vertical scroll
  owner. Individual lane lists are non-scrollable in that mode.
- Admin menu compact category and item panels now use the parent stack as the
  vertical scroll owner instead of fixed-height nested lists.
- Admin staff compact directory now uses the parent stack as the vertical
  scroll owner instead of a fixed-height internal directory list.
- Admin settings and e-invoice compact panels disable queue/detail panel
  scrolling and let the page own vertical movement.
- Admin reports compact analysis now uses a parent scroll wrapper so the
  analysis section and daily table do not overflow in short viewports.
- Admin attendance compact rows render as cards under the page scroll instead
  of a bounded table scroller; the payroll detail panel also disables its inner
  scroll in compact mode.
- Inventory-purchase `_PageShell` now detects unbounded compact page layout and
  renders its body directly instead of adding another `ToastViewportScroll`.
- Photo Ops compact dashboard now renders its dashboard sections directly under
  `ToastResponsiveScrollBody` instead of putting another vertical `ListView`
  inside the main surface.
- `PosSplitContent` now allows per-call compact pane heights; reports uses a
  taller secondary pane for operational signals while other callers keep the
  default compact heights.
- The manual QA regression audit script now checks for these markers.

## Verification

Run:

```sh
flutter analyze
flutter test test/web_scroll_contract_test.dart test/kitchen_operational_attention_contract_test.dart test/menu_admin_ui_contract_test.dart test/staff_admin_ui_contract_test.dart test/settings_admin_ui_contract_test.dart test/einvoice_admin_ui_contract_test.dart test/reports_admin_ui_contract_test.dart test/attendance_payroll_preview_contract_test.dart test/inventory_purchase_readonly_overview_contract_test.dart
node scripts/manual_qa_regression_audit.js
```

Recommended manual QA:

1. Phone portrait: admin menu, staff, settings, e-invoice, reports, attendance,
   inventory, kitchen.
2. Phone landscape: cashier, waiter, kitchen.
3. Tablet portrait: admin menu, staff, inventory, attendance, reports.
4. Confirm vertical drag does not alternate between a page and a card scroll.
