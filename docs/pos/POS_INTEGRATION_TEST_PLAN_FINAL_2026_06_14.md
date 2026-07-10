# POS Integration Test Plan - Final

작성일: 2026-06-14
대상: `/Users/andreahn/globos_pos_system`
범위: POS 매장 주문/결제/환불/마감, Office projection, Deliberry settlement 및 Deliberry 운영 주문 연동 준비 상태

## 0. 결론

이 계획의 목적은 POS 연동 테스트 당일에 "없는 기능을 있다고 가정"하거나 "테스트 seed가 불명확해서 중단"되는 일을 막는 것이다.

현재 POS 기준으로 테스트 범위는 두 단계로 나눈다.

1. **현재 구현 검증 범위**
   - POS 기본 로그인/라우팅/권한
   - 매장 주문 생성, 아이템 추가, 결제, 취소, 환불
   - active store scoping
   - 기본 daily close
   - Office가 읽는 POS/외부매출 projection 일부
   - Deliberry settlement/readiness 흐름

2. **추가 구현 또는 계약 확정 전에는 Full Go 불가 범위**
   - Deliberry 운영 주문 수신 화면 또는 큐
   - Deliberry 주문 accept/reject/ready 송신
   - 공통 통합 이벤트 outbox/inbox/retry/dead-letter
   - `trace_id`, `event_id`, `payload_version` 기반 end-to-end 추적
   - delivery payment를 POS daily close에 포함할지에 대한 계약
   - QA 계정, terminal, channel, seed 데이터의 실제 값

Full Office-POS-Deliberry 운영 연동 Go는 2번 항목이 완료되어야만 가능하다. 1번만 통과한 상태는 **POS core + Office projection + Deliberry settlement Go candidate**로만 판정한다.

## 1. Think_A 압력 점검

### 1.1 문제를 다시 정의한다

연동 테스트의 실제 위험은 "테스트 케이스 부족"이 아니라 다음 네 가지다.

- POS에 없는 Deliberry 운영 주문 기능을 테스트 계획이 있다고 가정한다.
- QA seed, terminal, payment method 값이 실제 코드 contract와 다르다.
- Office와 POS가 같은 데이터를 보더라도 trace 기준이 없어 실패 원인을 역추적할 수 없다.
- cross-store 데이터 노출 또는 중복 이벤트로 재무 데이터가 오염된다.

이 계획을 만들지 않으면 연동 테스트는 다음 지점에서 깨진다.

- 배송 주문 화면 또는 accept/reject/ready 버튼을 찾지 못한다.
- `DELIVERY_PAY`, `CARD_SANDBOX`, `POS-TERM-001` 같은 임의 값 때문에 테스트 데이터 생성이 실패한다.
- 주문/결제는 성공했지만 Office 또는 Deliberry 쪽 반영 여부를 같은 ID로 추적하지 못한다.
- duplicate/retry 테스트가 실제 중복 매출로 남는다.

### 1.2 기존 구현을 먼저 사용한다

새로운 테스트 전용 개념을 만들지 않는다.

- POS 결제수단은 `lib/core/payments/payment_method_contract.dart`의 contract만 사용한다.
- POS 기본 주문 idempotency는 `pos_client_mutation_attempts`를 기준으로 검증한다.
- Deliberry 현재 구현은 운영 주문이 아니라 settlement/readiness 중심으로 검증한다.
- Office coupling은 POS Supabase의 `restaurants` 테이블과 기존 views/projections를 깨지 않는 범위에서만 검증한다.
- WeTax 장애는 결제를 막지 않아야 한다. payment completion은 WeTax availability와 독립이다.

### 1.3 접근안 비교

| 접근 | A. 전체 자동화 먼저 | B. 계약 고정 후 staged manual+smoke | C. 누락 기능 구현 먼저 |
|---|---|---|---|
| Build 복잡도 | 높음 | 낮음 | 높음 |
| 운영 복잡도 | 높음 | 중간 | 중간 |
| 되돌리기 | 어려움 | 쉬움 | 중간 |
| Blast radius | 큼 | 작음 | 중간 |
| Supabase schema cost | 큼 | 작음 | 큼 |
| 첫 usable version | 늦음 | 빠름 | 중간 |
| 판정 | 비추천 | **채택** | Blocker 해결 단계에서 수행 |

채택안은 B다. 먼저 현재 구현으로 가능한 테스트를 통과시키고, Deliberry 운영 주문 및 통합 이벤트 추적은 별도 Blocker로 분리한다.

### 1.4 첫 공격 지점

테스트는 다음 공격을 반드시 포함한다.

- 같은 `client_mutation_id` 재전송
- 같은 `external_order_id` 중복 수신
- 다른 store의 주문/정산/마감 데이터 접근
- Office 또는 Deliberry endpoint 지연/실패
- WeTax unavailable 상태에서 POS 결제 완료
- 00:00 Asia/Ho_Chi_Minh 경계 daily close
- 한국어/영어/베트남어 메뉴명, 옵션명, 고객 메모
- 10배 주문량에서 화면/쿼리 지연

## 2. 테스트 원칙

### 2.1 절대 조건

