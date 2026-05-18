# GLOBOS POS Detailed Surface Spec

## 1. 목적

이 문서는 `waiter / cashier / kitchen` 3개 핵심 화면의 상세 설계 명세서다. 앞선 저충실도 와이어프레임 문서보다 한 단계 더 내려가, 각 영역의 정보 우선순위, 상태, 액션 노출 규칙, 빈 상태, 오프라인 상태, overflow 항목까지 구체적으로 정의한다.

이 문서는 인터랙티브 프로토타입 제작과 Flutter 컴포넌트 분해의 공통 기준으로 사용한다.

## 2. 공통 해부도

모든 핵심 화면은 아래 5개 영역으로 읽혀야 한다.

1. Context Bar
2. Queue Pane
3. Work Pane
4. Primary Action Zone
5. Optional Detail / Overflow

공통 금지 사항:

- queue보다 KPI가 먼저 보이는 화면
- primary CTA가 2개 이상 동시에 같은 강도로 보이는 화면
- 상세/히스토리가 메인 작업 영역을 밀어내는 화면
- 역할 외 정보가 기본 화면에 과하게 노출되는 구성

## 3. Waiter 상세 명세

## 3.1 사용자 목표

- 어떤 테이블을 먼저 처리해야 하는지 바로 파악
- 실수 없이 새 주문 또는 추가 주문 전송
- 드문 기능이 메인 흐름을 방해하지 않음

## 3.2 정보 구조

### Context Bar

반드시 보여야 할 것:

- 역할명: `Waiter`
- 현재 매장명
- 오프라인 배너 또는 연결 상태
- 최소 유틸리티

보여도 되는 것:

- 간단한 검색
- 도움말

기본으로 숨길 것:

- 관리자용 링크
- 복잡한 리포트 정보

### Queue Pane

기본 요소:

- 상태 필터
  - All
  - Empty
  - Occupied
  - Pending Send
- 테이블 카드 또는 행

테이블 카드 필수 정보:

- 테이블 번호
- 상태
- 게스트 수
- 현재 주문 금액
- 경과 시간
- 서버명 또는 담당자

테이블 카드 상태 규칙:

- Empty: muted
- Occupied: neutral with selected affordance
- Pending Send: warning
- Selected: accent border + selected surface

### Work Pane

구성:

- 카테고리 탐색
- 메뉴 아이템 리스트
- 선택 중인 카테고리 강조
- 아이템 추가 버튼 또는 탭

필수 규칙:

- 메뉴는 선택된 테이블이 없으면 비활성 또는 안내 상태
- 카테고리 없이 모든 메뉴를 한꺼번에 노출하지 않음
- unavailable item은 기본 목록에서 약화 또는 숨김 처리

### Primary Action Zone

구성:

- table summary
- sent items
- draft cart
- primary CTA: `SEND ORDER`
- secondary CTA: `CANCEL`

활성화 규칙:

- cart empty: `SEND ORDER` 비활성
- sent-only state: `SEND ORDER` 비활성
- draft item 존재: `SEND ORDER` 활성

### Optional Detail / Overflow

여기로 보낼 기능:

- Move Table
- Cancel Order
- Edit Guest Count
- Server Change

원칙:

- 메인 화면에서 기본 노출 금지
- destructive action은 직접 버튼보다 한 단계 더 들어가야 함

## 3.3 상태별 화면 정의

### Waiter State A: No Selection

- queue visible
- work pane disabled
- check panel empty helper 표시
- CTA 비활성

### Waiter State B: Selected Empty Table

- menu active
- cart empty
- send disabled

### Waiter State C: Draft Cart Present

- send enabled
- cart total visible
- selected table strong highlight

### Waiter State D: Active Order + Add More

- sent items section visible
- new cart section 분리
- `SEND ORDER`는 “추가 주문 전송” 의미 유지

### Waiter State E: Buffet Gate

- selection 직후 modal
- 게스트 수 입력 완료 후에만 work pane 진입

## 3.4 오류/예외 상태

- offline: queue는 보이나 submit blocked
- menu load failed: work pane error state
- no tables: operational empty state
- stale selected table: selection reset + helper

## 4. Cashier 상세 명세

## 4.1 사용자 목표

- 결제할 주문을 빠르게 찾는다
- 결제 수단을 혼동 없이 선택한다
- 결제 후 영수증/증빙/e-invoice 후속을 순차적으로 처리한다

## 4.2 정보 구조

### Context Bar

반드시 보여야 할 것:

- 역할명: `Cashier`
- 현재 매장명
- 오프라인 배너
- `Today's Settlement`

기본으로 숨길 것:

- e-invoice 예외 큐 전체
- 관리자 지표

### Queue Pane

필수 요소:

- 결제 대상 리스트
- 선택된 주문 강조

주문 카드 필수 정보:

- table number
- total amount
- item count
- created at 또는 elapsed time
- payment readiness badge

정렬 규칙:

- 오래된 payable order 우선
- service flow 같은 특수 주문은 badge로만 구분

### Work Pane

