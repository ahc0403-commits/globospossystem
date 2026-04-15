# Audit Execution Checklist

Updated: 2026-04-14

This checklist reflects the current post-implementation truth and the remaining cleanup work after the latest design-doc refresh.

## 1. Lock Document Truth

Goal: remove ambiguity before touching more code.

- [x] Decide and document the meaning of `admin`.
- [x] Set one rule: `admin` is either:
  - [x] a legacy alias of `store_admin`, or
  - [ ] a separate role with an explicit permission matrix.
- [x] Update all top-level source-of-truth docs to match the same role model:
  - [x] `/Users/andreahn/globos_pos_system/docs/ADR-014-Brand-Store-Multi-Access-Model.md`
  - [x] `/Users/andreahn/Documents/restaurant-ops-vault/GLOBOSVN POS/Stage 1/stage1_scope_v1.4.md`
  - [x] `/Users/andreahn/Documents/restaurant-ops-vault/GLOBOSVN POS/Stage 1/handover_v4.md`
- [x] Explicitly define fallback policy for legacy `restaurant_id` usage.
- [x] Split fallback policy into:
  - [x] allowed temporary legacy reads
  - [x] forbidden legacy writes / permission checks
- [x] Choose and document whether the following are:
  - [x] Stage 1 required now
  - [x] deferred to a later stage
- [ ] Resolve this for:
  - [x] WT09 buyer auto-fill
  - [x] payment proof photo flow
  - [x] admin polling/system-status banner
  - [x] failed-job mark-resolved action

Done when:

- every source document says the same thing about `admin`
- fallback scope is explicit
- WT09/proof-photo status is no longer contradictory across docs

## 2. Fix Server Boundaries

Goal: enforce ADR-014 on write paths.

### `request_red_invoice`

- [x] Change client call to send explicit `store_id`.
- [x] Change RPC signature to accept `p_store_id`.
- [x] Verify `p_store_id` belongs to the caller's accessible stores on the server.
- [x] Verify the target order belongs to `p_store_id`.
- [x] Stop using actor `restaurant_id` as the cache write target.
- [x] Use validated `p_store_id` for `b2b_buyer_cache` upsert.
- [x] Add audit payload fields for `store_id` and validation path.

Files to update:

  - [x] `/Users/andreahn/globos_pos_system/lib/core/services/einvoice_service.dart`
  - [x] `/Users/andreahn/globos_pos_system/lib/features/cashier/red_invoice_modal.dart`
  - [ ] `/Users/andreahn/globos_pos_system/supabase/migrations/20260413105202_stage2_step1_request_red_invoice_rpc.sql`

Done when:

- the RPC cannot mutate data for an unselected or inaccessible store
- cache writes always land in the validated active store

### Staff account mutation path

- [x] Align `admin_update_staff_account` with the final role model.
- [x] Start contract rename on active admin mutation path (`p_restaurant_id` → `p_store_id`).
- [ ] If `admin = store_admin` alias, remove role drift between:
  - [ ] router
  - [ ] edge function create path / role creation UI
  - [x] RPC update path
- [x] Add brand/store-scope checks for `brand_admin` and `store_admin` as applicable.

### Onboarding contract start

- [x] Rename `complete_onboarding_account_setup` input contract to `p_store_id`.
- [x] Update onboarding client call to send `p_store_id`.
- [x] Persist `primary_store_id` during onboarding account setup.
- [x] Refresh claims after onboarding role/store assignment.

### Cashier payment contract start

- [x] Rename `process_payment` input contract to `p_store_id`.
- [x] Rename `get_cashier_today_summary` input contract to `p_store_id`.
- [x] Update payment client calls to send `p_store_id`.
- [x] Use `user_accessible_stores()` for the cashier payment boundary instead of direct actor `restaurant_id` comparison.

### Order mutation contract start

- [x] Rename active dine-in order RPC inputs to `p_store_id`.
- [x] Update order client calls to send `p_store_id`.
- [x] Use `user_accessible_stores()` for active order mutation boundaries.
- [x] Align `create_order` / `add_items_to_order` inserts with current `order_items` item contract (`menu_item`, `display_name`).
- [x] Reconcile `create_buffet_order` with the post-Step-5 `order_items` contract and rename that path to `p_store_id`.
- [x] After any effective account/permission change, call `refresh_user_claims`.

### Table/menu create contract start

- [x] Rename `admin_create_table` input contract to `p_store_id`.
- [x] Rename `admin_create_menu_category` input contract to `p_store_id`.
- [x] Rename `admin_create_menu_item` input contract to `p_store_id`.
- [x] Update table/menu create client calls to send `p_store_id`.
- [x] Keep update/delete table/menu RPCs on row-derived store enforcement until they actually need an explicit store input.

### Inventory contract start

- [x] Rename active inventory RPC inputs to `p_store_id`.
- [x] Update inventory client RPC calls to send `p_store_id`.
- [x] Keep physical schema/storage on `restaurant_id` during coexistence.
- [ ] Replace direct table deletes for ingredient/recipe removal with hardened RPCs before final contract cleanup.

### Attendance contract start

- [x] Rename active attendance RPC inputs to `p_store_id`.
- [x] Update attendance client RPC calls to send `p_store_id`.
- [x] Keep `attendance-photos` path first segment aligned with the active store UUID during coexistence.
- [x] Keep storage/object policy implementation on `restaurant_id`-era fields until final physical contract cleanup.

### Daily closing and admin audit contract start

