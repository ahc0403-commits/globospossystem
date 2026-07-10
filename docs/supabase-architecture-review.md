# GLOBOSVN POS — Supabase Architecture Review

- **Date:** 2026-06-10 · **Scope:** `supabase/migrations/` (197 files), `supabase/functions/` (7), pg_cron, storage policies · **Status:** report only
- Excluded as intentional: restaurants/stores dual naming, `get_user_restaurant_id` legacy wrapper, `stores`/`store_settings` views, Office service_role coupling, the two settlement functions.

## 1. Migration history

### 1.1 Two unrelated series interleaved in one directory · **P1**
The directory mixes a **numeric Office-lineage series** (`001_schemas_extensions.sql` … `299_…` — creates `core/system/ops/hr/accounting` schemas, `core.accounts`, Office tables) with the **timestamp POS series** (`20260402…` … `20260609…`). `supabase db push` applies lexicographically: `001…201` → all timestamps → `210…299`. Anyone reasoning numerically gets the opposite order; some numeric files reference POS tables (`211_office_qc_followups.sql` → `public.qc_checks`) and only work because of the accidental interleaving.
**Fix:** segregate the Office series (separate directory or renumber into timestamp form with a recorded baseline); document the canonical order.

### 1.2 Duplicate table definitions with drift · **P2**
`210_office_purchases.sql` vs `20260405000006_office_purchases.sql` both `CREATE TABLE IF NOT EXISTS public.office_purchases` — `brand_id` NOT NULL in one, nullable + RLS-enabled in the other. Same for `211` vs `20260405000007`. Whichever runs first wins. **Fix:** tombstone 210/211 as superseded.

### 1.3 Numbering gaps 292–297 (also 202–209, 212–229, 237–239, 241–249) · **P2**
If deleted files were ever applied to an environment, fresh rebuild diverges from that environment. **Fix:** diff `supabase_migrations.schema_migrations` in both projects against the directory; record the result.

### 1.4 Transactionality · **P3**
Only 37/197 files use `BEGIN/COMMIT`. Notably `20260412150420` does DROP CONSTRAINT → UPDATE → ADD CONSTRAINT un-wrapped; a partial failure leaves `order_items` with no `item_type` CHECK.

## 2. RLS & access control

### 2.1 Owner-executed views leak across tenants · **P0**
Plain views owned by `postgres` (BYPASSRLS on Supabase) granted to `authenticated`, **without** `security_invoker = true`:
- `v_office_pos_sales_events`, `v_office_pos_sales_bucket_summary` (`20260604001000`, recreated in uncommitted `20260609000000`, grant at line 248) — union of `payments`, `payment_adjustments`, `orders`, `external_sales`, `photo_objet_sales` across **all stores**.
- `v_store_daily_sales`, `v_store_attendance_summary`, `v_quality_monitoring`, `v_inventory_status`, `v_brand_kpi` (`20260405000003`, `20260405000012`). A comment in `20260405000011:212` asserts the false premise that views inherit base-table RLS.

Migration `299_deliberry_integration_security_closure.sql` already demonstrates the correct pattern (`ALTER VIEW … SET (security_invoker = true)`) for four other views — these seven were missed. **Fix:** apply the same, or revoke `authenticated` and serve them service_role-only (the Office app connects with service_role). Then verify POS super_admin dashboards still function.

**Note for the uncommitted `20260609000000_office_pos_sales_photo_objet_events.sql`: fix it before it is ever applied.**

### 2.2 Hardcoded CRON_SECRET in committed migration · **P0 (rotate) / P1 (mechanism)**
`20260413001843…sql:28,43,58,73` — hardcoded bearer token inline in the cron job bodies, same value across the four WeTax jobs and (per the comment) the settlement jobs. **Fix:** rotate; read the secret at runtime (Vault / settings table via `current_setting`); `cron.alter_job`; scrub history.

### 2.3 Residual `USING (true)` policies · **P2**
`251_photo_objet.sql:115` (`po_stores_read` — all authenticated users see all Photo Objet stores), `20260405000000:29,55` (brands/companies — likely intentional directory data), `100_rls_policies.sql:134`. Review and either scope or document each.

