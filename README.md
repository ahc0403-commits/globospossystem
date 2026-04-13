# globos_pos_system

Flutter POS and operations client backed by Supabase for:

- in-store ordering, kitchen, cashier, tables, and attendance
- office/shared reporting, payroll review, QC, and inventory workflows
- Deliberry delivery revenue and settlement flows
- super-admin store management, including direct vs external store segmentation

## Repository Shape

- `lib/`: Flutter application code
- `supabase/migrations/`: database schema, RLS, RPCs, and governance fixes
- `supabase/functions/`: Edge Functions for staff provisioning and delivery settlement generation
- `docs/`: architectural decision records

## Governance-Critical Paths

- Tenant scope is enforced primarily in Supabase RLS and SECURITY DEFINER RPCs.
- High-risk business mutations live in `lib/core/services/` and/or database RPCs.
- Office visibility for stores is filtered by `restaurants.store_type` per [docs/ADR-013-Store-Type-Classification.md](docs/ADR-013-Store-Type-Classification.md).
- Delivery settlement receipt confirmation is handled through the `confirm_delivery_settlement_received` RPC so status transition, audit logging, and timestamps stay server-side.
- Fingerprint attendance is treated as a dormant feature and is disabled by default until a safer server-owned boundary exists.

## Key Database Artifacts

- Core schema: `supabase/migrations/20260402000000_initial_schema.sql`
- Delivery settlement layer: `supabase/migrations/20260405000011_deliberry_settlement.sql`
- Store-type segregation: `supabase/migrations/20260405000012_store_type_classification.sql`
- Security hardening: `supabase/migrations/20260408000000_security_hardening.sql`
- Harness audit fixes: `supabase/migrations/20260408000001_harness_audit_fixes.sql`
- Delivery settlement confirmation RPC: `supabase/migrations/20260408000003_delivery_settlement_confirm_rpc.sql`
- Order item status transition RPC: `supabase/migrations/20260408000004_order_item_status_rpc.sql`
- Daily closing snapshots: `supabase/migrations/20260410000000_daily_closing_snapshot.sql`
- Inventory restock/waste RPCs: `supabase/migrations/20260410000001_inventory_restock_waste_rpc.sql`
- QC follow-up + analytics: `supabase/migrations/20260410000002_qc_followup_and_analytics.sql`
- Inventory low-stock visibility: `supabase/migrations/20260410000003_inventory_low_stock_visibility.sql`

## Validation

Common local validation commands:

- `flutter analyze`
- `dart format lib supabase/functions`
