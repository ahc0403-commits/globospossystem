---
title: "Phase 0 — Existing Repo Audit"
version: "1.0"
date: "2026-04-12"
target: "~/globos_pos_system (branch: main)"
scope_basis: "stage1_scope_v1.md"
status: "historical baseline — superseded by Phase 2+ implementation docs"
---

# Phase 0 — Existing Repo Audit

This document is a pre-Phase-2 snapshot of the repo before the later multi-access,
WeTax, and hardening work landed. It is retained as a historical baseline and
should not be read as the current shipped state. For active design truth, prefer
the Phase 1 architecture, ADR-014, and the later phase completion/verification
reports.

## 1. Supabase Schema Inventory

### 1.1 Tables (28 total, including 5 dropped)

| # | Table | Columns | Key Relationships |
|---|-------|---------|-------------------|
| 1 | `restaurants` | id, name, address, slug, operation_mode, per_person_charge, is_active, created_at, **brand_id** (FK brands), **store_type** (direct/external) | Core tenant table |
| 2 | `users` | id, auth_id (FK auth.users), restaurant_id (FK restaurants), role, full_name, is_active, created_at, extra_permissions | Maps auth → tenant |
| 3 | `tables` | id, restaurant_id, table_number, seat_count, status (available/occupied), created_at, updated_at | UNIQUE(restaurant_id, table_number) |
| 4 | `menu_categories` | id, restaurant_id, name, sort_order, is_active, created_at | Display grouping only |
| 5 | `menu_items` | id, restaurant_id, category_id, name, description, price, is_available, is_visible_public, sort_order, created_at, updated_at | **No VAT fields** |
| 6 | `orders` | id, restaurant_id, table_id, sales_channel (dine_in/takeaway/delivery), status (pending/confirmed/serving/completed/cancelled), guest_count, created_by, notes, created_at, updated_at | Central order entity |
| 7 | `order_items` | id, restaurant_id, order_id, menu_item_id, item_type (standard/buffet_base/a_la_carte), label, unit_price, quantity, status (pending/preparing/ready/served/cancelled), notes, created_at | **No VAT fields** |
| 8 | `payments` | id, restaurant_id, order_id, amount, method (cash/card/pay/service), is_revenue, processed_by, notes, created_at | **UNIQUE(order_id)** — one payment per order |
| 9 | `attendance_logs` | id, restaurant_id, user_id, type (clock_in/clock_out), logged_at, created_at, photo_url, photo_thumbnail_url | |
| 10 | `inventory_items` | id, restaurant_id, name, quantity, unit (g/ml/ea), created_at, updated_at, current_stock, reorder_point, cost_per_unit, supplier_name | **Missing `is_active` column** (referenced in RPCs) |
| 11 | `inventory_transactions` | id, restaurant_id, ingredient_id, transaction_type (deduct/restock/adjust/waste), quantity_g, reference_type, reference_id, note, created_by, created_at | |
| 12 | `inventory_physical_counts` | id, restaurant_id, ingredient_id, count_date, actual_quantity_g, theoretical_quantity_g, variance_g, counted_by, created_at, updated_at | UNIQUE(ingredient_id, count_date) |
| 13 | `menu_recipes` | id, restaurant_id, menu_item_id, ingredient_id, quantity_g, created_at, updated_at | UNIQUE(menu_item_id, ingredient_id) |
| 14 | `external_sales` | id, restaurant_id, source_system (deliberry), external_order_id, sales_channel, gross/discount/delivery_fee/net amounts, currency, order_status, is_revenue, completed_at, payload, created_at, updated_at, settlement_id | Delivery platform orders |
| 15 | `fingerprint_templates` | id, restaurant_id, user_id, template_data, finger_index, enrolled_at | UNIQUE(user_id, finger_index) |
| 16 | `staff_wage_configs` | id, restaurant_id, user_id, wage_type (hourly/shift), hourly_rate, shift_rates, effective_from, is_active, created_at | UNIQUE(user_id, effective_from) |
| 17 | `payroll_records` | id, restaurant_id, user_id, period_start, period_end, total_hours, total_amount, breakdown, status (draft/store_submitted/office_confirmed/paid), confirmed_by, created_at | **Missing `updated_at` column** (referenced in RPCs) |
| 18 | `qc_templates` | id, restaurant_id (nullable for global), category, criteria_text, criteria_photo_url, sort_order, is_active, created_at, is_global, updated_at | |
| 19 | `qc_checks` | id, restaurant_id, template_id, check_date, checked_by, result (pass/fail/na), evidence_photo_url, note, created_at | UNIQUE(template_id, check_date) |
| 20 | `qc_followups` | id, restaurant_id, source_check_id, status (open/in_progress/resolved), assigned_to_name, resolution_notes, created_by, created_at, updated_at, resolved_at | |
| 21 | `restaurant_settings` | id, restaurant_id (UNIQUE), payroll_pin, settings_json, updated_at | |
| 22 | `companies` | id, name, created_at | Top-level entity |
| 23 | `brands` | id, company_id (FK companies), code (UNIQUE), name, logo_url, created_at | Mid-level grouping |
| 24 | `audit_logs` | id, actor_id (FK auth.users), action, entity_type, entity_id, details (JSONB), created_at | Append-only audit trail |
| 25 | `office_payroll_reviews` | id, source_payroll_id, restaurant_id, brand_id, period_start, period_end, status, reviewed_by, confirmed_by, review_notes, created_at, updated_at | |
| 26 | `delivery_settlements` | id, restaurant_id, source_system, period_start, period_end, period_label, gross_total, total_deductions, net_settlement, status, received_at, notes, created_at, updated_at | |
| 27 | `delivery_settlement_items` | id, settlement_id, item_type, amount, description, reference_rate, reference_base, created_at | |
| 28 | `daily_closings` | id, restaurant_id, closing_date, closed_by, orders_total/completed/cancelled, items_cancelled, payments_count/total/cash/card/pay, service_count/total, low_stock_count, notes, created_at | UNIQUE(restaurant_id, closing_date) |

