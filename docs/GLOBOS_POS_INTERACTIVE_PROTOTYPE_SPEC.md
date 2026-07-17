# GLOBOS POS Interactive Prototype Spec

## 1. 목적

이 문서는 `waiter / cashier / kitchen` 재설계를 실제 인터랙티브 프로토타입으로 검증하기 위한 명세서다. 목표는 "예쁘게 보이는 시안"이 아니라, 현장 직원이 다음 행동을 바로 찾고 실수 없이 완료할 수 있는지를 테스트 가능한 상태로 만드는 것이다.

프로토타입은 아래 질문에 답할 수 있어야 한다.

- 사용자가 첫 3초 안에 무엇을 눌러야 하는지 아는가
- 선택과 상태가 충분히 분명한가
- primary action이 혼동 없이 보이는가
- 예외 기능이 메인 흐름을 방해하지 않는가

## 2. 프로토타입 범위

1차 프로토타입 범위는 라이브 운영층만 포함한다.

- Waiter
- Cashier
- Kitchen

포함하지 않는 것:

- 실제 백엔드 연동
- 실제 데이터 쓰기
- 세부 관리자 기능
- HQ drill-down 전체
- 실제 e-invoice 복구 도구

단, 후속 상태를 이해시키기 위한 read-only mock 상태는 포함한다.

## 3. 프로토타입 방식

권장 fidelity:

- 1차: low-fi clickable
- 2차: mid-fi interactive
- 3차: near-real density validation

도구는 자유지만 아래 조건을 만족해야 한다.

- 선택 상태가 변해야 함
- 비활성/활성 버튼이 구분되어야 함
- 최소한 one-path happy flow는 끝까지 이어져야 함
- 오프라인/권한 부족/빈 선택 상태가 있어야 함

## 4. 공통 프로토타입 규칙

### 4.1 필수 상태

모든 역할 화면에 아래 상태가 있어야 한다.

- empty queue
- default queue
- selected item
- blocked action
- success handoff
- exception attention
- offline banner

### 4.2 필수 인터랙션

- queue item selection
- primary action activation
- secondary action open
- overflow menu open
- optional detail open/close

### 4.3 매장 컨텍스트

프로토타입에도 `Active Store`는 항상 보여야 한다.

- Waiter: `Store A`
- Cashier: `Store A`
- Kitchen: `Store A`

HQ 확장 시에는 store switching mock이 필요하지만 1차 범위에서는 제외한다.

## 5. Waiter Prototype Spec

## 5.1 목표 태스크

1. 빈 테이블 선택
2. 주문 시작
3. 메뉴 카테고리 탐색
4. 메뉴 2~3개 장바구니 추가
5. 주문 전송

확장 태스크:

6. 진행 중 테이블 선택 후 추가 주문
7. 버페/하이브리드 게스트 수 입력
8. 오버플로에서 테이블 이동 발견

## 5.2 필요한 화면 상태

### State A: Default Queue

- 빈 테이블
- 사용 중 테이블
- pending send 상태 테이블
- elapsed time 표시

### State B: Table Selected

- 선택된 테이블 강조
- 메뉴 브라우저 활성
- 체크 패널 표시
- `SEND ORDER` 비활성

### State C: Cart Ready

- 장바구니 2개 이상
- `SEND ORDER` 활성
- `CANCEL` secondary

### State D: Sent

- 전송 성공 상태
- queue 복귀 또는 active order view

### State E: Buffet Gate

- 선택 직후 게스트 수 모달

## 5.3 클릭 가능 요소

- table card
- category chip
- menu item add
- cart item increment/decrement
- send order
- cancel
- overflow menu
- move table

## 5.4 프로토타입 성공 기준

- 사용자가 설명 없이 `table -> item add -> send order` 흐름을 수행
- `Move table`을 메인 CTA로 오해하지 않음
- 버페 게스트 수 입력이 흐름을 깨지 않음

## 6. Cashier Prototype Spec

## 6.1 목표 태스크

1. 결제 대상 주문 선택
2. 결제 수단 선택
3. 결제 실행
4. 영수증 단계 확인
5. proof required일 경우 증빙 업로드 단계 진입

확장 태스크:

6. service 처리
7. offline 상태에서 결제 불가 이해
8. payment detail route 진입

