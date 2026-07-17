# GLOBOS POS Core Surface Wireframes and Token Spec

## 1. 목적

이 문서는 `waiter / cashier / kitchen` 핵심 화면 3개의 저충실도 와이어프레임과, 이를 공통적으로 지탱하는 semantic token 및 layout contract를 정의한다.

원칙:

- 와이어프레임은 정보 구조와 행동 우선순위를 보여 준다.
- 토큰은 시각 의미를 고정한다.
- 버튼 위치 규칙은 토큰이 아니라 layout convention으로 정의한다.

## 2. Semantic Token Spec

현재 코드 기준선:

- 색상/간격/반경: `lib/core/ui/pos_design_tokens.dart`
- 액션 톤/비활성 문구/empty/loading vocabulary: `lib/core/ui/toast/toast_vocabulary.dart`
- 앱 테마 별칭: `lib/core/ui/app_theme.dart`

이번 문서에서는 위 기준선 위에 운영 문법을 덧붙인다.

## 2.1 상태 색상 의미

| 상태 의미 | 토큰 | 용도 |
| --- | --- | --- |
| Primary action | `PosColors.accent` | 가장 추천되는 다음 행동 |
| Success / complete | `PosColors.success` | 완료, 정상, paid, ready |
| Warning / in-progress | `PosColors.warning` | 진행 중, attention 필요 |
| Danger / exception | `PosColors.danger` | 실패, 취소, blocked, overdue |
| Info / transitional | `PosColors.info` | partial, queued, review |
| Selected row | `PosColors.selectedRow` | 선택된 행/카드 |
| Muted surface | `PosColors.panelMuted` | 비선택 패널, 보조 정보 |

## 2.2 공통 상태 배지 규칙

| 공통 상태 | 배지 색 | 예시 |
| --- | --- | --- |
| Selected | accent border + selected row bg | 선택된 테이블/주문 |
| In Progress | warning | preparing, payment processing |
| Ready | success | ready, payable, confirmed |
| Blocked | danger muted + text | offline, permission, pending prerequisite |
| Exception | danger | failed e-invoice, disputed settlement |
| Resolved | success muted | resolved follow-up, served |

## 2.3 버튼 톤 규칙

`PosActionTone` 기준:

| Tone | 시각 | 예시 |
| --- | --- | --- |
| primary | accent filled | SEND ORDER, PROCESS PAYMENT |
| affirm | success filled | Mark Ready, Confirm Received |
| recovery | info filled | Retry Dispatch, Resolve Follow-up |
| secondary | neutral outlined | Filter, View Detail, Print |
| destructive | danger filled | Cancel Order, Void, Delete |

## 2.4 높이와 밀도 규칙

| 요소 | 기준 |
| --- | --- |
| 기본 버튼 높이 | `PosMetrics.buttonHeight` |
| Compact 버튼 높이 | `PosMetrics.buttonCompactHeight` |
| 최소 터치 타깃 | `PosMetrics.touchTarget` |
| 기본 row height | `PosMetrics.tableRowHeight` |
| Compact row height | `PosMetrics.tableRowCompactHeight` |

원칙:

- 라이브 운영층은 `dense but readable`
- HQ/관리 화면은 `compact but filterable`
- 고객용 보드가 아닌 이상 과도한 여백은 금지

## 2.5 아이콘 규칙

아이콘은 기능 설명이 아니라 상태 보조 수단이다.

- 같은 동작은 같은 아이콘 유지
- 액션 아이콘은 `toast_vocabulary.dart`의 `PosActionIcons`와 맞춘다
- 상태 표현은 아이콘보다 배지/색상 우선

## 3. Waiter Wireframe

### 3.1 Desktop

```text
+--------------------------------------------------------------------------------------------------+
| CONTEXT BAR | Waiter | Active Store | Offline Banner | Search(optional) | Help | Logout          |
+--------------------------------------------------------------------------------------------------+
| TABLE QUEUE                         | MENU BROWSER                              | CHECK PANEL    |
|-------------------------------------|-------------------------------------------|----------------|
| Filter: All / Empty / Occupied      | Category tabs                             | Table T12      |
|                                     |-------------------------------------------| Guests: 4      |
| [T01][Empty]                        | [Popular] [Main] [Drink] [Dessert]        | Elapsed: 12m   |
| [T02][Occupied][2 guests][₫320k]    |                                           |----------------|
| [T03][Pending send][₫120k]          |  Menu grid/list                           | Sent items     |
| [T04][Occupied][7m][Server A]       |  + Add item                               | Draft cart     |
| ...                                 |                                           |----------------|
|                                     |                                           | [CANCEL]       |
|                                     |                                           | [SEND ORDER]   |
|                                     |                                           | [MORE ...]     |
+--------------------------------------------------------------------------------------------------+
```

### 3.2 핵심 규칙

- 첫 시선은 `TABLE QUEUE`
- 선택 후에만 메뉴와 체크 패널 활성화
- `SEND ORDER`는 항상 마지막 위치의 primary CTA
- `Move table`, `Cancel order`, `Edit guest count`는 `MORE ...`
- 버페/하이브리드는 테이블 선택 직후 게스트 수 모달

### 3.3 Mobile/Tablet