**Dropped tables (5):** `office_purchases`, `office_qc_followups`, `office_user_profiles`, `office_accounting_entries`, `office_documents` + related tables (migrated to POS-native patterns).

### 1.2 Custom Types / Enums

**None.** All enumerations use `TEXT + CHECK` constraints.

### 1.3 RLS Policies

**Pattern:** All policies resolve identity via `auth.uid()` → `users` table lookup. No JWT claims are used.

| Table | Policy | Logic |
|-------|--------|-------|
| restaurants | SELECT | `is_super_admin() OR id = get_user_restaurant_id()` |
| users | SELECT | `is_super_admin() OR restaurant_id = get_user_restaurant_id()` |
| tables | SELECT | `is_super_admin() OR restaurant_id = get_user_restaurant_id()` |
| menu_categories | SELECT | `is_super_admin() OR restaurant_id = get_user_restaurant_id()` |
| menu_items | SELECT | `is_super_admin() OR restaurant_id = get_user_restaurant_id()` |
| orders | ALL | `is_super_admin() OR restaurant_id = get_user_restaurant_id()` |
| order_items | ALL | `is_super_admin() OR restaurant_id = get_user_restaurant_id()` |
| payments | ALL | `is_super_admin() OR restaurant_id = get_user_restaurant_id()` |
| attendance_logs | ALL | `is_super_admin() OR restaurant_id = get_user_restaurant_id()` |
| inventory_items | ALL | `is_super_admin() OR restaurant_id = get_user_restaurant_id()` |
| external_sales | SELECT | `is_super_admin() OR restaurant_id = get_user_restaurant_id()` |
| fingerprint_templates | ALL | service_role only |
| staff_wage_configs | SELECT | `restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin'])` |
| payroll_records | SELECT | same as staff_wage_configs |
| qc_templates | SELECT/INSERT/UPDATE/DELETE | global templates visible to all; writes scoped to admin+own restaurant |
| qc_checks | ALL | restaurant_isolation |
| restaurant_settings | ALL | admin_only + restaurant scoped |
| menu_recipes | ALL | restaurant_isolation |
| inventory_transactions | ALL | restaurant_isolation |
| inventory_physical_counts | ALL | restaurant_isolation |
| companies | SELECT | admin/super_admin only |
| brands | SELECT | admin/super_admin only |
| audit_logs | SELECT | admin/super_admin only |
| office_payroll_reviews | SELECT/UPDATE | restaurant scoped, update requires admin |
| delivery_settlements | SELECT/UPDATE | restaurant scoped, update requires admin |
| delivery_settlement_items | SELECT | via settlement FK join |
| daily_closings | — | RLS enabled, NO client policies (access via SECURITY DEFINER RPCs only) |
| qc_followups | ALL | restaurant_isolation |

