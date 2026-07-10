# GLOBOSVN POS — Performance & Cost Improvement Plan

- **Date:** 2026-06-10 · **Status:** report only
- **Scale assumption:** 10 stores × 500 orders/day ≈ 5k orders, 25k order_items, 5k payments, 5k einvoice_jobs per day (~1.8M orders/yr); ~4–6 always-on devices per store (~50 fleet-wide).

## Tier 1 — Request-volume elimination (biggest lever, smallest code)

### 1.1 Kill the 2-second poll while realtime is connected · **P0 / S**
Five providers run `Timer.periodic(2s)` → nested orders+items+menu join, regardless of realtime state:
`order_provider.dart:292-307`, `kitchen_provider.dart:278-290`, `table_provider.dart:189-196`, `payment_provider.dart:356-363`, `admin/providers/tables_provider.dart:198-203`.
The intended design already exists in `payment_detail_screen.dart:212-227` (cancels the timer when `_realtimeConnected`, polls only as fallback).
- Cost today: 43,200 req/day/screen → ≈ **2.1M PostgREST calls/day fleet-wide**, all duplicate (realtime triggers the same reload anyway). Dominant driver of egress, DB CPU, and pool pressure; scales with screens, not data.
- Fix: copy the guard into all five `_ensureAutoRefresh`s; raise fallback interval to 10–15 s.
- Expected effect: >95% reduction of the system's baseline request volume.

### 1.2 Debounce realtime-triggered full reloads · **P1 / M**
`order_provider.dart:197-256` (6 handlers), `kitchen_provider.dart:214-263`, `payment_provider.dart:281-341`, `table_provider.dart:119-172`, `tables_provider.dart:159-188`, `payment_detail_screen.dart:128-196`. Every store-scoped event triggers a full nested reload on every device; `order_items` events refresh unconditionally (table-level filter exists only for `orders`).
- Fix: 500 ms coalescing debounce per provider; filter `order_items` events by relevant order_id; longer-term apply payload deltas.
- Channels are properly store-scoped and disposed — only the reload amplification needs work.

### 1.3 Connectivity probe redesign · **P2 / S**
`connectivity_service.dart:104` pings `restaurants` every 10 s per device (~430k calls/day fleet-wide). Use socket/realtime channel state as the primary signal; hit the DB only on state transitions.

## Tier 2 — Database

### 2.1 `einvoice_jobs` indexes · **P1 / S**
Zero indexes beyond PK/uniques (table from `20260412145159…:196`). Dispatcher scans `status='pending' ORDER BY created_at` every 60 s; poller scans dispatched every 120 s; RLS policy `298` joins on `order_id`. At 1.8M rows/yr this is a forever-growing per-minute seq scan.
```sql
CREATE INDEX idx_einvoice_jobs_status_created ON einvoice_jobs (status, created_at);
CREATE INDEX idx_einvoice_jobs_order ON einvoice_jobs (order_id);
-- optional partial: WHERE status IN ('pending','dispatched')
```
(Pair with `UNIQUE(order_id)` — see supabase-architecture-review §3.4.)

### 2.2 Composite indexes for report paths · **P2→grows to P1 / S**
- `payments(restaurant_id, created_at)` — current index is `(restaurant_id)` only (`initial_schema.sql:287`); report and `v_brand_kpi` queries filter by date range. At 1.8M payments/yr this decides whether reports stay index-driven.
- `attendance_logs(restaurant_id, logged_at)` — `staff_provider.dart:231-238` filters on both; only `user_id` is indexed.
- `order_items(status)` partial `WHERE status='cancelled'` if the cancelled-items report query stays.

### 2.3 Server-side aggregation for reports · **P1 / M**
- `super_admin_provider.dart:371-409`: per-store loop, 2 sequential awaits each, downloading **every raw payment row** in range to sum in Dart. "All stores, last month" ≈ 150k rows to the device over 20 sequential round-trips.
- `report_provider.dart:171-229`: 7 sequential unbounded queries; the `audit_logs` query (223-229) has **no date filter at all** (unbounded growth).
- Fix: one aggregate RPC/view (`GROUP BY restaurant_id, sales_channel, day`); date-bound the audit query; `Future.wait` independent queries as an interim.

