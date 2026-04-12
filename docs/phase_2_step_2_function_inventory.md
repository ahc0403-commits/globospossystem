---
title: "Phase 2 Step 2 — Function & Trigger Inventory"
version: "1.0"
date: "2026-04-12"
status: "static analysis complete"
---

# Phase 2 Step 2 — Function & Trigger Inventory

## Summary
- Total active functions: 38
- Functions referencing restaurant_id: 33
- Functions referencing restaurants table: 8
- Triggers: 1

## Methodology

Functions use `CREATE OR REPLACE FUNCTION`, so the last migration to define a function wins. Only the final definition is documented. The source migration listed is the one containing the currently active version.

---

## RLS Helper Functions

These are foundational helpers used by every RLS policy and most RPCs.

### 1. `get_user_restaurant_id() RETURNS UUID`

**Source**: `20260402000000_initial_schema.sql` (search_path set in `20260408000000`)

**Body**: `SELECT restaurant_id FROM users WHERE auth_id = auth.uid()`

**Restaurant refs**: `restaurant_id` column in `users` table

**Security**: DEFINER, STABLE

---

### 2. `get_user_role() RETURNS TEXT`

**Source**: `20260402000000_initial_schema.sql` (search_path set in `20260408000000`)

**Body**: `SELECT role FROM users WHERE auth_id = auth.uid()`

**Restaurant refs**: None directly, but reads from `users` table

**Security**: DEFINER, STABLE

---

### 3. `has_any_role(required_roles TEXT[]) RETURNS BOOLEAN`

**Source**: `20260402000000_initial_schema.sql` (search_path set in `20260408000000`)

**Body**: `SELECT role = ANY(required_roles) FROM users WHERE auth_id = auth.uid()`

**Restaurant refs**: None directly

**Security**: DEFINER, STABLE

---

### 4. `is_super_admin() RETURNS BOOLEAN`

**Source**: `20260402000000_initial_schema.sql` (search_path set in `20260408000000`)

**Body**: `SELECT EXISTS (SELECT 1 FROM users WHERE auth_id = auth.uid() AND role = 'super_admin')`

**Restaurant refs**: None directly

**Security**: DEFINER, STABLE

---

## Order Lifecycle RPCs

### 5. `create_order(p_restaurant_id UUID, p_table_id UUID, p_items JSONB) RETURNS orders`

**Source**: `20260409000000_dine_in_sales_contract_closure.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `v_actor.restaurant_id` comparison
- `tables WHERE restaurant_id = p_restaurant_id`
- `menu_items m WHERE m.restaurant_id = p_restaurant_id`
- INSERT into `orders` with `restaurant_id`
- INSERT into `order_items` with `restaurant_id`
- Audit log `restaurant_id`

---

### 6. `create_buffet_order(p_restaurant_id UUID, p_table_id UUID, p_guest_count INT, p_extra_items JSONB) RETURNS orders`

**Source**: `20260409000000_dine_in_sales_contract_closure.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `v_actor.restaurant_id` comparison
- `tables WHERE restaurant_id = p_restaurant_id`
- `restaurants WHERE id = p_restaurant_id` (reads operation_mode, per_person_charge)
- INSERT into `orders`/`order_items` with `restaurant_id`
- Audit log `restaurant_id`

---

### 7. `add_items_to_order(p_order_id UUID, p_restaurant_id UUID, p_items JSONB) RETURNS SETOF order_items`

**Source**: `20260409000000_dine_in_sales_contract_closure.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `v_actor.restaurant_id` comparison
- `orders WHERE restaurant_id = p_restaurant_id`
- `menu_items m WHERE m.restaurant_id = p_restaurant_id`
- INSERT into `order_items` with `restaurant_id`
- Audit log `restaurant_id`

---

### 8. `process_payment(p_order_id UUID, p_restaurant_id UUID, p_amount DECIMAL, p_method TEXT) RETURNS payments`

**Source**: `20260409000014_order_lifecycle_completion.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `v_actor.restaurant_id` comparison
- `orders WHERE restaurant_id = p_restaurant_id`
- INSERT into `payments` with `restaurant_id`
- `menu_recipes mr WHERE mr.restaurant_id = p_restaurant_id`
- `inventory_items WHERE restaurant_id = p_restaurant_id`
- INSERT into `inventory_transactions` with `restaurant_id`
- Audit log `restaurant_id`

**Note**: This is the central atomic payment handler. It also performs inventory deduction (excluding cancelled items) and table status release.

---