**Key observation:** All RLS is single-axis (operational: `restaurant_id`). The **dual-axis model** required by Stage 1 (operational + tax axis) does not exist. The helper functions `user_accessible_stores()` and `user_accessible_tax_entities()` specified in the scope doc are **not yet implemented**.

### 1.4 Functions (63 total)

**RLS helpers (4):** `get_user_restaurant_id()`, `get_user_role()`, `has_any_role()`, `is_super_admin()` — all SECURITY DEFINER, lookup from `users` table via `auth.uid()`.

**Order lifecycle RPCs (9):** `create_order`, `create_buffet_order`, `add_items_to_order`, `process_payment`, `cancel_order`, `cancel_order_item`, `edit_order_item_quantity`, `transfer_order_table`, `update_order_item_status`.

**Payroll RPCs (2):** `office_confirm_payroll`, `office_return_payroll`.

**Inventory RPCs (9):** ingredient catalog, recipes, physical counts, transactions, restock, waste recording.

**Attendance RPCs (3):** staff directory, log view, record event.

**QC RPCs (9):** templates CRUD, checks CRUD, followups, analytics, superadmin summary.

**User management RPCs (3):** profile update, staff account admin, onboarding setup.

**Admin mutation RPCs (12+):** restaurant/table/menu CRUD operations.

**Reporting RPCs (4):** mutation audit trace, admin today summary, cashier today summary, daily closing.

**Delivery RPC (1):** confirm_delivery_settlement_received.

**Trigger function (1):** `on_payroll_store_submitted()` — auto-creates office_payroll_review record.

### 1.5 Triggers

| Trigger | Table | Event | Function |
|---------|-------|-------|----------|
| `trg_payroll_store_submitted` | payroll_records | AFTER UPDATE OF status (draft→store_submitted) | `on_payroll_store_submitted()` |

### 1.6 pg_cron Jobs

**None.** Settlement edge functions are designed for external cron invocation (check CRON_SECRET) but no `pg_cron.schedule()` calls exist.

### 1.7 Edge Functions (3)

| Function | Purpose | Auth |
|----------|---------|------|
| `create_staff_user` | Create auth.users + public.users record | JWT (admin/super_admin) |
| `generate-settlement` | Biweekly delivery settlement (original) | CRON_SECRET |
| `generate_delivery_settlement` | Biweekly delivery settlement (improved, VN timezone) | CRON_SECRET |

### 1.8 Storage Buckets (2)

| Bucket | Access |
|--------|--------|
| `attendance-photos` | Private, restaurant-scoped path policy |
| `qc-photos` | Private, restaurant-scoped path policy |

### 1.9 Views (11)

`public_restaurant_profiles`, `public_menu_items`, `v_store_daily_sales`, `v_store_attendance_summary`, `v_quality_monitoring`, `v_inventory_status`, `v_brand_kpi`, `v_daily_revenue_by_channel`, `v_settlement_summary`, `v_external_store_sales`, `v_external_store_overview`.

---

## 2. Payment Path Analysis

### 2.1 Order Status

Defined in `orders` table CHECK constraint:
- `pending` → `confirmed` → `serving` → `completed`
- `pending` → `cancelled`

Status is a plain `String` in Dart (`order_model.dart`) — no client-side enum.

### 2.2 Payment Flow (Critical Path)

```
cashier_screen.dart:397  → notifier.processPayment(...)
  payment_provider.dart:172  → paymentService.processPayment(...)
    payment_service.dart:10  → supabase.rpc('process_payment', params: {...})
      SQL (20260409000000, lines 412-572):
        1. Validate actor role (cashier/admin/super_admin)
        2. Validate payment method ∈ {cash, card, pay, service}
        3. Lock order row FOR UPDATE
        4. Check order not completed/cancelled
        5. Check no existing payment (UNIQUE constraint)
        6. Validate total matches order amount
        7. INSERT into payments
        8. ★ UPDATE orders SET status = 'completed'  ← LINE 501-505
        9. Release table (SET status = 'available')
        10. Deduct inventory per recipes
        11. INSERT audit_log
```

### 2.3 Dispatcher Attachment Point

**The exact moment where all payments are confirmed and the order becomes `completed`:**

- **SQL level:** `20260409000000_dine_in_sales_contract_closure.sql`, **lines 501-505** — `UPDATE orders SET status = 'completed'`
- **Dart level:** `payment_provider.dart`, **line 178** — return from `await paymentService.processPayment()`

