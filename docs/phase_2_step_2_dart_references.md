---
title: "Phase 2 Step 2 — Dart Code References"
version: "1.0"
date: "2026-04-12"
status: "static analysis complete"
---

# Phase 2 Step 2 — Dart Source Code References

## Summary
- Total files with references: **55**
- Total occurrences: **951**

---

## Category 1: Table Name Strings (CRITICAL)

References to Supabase table names as string literals.

### `'restaurants'` table

| File | Line | Context |
|------|------|---------|
| `lib/core/services/connectivity_service.dart` | 14 | `.from('restaurants')` |
| `lib/core/services/connectivity_service.dart` | 82 | `.from('restaurants')` |
| `lib/features/kitchen/kitchen_screen.dart` | 21 | `.from('restaurants')` |
| `lib/features/attendance/fingerprint_provider.dart` | 133 | `.from('restaurants')` |
| `lib/features/admin/providers/settings_provider.dart` | 100 | `.from('restaurants')` |
| `lib/features/waiter/waiter_screen.dart` | 21 | `.from('restaurants')` |
| `lib/features/waiter/waiter_screen.dart` | 44 | `.from('restaurants')` |
| `lib/features/super_admin/super_admin_provider.dart` | 195 | `.from('restaurants')` |
| `lib/features/admin/widgets/admin_audit_trace_panel.dart` | 203 | `'restaurants' => '매장'` (audit trail display mapping) |

### `'restaurant_settings'` table

| File | Line | Context |
|------|------|---------|
| `lib/core/services/pin_service.dart` | 16 | `.from('restaurant_settings')` |
| `lib/core/services/pin_service.dart` | 33 | `supabase.from('restaurant_settings').upsert({` |
| `lib/core/services/pin_service.dart` | 41 | `supabase.from('restaurant_settings').upsert({` |

**Total: 12 table name string references**

---

## Category 2: Column/Field References

References to `restaurant_id` as column names in queries and data maps.

