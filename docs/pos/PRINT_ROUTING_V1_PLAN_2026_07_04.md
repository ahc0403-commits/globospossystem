# Floor/Station Print Routing V1 — Revised Implementation Plan

Date: 2026-07-04
Status: PRODUCTION DEPLOYED 2026-07-06 (DB + Vercel; pilot printer setup/smoke still required)
Supersedes: draft print-routing proposal reviewed 2026-07-04
Binding contracts: `ORDER_LIFECYCLE_STATE_CONTRACT_2026_07_03.md` (recalc is
the single serving-transition point), CLAUDE.md §4 (order/payment flows never
depend on external device availability).

## 0. Verdict on the draft

Direction B (+ partial C) — floor data on tables, destination routing,
kitchen/floor/tray tickets, jobs queue with retry — is correct and retained.
The draft is not implementable as written; verified corrections:

| # | Draft claim | Verified reality | Consequence |
|---|---|---|---|
| P1 | "printerProvider의 단일 IP 설정을 여러 프린터로 확장" | `WifiPrinterService` = `dart:io Socket` → port 9100, **`isSupported => !kIsWeb`** ([wifi_printer_service.dart:14](lib/core/hardware/wifi_printer_service.dart)). The pilot client is the **Vercel web build** — browsers cannot open raw TCP sockets, ever | Client-direct printing cannot be the backbone. **Architecture pivots to a DB `print_jobs` queue + one native print-agent device on the store LAN** that drives all printers |
| P2 | printer IP is "stored" | stored in **device-local SharedPreferences** (`printer_ip`), not in DB ([printer_provider.dart:49](lib/features/settings/printer_provider.dart)) | destinations must move to a store-scoped DB table; the existing cashier receipt path stays as-is in V1 (risk containment) |
| P3 | "tables에 floor 추가" | confirmed absent: prod `tables` has layout_x/y/w/h/rotation/shape/sort (20260502000000) but **no floor column** | add `floor_label`; reuse the existing tables-tab editing UI pattern |
| P4 | ticket on "주문 확정" | confirm happens in DB RPCs (`create_order`, `add_items_to_order`); tray moment is the **serving transition inside `recalc_order_status`** — the contract's single derivation point | enqueue server-side inside those RPCs, atomic with the order mutation, works from any client incl. web |
| P5 | draft has no delta rule for 추가 주문 | `add_items_to_order` appends items mid-service | kitchen/floor tickets for add-item batches must print **only the delta items**, else the kitchen re-cooks the whole order |
| P6 | Supabase-side printing implied nowhere/unstated | Edge Functions run in the cloud and cannot reach LAN printers | stated explicitly: the executor must be on the store LAN (agent) |
| P7 | retry/dedup unspecified | — | idempotency key + `SKIP LOCKED` claim + bounded backoff specified (§4) |

Existing assets reused: `esc_pos_utils_plus` (byte building, platform-free),
`ReceiptBuilder`, `WifiPrinterService` (agent-side socket I/O), kitchen
realtime subscription pattern, `pg_cron` (retention).

## 1. Architecture (pinned)

```
web/native POS client
   └─ create_order / add_items_to_order / recalc(serving) [DB RPCs]
        └─ enqueue print_jobs (same transaction, exception-guarded)
print agent (1 native device in kitchen: Android tablet or mini-PC,
             same Flutter codebase, "print station mode")
   ├─ realtime subscribe print_jobs (+ 15s fallback poll, kitchen pattern)
   ├─ claim_print_jobs() RPC  (FOR UPDATE SKIP LOCKED)
   ├─ render ESC/POS bytes (ReceiptBuilder extensions)
   └─ Socket → printer IP per job (1F/2F/3F floor printers + kitchen/dumbwaiter)
```