The `sendOrderInfo` dispatcher should trigger **after the `process_payment` RPC returns successfully**. Options:
- A PostgreSQL trigger on `orders` (AFTER UPDATE, WHEN new.status = 'completed')
- An additional step in the `process_payment` RPC itself (insert into `einvoice_jobs`)
- A Dart-side call after `processPayment()` returns

### 2.4 Order Status Audit Logging

**Yes.** The `process_payment` RPC inserts into `audit_logs` at line 554-567 with:
- `action = 'process_payment'`
- `entity_type = 'payments'`
- `details` includes restaurant_id, amount, method

`create_order` and `cancel_order` also log to `audit_logs`.

---

## 3. Payments Table Analysis

### 3.1 Current Schema

```sql
payments (
  id UUID PK,
  restaurant_id UUID NOT NULL FK restaurants,
  order_id UUID NOT NULL FK orders,
  amount DECIMAL(12,2) NOT NULL CHECK > 0,
  method TEXT NOT NULL CHECK IN ('cash','card','pay','service'),
  is_revenue BOOLEAN NOT NULL DEFAULT TRUE,
  processed_by UUID FK auth.users,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
)
CONSTRAINT unique_payment_per_order UNIQUE (order_id)
```

### 3.2 Answers

| Question | Answer |
|----------|--------|
| `method` column exists? | **Yes** — values: `cash`, `card`, `pay`, `service` |
| Hybrid payments? | **No** — `UNIQUE(order_id)` enforces exactly one payment per order |
| Fee/commission fields? | **No** — only on `delivery_settlement_items` |
| Settlement/reconciliation? | **Partial** — `daily_closings` aggregates by method, but no per-payment settlement tracking |
| Proof photo fields? | **No** — none exist |

### 3.3 Stage 1 Gap

The scope document specifies these additions to `payments`:
- `method` enum expansion (cash/card/pay/service → CASH/CREDITCARD/ATM/MOMO/ZALOPAY/VNPAY/SHOPEEPAY/BANKTRANSFER/VOUCHER/CREDITSALE/OTHER)
- `proof_photo_url`, `proof_photo_taken_at`, `proof_photo_by`, `proof_required`
- `settlement_status`, `settlement_batch_id`

The `UNIQUE(order_id)` constraint must be evaluated — if the scope requires hybrid payments, it must be dropped.

---

## 4. Menu/Product VAT Handling

> Historical note: this section records the pre-implementation audit state. The current shipped VAT behavior is documented in `/Users/andreahn/globos_pos_system/docs/phase_1_architecture.md` Section 12 and implemented in `process_payment`.

### 4.1 Current State

| Aspect | Finding |
|--------|---------|
| Per-item `vat_rate` column on `menu_items` | **Does not exist** |
| Per-line `vat_rate` on `order_items` | **Does not exist** |
| Global VAT constant in app code | **Does not exist** |
| Category-level tax classification | **Does not exist** — `menu_categories` is display-only (name, sort_order) |
| Item type system | `order_items.item_type` has `standard/buffet_base/a_la_carte` — operational types, not tax classes |
| Price storage convention | Prices were stored as-is at audit time; VAT semantics were not yet formalized in code |

### 4.2 Vietnam F&B VAT Rule

- Food and non-alcoholic beverages: **8% VAT** (current reduced rate)
- Alcohol and beer: **10% VAT**
- The `sendOrderInfo.list_product` requires per-line `vat_rate`, `vat_amount`, `total_amount` (ex-tax), `paying_amount` (inc-tax)

### 4.3 Gap Summary

**The system has ZERO VAT infrastructure.** There is no mechanism to:
1. Classify items by VAT rate
2. Store per-item VAT rates
3. Calculate tax components at payment time
4. Build the `list_product` array with required tax fields

This is a **blocking dependency** for `sendOrderInfo` dispatch.

---

## 5. Existing Tax/Invoice/WeTax Integration

### 5.1 Search Results

| Search Term | Runtime Code | Database | Docs |
|-------------|-------------|----------|------|
| wetax | **None** | **None** | `docs/vendor/` (Phase -1 outputs) |
| tax_entity | **None** | **None** | **None** |
| einvoice | **None** | **None** | `docs/vendor/` |
| red_invoice | **None** | **None** | **None** |
| partner_credentials | **None** | **None** | **None** |
| b2b_buyer | **None** | **None** | **None** |
| hóa đơn | **None** | **None** | **None** |

**Zero existing integration code or schema.** All WeTax-related entities must be created from scratch.

### 5.2 Existing Brand/Tenant Tables