구성:

- selected order summary
- sent item list
- status badges
- proof status
- e-invoice handoff summary

원칙:

- 여기서는 결제 준비를 보여 준다
- 예외 복구 도구는 놓지 않는다

### Primary Action Zone

구성:

- payment method grid
- primary CTA: `PROCESS PAYMENT`
- optional payment options

필수 버튼 후보:

- Card
- Cash
- Pay / QR
- Split
- Service
- Rewards

규칙:

- method 미선택 시 `PROCESS PAYMENT` 비활성
- 한 번에 하나의 method만 selected
- split/rewards는 기본 happy path보다 뒤 단계로 둘 수 있음

### Post-Payment Handoff

순서:

1. payment success
2. receipt print
3. proof upload if required
4. red invoice / e-invoice handoff
5. payment detail route or queue return

원칙:

- handoff는 payment 완료 이후
- proof/e-invoice는 payment 자체를 막지 않음

## 4.3 상태별 화면 정의

### Cashier State A: No Selection

- queue visible
- selected order helper
- payment buttons disabled

### Cashier State B: Selected Order

- summary visible
- method buttons active
- process disabled

### Cashier State C: Method Selected

- selected method strong highlight
- process enabled

### Cashier State D: Payment Success

- queue refresh
- handoff steps visible
- selected order clears or moves to detail

### Cashier State E: Offline Block

- queue visible
- process disabled
- disabled reason visible

## 4.4 오류/예외 상태

- payment failed: visible error toast + selected order 유지
- proof upload queued: success-with-warning handoff
- e-invoice pending: informational, not blocking
- service confirm: extra confirmation dialog

## 5. Kitchen 상세 명세

## 5.1 사용자 목표

- 무엇이 먼저 조리되어야 하는지 즉시 파악
- 상태를 최소 클릭으로 전진
- 장기 대기와 준비 완료를 동시에 관리

## 5.2 정보 구조

### Context Bar

반드시 보여야 할 것:

- 역할명: `Kitchen`
- 현재 매장
- 오프라인 배너
- recall/view/settings 최소 유틸

### Attention Strip

필수 지표:

- pending items
- ready items
- oldest wait
- long-wait ticket count

원칙:

- 지표는 queue 해석을 돕는 수준
- top KPI 대시보드가 되어서는 안 됨

### Queue Pane

두 가지 패턴 중 하나를 채택한다.

1. Status columns
2. Dense ticket cards with filter chips

초기 테스트 권장:

- desktop: status columns
- tablet: dense cards

필수 정보:

- table number
- elapsed time
- item list
- quantity
- item status

### Primary Action Zone

주방은 별도 우측 rail보다 카드 내부 action이 더 적합하다.

원칙:

- 한 아이템 또는 한 카드에 현재 추천 액션은 1개
- `Start Prep`, `Mark Ready`, `Mark Served` 중 하나만 강하게
- 다음 상태는 텍스트와 배지 모두로 보이게 함

### Optional Detail / Overflow

보낼 기능:

- all day summary
- station filter
- settings
- recall

## 5.3 상태별 화면 정의

### Kitchen State A: Mixed Queue

- pending / preparing / ready 혼합
- default operational state

### Kitchen State B: New Arrival

- 신규 티켓 강조
- flashing 또는 short-lived highlight

### Kitchen State C: Long Wait Alert

- elapsed threshold 초과
- attention strip와 카드 모두 강조

### Kitchen State D: Ready To Serve

- ready badge
- served action visible

### Kitchen State E: Queue Clear

- operational empty state
- helper copy visible

## 5.4 오류/예외 상태

- realtime disconnected: fallback polling indicator 필요
- load failed: retry state
- item update failed: optimistic rollback + error toast

## 6. 공통 상태 사전

| 상태 | Waiter | Cashier | Kitchen |
| --- | --- | --- | --- |
| idle | 선택 없음 | 선택 없음 | 기본 queue |
| selected | 선택된 테이블 | 선택된 주문 | 선택/강조된 티켓 |
| in-progress | 주문 작성 중 | 결제 진행 중 | preparing |
| ready | 전송 가능 | payment method ready / success | ready |
| blocked | offline / no items | method 없음 / offline | permission or connectivity issue |
| exception | 충돌/실패 | payment failed / proof issue | long wait / update failure |
| resolved | 주문 전송 완료 | payment handoff done | served |

## 7. 리뷰 질문

- 사용자가 queue를 먼저 보는가
- selection이 다른 상태와 분명히 구분되는가
- primary action이 화면당 하나로 느껴지는가
- optional detail이 기본 작업을 방해하지 않는가
- 색상 의미가 3개 화면에서 일관적인가

## 8. 연계 문서

- `docs/GLOBOS_POS_INTERACTIVE_PROTOTYPE_SPEC.md`
- `docs/GLOBOS_POS_CORE_SURFACE_WIREFRAMES_AND_TOKEN_SPEC.md`
- `docs/GLOBOS_POS_USABILITY_TEST_AND_EXTENSION_PACK.md`
