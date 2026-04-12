---
title: "Historical Restaurant References in Migration Files"
version: "1.0"
date: "2026-04-12"
---

# Historical Restaurant References

## Purpose

This file documents all Supabase migration files that were applied before the 
`restaurants → stores` rename migration (20260412030000). These files contain 
references to the old `restaurants` table name and `restaurant_id` column name.

**These files are frozen historical records and must NOT be modified.**

Supabase does not re-run already-applied migrations. The references in these 
files are part of the migration history and reflect the schema as it existed 
at the time each migration was written. Modifying them would:
1. Have no effect on the database (already applied)
2. Break migration checksums if Supabase verifies them
3. Make the migration history inconsistent and harder to audit

## Historical Files

| Migration File | Restaurant References | Description |
|---|---|---|
| `20260402000000_initial_schema.sql` | 97 | Initial POS schema: creates restaurants, users, tables, menu_items, orders, order_items, payments, inventory, attendance, and all core RLS policies |
| `20260402000001_seed_data.sql` | 8 | Seeds default restaurant and sample data if no restaurants exist |
| `20260402000002_pilot_data.sql` | 47 | Pilot/test data for full-screen testing: multiple restaurants, staff, menu items, orders, and payments |
| `20260402000003_fingerprint_attendance.sql` | 8 | Adds fingerprint_templates table for ZKTeco ZK9500 scanner integration with restaurant-scoped RLS |
| `20260402000004_cancel_order_rpc.sql` | 3 | Creates cancel_order RPC with restaurant_id validation |
| `20260402000005_fix_cancel_order_rpc.sql` | 3 | Fixes cancel_order RPC: restricts cancellation to pending/confirmed statuses only |
| `20260403000000_attendance_camera_payroll.sql` | 14 | Adds photo columns to attendance_logs, creates payroll_periods and payroll_entries tables with restaurant-scoped RLS |
| `20260403000001_qc_module.sql` | 12 | Creates QC module: qc_templates and qc_checks tables with restaurant-scoped admin management |
| `20260403000002_inventory_v2.sql` | 33 | Extends inventory with unit/stock tracking, recipes, recipe_ingredients, inventory_transactions, and restaurant-scoped RLS |
| `20260403000003_permissions.sql` | 10 | Adds extra_permissions column to users and creates restaurant-scoped permission check functions |
| `20260403000004_qc_global_templates.sql` | 12 | Adds is_global flag to qc_templates with brand-level visibility and restaurant-scoped RLS |
| `20260405000000_office_shared_hierarchy.sql` | 8 | Office integration Phase 0: creates companies and brands tables, adds brand_id FK to restaurants |
| `20260405000001_office_brand_seed.sql` | 9 | Seeds brand hierarchy data linking existing restaurants to brands |
| `20260405000003_office_connection_views.sql` | 18 | Office integration Phase 1: creates 5 read-only views (v_brand_kpi, v_store_daily_sales, etc.) for Office system consumption |
| `20260405000005_office_payroll_trigger.sql` | 8 | Office integration Phase 2: creates trigger for automatic payroll review creation on restaurant payroll changes |
| `20260405000006_office_purchases.sql` | 3 | Migrates purchases table from restaurant_office_app with RLS |
| `20260405000007_office_qc_followups.sql` | 3 | Migrates QC followups table from restaurant_office_app with RLS |
| `20260405000009_office_view_rls.sql` | 3 | Office integration Phase 1: adds scope-based access control functions for Office views |
| `20260405000011_deliberry_settlement.sql` | 29 | Deliberry settlement integration: external_sales, delivery_settlements, settlement_items with restaurant-scoped RLS |
| `20260405000012_store_type_classification.sql` | 45 | ADR-013: adds store_type column to restaurants, public_store_profiles view, and store-type-aware RLS |
| `20260406000000_deliberry_store_type_integration.sql` | 10 | ADR-013 Phase 3: integrates Deliberry with store_type classification, all store types can receive delivery orders |
| `20260408000000_security_hardening.sql` | 23 | Security hardening: fixes RLS vulnerabilities, adds search_path settings, CHECK constraints, and storage policies |
| `20260408000001_harness_audit_fixes.sql` | 37 | Harness audit fixes: audit_logs RLS, WITH CHECK on core table policies, super_admin access patterns |
| `20260408000003_delivery_settlement_confirm_rpc.sql` | 7 | Delivery settlement confirmation RPC: fixes audit-log omission and client-side timestamp writes |
| `20260408000004_order_item_status_rpc.sql` | 7 | Order item status transition RPC: server-side validation for order_items status changes |
| `20260409000000_dine_in_sales_contract_closure.sql` | 69 | Dine-in sales contract closure: waiter/admin order creation, add-items, and table management RPCs |
| `20260409000001_inventory_ingredient_catalog_contracts.sql` | 29 | Inventory ingredient catalog contracts: canonical ingredient read/upsert RPCs |
| `20260409000002_inventory_recipe_bom_contracts.sql` | 30 | Inventory recipe/BOM mapping contracts: canonical recipe read/upsert/delete RPCs |
| `20260409000003_inventory_recipe_bom_contracts_fix.sql` | 17 | Fix for recipe/BOM contracts: resolves ambiguous column references in upsert function |
| `20260409000004_inventory_physical_count_contracts.sql` | 22 | Inventory physical count contracts: date-based count sheet read and apply RPCs |
| `20260409000005_inventory_physical_count_contracts_fix.sql` | 15 | Fix for physical count contracts: resolves ambiguous ON CONFLICT target references |
| `20260409000006_inventory_transaction_visibility_contracts.sql` | 10 | Inventory transaction visibility contracts: canonical transaction history read RPC |
| `20260409000007_attendance_event_capture_contracts.sql` | 27 | Attendance event capture and log visibility contracts: staff directory read and clock-in/out RPCs |
| `20260409000008_qc_contract_closure.sql` | 59 | QC contract closure: template read, check submission, follow-up, and analytics RPCs |
| `20260409000009_bundle_a_security_closure.sql` | 61 | Bundle A security closure: hardens users write boundary, restaurant_settings, store_type, and payroll RPCs |
| `20260409000010_bundle_b1_admin_mutation_rpcs.sql` | 121 | Bundle B-1: admin mutation RPCs for restaurants, tables, and menu items with full audit trail |
| `20260409000011_admin_mutation_audit_trace_read.sql` | 15 | Admin mutation audit trace surfacing: read-only recent audit log for hardened admin domains |
| `20260409000012_pos_native_auth_rewrite.sql` | 6 | POS-native auth rewrite: removes critical auth dependencies on external systems |
| `20260409000013_drop_office_remote_residue.sql` | 2 | Emergency cleanup: drops broken Office-side remote objects that were incorrectly applied to POS database |
| `20260409000014_order_lifecycle_completion.sql` | 46 | Bundle G-1: completes pre-payment order lifecycle with per-item status transitions and kitchen display RPCs |
| `20260409000015_admin_operational_visibility.sql` | 27 | Bundle G-2: strengthens admin operational visibility with expanded audit trace and order management views |
| `20260409000016_cashier_waiter_field_usability.sql` | 11 | Bundle G-3: adds cashier shift close summary and waiter status tracking RPCs |
| `20260410000000_daily_closing_snapshot.sql` | 31 | Bundle G-5: creates daily_closings table and create_daily_closing RPC for end-of-day operational snapshots |
| `20260410000001_inventory_restock_waste_rpc.sql` | 22 | Inventory write path hardening: atomic restock and waste RPCs with stock updates, transactions, and audit logs |
| `20260410000002_qc_followup_and_analytics.sql` | 44 | QC follow-up and analytics RPCs: restaurant-scoped follow-up management and scoring analytics |
| `20260410000003_inventory_low_stock_visibility.sql` | 43 | Inventory low-stock visibility: adds low_stock_count to daily_closings and creates low-stock dashboard view/RPC |

**Total: 46 files with 1,248 historical `restaurant` references**

Note: 6 pre-rename migration files contain zero restaurant references and are not listed:
`20260405000002`, `20260405000004`, `20260405000008`, `20260405000010`, `20260406000001`, `20260408000002`.

## For Future Developers

When reading the migration history:
- Migrations before `20260412030000` use `restaurants` and `restaurant_id`
- Migrations from `20260412030000` onward use `stores` and `store_id`
- The rename was atomic — there was never a period where both names coexisted
- If you need to understand the pre-rename schema, read migrations in order up to (but not including) `20260412030000`