### 9. `cancel_order(p_order_id UUID, p_restaurant_id UUID) RETURNS orders`

**Source**: `20260409000000_dine_in_sales_contract_closure.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `v_actor.restaurant_id` comparison
- `orders WHERE restaurant_id = p_restaurant_id`
- Audit log `restaurant_id`

---

### 10. `cancel_order_item(p_item_id UUID, p_restaurant_id UUID) RETURNS order_items`

**Source**: `20260409000014_order_lifecycle_completion.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `v_actor.restaurant_id` comparison
- `order_items WHERE restaurant_id = p_restaurant_id`
- Audit log `restaurant_id`

---

### 11. `edit_order_item_quantity(p_item_id UUID, p_restaurant_id UUID, p_new_quantity INT) RETURNS order_items`

**Source**: `20260409000014_order_lifecycle_completion.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `v_actor.restaurant_id` comparison
- `order_items WHERE restaurant_id = p_restaurant_id`
- Audit log `restaurant_id`

---

### 12. `transfer_order_table(p_order_id UUID, p_restaurant_id UUID, p_new_table_id UUID) RETURNS orders`

**Source**: `20260409000014_order_lifecycle_completion.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `v_actor.restaurant_id` comparison
- `orders WHERE restaurant_id = p_restaurant_id`
- `tables WHERE restaurant_id = p_restaurant_id`
- Audit log `restaurant_id`

---

### 13. `update_order_item_status(p_item_id UUID, p_restaurant_id UUID, p_new_status TEXT) RETURNS order_items`

**Source**: `20260409000014_order_lifecycle_completion.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `v_actor.restaurant_id` comparison
- `order_items WHERE restaurant_id = p_restaurant_id`
- Audit log `restaurant_id`

---

## Admin Mutation RPCs

### 14. `require_admin_actor_for_restaurant(p_restaurant_id UUID) RETURNS users`

**Source**: `20260409000010_bundle_b1_admin_mutation_rpcs.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `v_actor.restaurant_id <> p_restaurant_id` check

**Note**: Shared helper used by all admin table/menu/restaurant mutation RPCs.

---

### 15. `admin_create_restaurant(p_name, p_slug, p_operation_mode, p_address, p_per_person_charge, p_brand_id, p_store_type) RETURNS restaurants`

**Source**: `20260409000010_bundle_b1_admin_mutation_rpcs.sql`

**Restaurant refs**:
- INSERT into `restaurants` table
- Audit log `restaurant_id`

---

### 16. `admin_update_restaurant(p_restaurant_id UUID, p_name, p_slug, p_operation_mode, ...) RETURNS restaurants`

**Source**: `20260409000010_bundle_b1_admin_mutation_rpcs.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `restaurants WHERE id = p_restaurant_id`
- Calls `require_admin_actor_for_restaurant`
- UPDATE `restaurants`
- Audit log `restaurant_id`

---

### 17. `admin_deactivate_restaurant(p_restaurant_id UUID) RETURNS restaurants`

**Source**: `20260409000010_bundle_b1_admin_mutation_rpcs.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `restaurants WHERE id = p_restaurant_id`
- Calls `require_admin_actor_for_restaurant`
- Audit log `restaurant_id`

---

### 18. `admin_update_restaurant_settings(p_restaurant_id UUID, p_name, p_operation_mode, p_address, p_per_person_charge) RETURNS restaurants`

**Source**: `20260409000010_bundle_b1_admin_mutation_rpcs.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `restaurants WHERE id = p_restaurant_id`
- Calls `require_admin_actor_for_restaurant`
- UPDATE `restaurants`
- Audit log `restaurant_id`

---

### 19. `admin_create_table(p_restaurant_id UUID, p_table_number TEXT, p_seat_count INT) RETURNS tables`

**Source**: `20260409000010_bundle_b1_admin_mutation_rpcs.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- Calls `require_admin_actor_for_restaurant(p_restaurant_id)`
- INSERT into `tables` with `restaurant_id`
- Audit log `restaurant_id`

---

### 20. `admin_update_table(p_table_id UUID, p_table_number, p_seat_count, p_status) RETURNS tables`

**Source**: `20260409000010_bundle_b1_admin_mutation_rpcs.sql`

**Restaurant refs**:
- `v_existing.restaurant_id` (from table row)
- Calls `require_admin_actor_for_restaurant(v_existing.restaurant_id)`
- Audit log `restaurant_id`

---

### 21. `admin_delete_table(p_table_id UUID) RETURNS tables`

