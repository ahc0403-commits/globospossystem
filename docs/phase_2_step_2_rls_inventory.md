---
title: "Phase 2 Step 2 — RLS Policy Inventory"
version: "1.0"
date: "2026-04-12"
status: "static analysis complete"
---

# Phase 2 Step 2 — RLS Policy Inventory

## Summary
- Total active policies: 35
- Policies referencing restaurant_id: 28
- Policies on restaurants table: 1 (restaurants_select_policy)

## Methodology

Policies are listed as **currently active** after applying all migrations in filename order through `20260410000003`. Later migrations DROP and recreate policies from earlier ones; only the final surviving version is documented.

Key supersession chain:
- `20260402000000` created initial `*_policy` FOR ALL policies on all core tables
- `20260408000001` dropped and recreated `*_policy` on tables/menu_categories/menu_items/orders/order_items/payments/attendance_logs/inventory_items with `is_super_admin() OR` prefix + WITH CHECK
- `20260409000009` dropped `users_policy`, `restaurants_policy`, and the `*_policy` on tables/menu_categories/menu_items; created granular SELECT/INSERT/UPDATE/DELETE replacements
- `20260409000010` dropped the INSERT/UPDATE/DELETE write policies from `20260409000009` for restaurants/tables/menu_categories/menu_items (writes moved to SECURITY DEFINER RPCs)
- `20260409000012` rewrote companies/brands/audit_logs/office_payroll_reviews policies to remove office_user_profiles references
- `20260409000013` dropped 12 `office_read_*` policies and office-only tables

## Active Policies

### users

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `users_select_policy` | SELECT | `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())` | YES (column) | 20260409000009 |

### restaurants

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `restaurants_select_policy` | SELECT | `USING (is_super_admin() OR id = get_user_restaurant_id())` | YES (via get_user_restaurant_id) | 20260409000009 |

> Note: INSERT/UPDATE policies were created in 20260409000009 but dropped in 20260409000010. Writes go through admin RPCs only.

### tables

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `tables_select_policy` | SELECT | `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())` | YES | 20260409000009 |

> Note: INSERT/UPDATE/DELETE policies from 20260409000009 were dropped in 20260409000010. Writes go through admin RPCs.

### menu_categories

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `menu_categories_select_policy` | SELECT | `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())` | YES | 20260409000009 |

> Note: INSERT/UPDATE/DELETE policies from 20260409000009 were dropped in 20260409000010. Writes go through admin RPCs.

### menu_items

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `menu_items_select_policy` | SELECT | `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())` | YES | 20260409000009 |

> Note: INSERT/UPDATE/DELETE policies from 20260409000009 were dropped in 20260409000010. Writes go through admin RPCs.

### orders

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `orders_policy` | ALL | `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id()) WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id())` | YES | 20260408000001 |

### order_items

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `order_items_policy` | ALL | `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id()) WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id())` | YES | 20260408000001 |

### payments

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `payments_policy` | ALL | `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id()) WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id())` | YES | 20260408000001 |

### attendance_logs

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `attendance_logs_policy` | ALL | `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id()) WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id())` | YES | 20260408000001 |

### inventory_items

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `inventory_items_policy` | ALL | `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id()) WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id())` | YES | 20260408000001 |

### external_sales

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `external_sales_read` | SELECT | `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())` | YES | 20260405000011 |

> Note: `external_sales_insert` was created in 20260405000011 but dropped in 20260409000009. `external_sales_policy` from initial schema was dropped in 20260408000001.

### delivery_settlements

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `delivery_settlements_read` | SELECT | `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())` | YES | 20260405000011 |
| `delivery_settlements_insert` | INSERT | `WITH CHECK (restaurant_id = get_user_restaurant_id())` | YES | 20260405000011 |
| `delivery_settlements_confirm` | UPDATE | `USING (restaurant_id = get_user_restaurant_id() AND has_any_role(ARRAY['admin','super_admin'])) WITH CHECK (restaurant_id = get_user_restaurant_id())` | YES | 20260405000011 |

> Note: `delivery_settlements_insert` was dropped in 20260409000009.

### delivery_settlement_items

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `settlement_items_read` | SELECT | `USING (EXISTS (SELECT 1 FROM delivery_settlements ds WHERE ds.id = delivery_settlement_items.settlement_id AND (is_super_admin() OR ds.restaurant_id = get_user_restaurant_id())))` | YES (via join) | 20260405000011 |
| `settlement_items_insert` | INSERT | `WITH CHECK (EXISTS (SELECT 1 FROM delivery_settlements ds WHERE ds.id = delivery_settlement_items.settlement_id AND ds.restaurant_id = get_user_restaurant_id()))` | YES (via join) | 20260405000011 |

### menu_recipes

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `restaurant_isolation` | ALL | `USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin'])) WITH CHECK (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']))` | YES | 20260403000002 |