```text
+--------------------------------------+
| CONTEXT BAR                          |
+--------------------------------------+
| TABLE QUEUE                          |
| [cards...]                           |
+--------------------------------------+
| Selected Table Summary               |
| [Open Order Workspace]               |
+--------------------------------------+
```

주문 편집은 별도 full-screen sheet 또는 다음 step 화면으로 진입한다.

## 4. Cashier Wireframe

### 4.1 Desktop

```text
+--------------------------------------------------------------------------------------------------+
| CONTEXT BAR | Cashier | Active Store | Offline Banner | Today's Settlement | Logout             |
+--------------------------------------------------------------------------------------------------+
| PAYMENT QUEUE                       | SELECTED ORDER                            | PAYMENT ACTIONS  |
|-------------------------------------|-------------------------------------------|------------------|
| Search / Filter                     | Table T12                                 | [CARD]           |
|                                     | Items x 7                                 | [CASH]           |
| [T04][₫420k][payable]               | Notes / status badges                     | [PAY / QR]       |
| [T12][₫180k][selected]              |-------------------------------------------| [SPLIT]          |
| [T18][₫600k][service]               | Sent items list                           | [SERVICE]        |
| ...                                 |                                           | [REWARDS]        |
|                                     |-------------------------------------------|------------------|
|                                     | Payment proof status                      | [PROCESS PAYMENT]|
|                                     | E-Invoice handoff status                  | [MORE ...]       |
+--------------------------------------------------------------------------------------------------+
```

### 4.2 결제 후 단계

```text
Step 1: Payment success
Step 2: Receipt print
Step 3: Proof upload if required
Step 4: Red invoice / e-invoice handoff modal
Step 5: Payment detail or queue return
```

### 4.3 핵심 규칙

- 좌측 큐는 항상 살아 있어야 한다
- `PROCESS PAYMENT`는 method 선택 전 비활성화
- e-invoice 예외 처리는 메인 화면에서 해결하지 않는다
- 증빙 업로드는 결제 후 step으로 처리

## 5. Kitchen Wireframe

### 5.1 Desktop

```text
+--------------------------------------------------------------------------------------------------+
| CONTEXT BAR | Kitchen | Active Store | Offline Banner | Recall | View | Settings | Logout       |
+--------------------------------------------------------------------------------------------------+
| ATTENTION STRIP                                                                                  |
| Pending items | Ready items | Oldest wait | Long-wait tickets                                   |
+--------------------------------------------------------------------------------------------------+
| PENDING                              | PREPARING                            | READY             |
|--------------------------------------|--------------------------------------|-------------------|
| [T12][12m]                           | [T02][4m]                           | [T09][0m]         |
| 2x Pho            [Start Prep]       | 1x Tea            [Mark Ready]       | 1x Soup [Served]  |
| 1x Tea                                | 2x Rice                              |                   |
|--------------------------------------|--------------------------------------|-------------------|
| [T04][18m][ALERT]                    | ...                                  | ...               |
+--------------------------------------------------------------------------------------------------+
```

### 5.2 대안: 티켓 카드형

현재 구현처럼 카드형을 유지하되, 상태 컬럼과 시간 우선순위를 더 명확히 분리할 수 있다.

```text
[Queue filter]
[All] [Pending] [Preparing] [Ready]

[Ticket Card]
Table T12 | 12m | Pending
2x Pho
1x Tea
[Advance Status]
```

### 5.3 핵심 규칙

- 새 주문과 오래된 주문은 색상만이 아니라 위치로도 구분
- 카드 내 액션은 한 번에 하나만 추천
- 준비 완료는 success, 지연은 danger/warning으로 고정

## 6. 공통 Layout Contract

## 6.1 Top Bar

- 좌측: 역할명, store context
- 중앙: 필요 시 검색 또는 현재 모드
- 우측: 최소 유틸리티
- 금지: KPI 대시보드를 top bar에 올리는 것

## 6.2 Queue Pane

- 목록 중심
- status chip, elapsed time, amount 같은 비교 정보 우선
- 행 클릭 또는 카드 탭으로 selection 고정

## 6.3 Primary Action Zone

- 같은 역할의 핵심 CTA는 항상 같은 위치
- primary CTA는 화면마다 1개만 강하게
- 보조 CTA는 secondary 또는 overflow

## 6.4 Optional Detail

- drawer, modal, detail route 사용
- 기본 화면을 밀어내지 않음
- payload, history, audit, advanced settings는 여기에 둠

## 7. 확장 기준선

이 문서의 와이어프레임은 이후 아래 화면의 기준선이 된다.

- Admin: list + selected record + action sidecar
- HQ: priority queue + store list + drill-down
- E-Invoice: exception queue + recovery action panel + payload drawer

## 8. 구현 시 주의

- 현재 코드의 토큰 이름을 새 문서에서 다시 만들지 않는다
- semantic meaning만 보강하고, 구현 namespace는 기존 파일을 기준으로 유지
- 버튼 위치는 토큰이 아니라 component contract로 관리

## 9. 참고 코드

- `lib/widgets/order_workspace.dart`
- `lib/features/cashier/cashier_screen.dart`
- `lib/features/kitchen/kitchen_screen.dart`
- `lib/core/ui/pos_design_tokens.dart`
- `lib/core/ui/toast/toast_vocabulary.dart`