### 2.4 Storage policies · **P2**
`payment-proofs` is properly store-scoped via `user_accessible_stores` on the path (`20260414000012:13-46`). `qc-photos`, `attendance-photos`, `po-attendance` only check `authenticated` — cross-tenant read/write of staff imagery. Apply the payment-proofs pattern.

### 2.5 Confirmed good
- `partner_credentials`, `daily_closings`: RLS enabled, zero policies = deny-all to non-service roles; `partner_credential_access_log` super_admin-read append-only.
- SECURITY DEFINER `search_path` coverage retro-fixed in `20260408000000`; WeTax-era functions declare it inline.
- `users.auth_id` UNIQUE + indexed; policies funnel through indexed helpers.
- WeTax read RLS (`298`) correctly removed sibling-store visibility via shared tax_entity.
- `anon`-granted `public_restaurant_profiles`/`public_menu_items` are intentional tight-column public projections (keep column lists tight — they also run as owner).

## 3. Data consistency

| # | Finding | Pri |
|---|---------|-----|
| 3.1 | **Daily-close window bug:** `create_daily_closing` (`20260410000000:100-101`) — `v_closing_date::TIMESTAMPTZ` = midnight **UTC** = 07:00 HCMC; sales 00:00–07:00 HCMC excluded; no upper bound either. Fix: `v_closing_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'` + `< day_start + interval '1 day'`; audit/backfill historical closings | **P1** |
| 3.2 | `einvoice_jobs`: no `UNIQUE(order_id)` (one payment per order implies one job; only the in-RPC serialization prevents duplicates — admin/manual paths could insert a second) and no indexes (see performance plan §2.1) | **P1–P2** |
| 3.3 | Step-8 `process_payment` (`20260412155915:79`) dropped the original's amount-vs-items verification (`PAYMENT_AMOUNT_MISMATCH`, `20260409000000:446-463`) — server now trusts the client total. Re-add against `paying_amount_inc_tax` sums | **P2** |
| 3.4 | `inventory_items.current_stock` nullable, no `>= 0` CHECK; `process_payment` decrements unconditionally → silent negative drift. Decide: floor + variance record, or document negative-as-oversell-signal | **P2** |
| 3.5 | Status-vocabulary drift: `record_payment_adjustment` (`20260604001000:186`) tests `'cancelled'` which is not in the `einvoice_jobs` status CHECK — dead branch; reconcile state machine vs CHECK | **P3** |
| 3.6 | Confirmed good: `UNIQUE(order_id)` on payments; `UNIQUE(restaurant_id, closing_date)`; `UNIQUE(source_system, external_order_id)`; `UNIQUE(restaurant_id, source_system, period_label)`; `ref_id` UNIQUE + UUIDv7 CHECK (version nibble + variant enforced at schema level); money uniformly `numeric`, zero float columns; amount CHECKs present | ✅ |

## 4. Concurrency

| # | Finding | Pri |
|---|---------|-----|
| 4.1 | **Confirmed good:** `process_payment` locks the order `FOR UPDATE` before all checks/writes, single transaction, payments UNIQUE backstop — double payment serialized then rejected | ✅ |
| 4.2 | **Dispatcher has no job claiming** (`wetax-dispatcher/index.ts:261`): plain `select … eq status pending limit N`; overlapping cron runs (WeTax latency × batch) double-dispatch. Fix: claiming RPC — `UPDATE … SET status='dispatching' WHERE id IN (SELECT … FOR UPDATE SKIP LOCKED) RETURNING *`, or per-job CAS `.update().eq('status','pending')` | **P1** |
| 4.3 | `admin_retry_einvoice_job` (`20260414000011:41-77`) TOCTOU: reads without lock, unconditionally resets to pending — retry racing dispatcher re-dispatches an in-flight job. Conditional UPDATE checking rowcount. Same pattern (lower stakes) in `admin_mark_resolved_einvoice_job` | **P2** |
| 4.4 | Confirmed good: `confirm_delivery_settlement_received` locks + gate-checks; `record_payment_adjustment` locks payment before summing prior adjustments (over-refund closed); `create_order`/`create_buffet_order` lock the table row (one open order per table via serialization) | ✅ |
| 4.5 | Belt-and-braces (optional): partial unique `ON orders(table_id) WHERE status NOT IN ('completed','cancelled')`; catch `unique_violation` in `create_daily_closing` for the friendly error | P3 |

