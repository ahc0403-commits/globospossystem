# GLOBOSVN POS — Duplicate Code Report

- **Date:** 2026-06-10 · **Status:** report only
- Excluded as intentional (per CLAUDE.md): `generate-settlement` vs `generate_delivery_settlement`; restaurants/stores dual naming; sequential `CREATE OR REPLACE` redefinitions in migrations (expand-migrate, not duplication).

## Cluster 1 — VND currency formatting: 7+ independent implementations, output already drifted · **P0 (user-visible)**

| Site | Implementation | Output for 1234567 |
|------|----------------|--------------------|
| `lib/features/admin/tabs/reports_tab.dart:29` | `NumberFormat('#,###','vi_VN')` + `' VND'` | `1.234.567 VND` |
| `lib/features/admin/tabs/attendance_tab.dart:21` | byte-identical copy of the above | `1.234.567 VND` |
| `lib/features/admin/tabs/einvoice_tab.dart:1195` | `NumberFormat('#,###')` (default locale) + `' ₫'` | `1,234,567 ₫` |
| `lib/features/delivery/screens/delivery_settlement_tab.dart:39` | same ₫ variant | `1,234,567 ₫` |
| `lib/features/payment/payment_detail_screen.dart:1127` | `_formatCurrency(dynamic)` with num/String parsing + `' VND'` | `1,234,567 VND` |
| `lib/features/admin/tabs/inventory_tab.dart:5964` | `_formatCurrencyCompact` + `' VND'` | compact |
| `lib/core/hardware/receipt_builder.dart:141` | hand-rolled comma loop, no intl | `1,234,567` **on printed receipts** |
| ~7 ad-hoc `NumberFormat('#,###','vi_VN')` instantiations | `cashier_screen.dart:209,997,1060,1182,1581`, `menu_tab.dart:38`, `reports_tab.dart:44,2209,2523` | mixed |

The same amount renders three different ways depending on screen, including the customer-facing receipt.
**Target:** one `formatVnd(num)` in `lib/core/utils/` (decide grouping + suffix once). **Drift risk:** already real. **Difficulty:** M (mechanical, many call sites).

## Cluster 2 — WeTax edge functions: copy-pasted helpers with security-relevant drift · **P0 (latent breakage)**

- `decodeByteaToString` ×4 (`wetax-daily-close:14`, `wetax-dispatcher:58`, `wetax-poller:15`, `wetax-onboarding:20`) — typed in one copy, regex char-class differs in another.
- `getToken` ×4 (`daily-close:32`, `dispatcher:75`, `poller:45`, `onboarding:38`) — **behavioral drift:** only dispatcher supports `password_format` + AES `encryptPassword()` and logs failed refreshes to `partner_credential_access_log`; the other three always send plaintext. Migrating credentials to encrypted format silently breaks 3 of 4 functions. `access_reason` strings also differ per copy.
- `getConfig` ×2 (`dispatcher:138`, `poller:35`); `logEvent` ×2 (`dispatcher:147`, `poller:88`).

**Target:** `supabase/functions/_shared/wetax.ts` exporting `decodeByteaToString`, `getToken`, `getConfig`, `logEvent`, `WETAX_BASE_URL`; redeploy all four. **Difficulty:** M.

## Cluster 3 — Order entity modeled three times + select strings rebuilt in four providers · **P1**

Models: `Order`/`OrderItem` (`features/order/order_model.dart:29,116`), `KitchenOrder` (`kitchen_provider.dart:62`), `CashierOrder` (`payment_provider.dart:13`) — three parallel fromJson paths for the same `orders` rows, each with its own null/status handling.

Queries: `from('orders').select('…, order_items(…, menu_items(name))')` hand-built with slightly different column subsets in:
- `order_provider.dart:151-155`
- `table_provider.dart:207-211`
- `kitchen_provider.dart:137-141`
- `payment_provider.dart:92-96`

Adding one column means editing four select strings; missing one yields null-field bugs in only that screen (drift already present: payment adds `display_name, paying_amount_inc_tax, vat_category`; table omits `unit_price`).