| File | Line | Context |
|------|------|---------|
| `lib/core/services/pin_service.dart` | 18 | `.eq('restaurant_id', restaurantId)` |
| `lib/core/services/pin_service.dart` | 34 | `'restaurant_id': restaurantId,` |
| `lib/core/services/pin_service.dart` | 37 | `onConflict: 'restaurant_id'` |
| `lib/core/services/pin_service.dart` | 42 | `'restaurant_id': restaurantId,` |
| `lib/core/services/pin_service.dart` | 45 | `onConflict: 'restaurant_id'` |
| `lib/core/services/menu_service.dart` | 10 | `.eq('restaurant_id', restaurantId)` |
| `lib/core/services/menu_service.dart` | 21 | `.eq('restaurant_id', restaurantId)` |
| `lib/core/services/inventory_service.dart` | 85 | `.eq('restaurant_id', restaurantId)` |
| `lib/core/services/inventory_service.dart` | 126 | `.eq('restaurant_id', restaurantId)` |
| `lib/core/services/inventory_service.dart` | 179 | `.eq('restaurant_id', restaurantId)` |
| `lib/core/services/tables_service.dart` | 8 | `.eq('restaurant_id', restaurantId)` |
| `lib/core/services/staff_service.dart` | 18 | `'restaurant_id': restaurantId,` |
| `lib/core/services/attendance_service.dart` | 100 | `'restaurant_id': map['restaurant_id'],` |
| `lib/core/services/attendance_service.dart` | 131 | `.eq('restaurant_id', restaurantId)` |
| `lib/core/services/attendance_service.dart` | 152 | `'restaurant_id': restaurantId,` |
| `lib/core/services/payroll_service.dart` | 306 | `'restaurant_id': restaurantId,` |
| `lib/core/services/qc_service.dart` | 93 | `'restaurant_id': map['restaurant_id'],` |
| `lib/core/models/pos_table.dart` | 33 | `restaurantId: json['restaurant_id']?.toString() ?? '',` |
| `lib/features/auth/auth_provider.dart` | 38 | `.select('role, restaurant_id, is_active, extra_permissions')` |
| `lib/features/auth/auth_provider.dart` | 58 | `restaurantId: data['restaurant_id'] as String?,` |
| `lib/features/payment/payment_provider.dart` | 84 | `.eq('restaurant_id', restaurantId)` |
| `lib/features/kitchen/kitchen_provider.dart` | 133 | `.eq('restaurant_id', restaurantId)` |
| `lib/features/order/order_provider.dart` | 122 | `.eq('restaurant_id', restaurantId)` |
| `lib/features/table/table_provider.dart` | 44 | `.eq('restaurant_id', restaurantId)` |
| `lib/features/report/report_provider.dart` | 142 | `.eq('restaurant_id', restaurantId)` |
| `lib/features/report/report_provider.dart` | 150 | `.eq('restaurant_id', restaurantId)` |
| `lib/features/report/report_provider.dart` | 159 | `.eq('restaurant_id', restaurantId)` |
| `lib/features/report/report_provider.dart` | 167 | `.eq('restaurant_id', restaurantId)` |
| `lib/features/report/report_provider.dart` | 174 | `.select('id, order_id, orders!inner(restaurant_id, created_at)')` |
| `lib/features/report/report_provider.dart` | 176 | `.eq('orders.restaurant_id', restaurantId)` |
| `lib/features/delivery/delivery_models.dart` | 138 | `restaurantId: json['restaurant_id'].toString(),` |
| `lib/features/delivery/delivery_settlement_provider.dart` | 58 | `.eq('restaurant_id', restaurantId)` |
| `lib/features/delivery/delivery_settlement_provider.dart` | 77 | `.eq('restaurant_id', restaurantId)` |
| `lib/features/admin/providers/staff_provider.dart` | 132 | `.eq('restaurant_id', restaurantId)` |
| `lib/features/admin/providers/staff_provider.dart` | 234 | `.eq('restaurant_id', restaurantId)` |
| `lib/features/admin/providers/tables_provider.dart` | 102 | `.eq('restaurant_id', restaurantId)` |
| `lib/features/super_admin/super_admin_provider.dart` | 375 | `.eq('restaurant_id', restaurant.id)` |
| `lib/features/super_admin/super_admin_provider.dart` | 383 | `.eq('restaurant_id', restaurant.id)` |
| `lib/features/super_admin/super_admin_screen.dart` | 571 | `final restaurantId = row['restaurant_id']?.toString() ?? '';` |
| `lib/features/super_admin/super_admin_screen.dart` | 573 | `row['restaurant_name']?.toString() ?? '-';` |

### RPC parameter references (`'p_restaurant_id'`)

| File | Line | Context |
|------|------|---------|
| `lib/core/services/order_service.dart` | 12 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/order_service.dart` | 29 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/order_service.dart` | 47 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/order_service.dart` | 65 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/order_service.dart` | 77 | `'p_restaurant_id': restaurantId` |
| `lib/core/services/order_service.dart` | 90 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/order_service.dart` | 104 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/order_service.dart` | 119 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/menu_service.dart` | 36 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/menu_service.dart` | 53 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/payment_service.dart` | 14 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/payment_service.dart` | 27 | `'p_restaurant_id': restaurantId` |
| `lib/core/services/inventory_service.dart` | 9 | `'p_restaurant_id': restaurantId` |
| `lib/core/services/inventory_service.dart` | 26 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/inventory_service.dart` | 71 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/inventory_service.dart` | 97 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/inventory_service.dart` | 114 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/inventory_service.dart` | 136 | `'p_restaurant_id': restaurantId` |
| `lib/core/services/inventory_service.dart` | 147 | `'p_restaurant_id': restaurantId` |
| `lib/core/services/inventory_service.dart` | 161 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/inventory_service.dart` | 188 | `'p_restaurant_id': restaurantId` |
| `lib/core/services/inventory_service.dart` | 203 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/inventory_service.dart` | 220 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/attendance_service.dart` | 72 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/attendance_service.dart` | 89 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/attendance_service.dart` | 119 | `'p_restaurant_id': restaurantId` |
| `lib/core/services/staff_service.dart` | 49 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/qc_service.dart` | 13 | `'p_restaurant_id': restaurantId` |
| `lib/core/services/qc_service.dart` | 28 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/qc_service.dart` | 84 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/qc_service.dart` | 124 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/qc_service.dart` | 194 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/qc_service.dart` | 211 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/qc_service.dart` | 225 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/qc_service.dart` | 242 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/daily_closing_service.dart` | 11 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/daily_closing_service.dart` | 25 | `'p_restaurant_id': restaurantId` |
| `lib/core/services/admin_audit_service.dart` | 10 | `'p_restaurant_id': restaurantId` |
| `lib/core/services/admin_audit_service.dart` | 23 | `'p_restaurant_id': restaurantId` |
| `lib/features/delivery/delivery_settlement_provider.dart` | 110 | `'p_restaurant_id': restaurantId,` |
| `lib/features/onboarding/onboarding_provider.dart` | 98 | `'p_restaurant_id': restaurantId,` |
| `lib/core/services/restaurant_service.dart` | 42 | `'p_restaurant_id': id,` |
| `lib/core/services/restaurant_service.dart` | 63 | `'p_restaurant_id': id,` |
| `lib/core/services/restaurant_service.dart` | 75 | `'p_restaurant_id': id` |