One agent covers all printers (they're all LAN-reachable); a second agent
device is a warm spare, safe because claiming is `SKIP LOCKED`.
Wired LAN + fixed IP printers (draft's ops recommendation kept).

Failure semantics: order/payment flows NEVER block on printing. Enqueue is
wrapped `BEGIN…EXCEPTION → audit_logs('print_enqueue_failed')` so even a
print_jobs bug cannot abort an order. Failed jobs stay visible for reprint.

## 2. Data model (migration M1)

```sql
ALTER TABLE public.tables
  ADD COLUMN IF NOT EXISTS floor_label text NOT NULL DEFAULT '1F';

CREATE TABLE public.printer_destinations (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  name          text NOT NULL,
  ip            text NOT NULL,
  port          int  NOT NULL DEFAULT 9100,
  purpose       text NOT NULL CHECK (purpose IN ('kitchen','floor','tray')),
  floor_label   text,                     -- required when purpose='floor'
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT floor_purpose_needs_label
    CHECK (purpose <> 'floor' OR floor_label IS NOT NULL)
);

CREATE TABLE public.print_jobs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  order_id      uuid REFERENCES orders(id) ON DELETE CASCADE, -- NULL only for printer test jobs
  copy_type     text NOT NULL CHECK (copy_type IN ('kitchen','floor','tray')),
  batch_no      int  NOT NULL,            -- 1 = initial send, 2+ = add-item deltas / re-serving
  destination_id uuid REFERENCES printer_destinations(id),
  payload       jsonb NOT NULL,           -- structured ticket, NOT bytes (§3)
  status        text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','printing','done','failed','cancelled')),
  attempts      int NOT NULL DEFAULT 0,
  last_error    text,
  next_retry_at timestamptz NOT NULL DEFAULT now(),
  claimed_by    uuid,                     -- agent auth uid
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT print_jobs_idempotent UNIQUE (order_id, copy_type, batch_no, destination_id)
);
CREATE INDEX print_jobs_pending ON print_jobs(restaurant_id, status, next_retry_at)
  WHERE status IN ('pending','failed');
```

RLS: store-scoped SELECT for staff; INSERT/UPDATE via RPCs only. Realtime
publication on `print_jobs`. All new RPCs get explicit
`REVOKE … FROM PUBLIC, anon` / `GRANT … TO authenticated, service_role`
(F-1 lesson). Retention: pg_cron daily purge of `done`/`cancelled` jobs
older than 7 days.

## 3. Ticket contract

`payload` (jsonb, rendered to ESC/POS by the agent):

```json
{
  "ticket": "kitchen|floor|tray",
  "floor_label": "2F", "table_number": "T07",   // staff meal: table "STAFF"
  "ticket_code": "A38-…(shortOrderTicketCode)",
  "batch_no": 2, "printed_reason": "initial|added_items|serving|reprint",
  "at": "2026-07-04T14:22:00+07:00",
  "items": [ {"label":"Pho Bo","qty":2,"notes":"No onion","supplemental":true} ],
  "order_notes": "…"
}
```

Rendering rules (ReceiptBuilder additions `buildKitchenTicket`,
`buildFloorTicket`, `buildTrayLabel`): tray/floor tickets print
`floor_label / table_number` double-width-double-height FIRST; kitchen ticket
uses a compact kitchen header before the item list; add-item batches print
header `*** ADDED ITEMS (batch n) ***` and contain ONLY delta items (P5);
labels use raw DB menu names (kitchen convention — no client-locale translation
on paper). Multi-tray `Tray n/m` is deferred (§8-D3); V1 prints one tray label
per serving batch.

## 4. Enqueue + execution contract

### 4.1 Enqueue points (server-side, atomic with the mutation)

| Event | Where | Jobs created |
|---|---|---|
| initial send | `create_order` (after items insert) | `kitchen` batch 1 → kitchen dest; `floor` batch 1 → dest matching table's floor_label |
| add items | `add_items_to_order` | `kitchen`/`floor` batch = max(batch_no)+1, **delta items only** |
| all items ready (order → serving) | `recalc_order_status`, ONLY on the transition edge `v_next='serving' AND v_order.status <> 'serving'` | `tray` batch = tray-count+1 → tray dest (fallback kitchen dest) |
| reprint | `reprint_print_job(p_job_id)` RPC (kitchen/admin roles) | clone row, `printed_reason='reprint'` |
| order cancelled | `cancel_order` | mark that order's `pending/failed` jobs `cancelled` (don't print dead orders) |

A shared helper `enqueue_print_jobs(p_order_id, p_copy_types text[], p_items jsonb, p_reason text)`
resolves destinations (active, matching purpose/floor; missing destination ⇒
job created with `destination_id NULL` + status `failed` + error
`NO_DESTINATION` so it surfaces in the reprint panel instead of vanishing).
Helper body is exception-guarded per §1. Existing RPCs are regenerated
**from live `pg_get_functiondef`** (drift lesson — no repo file is current).

Re-serving after mid-service additions correctly produces a new tray ticket
(batch 2) — the added dishes need their own dumbwaiter run. This falls out
of the recalc edge for free.

### 4.2 Agent execution

- `claim_print_jobs(p_store_id, p_limit int)` — `UPDATE … SET status='printing',
  claimed_by=auth.uid(), attempts=attempts+1 WHERE id IN (SELECT … WHERE
  status IN ('pending','failed') AND next_retry_at <= now() ORDER BY
  created_at FOR UPDATE SKIP LOCKED LIMIT p_limit) RETURNING *` — safe for
  two agents.
- agent prints → `complete_print_job(p_job_id, p_ok, p_error)`; failure sets
  `failed`, `next_retry_at = now() + LEAST(attempts,5) * interval '20 s'`;
  after 10 attempts stays `failed` (manual reprint only) — no infinite loops.
- roles allowed: `kitchen`, `admin`, `store_admin`, `super_admin` (agent
  logs in with a station account, e.g. kitchen@…; no new role).
- agent UI: "프린트 스테이션" screen (native only, guarded by
  `WifiPrinterService.isSupported`) — job feed, per-destination status,
  test-print button, failed-job list with reprint.

## 5. Client changes

| Surface | Change |
|---|---|
| admin settings tab | printer destinations CRUD (name/ip/port/purpose/floor, test print by enqueueing an agent-processed `print_jobs` test job) |
| admin tables tab | `floor_label` editor per table (existing edit dialog pattern) |
| kitchen screen | failed-print badge + reprint entry (reads print_jobs failed count) |
| print station mode | new native-only screen per §4.2 (same codebase; entry visible only when `!kIsWeb`) |
| ReceiptBuilder | 3 ticket builders (§3) with double-size header helpers (esc_pos_utils_plus styles) |
| existing cashier receipt | untouched in V1 (P2) |
| l10n | new strings in en/ko/vi simultaneously |

Waiter/cashier web clients need NO printing code — they only trigger RPCs
they already call today.

## 6. Migration / PR split & rollout

0. 선행: 2026-07-04 lib 수정 재배포 및 할인/직원식 트랙과 마이그레이션
   번호 충돌 조정 (both patch `add_items_to_order`/`recalc` — 이 트랙의 RPC
   재생성은 **할인 트랙 M1/M2 이후** live prosrc에서 떠야 함; 순서 고정:
   discount M1→M2 → print M1).
1. **M1 (DB)**: §2 DDL + RLS + realtime + enqueue helper + RPC regeneration
   (create_order/add_items/recalc/cancel_order hooks) + claim/complete/reprint
   RPCs + pg_cron purge + REVOKE/GRANT.
2. **C1 (Flutter)**: ReceiptBuilder tickets + print station mode + agent loop.
3. **C2 (Flutter)**: admin destinations CRUD + floor_label editor + kitchen
   reprint badge.
4. Ops: 프린터 4대 고정 IP 부여, agent 기기 네이티브 빌드 설치, destinations
   등록, 층 라벨 일괄 입력(SQL 1회 or admin UI), 테스트 인쇄.

M1 is a no-op for current clients (new tables + hooks that only insert rows;
regression scenario TP0 proves order flows unchanged).

## 7. Test matrix

SQL contract test (`print_routing_contract_test.sql`, Gate-2 harness style):

| # | Scenario | Expect |
|---|---|---|
| TP0 | create/add/serve/pay/cancel with NO destinations configured | order lifecycle identical; jobs rows exist as `failed/NO_DESTINATION`; no exceptions leak |
| TP1 | create_order (2F table) | kitchen batch1 + floor(2F dest) batch1, payload items = full set |
| TP2 | add_items | batch2 jobs, payload = delta only |
| TP3 | all ready (serving edge) | tray batch1 once; re-running recalc (no edge) adds nothing |
| TP4 | add after serving → ready again | tray batch2 created |
| TP5 | cancel_order | pending jobs → `cancelled` |
| TP6 | two concurrent claims | SKIP LOCKED: no job claimed twice |
| TP7 | complete failure ×10 | backoff schedule honored; 11th claim not offered |
| TP8 | cross-store claim/reprint | forbidden |
| TP9 | reprint | cloned job, reason=reprint |
| TP10 | enqueue helper forced error | order RPC still succeeds; `print_enqueue_failed` audit row |

Flutter: builder unit tests (byte snapshots incl. double-size header, delta
header), station-mode smoke on macOS (agent claims a seeded job against a
mock socket). Gate 3: no changes required (web clients untouched).

## 8. Decisions needed (defaults proposed)

- D1 에이전트 하드웨어: 주방 Android 태블릿 1대(기본) vs mini-PC — 네이티브
  빌드만 가능하면 무엇이든.
- D2 층 프린터 부재 층: 해당 층 job을 kitchen dest로 폴백(기본) vs 미생성.
- D3 `Tray n/m` 분할 표기: V1 제외(기본), 서빙 배치당 1장.
- D4 티켓 코드: 기존 short ticket code 재사용(기본) vs 일일 순번 카운터
  (별도 시퀀스 테이블 필요 — V2).
- D5 취소 알림 티켓(주방에 "취소됨" 출력): V1 제외(기본; 주방 화면이 이미
  실시간 반영) vs 포함.

## 9. Explicit non-risks (verified)

- 주문/결제 흐름은 인쇄와 완전 분리 (enqueue 예외 가드 + 상태계약 무변경).
- 웹 클라이언트는 코드 변경 없음 — RPC가 이미 유일한 진입점.
- Edge Function 인쇄 불가 문제는 설계상 원천 회피 (LAN 에이전트).
- `tables` 물리 스키마 변경은 additive (`floor_label` default '1F') — Office
  앱 커플링(`restaurants` 테이블)과 무관.