- Production 데이터로 테스트하지 않는다.
- 문서에 평문 비밀번호, service role key, terminal token을 기록하지 않는다.
- `restaurants` 물리 테이블명은 바꾸지 않는다.
- POS의 `process_payment` RPC는 결제 원자성 anchor로 취급한다.
- WeTax 장애는 POS 결제 완료를 막는 실패 조건이 아니다.
- `generate-settlement`와 `generate_delivery_settlement`는 서로 다른 도메인이므로 중복으로 보지 않는다.
- 테스트 결과는 Pass/Fail/Blocked/Not Applicable 중 하나로만 기록한다.

### 2.2 용어

| 용어 | 기준 |
|---|---|
| store_id | POS `restaurants.id` 또는 그 view alias |
| restaurant_id | 기존 physical FK 명칭. `store_id`와 dual naming 상태를 고려한다. |
| terminal_id | 실제 seed/token이 확인되기 전까지 임의값 사용 금지 |
| channel_id | `POS`, `OFFICE`, `DELIBERRY`처럼 계약된 channel만 사용 |
| order_no | 실제 구현에 명시 필드가 없으면 UUID/display id 기준으로 임시 추적하고, Full Go 전 계약 확정 필요 |
| external_order_id | Deliberry 또는 외부 시스템 주문 ID |
| trace_id | 한 업무 흐름 전체를 묶는 ID |
| event_id | 개별 송수신 이벤트 ID |
| payload_version | event payload schema 버전 |

### 2.3 허용 결제수단

현재 POS contract 기준 결제수단은 다음만 사용한다.

- `CASH`
- `CREDITCARD`
- `ATM`
- `MOMO`
- `ZALOPAY`
- `VNPAY`
- `SHOPEEPAY`
- `BANKTRANSFER`
- `VOUCHER`
- `CREDITSALE`
- `OTHER`
- `SERVICE`

테스트 문서에서 `CARD_SANDBOX`, `DELIVERY_PAY`는 사용하지 않는다. 필요하면 별도 contract 변경 후 추가한다.

## 3. 사전 준비 Gate

이 Gate가 하나라도 Fail이면 연동 테스트를 시작하지 않는다.

| ID | 확인 항목 | 완료 기준 | 실패 시 판정 |
|---|---|---|---|
| G0-01 | 테스트 환경 | POS, Office, Supabase, Deliberry test endpoint가 모두 staging/test | No-Go |
| G0-02 | 코드 버전 | POS build version, commit hash, migration head 기록 | No-Go |
| G0-03 | 계정 | 캐셔/매니저/관리자/test API client 실제 seed 존재 | Blocked |
| G0-04 | 비밀값 | 비밀번호/token은 vault 또는 secure channel에만 존재 | No-Go |
| G0-05 | store seed | 테스트 store가 1개 이상 있고 active 상태 | Blocked |
| G0-06 | cross-store seed | 데이터 격리 검증용 두 번째 store 존재 | Blocked |
| G0-07 | 메뉴 seed | 한/영/베 메뉴명, 옵션, 품절 가능 상품 존재 | Blocked |
| G0-08 | terminal seed | 실제 terminal id/token 확인 | Blocked |
| G0-09 | cleanup 기준 | `qa_run_id` 또는 prefix로 생성 데이터 식별 가능 | No-Go |
| G0-10 | Office 연결 | Office가 같은 POS staging Supabase 또는 계약된 read source를 봄 | No-Go |
| G0-11 | Deliberry 모드 | settlement-only 테스트인지 operational-order 테스트인지 명시 | No-Go |
| G0-12 | Blocker 인정 | 없는 기능은 Fail이 아니라 Blocked로 기록하는 룰 합의 | No-Go |

## 4. 정적 Contract 검증

연동 테스트 전 로컬 repo에서 먼저 확인한다.

| ID | 확인 항목 | 명령/증거 | 완료 기준 |
|---|---|---|---|
| C1-01 | payment method contract | `lib/core/payments/payment_method_contract.dart` | 허용 결제수단 목록과 테스트 계획 일치 |
| C1-02 | role route contract | `flutter test test/role_routes_contract_test.dart` | Pass |
| C1-03 | active store scoping | `flutter test test/live_sync_scope_contract_test.dart` | Pass |
| C1-04 | order idempotency | `flutter test test/operational_stability_closure_contract_test.dart` | Pass |
| C1-05 | payment/refund contract | `flutter test test/payment_adjustment_contract_test.dart` | Pass |
| C1-06 | daily close HCMC window | `flutter test test/daily_closing_window_test.dart` | Pass |
| C1-07 | Deliberry settlement contract | `flutter test test/deliberry_integration_contract_test.dart` | Pass |
| C1-08 | tri-system projection harness | `flutter test test/tri_system_data_flow_harness_test.dart` | Pass |
| C1-09 | forbidden assumptions | repo search | `DELIVERY_PAY`, `CARD_SANDBOX`, fake account values are not used as hard contract |

권장 묶음 명령:

```bash
flutter test \
  test/role_routes_contract_test.dart \
  test/live_sync_scope_contract_test.dart \
  test/operational_stability_closure_contract_test.dart \
  test/payment_adjustment_contract_test.dart \
  test/daily_closing_window_test.dart \
  test/deliberry_integration_contract_test.dart \
  test/tri_system_data_flow_harness_test.dart
```

## 5. POS 기본 Gate