**Source**: `20260409000010_bundle_b1_admin_mutation_rpcs.sql`

**Restaurant refs**:
- `v_existing.restaurant_id`
- Calls `require_admin_actor_for_restaurant(v_existing.restaurant_id)`
- Audit log `restaurant_id`

---

### 22. `admin_create_menu_category(p_restaurant_id UUID, p_name TEXT, p_sort_order INT) RETURNS menu_categories`

**Source**: `20260409000010_bundle_b1_admin_mutation_rpcs.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- Calls `require_admin_actor_for_restaurant(p_restaurant_id)`
- INSERT with `restaurant_id`
- Audit log `restaurant_id`

---

### 23. `admin_update_menu_category(p_category_id UUID, p_name, p_sort_order, p_is_active) RETURNS menu_categories`

**Source**: `20260409000010_bundle_b1_admin_mutation_rpcs.sql`

**Restaurant refs**:
- `v_existing.restaurant_id`
- Calls `require_admin_actor_for_restaurant(v_existing.restaurant_id)`
- Audit log `restaurant_id`

---

### 24. `admin_delete_menu_category(p_category_id UUID) RETURNS menu_categories`

**Source**: `20260409000010_bundle_b1_admin_mutation_rpcs.sql`

**Restaurant refs**:
- `v_existing.restaurant_id`
- Calls `require_admin_actor_for_restaurant(v_existing.restaurant_id)`
- Audit log `restaurant_id`

---

### 25. `admin_create_menu_item(p_restaurant_id UUID, p_category_id, p_name, p_price, ...) RETURNS menu_items`

**Source**: `20260409000010_bundle_b1_admin_mutation_rpcs.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- Calls `require_admin_actor_for_restaurant(p_restaurant_id)`
- `menu_categories WHERE restaurant_id = p_restaurant_id`
- INSERT with `restaurant_id`
- Audit log `restaurant_id`

---

### 26. `admin_update_menu_item(p_item_id UUID, p_category_id, p_name, ...) RETURNS menu_items`

**Source**: `20260409000010_bundle_b1_admin_mutation_rpcs.sql`

**Restaurant refs**:
- `v_existing.restaurant_id`
- Calls `require_admin_actor_for_restaurant(v_existing.restaurant_id)`
- `menu_categories WHERE restaurant_id = v_existing.restaurant_id`
- Audit log `restaurant_id`

---

### 27. `admin_delete_menu_item(p_item_id UUID) RETURNS menu_items`

**Source**: `20260409000010_bundle_b1_admin_mutation_rpcs.sql`

**Restaurant refs**:
- `v_existing.restaurant_id`
- Calls `require_admin_actor_for_restaurant(v_existing.restaurant_id)`
- Audit log `restaurant_id`

---

## Inventory RPCs

### 28. `get_inventory_ingredient_catalog(p_restaurant_id UUID) RETURNS TABLE`

**Source**: `20260409000001_inventory_ingredient_catalog_contracts.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, `inventory_items WHERE restaurant_id = p_restaurant_id`

---

### 29. `create_inventory_item(p_restaurant_id UUID, p_name, p_unit, ...) RETURNS inventory_items`

**Source**: `20260409000001_inventory_ingredient_catalog_contracts.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, INSERT with `restaurant_id`, duplicate check via `restaurant_id`, audit log

---

### 30. `update_inventory_item(p_item_id UUID, p_restaurant_id UUID, p_patch JSONB) RETURNS inventory_items`

**Source**: `20260409000001_inventory_ingredient_catalog_contracts.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, `inventory_items WHERE restaurant_id = p_restaurant_id`, audit log

---

### 31. `get_inventory_recipe_catalog(p_restaurant_id UUID, p_menu_item_id UUID) RETURNS TABLE`

**Source**: `20260409000002_inventory_recipe_bom_contracts.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, joins with `menu_items`/`inventory_items`/`menu_recipes` all filtered by `restaurant_id`

---

### 32. `upsert_inventory_recipe_line(p_restaurant_id UUID, p_menu_item_id, p_ingredient_id, p_quantity_g) RETURNS TABLE`

**Source**: `20260409000003_inventory_recipe_bom_contracts_fix.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, `menu_items`/`inventory_items`/`menu_recipes` all filtered by `restaurant_id`, audit log

---

### 33. `get_inventory_physical_count_sheet(p_restaurant_id UUID, p_count_date DATE) RETURNS TABLE`

**Source**: `20260409000004_inventory_physical_count_contracts.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, joins filtered by `restaurant_id`