| Table | Status |
|-------|--------|
| `companies` | Exists — maps to scope doc `hq` |
| `brands` | Exists — maps to scope doc `brand` |
| `restaurants` | Exists — maps to scope doc `store`, has `brand_id` and `store_type` |

**Missing from scope hierarchy:** `brand_master` (internal vs external grouping), `tax_entity`, `einvoice_shop`, `store_tax_entity_history`.

---

## 6. Authentication and Tenant Context

### 6.1 Authentication

Supabase email/password (`signInWithPassword`). After sign-in, Dart queries `users` table for role, restaurant_id, is_active, extra_permissions.

Roles: `super_admin`, `master_admin`, `admin`, `waiter`, `kitchen`, `cashier`, `photo_objet_master`, `photo_objet_store_admin`.

Staff creation via edge function `create_staff_user`.

### 6.2 JWT Claims

**No custom JWT claims configured.** No `app_metadata` or `raw_app_meta_data` usage for role/tenant injection. All authorization is via database lookup from `auth.uid()` → `users` table.

### 6.3 RLS Tenant Context

All RLS resolves through four SECURITY DEFINER helper functions:
- `get_user_restaurant_id()` — returns `restaurant_id` from `users`
- `get_user_role()` — returns `role` from `users`
- `has_any_role(TEXT[])` — checks role membership
- `is_super_admin()` — boolean check

**No dual-axis RLS.** No `user_accessible_stores()` or `user_accessible_tax_entities()`. The current model is single-axis: one user → one restaurant.

---

## 7. Obsidian Vault Structure

### GLOBOSVN POS/ (current contents)

```
Stage 1/
├── README.md                              (index)
├── claude_code_prompt_v4.md               (execution prompt)
├── phase_minus_1_vendor_truth_table.md    (Phase -1 output)
└── stage1_scope_v1.md                     (scope document)
```

No other directories or files exist under `GLOBOSVN POS/`. The broader vault (`restaurant-ops-vault`) contains extensive Office system documentation under `00_HOME/` through `11_SECURITY/` (200+ files), but these document the **Office system**, not the POS Stage 1 work.

### Potential Conflicts

The vault `00_HOME/` contains several `PHASE_*` documents (e.g., `PHASE_1_ADMIN_FIRST_SCOPE.md`, `PHASE_2_SCOPE.md`) — these refer to the **Office system** phases, not POS Stage 1 phases. No naming conflict exists because POS Stage 1 documents live under `Stage 1/`.

---

## 8. Gap Analysis

### Stage 1 Scope Section 3 — Entity Status

| Entity | Status | Detail |
|--------|--------|--------|
| **hq** | Partially exists | `companies` table exists with `id, name, created_at`. Missing: global settings, top-level user account linkage |
| **brand_master** | **Does not exist** | No table. Scope requires `type` (internal/external) grouping layer between hq and brand |
| **brand** | Partially exists | `brands` table has `id, company_id, code, name, logo_url`. Missing: `suggested_tax_entity_id` |
| **store** | Partially exists | `restaurants` table has `brand_id`, `store_type`. Missing: `tax_entity_id` (NOT NULL per scope), tax-axis linkage |
| **tax_entity** | **Does not exist** | Requires: tax_code, owner_type, einvoice_provider, pos_key, declaration_status, wetax_end_point, data_source |
| **einvoice_shop** | **Does not exist** | Requires: tax_entity_id, provider_shop_code, shop_name, templates (JSONB) |
| **store_tax_entity_history** | **Does not exist** | Append-only: store_id, tax_entity_id, effective_from, effective_to, reason |
| **partner_credentials** | **Does not exist** | L4 envelope encryption: DEK, KEK, kek_version, auth_mode, etc. |
| **einvoice_jobs** | **Does not exist** | Full state machine: ref_id, order_id, tax_entity_id, status, payloads, polling, errors |
| **einvoice_events** | **Does not exist** | Append-only audit of einvoice_jobs state changes |
| **partner_credential_access_log** | **Does not exist** | Append-only credential read log |
| **b2b_buyer_cache** | **Does not exist** | Composite PK (store_id, buyer_tax_code), email-first fields, bounce tracking |
| **wetax_reference_values** | **Does not exist** | Cache for commons/payment-methods, tax-rates, currency |
| **payments (extended)** | Partially exists | Exists with `cash/card/pay/service`. Missing: expanded method enum, proof_photo fields, settlement fields |

### Summary