## 5. einvoice_jobs pipeline (state machine)

- ref_id UUIDv7: enforced by CHECK; `generate_uuidv7()` fixed in `20260428000003`; retry preserves ref_id (good idempotency key). ✅
- Retry policy: `system_config` max_retries=5, backoff `0,3,10,30,60`; terminal `failed_terminal`; >24 h → `stale`; admin escape hatches exist. Caveats = §4.2/4.3 and the poller/dispatcher failure-path gaps (risk register R-12/R-13).
- Transitions live in edge-function code only; nothing prevents an illegal `reported → pending` by service_role. Optional `BEFORE UPDATE` transition-guard trigger. (P3)

## 6. Triggers & views

- POS triggers are light (`updated_at`, immutability guard on `payment_adjustments` — good).
- Office series has a synchronous two-level chain: DML → audit trigger → `trg_enqueue_email_from_audit_log` (defined in `264`, redefined `281`, again `283`) → outbox insert. Cheap, but an enqueue bug rolls back the business write, and triple redefinition is drift-prone. (P3)
- View nesting is shallow (max 2). `v_office_pos_sales_events` recomputes a whole-union with a regex JSONB branch per Office pull — fine now; candidate for indexed materialization later. (P3)

## 7. pg_cron

- Schedules sane: dispatcher 1 min, poller 2 min, daily close `0 17 * * *` (= 00:00 HCMC ✅), commons refresh weekly, email jobs 5/10 min + daily retention.
- **`commons_refresh` is dead on arrival:** cron sends CRON_SECRET (`:71-79`) but `wetax-onboarding` only accepts service_role / INTERNAL_SECRET / user JWT (`index.ts:231-257`) → perpetual 401, unmonitored (`net.http_post` result unchecked). Reference caches never refresh. **P1**
- Cron job HTTP results are not checked anywhere — consider a tiny `cron_run_log` or alerting on function error rates. (P3)

## 8. Edge-function reliability summary (details in risk register)

- `wetax-onboarding`: cashier in allowlist; no store/brand scoping on `tax_entity` writes (keyed on `tax_code`, tenant-global). **P1**
- `wetax-poller`: no batch backoff; poison ref_id stalls the 50-job batch until the stale sweep. **P2**
- `wetax-dispatcher`: 409 → `dispatched` with null sid; no attempt cap on 401/5xx. **P2**
- `generate-settlement`: header/items/sales-link non-atomic; partial failure orphans sales permanently (existence check skips re-run). Move into one RPC transaction. **P2**
- Helper duplication ×4 with `getToken` behavioral drift → `_shared/wetax.ts`. **P1**
- ADR-014 compliance (decodeByteaToString): ✅ all four functions.
- P6 compliance (payment never waits on WeTax): ✅ verified — `process_payment` performs no HTTP; dispatch is cron-async.

## SQL change list (for the roadmap)

```sql
-- P0 batch (one migration)
ALTER VIEW v_office_pos_sales_events SET (security_invoker = true);          -- ×7 views
-- rotate CRON_SECRET + cron.alter_job(...) reading runtime secret

-- P1 batch
-- fix create_daily_closing window (CREATE OR REPLACE)
CREATE INDEX idx_einvoice_jobs_status_created ON einvoice_jobs (status, created_at);
CREATE INDEX idx_einvoice_jobs_order ON einvoice_jobs (order_id);
ALTER TABLE einvoice_jobs ADD CONSTRAINT uq_einvoice_jobs_order UNIQUE (order_id);  -- confirm re-issue flow first
-- claim_einvoice_jobs(batch int) RPC with FOR UPDATE SKIP LOCKED

-- P2 batch
-- re-add amount-vs-items check in process_payment
-- conditional UPDATE in admin_retry_einvoice_job / admin_mark_resolved_einvoice_job
-- store-scope qc-photos / attendance-photos / po-attendance storage policies
-- scope or document po_stores_read USING(true)
CREATE INDEX idx_payments_store_created ON payments (restaurant_id, created_at);
CREATE INDEX idx_attendance_logs_store_logged ON attendance_logs (restaurant_id, logged_at);
```