이 Gate가 깨지면 주문/결제/연동 테스트로 넘어가지 않는다.

| ID | 테스트 | 절차 | 기대 결과 |
|---|---|---|---|
| P0-01 | 캐셔 로그인 | 실제 QA 캐셔 계정으로 로그인 | cashier 또는 허용 판매 화면 표시 |
| P0-02 | 매니저 로그인 | 실제 QA 매니저/관리자 계정으로 로그인 | admin 또는 허용 관리 화면 표시 |
| P0-03 | 역할 차단 | 캐셔가 관리자 기능 접근 시도 | 라우팅/PIN/권한 차단 |
| P0-04 | 화면 이동 | waiter, kitchen, cashier, payment detail, admin 이동 | 빈 화면, 무한 로딩, route error 없음 |
| P0-05 | active store | 현재 store 표시 및 데이터 조회 | 다른 store 데이터 노출 없음 |
| P0-06 | 언어 | KO/EN/VI 전환 또는 데이터 표시 | 글자 깨짐, overflow 없음 |
| P0-07 | 앱 오류 | Flutter console, API error, toast 확인 | 미처리 예외 없음 |
| P0-08 | 버전 | 앱 버전/build/commit 기록 | 테스트 리포트에 고정 |
| P0-09 | terminal | 실제 terminal seed 확인 | 없으면 Blocked, 임의 `POS-TERM-001` 사용 금지 |

## 6. POS Core Workflow 테스트

### 6.1 주문

| ID | 테스트 | 절차 | 기대 결과 | 증거 |
|---|---|---|---|---|
| P1-01 | 신규 주문 생성 | 테스트 table 또는 order surface에서 메뉴 1개 주문 | `orders` row 생성, status 정상 | order id, screenshot |
| P1-02 | 아이템 추가 | 같은 주문에 옵션 포함 메뉴 추가 | `order_items` 증가, 총액 재계산 | order item ids |
| P1-03 | 다국어 메뉴 | KO/EN/VI 메뉴명 또는 메모 입력 | 화면/영수증/DB payload 깨짐 없음 | screenshot |
| P1-04 | 품절 메뉴 | unavailable item 주문 시도 | 주문 차단 또는 명확한 오류 | UI/API evidence |
| P1-05 | 주방 상태 | pending -> preparing -> ready/served | 내부 주문 상태 정상 반영 | status log |
| P1-06 | 주문 취소 | 미결제 주문 취소 | status cancelled, Office projection 확인 | order id |

### 6.2 결제

| ID | 테스트 | 절차 | 기대 결과 | 증거 |
|---|---|---|---|---|
| P2-01 | 현금 결제 | `CASH`로 결제 | payment 완료, 주문 completed | payment id |
| P2-02 | 카드 결제 | `CREDITCARD`로 결제 | 결제 증빙 요구/저장 정책 정상 | payment id, proof |
| P2-03 | 전자결제 | `VNPAY` 또는 실제 허용 e-payment | method 정상 저장 | payment id |
| P2-04 | 서비스 처리 | `SERVICE` 사용 | storage normalize와 revenue flag 기준 확인 | payment row |
| P2-05 | split/partial | 허용되는 경우 복합 결제 | 총액 일치, 중복 없음 | payment rows |
| P2-06 | WeTax unavailable | WeTax endpoint 비가용 상태에서 결제 | POS 결제 완료, einvoice는 async queue/error | payment id, job status |

### 6.3 환불/취소

| ID | 테스트 | 절차 | 기대 결과 | 증거 |
|---|---|---|---|---|
| P3-01 | 부분 환불 | 결제 일부 환불 | append-only adjustment 생성 | adjustment id |
| P3-02 | 전액 환불 | 결제 전액 환불 | over-refund 불가, status 정상 | adjustment id |
| P3-03 | 중복 환불 방지 | 같은 환불 재시도 | 중복 adjustment 또는 초과 환불 없음 | DB rows |
| P3-04 | 권한 검증 | 캐셔가 관리자 환불 기능 시도 | 차단 | UI/API evidence |

### 6.4 마감

| ID | 테스트 | 절차 | 기대 결과 | 증거 |
|---|---|---|---|---|
| P4-01 | 기본 마감 | 당일 주문/결제 후 daily close 생성 | HCMC 날짜 기준 집계 | closing row |
| P4-02 | 중복 마감 | 같은 store/date 마감 재시도 | 중복 row 방지 또는 명확한 오류 | error/row count |
| P4-03 | 00:00 경계 | HCMC 23:59/00:01 데이터 포함성 확인 | 지정 날짜 window 정확 | SQL evidence |
| P4-04 | delivery 포함 여부 | external_sales/delivery payment 포함 확인 | 현재 계약 없으면 Blocked/Decision Needed | decision record |

## 7. Office Projection 테스트

Office는 POS Supabase를 읽는 coupling이 있으므로, POS에서 생긴 재무/운영 이벤트가 Office read model 또는 projection에 나타나는지를 확인한다.

