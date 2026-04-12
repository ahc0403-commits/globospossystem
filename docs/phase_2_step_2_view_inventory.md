---
title: "Phase 2 Step 2 — View Inventory"
version: "1.0"
date: "2026-04-12"
status: "static analysis complete"
---

# Phase 2 Step 2 — View Inventory

## Summary
- Total active views: 11
- Views referencing restaurants/restaurant_id: 11 (all views reference restaurants or restaurant_id)

## Methodology

Views are listed as **currently active** after applying all migrations through `20260410000003`. `CREATE OR REPLACE VIEW` replaces in-place; `DROP VIEW ... CREATE VIEW` replaces with column changes. Only the final surviving definition is documented.

Key supersession chain:
- `20260402000000` created `public_restaurant_profiles` and `public_menu_items`
- `20260405000012` created/replaced `v_store_daily_sales`, `v_store_attendance_summary`, `v_quality_monitoring`, `v_inventory_status`, `v_brand_kpi`, `v_external_store_sales`, `v_external_store_overview`
- `20260406000000` dropped and recreated `public_restaurant_profiles` and `public_menu_items` (added store_type/brand columns)
- `20260405000011` created `v_daily_revenue_by_channel` and `v_settlement_summary`

---

## Active Views

### 1. `public_restaurant_profiles`

**Source file**: `20260406000000_deliberry_store_type_integration.sql`

**SELECT body summary**: Selects restaurant profile fields (id, slug, name, address, operation_mode, per_person_charge, is_active, store_type, brand_id, brand_name) from `restaurants` joined with `brands`, filtered by `r.is_active = TRUE`.

**Tables referenced**: `restaurants`, `brands`

**Restaurant references**:
- `restaurants` table (aliased `r`) -- direct FROM
- `r.id`, `r.brand_id`, `r.store_type`, `r.name`, etc.

**Access**: `GRANT SELECT TO anon, authenticated`

---

### 2. `public_menu_items`

**Source file**: `20260406000000_deliberry_store_type_integration.sql`

**SELECT body summary**: Selects menu item fields (external_menu_item_id, restaurant_id, restaurant_slug, store_type, category_name, name, description, price, operation_mode) from `menu_items` joined with `restaurants` and `menu_categories`, filtered by `mi.is_available = TRUE AND mi.is_visible_public = TRUE`.

**Tables referenced**: `menu_items`, `restaurants`, `menu_categories`

**Restaurant references**:
- `mi.restaurant_id` -- column in SELECT
- `restaurants` table joined via `r.id = mi.restaurant_id`
- `r.slug`, `r.store_type`, `r.operation_mode`

**Access**: `GRANT SELECT TO anon, authenticated`

---

### 3. `v_store_daily_sales`

**Source file**: `20260405000012_store_type_classification.sql`

**SELECT body summary**: Aggregates daily payment totals per store. Groups by restaurant/brand/date. Computes `order_count`, `revenue` (is_revenue=true), `service_amount` (is_revenue=false). Filtered by `r.store_type = 'direct'`.

**Tables referenced**: `payments`, `restaurants`, `brands`

**Restaurant references**:
- `p.restaurant_id` joined to `restaurants`
- `r.id AS store_id`, `r.brand_id`, `r.name AS store_name`
- `r.store_type = 'direct'` filter

**Access**: `GRANT SELECT TO authenticated`

---

### 4. `v_store_attendance_summary`

**Source file**: `20260405000012_store_type_classification.sql`

**SELECT body summary**: Aggregates daily attendance per employee per store. Shows first clock_in, last clock_out, counts. Filtered by `r.store_type = 'direct'`.

**Tables referenced**: `attendance_logs`, `restaurants`, `users`

**Restaurant references**:
- `al.restaurant_id AS store_id`
- `restaurants` table joined via `r.id = al.restaurant_id`
- `r.brand_id`
- `r.store_type = 'direct'` filter

**Access**: `GRANT SELECT TO authenticated`

---

### 5. `v_quality_monitoring`

**Source file**: `20260405000012_store_type_classification.sql`

**SELECT body summary**: Shows QC check details with template info per store. Filtered by `r.store_type = 'direct'`.

**Tables referenced**: `qc_checks`, `qc_templates`, `restaurants`

**Restaurant references**:
- `qc.restaurant_id AS store_id`
- `restaurants` table joined via `r.id = qc.restaurant_id`
- `r.brand_id`, `r.name AS store_name`
- `r.store_type = 'direct'` filter

**Access**: `GRANT SELECT TO authenticated`