**Total: ~84 column/field references**

---

## Category 3: Class and Type Names

| File | Line | Symbol | Kind |
|------|------|--------|------|
| `lib/core/services/restaurant_service.dart` | 3 | `RestaurantService` | class declaration |
| `lib/features/waiter/waiter_screen.dart` | 28 | `RestaurantSettings` | class declaration |
| `lib/features/waiter/waiter_screen.dart` | 29 | `const RestaurantSettings({` | constructor |
| `lib/features/waiter/waiter_screen.dart` | 39 | `FutureProvider.family<RestaurantSettings, String>` | type parameter |
| `lib/features/waiter/waiter_screen.dart` | 58 | `return RestaurantSettings(...)` | instantiation |
| `lib/features/waiter/waiter_screen.dart` | 329 | `AsyncValue<RestaurantSettings>.data(` | type parameter |
| `lib/features/waiter/waiter_screen.dart` | 330 | `RestaurantSettings(` | instantiation |
| `lib/features/super_admin/super_admin_provider.dart` | 8 | `SuperRestaurant` | class declaration |
| `lib/features/super_admin/super_admin_provider.dart` | 9 | `const SuperRestaurant({` | constructor |
| `lib/features/super_admin/super_admin_provider.dart` | 40 | `factory SuperRestaurant.fromJson(...)` | factory constructor |
| `lib/features/super_admin/super_admin_provider.dart` | 48 | `return SuperRestaurant(` | instantiation |
| `lib/features/super_admin/super_admin_provider.dart` | 68 | `SuperAdminRestaurantReport` | class declaration |
| `lib/features/super_admin/super_admin_provider.dart` | 69 | `const SuperAdminRestaurantReport({` | constructor |
| `lib/features/super_admin/super_admin_provider.dart` | 95 | `List<SuperAdminRestaurantReport> rows` | type reference |
| `lib/features/super_admin/super_admin_provider.dart` | 112 | `List<SuperRestaurant> restaurants` | type reference |
| `lib/features/super_admin/super_admin_provider.dart` | 116 | `SuperRestaurant? selectedRestaurant` | type reference |
| `lib/features/super_admin/super_admin_provider.dart` | 124 | `List<SuperRestaurant> get filteredRestaurants` | type reference |
| `lib/features/super_admin/super_admin_provider.dart` | 143 | `List<SuperRestaurant>? restaurants` | type parameter |
| `lib/features/super_admin/super_admin_provider.dart` | 147 | `SuperRestaurant? selectedRestaurant` | type parameter |
| `lib/features/super_admin/super_admin_provider.dart` | 199 | `.map<SuperRestaurant>(` | type parameter |
| `lib/features/super_admin/super_admin_provider.dart` | 200 | `SuperRestaurant.fromJson(...)` | factory call |
| `lib/features/super_admin/super_admin_provider.dart` | 321 | `selectRestaurant(SuperRestaurant? restaurant)` | method signature |
| `lib/features/super_admin/super_admin_provider.dart` | 415 | `SuperAdminRestaurantReport(` | instantiation |
| `lib/features/super_admin/super_admin_screen.dart` | 113 | `_RestaurantsTab(` | widget reference |
| `lib/features/super_admin/super_admin_screen.dart` | 656 | `class _RestaurantsTab` | class declaration |
| `lib/features/super_admin/super_admin_screen.dart` | 657 | `const _RestaurantsTab({` | constructor |
| `lib/features/super_admin/super_admin_screen.dart` | 929 | `SuperRestaurant? initial` | parameter type |
| `lib/features/super_admin/super_admin_screen.dart` | 1198 | `List<SuperAdminRestaurantReport> rows` | parameter type |
| `lib/features/super_admin/super_admin_screen.dart` | 1199 | `List<SuperRestaurant> restaurants` | parameter type |
| `lib/features/super_admin/super_admin_screen.dart` | 1205 | `.cast<SuperRestaurant?>()` | type cast |
| `lib/features/super_admin/super_admin_screen.dart` | 1247 | `DropdownButton<SuperRestaurant?>(` | type parameter |
| `lib/features/super_admin/super_admin_screen.dart` | 1248 | `state.selectedRestaurant` | field access |
| `lib/features/super_admin/super_admin_screen.dart` | 1255 | `DropdownMenuItem<SuperRestaurant?>(` | type parameter |
| `lib/features/super_admin/super_admin_screen.dart` | 1263 | `DropdownMenuItem<SuperRestaurant?>(` | type parameter |
| `lib/features/admin/tabs/tables_tab.dart` | 84 | `_RestaurantMissingView()` | widget reference |
| `lib/features/admin/tabs/tables_tab.dart` | 572 | `class _RestaurantMissingView` | class declaration |
| `lib/features/admin/tabs/tables_tab.dart` | 573 | `const _RestaurantMissingView()` | constructor |
| `lib/features/admin/tabs/menu_tab.dart` | 27 | `_RestaurantMissingView()` | widget reference |
| `lib/features/admin/tabs/menu_tab.dart` | 654 | `class _RestaurantMissingView` | class declaration |
| `lib/features/admin/tabs/menu_tab.dart` | 655 | `const _RestaurantMissingView()` | constructor |