| ID | 테스트 | 절차 | 기대 결과 |
|---|---|---|---|
| O1-01 | POS 주문 반영 | POS에서 주문 생성 후 Office 조회 | 같은 store/order 식별 가능 |
| O1-02 | POS 결제 반영 | POS 결제 완료 후 Office sales/projection 조회 | 금액, method, timestamp 일치 |
| O1-03 | 취소 반영 | POS 주문 취소 | Office cancel event/projection 확인 |
| O1-04 | 환불 반영 | POS refund adjustment 생성 | Office refund projection 확인 |
| O1-05 | daily close 반영 | POS daily close 생성 | Office 마감/리포트 기준과 일치 |
| O1-06 | cross-store 차단 | Store A 사용자로 Store B 데이터 확인 시도 | 노출 없음 |
| O1-07 | external_sales 반영 | Deliberry settlement용 external_sales seed | Office external sale projection 확인 |

모든 Office 확인은 다음 식별자를 리포트에 남긴다.

- `store_id` 또는 `restaurant_id`
- POS `order_id`
- `payment_id`
- `payment_adjustment_id`
- `external_order_id`, 있는 경우
- 생성 시각과 HCMC 영업일

## 8. Deliberry 테스트

Deliberry 테스트는 두 모드로 나눈다.

### 8.1 D0 - 현재 가능한 settlement/readiness 테스트

현재 코드 기준 기본 테스트 모드는 D0다.

| ID | 테스트 | 절차 | 기대 결과 |
|---|---|---|---|
| D0-01 | external_sales seed | Deliberry test sale 생성 또는 수신 | `external_sales`에 source/order id/amount 저장 |
| D0-02 | settlement summary | POS admin delivery settlement 화면 로드 | unsettled revenue, settlement summary 표시 |
| D0-03 | generate delivery settlement | `generate_delivery_settlement` test run | settlement header/items/linkage 생성 |
| D0-04 | confirm received | 관리자 입금 확인 | settlement status/received 상태 갱신 |
| D0-05 | duplicate external order | 같은 `external_order_id` 재처리 | 중복 매출 생성 없음 |
| D0-06 | Office projection | Deliberry external sale이 Office에 표시 | amount/status/source 일치 |

D0 통과는 Deliberry settlement Go candidate일 뿐이다. 운영 주문 연동 Go가 아니다.

### 8.2 D1 - Full Deliberry operational-order 테스트

D1은 다음 구현 또는 계약이 확인되기 전까지 Blocked다.

| ID | 필요 항목 | 완료 기준 |
|---|---|---|
| D1-B01 | POS delivery order inbox | 신규 Deliberry 주문이 POS 화면/큐에 표시 |
| D1-B02 | 주문 상세 | 고객 메모, 메뉴, 옵션, 금액, 결제/수금 방식 표시 |
| D1-B03 | accept 송신 | POS에서 접수 시 Deliberry에 accepted event 전달 |
| D1-B04 | reject 송신 | POS에서 거절 사유 선택 후 rejected event 전달 |
| D1-B05 | ready 송신 | 조리 완료 시 ready event 전달 |
| D1-B06 | duplicate 처리 | 같은 Deliberry order/event 재수신 시 중복 없음 |
| D1-B07 | retry/dead-letter | Deliberry 장애 시 retry 후 실패 보관 |
| D1-B08 | status inbound | picked_up/delivering/delivered/customer_cancelled 반영 |
| D1-B09 | inventory/sold-out | 주문 수락 또는 품절 시 재고/품절 신호 기준 확정 |
| D1-B10 | closing | delivery payment가 POS close에 포함되는지 계약 확정 |

D1 실행 테스트:

| ID | 테스트 | 절차 | 기대 결과 |
|---|---|---|---|
| D1-01 | 신규 주문 수신 | Deliberry test order 생성 | POS inbox에 1건 표시 |
| D1-02 | 주문 접수 | POS에서 accept | Deliberry accepted, Office trace 확인 |
| D1-03 | 주문 거절 | POS에서 reject + reason | Deliberry rejected, 중복 주문 없음 |
| D1-04 | 조리 완료 | POS/kitchen에서 ready | Deliberry ready, pickup 가능 |
| D1-05 | 배송 완료 inbound | Deliberry delivered event | POS/Office 상태 반영 |
| D1-06 | 고객 취소 inbound | customer_cancelled event | POS/Office cancel/refund 기준 반영 |
| D1-07 | 장애 후 재시도 | Deliberry endpoint 5xx/timeout | retry count 증가, 최종 dead-letter |
| D1-08 | signature/token 실패 | 잘못된 token/signature | 401/403, 데이터 미변경 |

## 9. 통합 이벤트 추적 기준

현재 POS에 공통 outbox/inbox/dead-letter가 없으면 이 섹션은 Full Go Blocker다. 임시로는 DB row id, logs, Office projection을 묶어 증거를 남긴다.

### 9.1 필수 이벤트 타입