### inventory_transactions

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `restaurant_isolation` | ALL | `USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin'])) WITH CHECK (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']))` | YES | 20260403000002 |

### inventory_physical_counts

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `restaurant_isolation` | ALL | `USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin'])) WITH CHECK (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']))` | YES | 20260403000002 |

### staff_wage_configs

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `restaurant_isolation` | ALL | `USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']))` | YES | 20260403000000 |

### payroll_records

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `restaurant_isolation` | ALL | `USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']))` | YES | 20260403000000 |

### qc_templates

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `qc_templates_select` | SELECT | `USING (is_global = TRUE OR restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']))` | YES | 20260403000004 |
| `qc_templates_insert` | INSERT | `WITH CHECK (has_any_role(ARRAY['super_admin']) OR (has_any_role(ARRAY['admin']) AND is_global = FALSE AND restaurant_id = get_user_restaurant_id()))` | YES | 20260403000004 |
| `qc_templates_update` | UPDATE | `USING (has_any_role(ARRAY['super_admin']) OR (has_any_role(ARRAY['admin']) AND is_global = FALSE AND restaurant_id = get_user_restaurant_id()))` | YES | 20260403000004 |
| `qc_templates_delete` | DELETE | `USING (has_any_role(ARRAY['super_admin']) OR (has_any_role(ARRAY['admin']) AND is_global = FALSE AND restaurant_id = get_user_restaurant_id()))` | YES | 20260403000004 |

### qc_checks

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `restaurant_isolation` | ALL | `USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']))` | YES | 20260403000001 |

### qc_followups

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `qc_followups_restaurant_isolation` | ALL | `USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']))` | YES | 20260410000002 |

### restaurant_settings

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `admin_only` | ALL | `USING (restaurant_id = get_user_restaurant_id() AND has_any_role(ARRAY['admin','super_admin'])) WITH CHECK (restaurant_id = get_user_restaurant_id() AND has_any_role(ARRAY['admin','super_admin']))` | YES | 20260403000003 |

### fingerprint_templates

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `fingerprint_templates_service_policy` | ALL (service_role) | `USING (true)` | NO | 20260402000003 |

> Note: `fingerprint_templates_restaurant_policy` was dropped in 20260409000009 (dormant feature closure). Only service_role access remains.

### audit_logs

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `audit_logs_admin_read` | SELECT | `USING (EXISTS (SELECT 1 FROM users u WHERE u.auth_id = auth.uid() AND u.role IN ('admin', 'super_admin')))` | NO (role check only) | 20260409000012 |

### companies

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `companies_scoped_read` | SELECT | `USING (EXISTS (SELECT 1 FROM users u WHERE u.auth_id = auth.uid() AND u.role IN ('admin', 'super_admin')))` | NO (role check only) | 20260409000012 |

### brands

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `brands_scoped_read` | SELECT | `USING (EXISTS (SELECT 1 FROM users u WHERE u.auth_id = auth.uid() AND u.role IN ('admin', 'super_admin')))` | NO (role check only) | 20260409000012 |

### office_payroll_reviews

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `office_payroll_reviews_scoped_select` | SELECT | `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())` | YES | 20260409000012 |
| `office_payroll_reviews_pos_update` | UPDATE | `USING (has_any_role(ARRAY['admin','super_admin']) AND (is_super_admin() OR restaurant_id = get_user_restaurant_id())) WITH CHECK (has_any_role(ARRAY['admin','super_admin']) AND (is_super_admin() OR restaurant_id = get_user_restaurant_id()))` | YES | 20260409000012 |

### daily_closings

> RLS enabled but NO policies defined. All access is through SECURITY DEFINER RPCs (`create_daily_closing`, `get_daily_closings`).

### storage.objects

| Policy | Operation | Expression | Refs restaurant_id | Source |
|--------|-----------|------------|-------------------|--------|
| `storage_attendance_scoped` | ALL | Path-based: `(storage.foldername(name))[1] = u.restaurant_id::text` or super_admin | YES (via path) | 20260408000000 |
| `storage_qc_scoped` | ALL | Path-based: `(storage.foldername(name))[1] = u.restaurant_id::text` or super_admin | YES (via path) | 20260408000000 |
| `authenticated_access_qc_photos` | ALL | `bucket_id = 'qc-photos' AND auth.role() = 'authenticated'` | NO | 20260403000001 |

## Rename Impact Summary

All 28 policies referencing `restaurant_id` use one of these patterns:
1. **Direct column**: `restaurant_id = get_user_restaurant_id()` -- most common
2. **ID equality on restaurants table**: `id = get_user_restaurant_id()`
3. **Subquery join**: `EXISTS (... ds.restaurant_id = get_user_restaurant_id())`
4. **Storage path**: `(storage.foldername(name))[1] = u.restaurant_id::text`

The rename will need to update:
- The `restaurant_id` column name across all tables
- The `get_user_restaurant_id()` helper function
- The `restaurants` table name
- Storage path conventions referencing `restaurant_id`
