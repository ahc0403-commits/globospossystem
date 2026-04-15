---
title: "Phase 2 Step 2 — Rename Map Spec"
version: "1.0"
date: "2026-04-12"
scope_basis: "stage1_scope_v1.3.md, Appendix A.1"
status: "historical baseline — not shipped"
---

# Phase 2 Step 2 — Rename Map (restaurants → stores)

> Historical note: this file captures the abandoned atomic rename plan. It is retained as an audit artifact only. It is not the current implementation contract.
>
> Current shipped rename strategy is the coexistence rollout documented in `/Users/andreahn/globos_pos_system/docs/phase_1_architecture.md` Section 11 and the Phase 2 Step 2 expand/migrate reports.

> This document is the baseline specification for the atomic rename migration. Every action in the forward migration, rollback migration, and Dart codemod MUST trace back to an entry in this map. Any reference discovered during static analysis that is NOT in this map must be added before proceeding.

## 1. Rationale

From scope v1.3 Section 3.1: The existing `restaurants` table represents a physical location that operates under one brand and reports to one tax_entity. The term "store" better reflects the multi-tenant, multi-brand model where locations can be direct or external franchise operations. The rename aligns the schema with the domain language used throughout the scope document.

## 2. Table Rename

| Current Name | New Name | Type |
|---|---|---|
| `restaurants` | `stores` | ALTER TABLE RENAME |
| `restaurant_settings` | `store_settings` | ALTER TABLE RENAME |

## 3. Column Renames (restaurant_id → store_id)

Every table with a `restaurant_id` column gets renamed to `store_id`:

| Table | Column | New Column |
|---|---|---|
| `users` | `restaurant_id` | `store_id` |
| `tables` | `restaurant_id` | `store_id` |
| `menu_categories` | `restaurant_id` | `store_id` |
| `menu_items` | `restaurant_id` | `store_id` |
| `orders` | `restaurant_id` | `store_id` |
| `order_items` | `restaurant_id` | `store_id` |
| `payments` | `restaurant_id` | `store_id` |
| `attendance_logs` | `restaurant_id` | `store_id` |
| `inventory_items` | `restaurant_id` | `store_id` |
| `inventory_transactions` | `restaurant_id` | `store_id` |
| `inventory_physical_counts` | `restaurant_id` | `store_id` |
| `menu_recipes` | `restaurant_id` | `store_id` |
| `external_sales` | `restaurant_id` | `store_id` |
| `fingerprint_templates` | `restaurant_id` | `store_id` |
| `staff_wage_configs` | `restaurant_id` | `store_id` |
| `payroll_records` | `restaurant_id` | `store_id` |
| `qc_templates` | `restaurant_id` | `store_id` |
| `qc_checks` | `restaurant_id` | `store_id` |
| `qc_followups` | `restaurant_id` | `store_id` |
| `restaurant_settings` | `restaurant_id` | `store_id` |
| `daily_closings` | `restaurant_id` | `store_id` |
| `delivery_settlements` | `restaurant_id` | `store_id` |
| `office_payroll_reviews` | `restaurant_id` | `store_id` |
| `office_purchases` (if exists) | `restaurant_id` | `store_id` |

Note: `restaurant_settings.restaurant_id` gets renamed AFTER the table itself is renamed to `store_settings`.

## 4. FK Constraint Renames

Every FK constraint referencing `restaurants(id)` must be dropped and recreated pointing to `stores(id)`. The constraint names typically follow `{table}_restaurant_id_fkey` → `{table}_store_id_fkey`.

## 5. Index Renames

Any index containing `restaurant` in its name must be renamed. Key ones:
- `UNIQUE(restaurant_id, table_number)` on `tables`
- `UNIQUE(restaurant_id, closing_date)` on `daily_closings`
- `UNIQUE(restaurant_id)` on `restaurant_settings`
- `UNIQUE(user_id, finger_index)` on `fingerprint_templates` (no rename needed, no restaurant in name)
- `UNIQUE(user_id, effective_from)` on `staff_wage_configs` (no rename needed)
- `UNIQUE(menu_item_id, ingredient_id)` on `menu_recipes` (no rename needed)
- `UNIQUE(template_id, check_date)` on `qc_checks` (no rename needed)
- `UNIQUE(ingredient_id, count_date)` on `inventory_physical_counts` (no rename needed)