| 이벤트 | 방향 | 최소 상태 |
|---|---|---|
| `POS_ORDER_CREATED` | POS -> Office | 현재 구현 증거로 검증 |
| `POS_PAYMENT_COMPLETED` | POS -> Office | 현재 구현 증거로 검증 |
| `POS_ORDER_CANCELLED` | POS -> Office | 현재 구현 증거로 검증 |
| `POS_REFUND_RECORDED` | POS -> Office | 현재 구현 증거로 검증 |
| `POS_DAILY_CLOSE_CREATED` | POS -> Office | 현재 구현 증거로 검증 |
| `DELIBERRY_EXTERNAL_SALE_RECORDED` | Deliberry/POS -> Office | settlement 모드 검증 |
| `DELIBERRY_ORDER_RECEIVED` | Deliberry -> POS | Full Go 전 필요 |
| `DELIBERRY_ORDER_ACCEPTED` | POS -> Deliberry | Full Go 전 필요 |
| `DELIBERRY_ORDER_REJECTED` | POS -> Deliberry | Full Go 전 필요 |
| `DELIBERRY_ORDER_READY` | POS -> Deliberry | Full Go 전 필요 |
| `POS_INVENTORY_SOLD_OUT` | POS -> Deliberry/Office | Full Go 전 필요 |

### 9.2 이벤트 필수 필드

Full Go 전 모든 integration event는 다음 필드를 가져야 한다.

- `event_id`
- `trace_id`
- `payload_version`
- `event_type`
- `source_system`
- `destination_system`
- `tenant_id`, 있으면
- `store_id`
- `channel_id`
- `terminal_id`, POS terminal event인 경우
- `actor_id`, 사람이 수행한 경우
- `order_id`, POS order인 경우
- `order_no`, 계약 확정 후
- `external_order_id`, Deliberry/external order인 경우
- `status`
- `attempt_count`
- `last_error`
- `created_at`
- `processed_at`

### 9.3 통합 trace Pass 기준

하나의 테스트 주문에 대해 다음을 한 줄로 연결할 수 있어야 한다.

```text
trace_id
  -> POS order_id/order_no
  -> payment_id or external_order_id
  -> Office projection row/event
  -> Deliberry event or settlement row
  -> retry/dead-letter row, 실패 시
```

이 연결이 불가능하면 Full Go가 아니다.

## 10. 장애/보안 테스트

| ID | 테스트 | 공격 | 기대 결과 |
|---|---|---|---|
| F1-01 | 주문 중복 | 같은 `client_mutation_id` 재전송 | 주문 1건만 존재 |
| F1-02 | 결제 중복 | 같은 결제 액션 반복 | 중복 revenue 없음 |
| F1-03 | 환불 초과 | 결제금액 초과 환불 | 차단 |
| F1-04 | 외부주문 중복 | 같은 `external_order_id` 재수신 | external sale/order 중복 없음 |
| F1-05 | Office 조회 지연 | Office app/API 지연 | POS 결제/주문은 독립 완료 |
| F1-06 | Deliberry timeout | outbound timeout | retry/dead-letter 또는 Blocked |
| F1-07 | WeTax down | WeTax unavailable | POS payment completed |
| F1-08 | cross-store read | Store A 계정으로 Store B 조회 | 접근 차단 |
| F1-09 | wrong terminal | 다른 store terminal token 사용 | 접근 차단 |
| F1-10 | invalid payload | 필수 필드 누락/잘못된 타입 | 4xx 또는 rejected, partial write 없음 |
| F1-11 | 10x data | 평소의 10배 주문/결제 seed | 화면 timeout/overflow 없음 |
| F1-12 | 3 languages | KO/EN/VI 이름/메모 | 깨짐/누락 없음 |

## 11. 테스트 데이터 설계

### 11.1 seed 원칙

- 모든 row는 `qa_run_id` 또는 고유 prefix를 가진다.
- 실제 계정명/비밀번호는 이 문서에 쓰지 않는다.
- 테스트 store는 최소 2개를 둔다.
- test order는 onsite, refund, cancelled, delivery external sale을 분리한다.
- 운영 주문 테스트는 Deliberry test/sandbox order만 사용한다.

### 11.2 최소 데이터

| 데이터 | 최소 수량 | 목적 |
|---|---:|---|
| store | 2 | active store/cross-store 검증 |
| cashier user | 1 | 주문/결제 |
| manager/admin user | 1 | 환불/마감/정산 |
| terminal | 1 | POS terminal binding |
| menu item | 5 | 일반/옵션/품절/다국어/고가 |
| table/order surface | 2 | 동시 주문/중복 방지 |
| payment methods | 4 | `CASH`, `CREDITCARD`, `VNPAY`, `OTHER` |
| external sales | 3 | Deliberry settlement |
| delivery order | 3 | D1 구현 후 accept/reject/ready |

## 12. Cleanup/Rollback

테스트 cleanup은 삭제 대상을 넓게 잡지 않는다. `qa_run_id`로 생성한 데이터만 정리한다.

권장 순서:

1. 자동 job 또는 poller가 테스트 데이터를 계속 생성하는지 확인한다.
2. 테스트 run의 row count snapshot을 저장한다.
3. integration event/outbox/dead-letter가 있으면 해당 `qa_run_id`만 정리한다.
4. Deliberry operational order가 있으면 해당 `external_order_id`만 정리한다.
5. delivery settlement item/header/linkage를 해당 run 기준으로 정리한다.
6. `external_sales` 중 해당 run의 source/external order만 정리한다.
7. `payment_adjustments`를 정리한다.
8. `payments`를 정리한다.
9. `order_items`를 정리한다.
10. `orders`를 정리한다.
11. inventory movement/sold-out test row를 정리한다.
12. daily closing test row를 정리한다.
13. terminal/user seed는 재사용 seed면 삭제하지 않고 비활성화 또는 reset만 한다.
14. cleanup 후 row count가 0 또는 기대값인지 확인한다.