### 2.4 `v_brand_kpi` correlated scans · **P3 / M**
`20260405000003:95-120` — two correlated subqueries over `payments` per brand row, queried by the Office app. Tolerable with 2.2's composite index; long-term: daily materialized rollup.

## Tier 3 — Edge functions & cron

### 3.1 Dispatcher/poller micro-batching · **P2 / S**
- `wetax-dispatcher/index.ts:269-272`: per-job re-`select("*")` inside the loop — data already fetched at line 260 (N+1).
- `wetax-poller/index.ts:129-135`: stale jobs updated one-by-one — single `UPDATE … WHERE id IN (…)`.
- Dispatcher writes ~2 rows/min to `partner_credential_access_log` even on idle runs — skip credential decrypt/log when zero pending jobs.
- Baseline burn: dispatcher 1 min + poller 2 min ≈ 65k invocations/month at zero sales — acceptable, but make the no-op path cheap.

### 3.2 Poller/dispatcher backoff (also reliability) · **P2 / M**
Batch-level `polling_next_at` backoff on WT06 failure; dispatch attempt caps. Without this, a vendor outage means re-hammering WeTax every 1–2 minutes indefinitely. (Details in risk-register R-12/R-13.)

## Tier 4 — Flutter rendering & memory

| Item | Location | Fix | Pri/Diff |
|------|----------|-----|----------|
| Kitchen screen rebuilds entire grid every second for the elapsed-time clock | `kitchen_screen.dart:56-63` (+ non-builder `ListView` at 309) | isolate clock into a leaf StatefulWidget | P2 / S |
| Non-builder `ListView(` with dynamic content | `qc_tab.dart:399,1847`, `inventory_tab.dart:406,1071,1432`, `reports_tab.dart:521,1047`, `super_admin_screen.dart:372,1502`, `order_workspace.dart:1086` | `ListView.builder` opportunistically; kitchen + super_admin first (always-on / multi-store) | P3 / S |
| Non-autoDispose `.family` providers cache one entry per param forever | `restaurantNameProvider` ×3, `qc_provider.dart:480,648` | `.autoDispose` | P3 / S |
| Session StateNotifiers never reset on logout (memory + correctness) | ~20 providers; `auth_provider.dart:168-172` | invalidate on logout | P1 / S |

Verified clean: timer/channel disposal is consistent; no `ref.watch` in loops/itemBuilders; no leaked camera controllers.

## Tier 5 — Storage & egress

- **QC photos skip compression on web** (`qc_service.dart:386-393` returns raw bytes; `qc_check_screen.dart:96` has no `maxWidth`): 4–8 MB per photo vs ~150 KB on native. Compress on web too (the `image` package works on web) or pass `maxWidth`/`imageQuality` to the picker. **P2 / S**
- Attendance (800px/q70) and payment proofs are already compressed — fine.
- 10-year signed URLs stored in DB (`attendance_service.dart:48`, `qc_service.dart:179`): not a perf issue, but a bucket-policy change invalidates all of them at once — noted.

## Sequencing & verification

1. **Week 1 (with the P0 security batch):** 1.1 poll guard + 2.1 einvoice indexes. Verify: Supabase dashboard request count drops ~10× per store; `EXPLAIN` on dispatcher query shows index scan.
2. **Week 2–3:** 1.2 debounce, 2.3 aggregate RPCs, 3.1 micro-batching, 5 web compression. Verify: report screen network tab shows one RPC instead of 7+ raw queries; egress per report < 100 KB.
3. **Opportunistic:** Tier 4 items when each file is next touched; 2.2 composite indexes anytime (online, cheap).

Success criteria: daily PostgREST request count per store < 50k (from ~430k); report generation does no client-side row aggregation; dispatcher query plan uses the status index; no `Timer.periodic` below 10 s in lib/ except transient countdowns.