**Total: ~39 class/type name references**

---

## Category 4: Variable and Parameter Names

These are camelCase Dart variables, parameters, and fields using `restaurantId`, `restaurantName`, `restaurant`, etc. across all files. Listed by file.

### `lib/features/auth/auth_state.dart`
| Line | Reference |
|------|-----------|
| 7 | `final String? restaurantId;` |
| 15 | `this.restaurantId,` |
| 24 | `String? restaurantId,` |
| 34 | `restaurantId: ... (restaurantId ?? this.restaurantId),` |

### `lib/core/router/app_router.dart`
| Line | Reference |
|------|-----------|
| 38 | `final restaurantId = auth.restaurantId;` |
| 52 | `restaurantId == null` |
| 162 | `path: '/admin/:restaurantId',` |
| 164 | `overrideRestaurantId: state.pathParameters['restaurantId'],` |

### `lib/features/admin/admin_screen.dart`
| Line | Reference |
|------|-----------|
| 26 | `this.overrideRestaurantId,` |
| 31 | `final String? overrideRestaurantId;` |
| 61 | `widget.overrideRestaurantId != null` |

### `lib/core/models/pos_table.dart`
| Line | Reference |
|------|-----------|
| 4 | `required this.restaurantId,` |
| 11 | `final String restaurantId;` |

### `lib/core/services/restaurant_service.dart`
| Line | Reference |
|------|-----------|
| 80 | `final restaurantService = RestaurantService();` |

### `lib/core/hardware/receipt_builder.dart`
| Line | Reference |
|------|-----------|
| 6 | `required String restaurantName,` |
| 20 | `restaurantName,` |

### `lib/features/onboarding/onboarding_provider.dart`
| Line | Reference |
|------|-----------|
| 3 | `import '../../core/services/restaurant_service.dart';` |
| 12 | `this.createdRestaurantId,` |
| 13 | `this.createdRestaurantName,` |
| 19 | `final String? createdRestaurantId;` |
| 20 | `final String? createdRestaurantName;` |
| 26-36 | `createdRestaurantId`, `createdRestaurantName` (copyWith) |
| 46 | `createRestaurant(` |
| 59 | `restaurantService.createRestaurant(` |
| 70-71 | `createdRestaurantId`, `createdRestaurantName` |
| 85-86 | `final restaurantId = state.createdRestaurantId;` |