`POS 이벤트 송신 outbox 정지` 같은 절차는 실제 outbox 구현이 있을 때만 수행한다. 현재 구현이 없으면 절차에 넣지 않는다.

## 13. 실행 순서

### Phase A - 사전 확정

1. 테스트 환경과 seed 값을 확정한다.
2. Full Deliberry operational-order 테스트를 할지, settlement-only 테스트를 할지 결정한다.
3. build version/commit/migration head를 기록한다.
4. cleanup 기준 `qa_run_id`를 정한다.

### Phase B - 정적 검증

1. contract tests 실행.
2. payment method, route, daily close, settlement 계약 확인.
3. Forbidden assumptions 검색.

### Phase C - POS 기본 검증

1. 로그인/권한.
2. 화면 이동.
3. active store.
4. 오류 로그.
5. 버전/terminal.

### Phase D - POS core 업무 검증

1. 주문 생성.
2. 아이템 추가/취소.
3. 결제.
4. 환불/void/adjustment.
5. daily close.
6. retry/idempotency.

### Phase E - Office projection 검증

1. 주문/결제/취소/환불 projection.
2. daily close alignment.
3. cross-store isolation.

### Phase F - Deliberry 검증

1. D0 settlement/readiness는 현재 검증 가능.
2. D1 operational-order는 구현/계약 완료 후만 실행.

### Phase G - 장애/보안 검증

1. duplicate.
2. timeout.
3. invalid payload.
4. cross-store/terminal/token.
5. WeTax down.
6. 10x/3 languages.

### Phase H - cleanup 및 리포트

1. cleanup.
2. row count 검증.
3. evidence archive.
4. Go/No-Go 판정.

## 14. 리포트 템플릿

모든 테스트는 다음 형식으로 기록한다.

| 필드 | 값 |
|---|---|
| Test ID | 예: P2-01 |
| Run ID | `qa_run_id` |
| Environment | POS/Office/Supabase/Deliberry test URL |
| POS version | version/build/commit |
| Actor | role only, not password |
| Store | store id/name |
| Steps | 실제 수행 단계 |
| Expected | 기대 결과 |
| Actual | 실제 결과 |
| Status | Pass/Fail/Blocked/Not Applicable |
| Evidence | screenshot, DB row id, log, trace id |
| Owner | POS/Office/Deliberry/Backend/QA |
| Blocker ID | 있을 경우 |

## 15. Go/No-Go 기준

### 15.1 POS Core Go

다음이 모두 Pass면 POS core는 Go candidate다.

- G0 사전 준비 Gate
- C1 정적 contract 검증
- P0 기본 Gate
- P1 주문
- P2 결제
- P3 환불/취소
- P4 기본 daily close
- cross-store isolation

### 15.2 Office Projection Go

다음이 모두 Pass면 Office projection은 Go candidate다.

- POS 주문/결제/취소/환불이 Office에서 같은 store 기준으로 조회된다.
- 금액, method, status, timestamp가 일치한다.
- 다른 store 데이터가 노출되지 않는다.
- `restaurants` table coupling이 깨지지 않는다.

### 15.3 Deliberry Settlement Go

다음이 모두 Pass면 Deliberry settlement는 Go candidate다.

- external sales 생성/조회
- settlement summary
- settlement generation
- confirm received
- duplicate external order 방지
- Office projection 확인

### 15.4 Full Office-POS-Deliberry Operational Go

다음이 모두 Pass여야 Full Go다.

- POS core Go
- Office projection Go
- Deliberry settlement Go
- Deliberry operational order D1
- integration event trace
- retry/dead-letter
- delivery payment daily close contract
- terminal/channel/account seed 확정

### 15.5 즉시 No-Go

하나라도 발생하면 즉시 No-Go다.

- production 데이터 사용
- cross-store 데이터 노출
- 중복 이벤트로 중복 매출/중복 결제 생성
- payment completion이 WeTax 장애 때문에 실패
- 환불 초과 허용
- Office coupling table/column 파손
- D1 구현/계약이 Blocked인데도 Full Go로 판정하려고 함
- trace/evidence 없이 "수동으로 봤다"만 남김
- cleanup 대상이 불명확함

## 16. 최종 판정 문구

테스트 후 최종 보고는 아래 네 문장 중 하나를 사용한다.

1. **Full Go**: POS core, Office projection, Deliberry settlement, Deliberry operational order, integration trace가 모두 Pass.
2. **Partial Go - POS/Office/Settlement**: POS core, Office projection, Deliberry settlement는 Pass이나 Deliberry operational order 또는 event trace는 Blocked.
3. **Blocked**: seed, terminal, credentials, endpoint, missing implementation 때문에 실행 불가.
4. **No-Go**: 데이터 격리, 결제, 환불, 중복, 마감, coupling 중 하나가 Fail.

현재 코드 기준 예상 기본 판정은 **Partial Go - POS/Office/Settlement**, 그리고 Full Go를 위해서는 Deliberry operational order와 integration event trace를 추가해야 한다.

## 17. Blocker별 실행 명령

