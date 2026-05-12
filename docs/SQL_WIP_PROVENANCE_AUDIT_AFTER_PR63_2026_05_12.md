# SQL WIP Provenance Audit After PR63 — 2026-05-12

## Verdict

Current verdict is **NO-GO** for using any untracked SQL artifact as runtime truth.

Reason:

- all target SQL WIP files exist on disk
- `supabase/schema.sql` is tracked but `0 bytes`
- the tracked schema baseline is therefore unusable for reflection comparison
- none of the untracked SQL artifacts can be proven from current tracked schema content alone

As a result, every untracked SQL artifact in this report remains:

- `DO NOT APPLY`
- `DO NOT CONNECT`
- `DO NOT TREAT AS CANONICAL`

until lineage is proven through a real tracked schema baseline or accepted tracked migration history.

## Current git and schema baseline

- Repo: `~/globos_pos_system`
- HEAD: `466b206027dd8b631be30d588d67551f0944c3b5`
- Branch: `main`
- `supabase/schema.sql`: tracked, `0 bytes`

This means PR `#63` created a tracked schema-baseline path, but not a usable schema-baseline body.

## Target file existence check

All required target files exist:

- [supabase/schema.sql](/Users/andreahn/globos_pos_system/supabase/schema.sql)
- [20260428000002_vat_pricing_mode.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260428000002_vat_pricing_mode.sql)
- [20260428000004_disable_photo_objet_red_invoice.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260428000004_disable_photo_objet_red_invoice.sql)
- [20260428000006_restore_wt03_feature_payload.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260428000006_restore_wt03_feature_payload.sql)
- [vui_vui_food_inclusive_validation.sql](/Users/andreahn/globos_pos_system/supabase/snippets/vui_vui_food_inclusive_validation.sql)

## Migration order conflict check

The three untracked migration files sit inside an otherwise tracked chronological sequence:

- tracked: `20260428000001`
- untracked: `20260428000002`
- tracked: `20260428000003`
- untracked: `20260428000004`
- tracked: `20260428000005`
- untracked: `20260428000006`
- tracked: `20260428000007`
- tracked: `20260428000008`

This ordering is a provenance risk in itself.

Why it matters:

- the timestamps make the untracked files look like they were meant to be part of canonical migration history
- but current git-tracked history excludes them
- the existence of tracked neighbors before and after them means they may be:
  - missing canonical migrations
  - abandoned local drafts
  - superseded intermediate steps

From current repo state alone, this conflict cannot be resolved.

## SQL artifact inventory table

| File | Tracked? | Schema reflection status vs `supabase/schema.sql` | Risk level | Safe next action |
|---|---|---|---|---|
| `supabase/schema.sql` | Yes | unusable baseline (`0 bytes`) | High | keep untouched; replace only through proven schema-baseline work |
| `20260428000002_vat_pricing_mode.sql` | No | not reflected in tracked schema baseline | High | audit against accepted migration history before any staging |
| `20260428000004_disable_photo_objet_red_invoice.sql` | No | not reflected in tracked schema baseline | High | treat as provenance-unknown until reconciled |
| `20260428000006_restore_wt03_feature_payload.sql` | No | not reflected in tracked schema baseline | High | treat as provenance-unknown until reconciled |
| `vui_vui_food_inclusive_validation.sql` | No | not reflected in tracked schema baseline | High | keep as validation-only candidate, not migration truth |

## Per-file provenance status

### 1. `supabase/schema.sql`

Classification:

- tracked baseline placeholder
- not a usable reflection source

Evidence:

- file exists
- file size is `0 bytes`
- no DDL or schema objects are present in it

Schema reflection status:

- unusable

Risk level:

- High

Safe next action:

- leave untouched
- do not infer schema truth from it
- replace only through explicit schema-baseline repair work

### 2. `20260428000002_vat_pricing_mode.sql`

Classification:

- provenance unknown
- local-only candidate
- potentially sequence-conflicting

Evidence from file contents:

- `ALTER TABLE public.restaurants ADD COLUMN IF NOT EXISTS vat_pricing_mode`
- `COMMENT ON COLUMN public.restaurants.vat_pricing_mode`
- `DROP FUNCTION IF EXISTS public.process_payment(...)`
- `CREATE OR REPLACE FUNCTION public.process_payment(...)`
- `CREATE OR REPLACE FUNCTION public.request_red_invoice(...)` in two overloads
- `CREATE OR REPLACE FUNCTION public.search_b2b_buyers(...)`
- `CREATE OR REPLACE FUNCTION public.admin_update_restaurant_settings(...)`
- multiple `DROP POLICY` / `CREATE POLICY` blocks

Affected objects:

- tables / columns:
  - `public.restaurants.vat_pricing_mode`
  - `public.order_items`
  - `public.einvoice_jobs`
  - `public.b2b_buyer_cache`
  - `public.store_tax_entity_history`
  - `public.einvoice_events`
- functions:
  - `public.process_payment`
  - `public.request_red_invoice` (legacy/store overloads)
  - `public.search_b2b_buyers`
  - `public.admin_update_restaurant_settings`