### `lib/features/delivery/delivery_models.dart`
| Line | Reference |
|------|-----------|
| 65 | `required this.restaurantId,` |
| 80 | `final String restaurantId;` |

### `lib/features/super_admin/super_admin_provider.dart`
| Line | Reference |
|------|-----------|
| 3 | `import '../../core/services/restaurant_service.dart';` |
| 70-78 | `restaurantId`, `restaurantName` (fields in SuperRestaurant) |
| 100 | `this.restaurants = const [],` |
| 104 | `this.selectedRestaurant,` |
| 112 | `final List<SuperRestaurant> restaurants;` |
| 116 | `final SuperRestaurant? selectedRestaurant;` |
| 125 | `var list = restaurants;` |
| 143-170 | `restaurants`, `selectedRestaurant` (copyWith and state) |
| 191 | `loadAllRestaurants()` |
| 198-204 | `restaurants` variable |
| 242 | `addRestaurant(...)` |
| 253 | `restaurantService.createRestaurant(...)` |
| 273 | `updateRestaurant(...)` |
| 285 | `restaurantService.updateRestaurant(...)` |
| 306 | `deactivateRestaurant(id)` |
| 309 | `restaurantService.deactivateRestaurant(id)` |
| 321-324 | `selectRestaurant(...)`, `restaurant` param |
| 341-389 | `restaurants`, `restaurant`, `sourceRestaurants` variables |
| 416-417 | `restaurantId`, `restaurantName` in report builder |
| 463-465 | `restaurantId`, `restaurantName` in `_Accumulator` |

### `lib/features/admin/providers/settings_provider.dart`
| Line | Reference |
|------|-----------|
| 4 | `import '../../../core/services/restaurant_service.dart';` |
| 11 | `this.isSavingRestaurant = false,` |
| 14-15 | `this.restaurantId,`, `this.restaurantName = '',` |
| 24 | `final bool isSavingRestaurant;` |
| 27-28 | `final String? restaurantId;`, `final String restaurantName;` |
| 40-56 | `restaurantId`, `restaurantName`, `isSavingRestaurant` (copyWith) |
| 96-124 | `loadSettings(String restaurantId, ...)`, `restaurantData`, `restaurantId`, `restaurantName` |
| 136 | `saveRestaurant(...)` |
| 142 | `final restaurantId = state.restaurantId;` |
| 158-183 | `restaurantName`, `restaurantService.updateRestaurantSettings(...)`, `isSavingRestaurant` |

### Other files with `restaurantId` parameter/variable usage

The following files all use `restaurantId` as a parameter name or local variable extensively (not exhaustively listed -- see Category 2 for their column-access patterns):

- `lib/features/inventory/inventory_provider.dart` (33 occurrences)
- `lib/features/payment/payment_provider.dart` (21 occurrences)
- `lib/features/kitchen/kitchen_provider.dart` (21 occurrences)
- `lib/features/order/order_provider.dart` (30 occurrences)
- `lib/features/qc/qc_provider.dart` (44 occurrences)
- `lib/features/qc/qc_check_screen.dart` (12 occurrences)
- `lib/features/table/table_provider.dart` (9 occurrences)
- `lib/features/report/report_provider.dart` (9 occurrences)
- `lib/features/cashier/cashier_screen.dart` (20 occurrences)
- `lib/features/waiter/waiter_screen.dart` (58 occurrences)
- `lib/features/kitchen/kitchen_screen.dart` (23 occurrences)
- `lib/features/attendance/attendance_kiosk_screen.dart` (11 occurrences)
- `lib/features/attendance/fingerprint_provider.dart` (11 occurrences)
- `lib/features/delivery/delivery_settlement_provider.dart` (6 occurrences)
- `lib/features/delivery/screens/delivery_settlement_tab.dart` (2 occurrences)
- `lib/features/admin/tabs/tables_tab.dart` (31 occurrences)
- `lib/features/admin/tabs/inventory_tab.dart` (49 occurrences)
- `lib/features/admin/tabs/qc_tab.dart` (45 occurrences)
- `lib/features/admin/tabs/staff_tab.dart` (16 occurrences)
- `lib/features/admin/tabs/attendance_tab.dart` (12 occurrences)
- `lib/features/admin/tabs/reports_tab.dart` (33 occurrences)
- `lib/features/admin/tabs/settings_tab.dart` (38 occurrences)
- `lib/features/admin/tabs/menu_tab.dart` (9 occurrences)
- `lib/features/admin/providers/menu_provider.dart` (7 occurrences)
- `lib/features/admin/providers/staff_provider.dart` (13 occurrences)
- `lib/features/admin/providers/tables_provider.dart` (7 occurrences)
- `lib/features/admin/providers/admin_audit_provider.dart` (5 occurrences)
- `lib/features/admin/providers/daily_closing_provider.dart` (3 occurrences)
- `lib/features/admin/widgets/admin_audit_trace_panel.dart` (4 occurrences -- `restaurantId` field) |
- `lib/core/services/order_service.dart` (16 occurrences)
- `lib/core/services/menu_service.dart` (8 occurrences)
- `lib/core/services/inventory_service.dart` (28 occurrences)
- `lib/core/services/payment_service.dart` (4 occurrences)
- `lib/core/services/staff_service.dart` (4 occurrences)
- `lib/core/services/tables_service.dart` (6 occurrences)
- `lib/core/services/attendance_service.dart` (14 occurrences)
- `lib/core/services/qc_service.dart` (22 occurrences)
- `lib/core/services/daily_closing_service.dart` (4 occurrences)
- `lib/core/services/admin_audit_service.dart` (4 occurrences)
- `lib/core/services/payroll_service.dart` (5 occurrences)

