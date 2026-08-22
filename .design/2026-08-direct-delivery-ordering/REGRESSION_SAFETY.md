# Regression Safety Contract: 직접 배달 주문

Date: 2026-08-21
Regression budget: **0 observed regressions**

## 의미

이 계약은 버그가 절대로 존재하지 않는다고 주장하지 않는다. 기존 기능에서 변화나 실패가 하나라도 관측되면 직접 배달 기능을 다음 단계로 진행하거나 배포하지 않는다는 release 규칙이다.

## Frozen core

V1 migration과 구현은 다음 객체의 시그니처·본문·trigger 연결·기존 호출 결과를 변경하지 않는다.

- `process_payment`
- `recalc_order_status`
- `update_order_item_status`
- `complete_kitchen_order`
- daily cutoff/grace/finalization 함수와 trigger
- scheduled promotion sync 함수와 trigger
- QR placement/status/menu RPC와 `qr_order_screen.dart`
- 기존 cashier queue/provider와 결제 화면
- 기존 KDS provider, normal/paperless/emergency ledger와 화면
- `enqueue_print_jobs`, print job routing, print agent
- inventory deduction과 MISA/e-invoice 함수·trigger
- digital receipt와 customer display
- 기존 report view/RPC/query
- Deliberry, Photo, Office coupling
- 기존 bank-transfer/SePay/kitchen/emergency alert의 source, sound, cursor,
  acknowledgement, push, test와 generated localization

## 허용되는 변경

- 새 `direct_order_*`, `direct_delivery_*` table, index, policy, function, Edge Function
- 새 direct customer/cashier/kitchen/report route와 widget/provider
- 기존 `pos_live_events` emit 함수를 그대로 호출하는 direct request
  INSERT-only trigger와 direct-only cashier alert host/service/sound
- 기존 router와 role route에 새 경로를 추가하는 최소 변경
- 안정화 이후 feature flag가 켜진 경우만 보이는 작은 진입 버튼
- 승인 transaction 안에서 기존 허용값을 사용한 `orders`, `order_items` insert와 unchanged `process_payment` 호출
- 호환성이 증명된 경우에만 기존 schema를 소비하는 별도 print job insert

## 금지되는 변경

- 기존 core table의 column/constraint/type 변경
- frozen function/view/trigger의 `ALTER`, `DROP`, `CREATE OR REPLACE`
- 직접 주문을 위해 기존 order source/item type enum 또는 check를 확장하는 변경
- 기존 KDS/cashier/QR provider에 direct request를 합치는 변경
- 기존 report bucket이나 Deliberry settlement 의미를 바꾸는 변경
- 기존 테스트 expected value를 신규 기능에 맞춰 갱신하는 변경
- MISA/출력 실패가 기존 결제 성공 여부를 바꾸는 변경

## 호환성 matrix

| 기존 기능 | 직접 기능 OFF | 요청/채팅 중 | 승인 transaction 중 | 승인 후 조리 중 | 필수 증거 |
|---|---|---|---|---|---|
| 홀/포장 POS 주문 | 동일 | 동일 | 동일 | 동일 | integration + baseline diff |
| 테이블 QR/추가주문 | 동일 | 동일 | 동일 | 동일 | RPC/widget/E2E |
| 단일·복합 결제 | 동일 | 동일 | 기존 함수 호출 1회 | 동일 | SQL payment fixtures |
| 할인/VAT/service charge | 동일 | 동일 | quote parity | 동일 | differential fixtures |
| 취소/refund/void | 동일 | 동일 | 기존 권한 유지 | 관리자 reconciliation | SQL/E2E |
| normal KDS | 동일 | 동일 | direct 미노출 | direct 미노출 | provider/widget tests |
| paperless/emergency KDS | 동일 | direct feature 차단 | 승인 차단 | 해당 없음 | guard + regression suite |
| 주방/영수증 출력 | 동일 | 없음 | 기존 출력 무변경 | optional direct slip 격리 | print contract tests |
| 재고 차감 | 동일 | 없음 | 기존 payment에서 1회 | 추가 차감 없음 | inventory ledger diff |
| MISA/e-invoice | 동일 | 없음 | 기존 async enqueue 1회 | 재호출 없음 | failure + queue tests |
| 디지털 영수증/customer display | 동일 | 없음 | 기존 완료 주문 계약 | 동일 | widget/RPC tests |
| cutoff/finalization | 동일 | direct request만 존재 | 21:30 이후 승인 차단 | ticket만 계속 | time-boundary SQL |
| 기존 Reports | 동일 | 동일 | payment 1회 포함 | 중복 없음 | daily reconciliation |
| Deliberry settlement | 동일 | 동일 | write 없음 | write 없음 | table diff |
| Photo/Office coupling | 동일 | 동일 | 기존 payment 결과만 | 추가 event 없음 | contract tests |

## 단계별 release gate

1. **Baseline gate**: 현재 main/worktree 상태에서 기존 전체 suite와 핵심 fixture를 기록한다.
2. **Schema gate**: additive migration과 frozen-core 정적 검사가 통과한다.
3. **Flag-off gate**: 새 코드를 포함한 상태에서 기능 OFF 결과가 baseline과 같다.
4. **Approval gate**: 동시성·idempotency·failure injection·quote parity·cutoff가 통과한다.
5. **Isolation gate**: direct ticket 진행 전후 existing core table diff가 허용된 재무 insert 외 0이다.
6. **Full regression gate**: 호환성 matrix, 전체 Flutter/SQL/Edge/repository gate가 통과한다.
7. **Pilot gate**: 한 매장 내부 20건 대사에서 중복·누락·기존 업무 영향이 0이다.
8. **Production gate**: 별도 승인, exact SHA 배포, GitHub Actions 성공 후 한 매장 flag만 연다.

## 즉시 중단 조건

다음 중 하나라도 발생하면 새 기능을 OFF로 유지하고 원인과 영향 범위를 해결할 때까지 진행하지 않는다.

- baseline test 또는 기존 fixture 결과 변경
- frozen core의 diff 발견
- quote와 actual payment가 1 VND라도 불일치
- 승인 실패 후 부분 order/payment/ticket/MISA/inventory 흔적 발견
- 동일 요청의 중복 order/payment/ticket 발견
- direct ticket mutation이 기존 orders/order_items/inventory/MISA를 변경
- feature flag OFF 상태에서 route/provider/startup 오류
- 새 provider/Realtime/polling 장애가 기존 cashier/KDS에 전파
- direct arrival alert가 기존 alert cursor/ack/sound를 호출하거나 frozen
  alert hash를 변경
- cross-store/cross-request 데이터 또는 exact PII 노출
- 기존 report 총매출 중복·누락, Deliberry/Office/Photo 영향
- paperless/emergency/promotion guard 우회
- 전체 test/analyze/check gate 중 하나라도 실패

## Rollback 원칙

- 첫 조치는 Google 주문 링크 제거와 매장 storefront flag OFF다.
- 열린 승인 전 요청은 거절/만료하고 audit를 남긴다.
- 이미 승인된 건은 기존 financial order를 임의 삭제하지 않고 관리자 refund/void 및 ticket reconciliation으로 처리한다.
- additive table과 audit는 보존한다.
- 기존 core 객체를 되돌리는 파괴적 downgrade가 필요 없는 구조를 유지한다.