## 6.2 필요한 화면 상태

### State A: Payment Queue

- payable order 3건 이상
- table number
- amount
- item count
- created time 또는 elapsed time

### State B: Order Selected

- 선택 주문 강조
- 우측 결제 수단 활성
- `PROCESS PAYMENT`는 method 선택 전 비활성

### State C: Method Selected

- method button selected
- `PROCESS PAYMENT` primary 활성

### State D: Payment Success

- success banner 또는 handoff stepper
- receipt
- proof
- e-invoice handoff

### State E: Offline Block

- queue는 보이지만 결제 실행 비활성
- disabled reason 명확히 노출

## 6.3 클릭 가능 요소

- order row/card
- payment method button
- process payment
- service confirm
- proof upload CTA
- payment detail CTA
- overflow menu

## 6.4 프로토타입 성공 기준

- 사용자가 가장 먼저 order queue를 클릭
- `PROCESS PAYMENT`가 method 선택 전에는 눌리지 않음을 이해
- 증빙/e-invoice 후속은 결제 후 단계로 인식

## 7. Kitchen Prototype Spec

## 7.1 목표 태스크

1. 가장 오래된 주문 찾기
2. 새 주문 찾기
3. pending item을 preparing으로 전환
4. ready item 식별
5. served까지 완료

확장 태스크:

6. 스테이션별 필터
7. recall
8. all-day summary 보기

## 7.2 필요한 화면 상태

### State A: Mixed Queue

- pending, preparing, ready 혼합
- long wait ticket 포함
- new arrival 포함

### State B: Item Advanced

- item status changed
- 카드 색상/배지 변경

### State C: Alerted Ticket

- 오래된 주문 경고
- attention strip에서 반영

### State D: Ready Complete

- ready 항목만 있는 주문
- served 후 queue에서 제거되거나 resolved 처리

## 7.3 클릭 가능 요소

- ticket card
- item row
- advance status
- filter chip
- recall
- settings

## 7.4 프로토타입 성공 기준

- 사용자가 `새 주문`과 `오래된 주문`을 각각 3초 안에 찾음
- 상태 전환 버튼 의미를 별도 설명 없이 이해
- column형과 card형 중 어느 쪽이 현장 인식 속도가 더 빠른지 비교 가능

## 8. 프로토타입 네비게이션 플로우

### Waiter

```text
Queue -> Select Table -> Menu Add -> Cart Ready -> Send Order -> Back to Queue
```

### Cashier

```text
Queue -> Select Order -> Select Method -> Process Payment -> Proof/Receipt Step -> Detail or Queue
```

### Kitchen

```text
Queue -> Select Ticket/Item -> Advance Status -> Ready/Served -> Queue Refresh
```

## 9. 테스트용 더미 데이터 세트

프로토타입에는 아래 mock이 포함되어야 한다.

### Waiter

- empty table 4개
- occupied table 3개
- pending send table 1개
- buffet table 1개

### Cashier

- payable dine-in 3건
- service flow 1건
- proof required 1건
- payment failed visual sample 1건

### Kitchen

- new arrival 2건
- long-wait 1건
- ready 1건
- mixed status ticket 2건

## 10. 프로토타입 리뷰 체크리스트

- queue가 first glance에서 보이는가
- selection이 명확한가
- primary CTA가 하나로 느껴지는가
- overflow 기능이 과하게 보이지 않는가
- 오프라인과 blocked 상태를 설명 없이 이해하는가
- 상태 색상 의미가 화면 간 일관적인가

## 11. 인수 기준

이 문서의 프로토타입이 통과된 것으로 보기 위한 기준:

- 3개 역할 화면 모두 happy path clickable
- 오프라인/blocked 상태 포함
- overflow/optional detail 경로 포함
- usability test round 1에 바로 쓸 수 있는 수준

## 12. 연계 문서

- `docs/GLOBOS_POS_ROLE_TASK_MATRIX_AND_OPERATIONAL_GRAMMAR.md`
- `docs/GLOBOS_POS_CORE_SURFACE_WIREFRAMES_AND_TOKEN_SPEC.md`
- `docs/GLOBOS_POS_USABILITY_TEST_AND_EXTENSION_PACK.md`