이 섹션은 Full Go를 막는 네 가지 Blocker를 각각 독립 작업으로 넘기기 위한 명령 묶음이다. Claude Code에 전달하는 프롬프트는 프로젝트 규칙에 따라 영어로 작성한다. 각 Workstream은 구현 명령, 검증 명령, 완료 판정이 함께 있어야 한다.

### 17.1 B1 - Deliberry operational order

목표: POS가 Deliberry 신규 주문을 수신하고, 주문 상세를 표시하며, accept/reject/ready 상태를 Deliberry와 Office 추적 흐름에 남긴다.

Claude Code command:

```text
Load Design Documents:
- CLAUDE.md
- /Users/andreahn/.claude/CLAUDE.md
- docs/pos/POS_INTEGRATION_TEST_PLAN_FINAL_2026_06_14.md
- docs/ADR-013-Store-Type-Classification.md
- docs/ADR-014-Brand-Store-Multi-Access-Model.md
- docs/phase_1_architecture.md

Load Code Structure:
- lib/features/delivery/
- lib/features/admin/admin_screen.dart
- lib/core/router/app_router.dart
- lib/core/utils/role_routes.dart
- supabase/migrations/
- supabase/functions/
- test/deliberry_integration_contract_test.dart
- test/tri_system_data_flow_harness_test.dart

Objective:
Implement the minimum Deliberry operational order D1 slice for POS without changing existing Deliberry settlement behavior.

Frozen Criteria:
1. POS has a scoped delivery-order inbox/read model for the active store.
2. POS can represent new, accepted, rejected, ready, delivered, and customer-cancelled states without duplicating revenue.
3. POS exposes accept, reject-with-reason, and ready actions behind the correct role/store scope.
4. Duplicate Deliberry order/event input cannot create duplicate POS orders or duplicate revenue.
5. Existing delivery settlement tests and tri-system tests still pass.
6. The implementation does not rename or break the physical restaurants table or Office coupling.

Run Checks by Category:
- flutter test test/deliberry_integration_contract_test.dart test/tri_system_data_flow_harness_test.dart
- flutter test test/role_routes_contract_test.dart test/live_sync_scope_contract_test.dart
- rg -n "DELIBERRY_ORDER_RECEIVED|DELIBERRY_ORDER_ACCEPTED|DELIBERRY_ORDER_REJECTED|DELIBERRY_ORDER_READY|external_order_id" lib supabase test

Generate Harness Report:
Return severity-classified findings and a Priority Fix List.
```

완료 후 검증 명령:

```bash
flutter test \
  test/deliberry_integration_contract_test.dart \
  test/tri_system_data_flow_harness_test.dart \
  test/role_routes_contract_test.dart \
  test/live_sync_scope_contract_test.dart

rg -n "DELIBERRY_ORDER_RECEIVED|DELIBERRY_ORDER_ACCEPTED|DELIBERRY_ORDER_REJECTED|DELIBERRY_ORDER_READY|external_order_id" lib supabase test
```

완료 판정:

- D1-B01부터 D1-B08까지 Pass.
- D0 settlement flow가 regression 없이 Pass.
- Full Go 전 integration event trace와 retry/dead-letter도 별도 Pass 필요.

### 17.2 B2 - integration event trace

목표: POS, Office, Deliberry 사이의 주문/결제/환불/마감/배송 이벤트를 `trace_id`, `event_id`, `payload_version`으로 연결한다.

Claude Code command:

```text
Load Design Documents:
- CLAUDE.md
- /Users/andreahn/.claude/CLAUDE.md
- docs/pos/POS_INTEGRATION_TEST_PLAN_FINAL_2026_06_14.md
- docs/ADR-014-Brand-Store-Multi-Access-Model.md
- docs/supabase-architecture-review.md
- docs/risk-register.md

Load Code Structure:
- lib/core/services/
- lib/features/order/
- lib/features/payment/
- lib/features/delivery/
- supabase/migrations/
- supabase/functions/
- test/tri_system_data_flow_harness_test.dart
- test/payment_adjustment_contract_test.dart
- test/operational_stability_closure_contract_test.dart

Objective:
Design and implement the smallest POS integration event trace layer needed to connect POS, Office, and Deliberry events with trace_id, event_id, payload_version, store_id, channel_id, and relevant order/payment/external_order references.

Frozen Criteria:
1. Every POS integration event has event_id, trace_id, payload_version, event_type, source_system, destination_system, store_id, status, attempt_count, created_at, and processed_at or last_error.
2. POS order created, payment completed, order cancelled, refund recorded, daily close created, and Deliberry external sale/order events can be traced end-to-end.
3. The trace layer is store-scoped and cannot leak cross-store data.
4. Existing POS payment completion remains independent of WeTax availability.
5. Existing Office coupling to restaurants is not broken.
6. Contract tests cover required fields and at least one synthetic end-to-end trace.

Run Checks by Category:
- flutter test test/tri_system_data_flow_harness_test.dart test/payment_adjustment_contract_test.dart test/operational_stability_closure_contract_test.dart
- rg -n "trace_id|event_id|payload_version|event_type|source_system|destination_system|attempt_count|last_error" lib supabase test

Generate Harness Report:
Return severity-classified findings and a Priority Fix List.
```

완료 후 검증 명령:

```bash
flutter test \
  test/tri_system_data_flow_harness_test.dart \
  test/payment_adjustment_contract_test.dart \
  test/operational_stability_closure_contract_test.dart

rg -n "trace_id|event_id|payload_version|event_type|source_system|destination_system|attempt_count|last_error" lib supabase test
```

완료 판정:

- 하나의 `trace_id`로 POS order, payment/refund 또는 external_order, Office projection, 실패 시 dead-letter까지 연결 가능.
- trace 필드가 없는 통합 이벤트는 Full Go 불가.

### 17.3 B3 - retry/dead-letter

목표: Office 또는 Deliberry 송수신 실패가 데이터 유실이나 중복 매출로 이어지지 않도록 retry와 dead-letter를 구현한다.

Claude Code command:

```text
Load Design Documents:
- CLAUDE.md
- /Users/andreahn/.claude/CLAUDE.md
- docs/pos/POS_INTEGRATION_TEST_PLAN_FINAL_2026_06_14.md
- docs/risk-register.md
- docs/supabase-architecture-review.md

Load Code Structure:
- supabase/migrations/
- supabase/functions/
- lib/features/delivery/
- lib/core/services/
- test/tri_system_data_flow_harness_test.dart
- test/deliberry_integration_contract_test.dart

Objective:
Implement retry and dead-letter handling for POS integration events without making payment completion depend on external system availability.

Frozen Criteria:
1. Failed outbound integration events increment attempt_count and preserve last_error.
2. Retry is idempotent and cannot create duplicate revenue, duplicate payment, or duplicate external sale rows.
3. Exhausted events move to or are queryable as dead-letter with trace_id and event_id.
4. Deliberry timeout/5xx and Office projection failure are represented as retryable failures.
5. Invalid auth/signature/payload failures are rejected safely without partial writes.
6. Existing settlement, payment, and tri-system tests still pass.

Run Checks by Category:
- flutter test test/tri_system_data_flow_harness_test.dart test/deliberry_integration_contract_test.dart test/payment_adjustment_contract_test.dart
- rg -n "retry|dead_letter|dead-letter|attempt_count|last_error|processed_at|trace_id|event_id" lib supabase test

Generate Harness Report:
Return severity-classified findings and a Priority Fix List.
```

완료 후 검증 명령:

```bash
flutter test \
  test/tri_system_data_flow_harness_test.dart \
  test/deliberry_integration_contract_test.dart \
  test/payment_adjustment_contract_test.dart

rg -n "retry|dead_letter|dead-letter|attempt_count|last_error|processed_at|trace_id|event_id" lib supabase test
```

완료 판정:

- timeout, 5xx, duplicate event, invalid payload 각각의 결과가 Pass/Fail/Dead-letter로 명확히 구분된다.
- 중복 이벤트가 중복 매출이나 중복 결제를 만들면 즉시 No-Go.

### 17.4 B4 - delivery payment daily close contract

목표: Deliberry/external delivery 매출을 POS daily close에 포함할지, Office settlement에만 둘지 계약을 확정하고 그 결정에 맞게 테스트를 고정한다.

Decision command:

```text
Load Design Documents:
- CLAUDE.md
- /Users/andreahn/.claude/CLAUDE.md
- docs/pos/POS_INTEGRATION_TEST_PLAN_FINAL_2026_06_14.md
- docs/ADR-013-Store-Type-Classification.md
- docs/ADR-014-Brand-Store-Multi-Access-Model.md
- docs/phase_1_architecture.md

Load Code Structure:
- supabase/migrations/*daily_closing*.sql
- supabase/migrations/*external_sales*.sql
- lib/core/services/daily_closing_service.dart
- lib/features/admin/providers/daily_closing_provider.dart
- lib/features/delivery/
- test/daily_closing_window_test.dart
- test/tri_system_data_flow_harness_test.dart

Objective:
Decide and document whether Deliberry/external delivery payments are included in POS daily close, Office settlement only, or both with separate buckets.

Frozen Criteria:
1. The decision explicitly defines source of truth for delivery revenue at close time.
2. The decision prevents double counting between POS payments and external_sales.
3. The decision preserves HCMC 00:00 daily close boundaries.
4. The decision defines Office projection expectations.
5. The decision states whether `DELIVERY_PAY` remains forbidden or becomes a new contract value.
6. Follow-up implementation tests are listed.

Run Checks by Category:
- rg -n "external_sales|delivery|create_daily_closing|daily_closings|paymentMethod" supabase/migrations lib test
- flutter test test/daily_closing_window_test.dart test/tri_system_data_flow_harness_test.dart

Generate Harness Report:
Return severity-classified findings, the recommended contract, and a Priority Fix List.
```

구현 후 검증 명령:

```bash
flutter test \
  test/daily_closing_window_test.dart \
  test/tri_system_data_flow_harness_test.dart

rg -n "external_sales|delivery|create_daily_closing|daily_closings|paymentMethod|DELIVERY_PAY" supabase/migrations lib test
```

완료 판정:

- delivery revenue가 POS close에 포함되는지 제외되는지 명확하다.
- 포함한다면 cash/card/e-pay/external delivery bucket이 이중계산 없이 분리된다.
- 제외한다면 settlement/Office projection에서만 다루며 POS close 테스트는 그 제외를 명시적으로 검증한다.