## 6. RLS Policy Recreates

All RLS policies that reference `restaurant_id` or the `restaurants` table must be dropped and recreated with `store_id` / `stores`. This includes:

### On `stores` (formerly `restaurants`)
- `restaurants_select_policy` → `stores_select_policy`
- Note: insert/update policies were dropped in bundle_b1 migration (mutations go through RPCs)

### On other tables (policies referencing `restaurant_id`)
- `users_select_policy`
- `tables_select_policy`
- `menu_categories_select_policy`
- `menu_items_select_policy`
- `orders_policy`
- `order_items_policy`
- `payments_policy`
- `attendance_logs_policy`
- `inventory_items_policy`
- `restaurant_isolation` on `menu_recipes`
- `restaurant_isolation` on `inventory_transactions`
- `restaurant_isolation` on `inventory_physical_counts`
- `restaurant_isolation` on `staff_wage_configs`
- `restaurant_isolation` on `payroll_records`
- `qc_templates_select/insert/update/delete`
- `restaurant_isolation` on `qc_checks`
- `qc_followups_restaurant_isolation`
- `admin_only` on `restaurant_settings` (→ `store_settings`)
- `external_sales_read`
- `delivery_settlements_read/confirm`
- `settlement_items_read`
- `office_payroll_reviews_scoped_select/pos_update`
- `fingerprint_templates_restaurant_policy`
- Storage policies: `storage_attendance_scoped`, `storage_qc_scoped`

## 7. View Recreates

All views referencing `restaurants` or `restaurant_id`:

| View | References |
|---|---|
| `public_restaurant_profiles` | Renamed to `public_store_profiles`; SELECT FROM `restaurants` → `stores` |
| `public_menu_items` | JOIN to `restaurants` → `stores` |
| `v_store_daily_sales` | `restaurant_id` → `store_id` in column list and JOINs |
| `v_store_attendance_summary` | `restaurant_id` → `store_id` |
| `v_quality_monitoring` | `restaurant_id` → `store_id` |
| `v_inventory_status` | `restaurant_id` → `store_id` |
| `v_brand_kpi` | `restaurant_id` → `store_id` |
| `v_daily_revenue_by_channel` | `restaurant_id` → `store_id` |
| `v_settlement_summary` | `restaurant_id` → `store_id` |
| `v_external_store_sales` | `restaurant_id` → `store_id` |
| `v_external_store_overview` | `restaurant_id` → `store_id` |

## 8. Function Recreates

All functions that reference `restaurants`, `restaurant_id`, or `get_user_restaurant_id()`:

### RLS Helper Functions
| Function | Change |
|---|---|
| `get_user_restaurant_id()` | Rename to `get_user_store_id()`, query `store_id` from `users` |

### Order Lifecycle RPCs
- `create_order` — params and body reference `restaurant_id`
- `create_buffet_order` — same
- `add_items_to_order` — same
- `process_payment` — same
- `cancel_order` — same
- `cancel_order_item` — same
- `edit_order_item_quantity` — same
- `transfer_order_table` — same
- `update_order_item_status` — same

### Admin Mutation RPCs
- `require_admin_actor_for_restaurant()` → `require_admin_actor_for_store()`
- `admin_create_restaurant()` → `admin_create_store()`
- `admin_update_restaurant()` → `admin_update_store()`
- `admin_deactivate_restaurant()` → `admin_deactivate_store()`
- `admin_update_restaurant_settings()` → `admin_update_store_settings()`
- `admin_create_table`, `admin_update_table`, `admin_delete_table` — body refs
- `admin_create_menu_category`, `admin_update_menu_category`, `admin_delete_menu_category` — body refs
- `admin_create_menu_item`, `admin_update_menu_item`, `admin_delete_menu_item` — body refs

### Inventory RPCs
- `get_inventory_ingredient_catalog` — `restaurant_id` param/body
- `create_inventory_item` — same
- `update_inventory_item` — same
- `restock_inventory_item` — same
- `record_inventory_waste` — same
- `get_inventory_recipe_catalog` — same
- `upsert_inventory_recipe_line` — same
- `get_inventory_physical_count_sheet` — same
- `apply_inventory_physical_count_line` — same
- `get_inventory_transaction_visibility` — same