---

### 34. `apply_inventory_physical_count_line(p_restaurant_id UUID, p_count_date, p_ingredient_id, p_actual_quantity_g, p_note) RETURNS TABLE`

**Source**: `20260409000005_inventory_physical_count_contracts_fix.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, `inventory_items`/`inventory_physical_counts`/`inventory_transactions` all filtered by `restaurant_id`, audit log

---

### 35. `get_inventory_transaction_visibility(p_restaurant_id UUID, p_from TIMESTAMPTZ, p_to TIMESTAMPTZ) RETURNS TABLE`

**Source**: `20260409000006_inventory_transaction_visibility_contracts.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, `inventory_transactions WHERE restaurant_id`, join `inventory_items WHERE restaurant_id`

---

### 36. `restock_inventory_item(p_restaurant_id UUID, p_ingredient_id UUID, p_quantity_g DECIMAL, p_note TEXT) RETURNS VOID`

**Source**: `20260410000001_inventory_restock_waste_rpc.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, `inventory_items WHERE restaurant_id`, INSERT `inventory_transactions` with `restaurant_id`, audit log

---

### 37. `record_inventory_waste(p_restaurant_id UUID, p_ingredient_id UUID, p_quantity_g DECIMAL, p_note TEXT) RETURNS VOID`

**Source**: `20260410000001_inventory_restock_waste_rpc.sql`

**Restaurant refs**: Same pattern as `restock_inventory_item`

---

## Attendance RPCs

### 38. `get_attendance_staff_directory(p_restaurant_id UUID) RETURNS TABLE`

**Source**: `20260409000007_attendance_event_capture_contracts.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, `users WHERE restaurant_id = p_restaurant_id`

---

### 39. `get_attendance_log_view(p_restaurant_id UUID, p_from, p_to, p_user_id) RETURNS TABLE`

**Source**: `20260409000007_attendance_event_capture_contracts.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, `attendance_logs WHERE restaurant_id`, `users WHERE restaurant_id`, `users WHERE u.restaurant_id = p_restaurant_id` (validation)

---

### 40. `record_attendance_event(p_restaurant_id UUID, p_user_id, p_type, p_photo_url, p_photo_thumbnail_url) RETURNS TABLE`

**Source**: `20260409000007_attendance_event_capture_contracts.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, `users WHERE restaurant_id = p_restaurant_id`, INSERT `attendance_logs` with `restaurant_id`, audit log

---

## QC RPCs

### 41. `get_qc_templates(p_restaurant_id UUID, p_scope TEXT) RETURNS TABLE`

**Source**: `20260409000008_qc_contract_closure.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, `qc_templates WHERE restaurant_id = p_restaurant_id`

---

### 42. `create_qc_template(p_category, p_criteria_text, p_restaurant_id UUID, ...) RETURNS qc_templates`

**Source**: `20260409000008_qc_contract_closure.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, INSERT with `restaurant_id`, audit log

---

### 43. `update_qc_template(p_template_id UUID, p_patch JSONB) RETURNS qc_templates`

**Source**: `20260409000008_qc_contract_closure.sql`

**Restaurant refs**: `v_existing.restaurant_id` comparison with `v_actor.restaurant_id`, audit log

---

### 44. `deactivate_qc_template(p_template_id UUID) RETURNS qc_templates`

**Source**: `20260409000008_qc_contract_closure.sql`

**Restaurant refs**: `v_existing.restaurant_id` comparison, audit log

---

### 45. `get_qc_checks(p_restaurant_id UUID, p_from DATE, p_to DATE) RETURNS TABLE`

**Source**: `20260409000008_qc_contract_closure.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, `qc_checks WHERE restaurant_id = p_restaurant_id`

---

### 46. `upsert_qc_check(p_restaurant_id UUID, p_template_id, p_check_date, p_result, ...) RETURNS qc_checks`

**Source**: `20260409000008_qc_contract_closure.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, `qc_templates WHERE restaurant_id = p_restaurant_id`, INSERT/UPSERT with `restaurant_id`, audit log

---

### 47. `get_qc_superadmin_summary(p_week_start DATE) RETURNS TABLE`

**Source**: `20260409000008_qc_contract_closure.sql`

**Restaurant refs**: `restaurants WHERE is_active = TRUE` (active_restaurants CTE), `qc_templates WHERE restaurant_id = ar.id`, `qc_checks.restaurant_id`

---