- [x] Rename `create_daily_closing` input contract to `p_store_id`.
- [x] Rename `get_daily_closings` input contract to `p_store_id`.
- [x] Rename `get_admin_mutation_audit_trace` input contract to `p_store_id`.
- [x] Rename `get_admin_today_summary` input contract to `p_store_id`.
- [x] Update daily closing/admin audit client calls to send `p_store_id`.
- [x] Make admin audit trace accept both `store_id` and legacy `restaurant_id` audit payload keys during coexistence.

### QC contract start

- [x] Rename active QC RPC inputs to `p_store_id`.
- [x] Update QC client RPC calls to send `p_store_id`.
- [x] Keep nullable `p_store_id` semantics for global template reads/writes.
- [x] Keep qc photo storage/object policy implementation on `restaurant_id`-era fields until final physical contract cleanup.

### Store settings contract start

- [x] Rename `admin_update_restaurant` input contract to `p_store_id`.
- [x] Rename `admin_update_restaurant_settings` input contract to `p_store_id`.
- [x] Rename `admin_deactivate_restaurant` input contract to `p_store_id`.
- [x] Update store service client calls to send `p_store_id`.
- [x] Keep canonical RPC names and physical `restaurants` table unchanged during coexistence.

### Delivery settlement contract start

- [x] Rename `confirm_delivery_settlement_received` input contract to `p_store_id`.
- [x] Update delivery settlement client calls to send `p_store_id`.
- [x] Use `user_accessible_stores()` for the delivery settlement confirmation boundary.

Files to update:

- [ ] `/Users/andreahn/globos_pos_system/supabase/migrations/20260409000009_bundle_a_security_closure.sql`
- [ ] `/Users/andreahn/globos_pos_system/supabase/functions/create_staff_user/index.ts`
- [ ] `/Users/andreahn/globos_pos_system/lib/core/services/staff_service.dart`
- [ ] `/Users/andreahn/globos_pos_system/lib/features/admin/providers/staff_provider.dart`

Done when:

- staff create/update permissions follow one role model
- claim refresh happens after admin-driven permission changes

## 3. Reconcile WeTax Scope vs Implementation

Goal: make WeTax docs and code describe the same shipped state.

### Already aligned

- [x] Keep WT03 `/pos/invoices` as the authoritative create-bill endpoint.
- [x] Keep AP1 marked as removed.
- [x] Keep `sid` as immediately returned from WT03.
- [x] Keep `request_einvoice_payload` documented as full WT05 body.

Reference docs:

  - [x] `/Users/andreahn/Documents/restaurant-ops-vault/GLOBOSVN POS/Stage 1/stage1_scope_v1.4.md`
  - [x] `/Users/andreahn/Documents/restaurant-ops-vault/GLOBOSVN POS/Stage 1/database_schema_reference.md`
  - [x] `/Users/andreahn/Documents/restaurant-ops-vault/GLOBOSVN POS/Stage 1/wetax_integration_runbook.md`

### Current shipped interpretation

- [x] Decide whether WT09 buyer lookup is required in the current phase.
- [x] If yes, wire UI cache-miss flow to `wetax-onboarding` `company_lookup`.
- [x] Document current credential model, token cache, and polling-disabled operating mode as shipped behavior.
- [x] Decide whether proof-photo is required in the current phase.
- [x] If yes, implement capture, local queue, upload worker, and payment row update.
- [x] Document admin retry / mark-resolved RPC flow as shipped behavior.

Done when:

- scope docs, handover docs, and shipped code all tell the same story

## 4. Triage UI Work

Goal: separate must-fix correctness issues from deferred product work.

### Must-fix now

- [x] Block direct client-side mutations that contradict RLS/service-role-only design.
- [x] Replace failed-job retry direct table update with a server-owned RPC or edge function.

Files to update:

  - [x] `/Users/andreahn/globos_pos_system/lib/features/admin/tabs/einvoice_tab.dart`
  - [x] add server retry entry point in SQL or edge function

Done when:

- admin retry uses a server-owned mutation boundary
- retry behavior can preserve same `ref_id` and audit trail

### Product work only if still in scope

- [x] WT09 auto-fill UX
- [x] proof-photo capture UI
- [x] proof-photo offline queue/status badge
- [x] polling-disabled status banner
- [x] mark-resolved action for failed jobs

## 5. Verification Pass

Goal: confirm the repo matches the chosen rules after changes.

- [ ] Re-run design-vs-code audit after doc updates and server-boundary fixes.
- [ ] Re-check role routing:
  - [ ] `/admin`
  - [ ] `/super-admin`
  - [ ] `/photo-ops`
- [ ] Re-check remaining legacy write paths and classify which still intentionally use compatibility fallback.
- [ ] Re-check claim refresh after create/update/revoke flows.
- [ ] Re-check WeTax docs vs code for:
  - [ ] WT03 endpoint name
  - [ ] sid semantics
  - [ ] WT05 payload structure
  - [ ] polling-disabled operating mode
- [ ] Re-classify remaining issues into:
  - [ ] confirmed violation
  - [ ] allowed transition state
  - [ ] intentional deferment

## Recommended Order

1. Lock document truth.
2. Fix `request_red_invoice`.
3. Fix staff mutation + claim refresh.
4. Replace direct admin retry mutation with server-owned boundary.
5. Resolve WT09/proof-photo scope decision.
6. Implement deferred UI only if still in scope.
7. Re-audit.