### Provider name references

| File | Line | Reference |
|------|------|-----------|
| `lib/features/waiter/waiter_screen.dart` | 16 | `restaurantNameProvider = FutureProvider.family<String, String>(...)` |
| `lib/features/waiter/waiter_screen.dart` | 38 | `restaurantSettingsProvider = FutureProvider.family<RestaurantSettings, String>(...)` |
| `lib/features/kitchen/kitchen_screen.dart` | 16 | `kitchenRestaurantNameProvider = FutureProvider.family<String, String>(...)` |
| `lib/features/attendance/fingerprint_provider.dart` | 128 | `restaurantNameProvider = FutureProvider.family<String, String>(...)` |

---

## Category 5: RPC/Function Name References

| File | Line | RPC function name |
|------|------|-------------------|
| `lib/core/services/restaurant_service.dart` | 14 | `'admin_create_restaurant'` |
| `lib/core/services/restaurant_service.dart` | 39 | `'admin_update_restaurant'` |
| `lib/core/services/restaurant_service.dart` | 61 | `'admin_update_restaurant_settings'` |
| `lib/core/services/restaurant_service.dart` | 74 | `'admin_deactivate_restaurant'` |
| `lib/features/admin/widgets/admin_audit_trace_panel.dart` | 216 | `'admin_create_restaurant' => '생성'` |
| `lib/features/admin/widgets/admin_audit_trace_panel.dart` | 217 | `'admin_update_restaurant' => '수정'` |
| `lib/features/admin/widgets/admin_audit_trace_panel.dart` | 218 | `'admin_update_restaurant_settings' => '설정 수정'` |
| `lib/features/admin/widgets/admin_audit_trace_panel.dart` | 219 | `'admin_deactivate_restaurant' => '비활성화'` |

**Total: 8 RPC function name references**

---

## Category 6: UI Strings and Labels