---

### 6. `v_inventory_status`

**Source file**: `20260405000012_store_type_classification.sql`

**SELECT body summary**: Shows current inventory status per item per store with reorder flag. Filtered by `r.store_type = 'direct'`.

**Tables referenced**: `inventory_items`, `restaurants`

**Restaurant references**:
- `ii.restaurant_id AS store_id`
- `restaurants` table joined via `r.id = ii.restaurant_id`
- `r.brand_id`, `r.name AS store_name`
- `r.store_type = 'direct'` filter

**Access**: `GRANT SELECT TO authenticated`

---

### 7. `v_brand_kpi`

**Source file**: `20260405000012_store_type_classification.sql`

**SELECT body summary**: Aggregates brand-level KPIs: store_count, active_staff_count, mtd_revenue, mtd_order_count. All subqueries filter `r.store_type = 'direct'`.

**Tables referenced**: `brands`, `restaurants`, `users`, `payments`

**Restaurant references**:
- `restaurants` table joined to `brands`
- `r.store_type = 'direct'` filter (multiple locations)
- `r2.brand_id`, `r2.store_type = 'direct'` in subqueries
- `u.restaurant_id = r.id` for staff count

**Access**: `GRANT SELECT TO authenticated`

---

### 8. `v_external_store_sales`

**Source file**: `20260405000012_store_type_classification.sql`

**SELECT body summary**: Same structure as `v_store_daily_sales` but filtered by `r.store_type = 'external'`. Shows daily payment aggregates for external stores.

**Tables referenced**: `payments`, `restaurants`, `brands`

**Restaurant references**:
- `p.restaurant_id` joined to `restaurants`
- `r.id AS store_id`, `r.brand_id`, `r.name AS store_name`
- `r.store_type = 'external'` filter

**Access**: `GRANT SELECT TO authenticated`

---

### 9. `v_external_store_overview`

**Source file**: `20260405000012_store_type_classification.sql`

**SELECT body summary**: External store overview with staff count, MTD sales, MTD order count. Filtered by `r.store_type = 'external'`.

**Tables referenced**: `restaurants`, `brands`, `users`, `payments`, `orders`

**Restaurant references**:
- `r.id AS store_id`, `r.name AS store_name`, `r.brand_id`, `r.is_active`
- `r.store_type = 'external'` filter
- `u.restaurant_id = r.id` subquery
- `p.restaurant_id = r.id` subquery
- `o.restaurant_id = r.id` subquery

**Access**: `GRANT SELECT TO authenticated`

---

### 10. `v_daily_revenue_by_channel`

**Source file**: `20260405000011_deliberry_settlement.sql`

**SELECT body summary**: Full outer join of POS (dine_in + takeaway from orders/payments) and delivery (from external_sales). Computes daily revenue by channel with total.

**Tables referenced**: `orders`, `payments`, `external_sales`

**Restaurant references**:
- `o.restaurant_id` -- grouped by, in POS subquery
- `external_sales.restaurant_id` -- grouped by, in delivery subquery
- No direct `restaurants` table join

**Access**: Inherits RLS from underlying tables (orders, payments, external_sales)

---

### 11. `v_settlement_summary`

**Source file**: `20260405000011_deliberry_settlement.sql`

**SELECT body summary**: Settlement header with aggregated deduction items as JSON array and order count. Shows period, amounts, status, received_at.

**Tables referenced**: `delivery_settlements`, `delivery_settlement_items`, `external_sales`

**Restaurant references**:
- `ds.restaurant_id` -- column in SELECT
- No direct `restaurants` table join

**Access**: Inherits RLS from `delivery_settlements`

---

## Rename Impact Summary

All 11 views reference `restaurant_id` or the `restaurants` table:

| Pattern | Count | Views |
|---------|-------|-------|
| JOIN `restaurants` table | 9 | All except v_daily_revenue_by_channel, v_settlement_summary |
| `restaurant_id` column in SELECT | 11 | All views |
| `r.store_type` filter | 7 | v_store_daily_sales, v_store_attendance_summary, v_quality_monitoring, v_inventory_status, v_brand_kpi, v_external_store_sales, v_external_store_overview |

The rename will require:
- All 11 views to be recreated with `store_id` replacing `restaurant_id` (where applicable)
- 9 views that JOIN `restaurants` need table name updated to `stores`
- 7 views with `r.store_type` filter need no change (already uses correct terminology)
- 2 public views (`public_restaurant_profiles`, `public_menu_items`) may need name changes