**Target:** shared select-fragment constants + unified base model in `lib/core/models/order.dart`, served from the already-existing `lib/core/services/order_service.dart`. Do Clusters 3's models and queries together. **Difficulty:** L (touches order/kitchen/payment; needs tests first).

## Cluster 4 — Timestamp display: `TimeUtils.toVietnam()` vs raw `.toLocal()` · **P1**

`lib/core/utils/time_utils.dart` exists precisely for UTC→Asia/Ho_Chi_Minh display and is used by attendance/payroll/kitchen/qc. But ≥10 files use bare `.toLocal()` instead: `payment_detail_screen.dart:1143`, `einvoice_tab.dart:1200,1330`, `staff_tab.dart:968,1077`, `qc_tab.dart:2290`, `delivery_settlement_tab.dart:1175`, `admin_audit_trace_panel.dart:136`, `report_provider.dart:402`, etc. On any device not set to UTC+7, screens disagree with each other and with the fixed-HCMC daily close.

**Target:** add `TimeUtils.formatDateTime…` variants; convert all business-timestamp display; treat bare `.toLocal()` as banned for business data. **Difficulty:** M.

## Cluster 5 — `restaurantNameProvider` ×3 + ad-hoc store lookups · **P2**

Verbatim provider in `waiter_screen.dart:20-31`, `kitchen_screen.dart:21-32` (renamed), `fingerprint_provider.dart:128`. Plus ad-hoc single-column `from('restaurants')` lookups in `auth_provider.dart:250`, `settings_provider.dart:100`, `payment_provider.dart:183`, `inventory_service.dart:1100` (13 total call sites). `StoreSettings` class is defined inside `waiter_screen.dart:33` while `settings_provider.dart:124` re-parses `operation_mode` separately.

**Target:** one family provider / `StoreService` in `lib/core/services/`; move `StoreSettings` to `lib/core/models/`. **Difficulty:** S.

## Cluster 6 — `_startOfWeek` ×5 · **P2**

`attendance_tab.dart:48`, `qc_tab.dart:44`, `qc_review_screen.dart:34`, `qc_check_screen.dart:42`, `super_admin_screen.dart:688`. If one copy changes the Monday/Sunday convention, weekly QC and payroll ranges silently disagree. **Target:** `TimeUtils.startOfWeek()`. **Difficulty:** S.

## Cluster 7 — `_RestaurantMissingView` widget ×2 · **P3**

`tables_tab.dart:1167` and `menu_tab.dart:825`, identical except the l10n key (`noLinkedStoreMessage` vs `menuNoLinkedStoreMessage` — the message itself is also duplicated in ARB). **Target:** `lib/widgets/store_missing_view.dart` + one key. **Difficulty:** S.

## Cluster 8 — `report_provider.dart` windowed-query shells · **P3**

Lines 172/181/191/199 repeat the same `eq('restaurant_id').gte/lte('created_at')` boilerplate across payments/external_sales/orders. Single-file local helper. **Difficulty:** S.

## Checked and clean

- RLS policy boilerplate: consistent use of `get_user_store_id()` helper, no drifted copies.
- Validation logic (PIN regex etc.): defined once each.
- No duplicate class names in lib/ besides `_RestaurantMissingView`.
- Migration-level `SELECT restaurant_id FROM users` appears only inside the two helper-function definitions (intentional dual naming).

## Consolidation order (see refactoring-roadmap.md)

1. `_shared/wetax.ts` (Cluster 2) — pairs naturally with the dispatcher/poller reliability fixes.
2. `formatVnd()` (Cluster 1) — decide canonical format with the business first (dot vs comma grouping, `VND` vs `₫`), then mechanical sweep.
3. TimeUtils standardization (Cluster 4) — pairs with the daily-close timezone fix.
4. Order model + select fragments (Cluster 3) — last; largest blast radius, write payment/kitchen behavioral tests first.
5. Clusters 5–8 — opportunistic, bundle into one cleanup PR.