| File | Line | String |
|------|------|--------|
| `lib/features/onboarding/onboarding_screen.dart` | 103 | `'Restaurant Name'` (InputDecoration label) |
| `lib/features/admin/tabs/settings_tab.dart` | 279 | `'Restaurant Info'` (section title) |
| `lib/features/admin/tabs/settings_tab.dart` | 287 | `'Restaurant Name'` (InputDecoration label) |
| `lib/features/admin/tabs/menu_tab.dart` | 663 | `'Restaurant not found for this account.'` (error message) |
| `lib/features/admin/providers/settings_provider.dart` | 144 | `'Restaurant is not available.'` (error message) |
| `lib/features/waiter/waiter_screen.dart` | 25 | `'Restaurant'` (fallback name) |
| `lib/features/waiter/waiter_screen.dart` | 522 | `'Restaurant'` (fallback in offline mode) |
| `lib/features/waiter/waiter_screen.dart` | 564 | `'Restaurant'` (fallback display) |
| `lib/features/kitchen/kitchen_screen.dart` | 25 | `'Restaurant'` (fallback name) |
| `lib/features/kitchen/kitchen_screen.dart` | 406 | `'Restaurant'` (fallback in offline mode) |
| `lib/features/kitchen/kitchen_screen.dart` | 447 | `'Restaurant'` (fallback display) |
| `lib/features/super_admin/super_admin_screen.dart` | 79 | `'Restaurants'` (nav item label) |
| `lib/features/super_admin/super_admin_screen.dart` | 701 | `'Add Restaurant'` (FAB label) |
| `lib/features/super_admin/super_admin_screen.dart` | 979 | `'Restaurant updated'` / `'Restaurant created'` (toast messages) |
| `lib/features/super_admin/super_admin_screen.dart` | 1004 | `'Edit Restaurant'` / `'Add Restaurant'` (sheet title) |
| `lib/features/super_admin/super_admin_screen.dart` | 1142 | `'Restaurant deactivated'` (toast message) |
| `lib/features/super_admin/super_admin_screen.dart` | 1251 | `'All Restaurants'` (dropdown default) |
| `lib/features/super_admin/super_admin_screen.dart` | 1258 | `'All Restaurants'` (dropdown label) |
| `lib/features/super_admin/super_admin_screen.dart` | 1374 | `'Restaurant'` (column header, conditional) |
| `lib/features/admin/admin_screen.dart` | 73 | `Icons.restaurant_menu` (Flutter icon constant -- not a rename target) |
| `lib/features/admin/admin_screen.dart` | 151 | `Icons.restaurant_menu` (Flutter icon constant -- not a rename target) |
| `lib/features/kitchen/kitchen_screen.dart` | 219 | `Icons.restaurant_menu` (Flutter icon constant -- not a rename target) |
| `lib/features/order/order_provider.dart` | 420 | `'...this restaurant.'` (error message) |
| `lib/features/order/order_provider.dart` | 430 | `'This restaurant does not support...'` (error message) |
| `lib/features/super_admin/super_admin_provider.dart` | 54 | `'Only super_admin can create restaurants'` (error message) |
| `lib/features/super_admin/super_admin_provider.dart` | 211 | `'Failed to load restaurants: ...'` (error message) |
| `lib/features/super_admin/super_admin_provider.dart` | 267 | `'Failed to create restaurant: ...'` (error message) |
| `lib/features/super_admin/super_admin_provider.dart` | 300 | `'Failed to update restaurant: ...'` (error message) |
| `lib/features/super_admin/super_admin_provider.dart` | 315 | `'Failed to deactivate restaurant: ...'` (error message) |
| `lib/features/onboarding/onboarding_provider.dart` | 77 | `'Failed to create restaurant: ...'` (error message) |
| `lib/features/onboarding/onboarding_provider.dart` | 88 | `'Missing user or restaurant setup information.'` (error message) |
| `lib/features/cashier/cashier_screen.dart` | 169 | `restaurantName: 'GLOBOS POS'` (receipt builder -- not a rename target) |

**Note:** `Icons.restaurant_menu` is a Flutter Material icon constant and should NOT be renamed.

**Total: ~29 UI string references (excluding Flutter icon constants)**

---

## Category 7: Comments and Documentation

| File | Line | Comment text |
|------|------|-------------|
| `lib/core/router/app_router.dart` | 84 | `// super_admin이 /admin/:restaurantId에 접근하는 건 허용` |
| `lib/core/router/app_router.dart` | 111 | `// 6-D. /admin/:restaurantId 는 super_admin 전용` |
| `lib/features/super_admin/super_admin_provider.dart` | 123 | `/// Returns restaurants filtered by selected brand and store type` |
| `lib/features/kitchen/kitchen_provider.dart` | 248 | `error: 'Failed to update item status: restaurant context missing'` (embedded in error string) |
| `lib/features/super_admin/super_admin_screen.dart` | 84 | `// admin can only create staff for their own restaurant` (in create_staff_user but also mirrored in comments) |

**Total: 5 comment/documentation references**

---

## File-Level Summary