### 48. `create_qc_followup(p_restaurant_id UUID, p_source_check_id UUID, p_assigned_to_name TEXT) RETURNS qc_followups`

**Source**: `20260410000002_qc_followup_and_analytics.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, `qc_checks WHERE restaurant_id = p_restaurant_id`, INSERT with `restaurant_id`, audit log

---

### 49. `update_qc_followup_status(p_followup_id UUID, p_restaurant_id UUID, p_status, p_resolution_notes) RETURNS qc_followups`

**Source**: `20260410000002_qc_followup_and_analytics.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, `qc_followups WHERE restaurant_id = p_restaurant_id`, audit log

---

### 50. `get_qc_followups(p_restaurant_id UUID, p_status_filter TEXT) RETURNS TABLE`

**Source**: `20260410000002_qc_followup_and_analytics.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, `qc_followups WHERE restaurant_id = p_restaurant_id`

---

### 51. `get_qc_analytics(p_restaurant_id UUID, p_from DATE, p_to DATE) RETURNS TABLE`

**Source**: `20260410000002_qc_followup_and_analytics.sql`

**Restaurant refs**: `p_restaurant_id` param, `v_actor.restaurant_id` check, `qc_checks WHERE restaurant_id = p_restaurant_id`, `qc_templates WHERE restaurant_id = p_restaurant_id`, `qc_followups WHERE restaurant_id = p_restaurant_id`

---

## User Management RPCs

### 52. `update_my_profile_full_name(p_full_name TEXT) RETURNS users`

**Source**: `20260409000009_bundle_a_security_closure.sql`

**Restaurant refs**: None directly (operates on authenticated user's own record)

---

### 53. `admin_update_staff_account(p_user_id UUID, p_restaurant_id UUID, p_full_name, p_is_active, p_extra_permissions) RETURNS users`

**Source**: `20260409000009_bundle_a_security_closure.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `v_actor.restaurant_id <> p_restaurant_id` check
- `users WHERE id = p_user_id AND restaurant_id = p_restaurant_id`
- Audit log `restaurant_id`

---

### 54. `complete_onboarding_account_setup(p_restaurant_id UUID, p_full_name TEXT, p_role TEXT) RETURNS users`

**Source**: `20260409000009_bundle_a_security_closure.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- UPDATE `users SET restaurant_id = p_restaurant_id`
- Audit log `restaurant_id`

---

## Reporting RPCs

### 55. `get_admin_mutation_audit_trace(p_restaurant_id UUID, p_limit INT) RETURNS TABLE`

**Source**: `20260409000015_admin_operational_visibility.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `v_actor.restaurant_id` check
- `al.details ->> 'restaurant_id' = p_restaurant_id` filter
- `al.entity_id = p_restaurant_id` for restaurants entity_type

---

### 56. `get_admin_today_summary(p_restaurant_id UUID) RETURNS JSONB`

**Source**: `20260410000003_inventory_low_stock_visibility.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `v_actor.restaurant_id` check
- `orders WHERE restaurant_id = p_restaurant_id`
- `order_items/orders WHERE o.restaurant_id = p_restaurant_id`
- `payments WHERE restaurant_id = p_restaurant_id`
- `tables WHERE restaurant_id = p_restaurant_id`
- `inventory_items WHERE restaurant_id = p_restaurant_id`

---

### 57. `get_cashier_today_summary(p_restaurant_id UUID) RETURNS JSONB`

**Source**: `20260409000016_cashier_waiter_field_usability.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `v_actor.restaurant_id` check
- `payments WHERE restaurant_id = p_restaurant_id`
- `orders WHERE restaurant_id = p_restaurant_id`

---

### 58. `create_daily_closing(p_restaurant_id UUID, p_notes TEXT) RETURNS JSONB`

**Source**: `20260410000003_inventory_low_stock_visibility.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `v_actor.restaurant_id` check
- `daily_closings WHERE restaurant_id = p_restaurant_id`
- `orders WHERE restaurant_id = p_restaurant_id`
- `order_items/orders WHERE o.restaurant_id = p_restaurant_id`
- `payments WHERE restaurant_id = p_restaurant_id`
- `inventory_items WHERE restaurant_id = p_restaurant_id`
- INSERT `daily_closings` with `restaurant_id`
- Audit log `restaurant_id`

---

### 59. `get_daily_closings(p_restaurant_id UUID, p_limit INT) RETURNS TABLE`

**Source**: `20260410000003_inventory_low_stock_visibility.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `v_actor.restaurant_id` check
- `daily_closings WHERE restaurant_id = p_restaurant_id`