| Category | Count |
|----------|-------|
| Exists fully | 0 |
| Partially exists | 4 (hq/companies, brand/brands, store/restaurants, payments) |
| Does not exist | 10 (brand_master, tax_entity, einvoice_shop, store_tax_entity_history, partner_credentials, einvoice_jobs, einvoice_events, partner_credential_access_log, b2b_buyer_cache, wetax_reference_values) |

---

## 9. Migration Impact Assessment

### 9.1 Existing Tables Requiring Modification

| Table | Changes Needed |
|-------|---------------|
| `restaurants` (→ store) | Add `tax_entity_id UUID NOT NULL` (FK), requires backfill strategy for existing rows |
| `brands` | Add `suggested_tax_entity_id UUID` (FK, nullable) |
| `menu_items` | Add `vat_rate` column (for sendOrderInfo line-item tax) |
| `order_items` | Add `vat_rate`, `vat_amount`, `total_amount_ex_tax` (snapshot at order time) |
| `payments` | Expand `method` CHECK, add `proof_photo_url`, `proof_photo_taken_at`, `proof_photo_by`, `proof_required`, `settlement_status`, `settlement_batch_id` |
| `process_payment` RPC | Add einvoice_jobs creation step |

### 9.2 New Tables (Additive Only)

| Table | Risk |
|-------|------|
| `brand_master` | None — new table, no existing data |
| `tax_entity` | None — new table |
| `einvoice_shop` | None — new table |
| `store_tax_entity_history` | None — new table |
| `partner_credentials` | None — new table, requires Vault setup |
| `einvoice_jobs` | None — new table |
| `einvoice_events` | None — new table |
| `partner_credential_access_log` | None — new table |
| `b2b_buyer_cache` | None — new table |
| `wetax_reference_values` | None — new table |

### 9.3 Production-Critical Migrations

| Migration | Risk | Mitigation |
|-----------|------|------------|
| `restaurants.tax_entity_id NOT NULL` | **High** — existing rows have no tax_entity. Cannot add NOT NULL without backfill | Create tax_entity rows first, then backfill, then add NOT NULL constraint |
| `payments.method` CHECK expansion | **Medium** — existing values (cash/card/pay/service) must map to new enum | Migration must preserve existing values or define mapping |
| `menu_items` VAT columns | **Low** — nullable columns, can be added without downtime | Default to 8% for existing items (Vietnam standard rate) |
| `order_items` VAT columns | **Low** — nullable, historical orders don't need VAT | Only new orders will populate these fields |

---

## 10. Concerns

### C-01: Missing Columns Referenced in RPCs (Runtime Bugs)

- `inventory_items.is_active` — referenced in `get_admin_today_summary` and `create_daily_closing` RPCs but never created. **Will cause runtime errors on daily closing.**
- `payroll_records.updated_at` — referenced in `office_confirm_payroll` and `office_return_payroll` RPCs but never created. **Will cause runtime errors on payroll confirmation.**

### C-02: Single Payment Per Order Constraint

The `UNIQUE(order_id)` constraint on `payments` prevents hybrid/split payments. The scope document Section 2 mentions "manual confirmation for all non-card, non-integrated channels" which implies a single payment event, but the expanded payment method enum (CASH, CREDITCARD, MOMO, etc.) suggests future need for split payments. This constraint should be explicitly evaluated during Phase 1 architecture.

### C-03: No Custom JWT Claims

All RLS policies perform a table lookup on every query. At scale with many concurrent users, the `get_user_restaurant_id()` function call on every row evaluation could become a performance bottleneck. The Stage 1 dual-axis model adds `user_accessible_stores()` and `user_accessible_tax_entities()` which are more complex. Consider migrating role and restaurant_id into JWT `app_metadata` during Phase 2.

### C-04: Duplicate Settlement Edge Functions

Both `generate-settlement` and `generate_delivery_settlement` exist with overlapping purpose. One should be deprecated.

### C-05: Storage Policy Gap

The `authenticated_access_qc_photos` storage policy (broad access) may still be active alongside the scoped `storage_qc_scoped` policy. The security_hardening migration dropped `qc_photos_access` but not `authenticated_access_qc_photos`.

### C-06: No Payment Proof Photos

The scope requires mandatory receipt proof photos for non-cash payments. The current schema has no photo fields on `payments`, no storage bucket for payment proofs, and no offline queue mechanism. This is entirely new infrastructure.

---

*Generated: 2026-04-12 | Phase 0 complete. Awaiting confirmation to proceed to Phase 1.*