| # | File Path | Count |
|---|-----------|-------|
| 1 | `lib/features/admin/tabs/inventory_tab.dart` | 49 |
| 2 | `lib/features/waiter/waiter_screen.dart` | 58 |
| 3 | `lib/features/admin/tabs/qc_tab.dart` | 45 |
| 4 | `lib/features/qc/qc_provider.dart` | 44 |
| 5 | `lib/features/admin/providers/settings_provider.dart` | 36 |
| 6 | `lib/features/admin/tabs/settings_tab.dart` | 38 |
| 7 | `lib/features/admin/tabs/reports_tab.dart` | 33 |
| 8 | `lib/features/inventory/inventory_provider.dart` | 33 |
| 9 | `lib/features/admin/tabs/tables_tab.dart` | 31 |
| 10 | `lib/features/order/order_provider.dart` | 30 |
| 11 | `lib/core/services/inventory_service.dart` | 28 |
| 12 | `lib/features/kitchen/kitchen_screen.dart` | 23 |
| 13 | `lib/core/services/qc_service.dart` | 22 |
| 14 | `lib/features/payment/payment_provider.dart` | 21 |
| 15 | `lib/features/kitchen/kitchen_provider.dart` | 21 |
| 16 | `lib/features/onboarding/onboarding_provider.dart` | 20 |
| 17 | `lib/features/cashier/cashier_screen.dart` | 20 |
| 18 | `lib/core/services/order_service.dart` | 16 |
| 19 | `lib/features/admin/tabs/staff_tab.dart` | 16 |
| 20 | `lib/core/services/attendance_service.dart` | 14 |
| 21 | `lib/core/services/restaurant_service.dart` | 13 |
| 22 | `lib/features/admin/providers/staff_provider.dart` | 13 |
| 23 | `lib/core/services/pin_service.dart` | 13 |
| 24 | `lib/features/admin/tabs/attendance_tab.dart` | 12 |
| 25 | `lib/features/qc/qc_check_screen.dart` | 12 |
| 26 | `lib/features/onboarding/onboarding_screen.dart` | 11 |
| 27 | `lib/features/attendance/fingerprint_provider.dart` | 11 |
| 28 | `lib/features/attendance/attendance_kiosk_screen.dart` | 11 |
| 29 | `lib/features/table/table_provider.dart` | 9 |
| 30 | `lib/features/admin/tabs/menu_tab.dart` | 9 |
| 31 | `lib/features/report/report_provider.dart` | 9 |
| 32 | `lib/core/services/menu_service.dart` | 8 |
| 33 | `lib/features/admin/widgets/admin_audit_trace_panel.dart` | 9 |
| 34 | `lib/features/admin/admin_screen.dart` | 7 |
| 35 | `lib/features/admin/providers/menu_provider.dart` | 7 |
| 36 | `lib/features/admin/providers/tables_provider.dart` | 7 |
| 37 | `lib/core/router/app_router.dart` | 6 |
| 38 | `lib/core/services/tables_service.dart` | 6 |
| 39 | `lib/features/delivery/delivery_settlement_provider.dart` | 6 |
| 40 | `lib/core/services/payroll_service.dart` | 5 |
| 41 | `lib/features/admin/providers/admin_audit_provider.dart` | 5 |
| 42 | `lib/features/super_admin/super_admin_provider.dart` | 68 |
| 43 | `lib/features/super_admin/super_admin_screen.dart` | 59 |
| 44 | `lib/features/auth/auth_state.dart` | 4 |
| 45 | `lib/core/services/staff_service.dart` | 4 |
| 46 | `lib/core/services/payment_service.dart` | 4 |
| 47 | `lib/core/services/daily_closing_service.dart` | 4 |
| 48 | `lib/core/services/admin_audit_service.dart` | 4 |
| 49 | `lib/features/delivery/delivery_models.dart` | 3 |
| 50 | `lib/core/models/pos_table.dart` | 3 |
| 51 | `lib/features/admin/providers/daily_closing_provider.dart` | 3 |
| 52 | `lib/core/hardware/receipt_builder.dart` | 2 |
| 53 | `lib/features/auth/auth_provider.dart` | 2 |
| 54 | `lib/features/delivery/screens/delivery_settlement_tab.dart` | 2 |
| 55 | `lib/core/services/connectivity_service.dart` | 2 |