- policies:
  - `brand_master_admin_read`
  - `tax_entity_admin_read`
  - `einvoice_shop_admin_read`
  - `system_config_admin_read`
  - multiple `b2b_buyer_cache_*`
  - `store_tax_history_admin_read`
  - `einvoice_jobs_admin_read`
  - `einvoice_events_admin_read`
- constraints:
  - `CHECK (vat_pricing_mode IN ('exclusive', 'inclusive'))`

Schema reflection status:

- not reflected in tracked schema baseline

Risk level:

- High

Safe next action:

- do not stage
- do not apply
- compare against accepted tracked migration history before any decision

### 3. `20260428000004_disable_photo_objet_red_invoice.sql`

Classification:

- provenance unknown
- obsolete / unsafe candidate
- sequence-conflicting

Evidence from file contents:

- `CREATE OR REPLACE FUNCTION public.request_red_invoice(...)` in two overloads
- raises `RED_INVOICE_DISABLED_FOR_PHOTO_OBJET`
- updates `einvoice_jobs`
- writes `b2b_buyer_cache`
- writes `audit_logs`

Affected objects:

- functions:
  - `public.request_red_invoice` (two overloads)
- tables:
  - `public.einvoice_jobs`
  - `public.einvoice_shop`
  - `public.tax_entity`
  - `public.restaurants`
  - `public.order_items`
  - `public.b2b_buyer_cache`
  - `public.audit_logs`
- constants / behavior:
  - `RED_INVOICE_DISABLED_FOR_PHOTO_OBJET`

Schema reflection status:

- not reflected in tracked schema baseline

Risk level:

- High

Safe next action:

- do not stage
- do not apply
- reconcile against tracked neighbors `20260428000005` and `20260428000007` first

### 4. `20260428000006_restore_wt03_feature_payload.sql`

Classification:

- provenance unknown
- obsolete / unsafe candidate
- sequence-conflicting

Evidence from file contents:

- `DROP FUNCTION IF EXISTS public.process_payment(...)`
- `CREATE OR REPLACE FUNCTION public.process_payment(...)`
- uses `vat_pricing_mode`
- uses WT03-like payload fields:
  - `feature`
  - `seq`
  - `item_code`
  - `item_name`
- filename contains `restore`, implying prior rollback or correction lineage

Affected objects:

- functions:
  - `public.process_payment`
- tables:
  - `public.restaurants`
  - `public.order_items`
  - `public.einvoice_jobs`
  - `public.tax_entity`
  - `public.einvoice_shop`
  - `public.audit_logs`
- columns / payload semantics:
  - `restaurants.vat_pricing_mode`
  - WT03 item payload shape in generated invoice payload

Schema reflection status:

- not reflected in tracked schema baseline

Risk level:

- High

Safe next action:

- do not stage
- do not apply
- audit against tracked `process_payment` lineage before any acceptance

### 5. `vui_vui_food_inclusive_validation.sql`

Classification:

- validation-only candidate
- local-only candidate
- obsolete / unsafe for canonical migration use

Evidence from file contents:

- updates `public.restaurants.vat_pricing_mode`
- inserts seed-like rows into:
  - `public.restaurants`
  - `public.tables`
  - `public.menu_categories`
  - `public.menu_items`
  - `auth.users`
  - `public.users`
- creates temp validation table
- invokes `public.process_payment(...)`
- checks `public.order_items`, `public.einvoice_jobs`, and `public.restaurants`

Affected objects:

- tables:
  - `public.restaurants`
  - `public.tables`
  - `public.menu_categories`
  - `public.menu_items`
  - `public.users`
  - `public.order_items`
  - `public.einvoice_jobs`
  - `auth.users`
- function:
  - `public.process_payment`
- temp objects:
  - `temp_vui_vui_validation_result`

Schema reflection status:

- not reflected in tracked schema baseline

Risk level:

- High

Safe next action:

- do not stage
- do not apply
- keep only as a validation harness candidate after schema lineage is proven

## Runtime safety implications

The audited SQL WIP remains unsafe for runtime use.

Direct implications:

- `payment_detail_screen.dart` must remain disconnected
- `inventory_purchase/*` must remain unmounted
- `admin_sidebar_signal_provider.dart` must remain dormant

Reason:

- those runtime surfaces could end up depending on payment / invoice / store-setting behavior that is not yet proven in tracked SQL lineage

## Safe next action

The only safe next action is:

**continue SQL lineage reconciliation without applying any WIP SQL**

Specifically:

1. preserve all audited SQL files untouched
2. do not promote any of them into runtime assumptions
3. establish a real schema reflection baseline before any migration acceptance decision
4. then compare these three untracked migrations against accepted tracked migration history

## Explicit list of files that remained untouched

- [supabase/schema.sql](/Users/andreahn/globos_pos_system/supabase/schema.sql)
- [20260428000002_vat_pricing_mode.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260428000002_vat_pricing_mode.sql)
- [20260428000004_disable_photo_objet_red_invoice.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260428000004_disable_photo_objet_red_invoice.sql)
- [20260428000006_restore_wt03_feature_payload.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260428000006_restore_wt03_feature_payload.sql)
- [vui_vui_food_inclusive_validation.sql](/Users/andreahn/globos_pos_system/supabase/snippets/vui_vui_food_inclusive_validation.sql)

No target SQL file was modified, staged, or applied during this audit.
