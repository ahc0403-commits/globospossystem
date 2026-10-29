# POS responsive layout review

The reference is the owner's Vietnamese JeonGabok report screenshot for
2026-10-28. The four payment cards had different heights, the four supporting
metrics formed an uneven row, and the actionable issue panel was clipped.
The screenshot establishes these layout defects; it does not establish that
another store's menu data was returned by either analytics endpoint.

The review covers the 34 route definitions in `lib/core/router/app_router.dart`,
the conditional Admin (up to 11), Super Admin (9), inventory/purchase (11)
sections, and the three dedicated report analyses. These overlap and must not
be added together as a screen count. Photo contexts replace or hide sections.
Keep every existing role check and target index. A source inventory is not an
authenticated rendering of every route.

## Implementation and verification order

1. Fix the reproduced report defects in shared components: balance four metrics
   as 4, 2+2 or one column; measure payment-card titles at the actual font scale;
   equalize each semantic row's height; align amounts and bottom actions.
2. Give the report page one scrolling owner. Let issue panels, daily rows and
   translated text grow instead of subtracting fixed panel heights from a
   viewport. Keep all three analysis launchers, dates, closing actions and
   issue drilldowns.
3. Apply the same content-width and large-text policy to the shared topbar and
   secondary metric strip. Preserve complete monetary values. Keep wide tables'
   horizontal scrolling local. Confirmation dialogs retain their result and
   callbacks while growing their action label at large text and scrolling above
   the keyboard.
4. Render the actual menu-sales, operational-performance and revenue-analysis
   widgets with isolated data. Separate chart canvas height from translated
   captions; reserve scaled axis-label space. Keep menu sorting, groups, date
   requests, formulas, prices and store IDs unchanged.
5. Run affected tests, fatal-info Dart analysis, a browser fixture build and
   visual/interaction checks, then the full final-SHA candidate recipe. After
   normal publication/merge, use the official production entry point and its
   fresh exact-main recipe, Auth/migration/Edge and fixed-account smoke checks.
   No previous SHA's PASS is a substitute.

## Surface inventory and existing regression entry points

| Family | Source surfaces | Regression entry points |
| --- | --- | --- |
| Public ordering and receipts | `/qr/:token`, `/order/:slug`, request receipt, `/receipt` | `qr_order_operational_ui_test`, `direct_delivery_storefront_widget_test`, `pos_paperless_visual_test` |
| Authentication and onboarding | login, restore, password, consent, onboarding, store setup | `remaining_route_operational_state_test`, `store_onboarding_widget_test`, `store_setup_screen_contract_test` |
| Orders, tables and KDS | waiter, kitchen, cashier, direct-order work queues, customer display, emergency | `waiter_overlay_operational_test`, `kitchen_overlay_operational_test`, `cashier_overlay_operational_test`, `direct_order_acceptance_widget_test`, `tray_floor_customer_delivery_widget_test` |
| Reports and financials | Admin Reports, three analysis screens, payment detail, receipt ledger, sales export | `reports_full_layout_test`, `financial_amount_card_geometry_test`, `daily_sales_report_screen_test`, `menu_sales_analytics_widget_test`, `paperless_operations_dashboard_test`, `sales_revenue_analysis_widget_test`, `shared_surface_layout_test` |
| Inventory and procurement | inventory order routes and 11 conditional sections; Admin inventory | `inventory_workflow_all_stores_widget_test`, `inventory_purchase_overlay_operational_test`, `admin_inventory_overlay_operational_test`, procurement responsive/approval/adjustment tests |
| Workforce and quality | attendance kiosk, Admin employees/attendance, QC check/review | `workforce_setup_provisioning_widget_test`, `admin_core_overlay_operational_test`, `qc_route_overlay_operational_test` |
| Settings, invoice and administration | Admin/Super Admin tabs, direct-delivery settings/analytics, invoice exports, Photo operations | `super_admin_overlay_operational_test`, `einvoice_overlay_operational_test`, `red_invoice_intake_overlay_operational_test`, `photo_ops_role_surface_widget_test`, routed-surface tests |

Tests in this table have different fixture/role/viewport coverage. Their presence
does not mean that every screen was captured in all languages and sizes. The
full candidate log records actual execution; unavailable Windows hardware and
external Office checks retain their existing unverified status.

## Layout acceptance

Use the canonical content-width classes 600/1024/1440 and the existing 1.3
large-text policy. Widget tests set `tester.view.physicalSize` and DPR explicitly:
`setSurfaceSize` alone does not change the MediaQuery window used by these
screens. Include phone, tablet, desktop, short landscape and breakpoint edges.
Exercise KO/EN/VI, 100/130/200% text, loading/empty/error data, large amounts,
long names, role context and the final action. Browser zoom must be measured
through actual browser zoom, not claimed from a pinch/page scale or DPR override.

Require no overflow or layout exception; equal heights within each payment-card
row; aligned amount and action baselines; complete amounts; fully visible issue
rows with working drilldowns; reachable navigation, table cells and confirmation
buttons. Do not impose one fixed height on unrelated business cards or shrink
large text to make a test pass.

No new production transactions are needed. Preview data uses a blocked HTTP
client and synthetic store/menu/payment identifiers. The optional browser entry
is `test/support/pos_layout_preview.dart`, not the production app target. Do not
ship that fixture as the operating site or include real account credentials in
screenshots or artifacts.

## Operational evidence limits

The supplied store-manager login returned `invalid_credentials`; neither a
super-admin DB read nor a fixture role establishes that account's operating UI.
Keep the reported cross-store symptom unresolved until the actual authenticated
request/response and selected store/date are observed. Current read-only menu
and order integrity checks found no cross-store relationship mismatch; shared
translated menu names were generic rice and packaged beverages. No sales data,
menu registrations, accounting rules, RLS, permissions or historical orders are
corrected by this layout change.

Office buyer-account visibility remains a separate unverified integration check.
Print-station package delivery was cancelled. Preserve these boundaries in the
final coordinated release report.