---

## Delivery/Settlement RPCs

### 60. `confirm_delivery_settlement_received(p_settlement_id UUID, p_restaurant_id UUID) RETURNS delivery_settlements`

**Source**: `20260408000003_delivery_settlement_confirm_rpc.sql`

**Restaurant refs**:
- `p_restaurant_id` parameter
- `v_actor.restaurant_id <> p_restaurant_id` check
- `delivery_settlements WHERE restaurant_id = p_restaurant_id`
- Audit log `restaurant_id`

---

### 61. `office_get_accessible_store_ids() RETURNS uuid[]`

**Status**: **DROPPED** in `20260409000012_pos_native_auth_rewrite.sql`

> This function was defined in `20260405000012_store_type_classification.sql` but dropped in the POS-native auth rewrite. It is no longer active.

---

## Payroll RPCs

### 62. `office_confirm_payroll(p_payroll_id UUID) RETURNS payroll_records`

**Source**: `20260405000004_office_payroll_rpc.sql` (search_path set in `20260408000000`)

**Restaurant refs**: None directly. Reads/updates `payroll_records` by ID. Audit log does not include `restaurant_id`.

---

### 63. `office_return_payroll(p_payroll_id UUID) RETURNS payroll_records`

**Source**: `20260405000004_office_payroll_rpc.sql` (search_path set in `20260408000000`)

**Restaurant refs**: None directly. Same pattern as `office_confirm_payroll`.

---

## Trigger Functions

### 64. `on_payroll_store_submitted() RETURNS TRIGGER`

**Source**: `20260405000005_office_payroll_trigger.sql` (search_path set in `20260408000000`)

**Restaurant refs**:
- `NEW.restaurant_id` -- from trigger row (payroll_records)
- `restaurants WHERE id = NEW.restaurant_id` -- reads `brand_id`
- INSERT into `office_payroll_reviews` with `restaurant_id`

---

## Triggers

### 1. `trg_payroll_store_submitted`

**Source**: `20260405000005_office_payroll_trigger.sql`

**Target table**: `payroll_records`

**Event**: `AFTER UPDATE OF status`

**Condition**: `WHEN (NEW.status = 'store_submitted' AND OLD.status = 'draft')`

**Function**: `on_payroll_store_submitted()`

**Restaurant refs**: Indirect via trigger function (reads `NEW.restaurant_id`)

---

## Rename Impact Summary

### Functions by restaurant reference pattern

| Pattern | Count | Description |
|---------|-------|-------------|
| `p_restaurant_id` parameter | 30 | Explicit restaurant_id input parameter |
| `v_actor.restaurant_id` comparison | 30 | Actor tenant scoping check |
| `WHERE restaurant_id = p_restaurant_id` | 28 | Direct column filter in queries |
| `restaurants` table SELECT | 8 | Direct read from restaurants table |
| `restaurants` table INSERT/UPDATE | 3 | admin_create/update/deactivate_restaurant |
| `get_user_restaurant_id()` helper | 1 | Foundation function (all policies depend on this) |
| No restaurant reference | 5 | get_user_role, has_any_role, is_super_admin, update_my_profile_full_name, office_confirm/return_payroll |

### Critical rename targets

1. **`get_user_restaurant_id()`** -- Used by every RLS policy. Must be renamed or aliased.
2. **`require_admin_actor_for_restaurant(p_restaurant_id)`** -- Shared helper for all admin mutations. Parameter name contains "restaurant".
3. **`process_payment()`** -- Central atomic handler with deep restaurant_id usage.
4. **`on_payroll_store_submitted()`** -- Trigger function that reads from `restaurants` table.
5. **`admin_create_restaurant()` / `admin_update_restaurant()` / `admin_deactivate_restaurant()`** -- Function names contain "restaurant".
6. **`admin_update_restaurant_settings()`** -- Function name contains "restaurant".
7. **`complete_onboarding_account_setup()`** -- Exception message says `ONBOARDING_RESTAURANT_REQUIRED`.

### Exception message inventory (containing "restaurant")

- `RESTAURANT_ID_REQUIRED`
- `RESTAURANT_NAME_REQUIRED`
- `RESTAURANT_OPERATION_MODE_REQUIRED`
- `RESTAURANT_NOT_FOUND`
- `RESTAURANT_CREATE_FORBIDDEN`
- `ONBOARDING_RESTAURANT_REQUIRED`

These are referenced by client-side Dart code and must be coordinated with the frontend rename.