### Attendance RPCs
- `get_attendance_staff_directory` — `restaurant_id` param/body
- `get_attendance_log_view` — same
- `record_attendance_event` — same

### QC RPCs
- `get_qc_templates`, `create_qc_template`, `update_qc_template`, `deactivate_qc_template`
- `get_qc_checks`, `upsert_qc_check`
- `get_qc_superadmin_summary`
- `create_qc_followup`, `update_qc_followup_status`, `get_qc_followups`, `get_qc_analytics`

### User Management RPCs
- `update_my_profile_full_name` — body refs
- `admin_update_staff_account` — `restaurant_id` param/body
- `complete_onboarding_account_setup` — body refs

### Reporting RPCs
- `get_admin_mutation_audit_trace` — `restaurant_id` param/body, entity_type 'restaurants'
- `get_admin_today_summary` — `restaurant_id` param/body
- `get_cashier_today_summary` — `restaurant_id` param/body
- `create_daily_closing` — `restaurant_id` param/body
- `get_daily_closings` — `restaurant_id` param/body

### Delivery/Settlement RPCs
- `confirm_delivery_settlement_received` — `restaurant_id` in body
- `office_get_accessible_store_ids()` — body references `restaurants`

### Payroll RPCs
- `office_confirm_payroll` — body refs
- `office_return_payroll` — body refs
- `on_payroll_store_submitted()` — trigger function, body refs

## 9. Trigger Renames

| Trigger | Table | Change |
|---|---|---|
| `trg_payroll_store_submitted` | `payroll_records` | No name change needed (already uses "store"). Function body updated. |

## 10. Sequence/Serial Renames

No sequences with `restaurant` in the name (all PKs are UUID).

## 11. Dart Code Renames

| Category | Pattern | Replacement |
|---|---|---|
| Table name strings | `'restaurants'` | `'stores'` |
| Column references | `'restaurant_id'` | `'store_id'` |
| Table reference | `'restaurant_settings'` | `'store_settings'` |
| Class names | `SuperRestaurant` | `SuperStore` |
| Variable names | `restaurantId` | `storeId` |
| Variable names | `restaurant` | `store` |
| Variable names | `restaurants` | `stores` |
| Function names | `selectRestaurant` | `selectStore` |
| Function ref | `get_user_restaurant_id` | `get_user_store_id` |
| RPC names | `admin_create_restaurant` | `admin_create_store` |
| RPC names | `admin_update_restaurant` | `admin_update_store` |
| RPC names | `admin_deactivate_restaurant` | `admin_deactivate_store` |
| RPC names | `admin_update_restaurant_settings` | `admin_update_store_settings` |
| UI strings | `'Restaurant'` (labels) | `'Store'` (context-dependent — some may stay as "Restaurant" for user-facing text) |

## 12. Edge Function Renames

| File | Changes |
|---|---|
| `create_staff_user/index.ts` | `restaurant_id` → `store_id` in request body, DB queries, and validation |
| `generate_delivery_settlement/index.ts` | `restaurant_id` → `store_id` in all queries and variable names |
| `generate-settlement/index.ts` | `restaurant_id` → `store_id` in all queries and variable names |

## 13. Storage Policy Path References

Storage policies use path patterns like `restaurants/{restaurant_id}/...`. These paths in `storage.objects` must be updated:
- `attendance-photos` bucket: path pattern references
- `qc-photos` bucket: path pattern references

**WARNING:** Changing storage path patterns means existing uploaded files will be inaccessible unless the actual storage paths are also migrated. This requires either:
1. A separate data migration to rename paths in `storage.objects`
2. OR keeping the old path pattern in storage policies (storage paths are independent of table names)

**DECISION NEEDED:** Storage paths are data, not schema. Recommend keeping existing storage paths and NOT renaming them in this migration to avoid data loss risk. The storage policies should keep their old path patterns.

## 14. Categories to Verify in Step 3

After building the migration, every entry in sections 2–13 above must be checked off as addressed. Any missing entry is a CRITICAL finding.

---

*Baseline established: 2026-04-12*
