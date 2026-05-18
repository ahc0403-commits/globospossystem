# GLOBOS POS Role Task Matrix and Operational Grammar

## 1. 목적

이 문서는 GLOBOS POS 재설계의 첫 기준 문서다. `waiter / cashier / kitchen` 3개 핵심 라이브 운영 화면을 먼저 고정하기 위해, 역할별 최우선 태스크와 모든 화면이 공유해야 할 운영 문법을 정의한다.

이 문서의 목적은 두 가지다.

- 와이어프레임을 그리기 전에 각 역할의 "실제 업무 단위"를 먼저 고정한다.
- 이후 `admin / HQ / e-invoice`까지 확장할 수 있는 최소 공통 문법을 정의한다.

이 문서는 구현 문서가 아니라 설계 계약 문서다.

## 2. 비가역 기준

다음 항목은 재설계 과정에서 바꾸지 않는다.

- 비즈니스 로직, RLS, RPC 경계, 계산 규칙
- 역할/권한/라우팅 의미
- 다점포 `store context`
- 결제 완료는 WeTax 가용성에 의존하지 않음
- 전자세금계산서는 결제 후 비동기 후속 처리

관련 기준:

- `docs/office/TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md`
- `lib/core/router/app_router.dart`
- `lib/features/auth/auth_provider.dart`
- `lib/core/services/order_service.dart`
- `lib/core/services/payment_service.dart`

## 3. 공통 운영 모델

모든 운영 화면은 아래 순서를 따라야 한다.

1. Queue
2. Select
3. Act
4. Optional Detail

해석은 아래와 같다.

- Queue: 지금 처리해야 할 항목이 먼저 보인다.
- Select: 사용자가 현재 무엇을 선택했는지 분명하다.
- Act: 다음에 해야 할 핵심 액션이 가장 눈에 띈다.
- Optional Detail: 세부 정보는 뒤로 물러난다.

## 4. 역할별 핵심 태스크 매트릭스

## 4.1 Waiter

| 항목 | 정의 |
| --- | --- |
| 역할 목표 | 테이블 상태를 빠르게 파악하고 주문을 정확하게 생성/전송 |
| 주요 큐 | 테이블 큐 |
| 선택 단위 | 테이블 |
| 주 액션 | 주문 시작, 주문 추가, 주문 전송 |
| 보조 액션 | 테이블 이동, 주문 취소, 게스트 수 수정 |
| 상세 정보 | 주문 항목, 게스트 수, 경과 시간, 서버 |

핵심 태스크:

1. 빈 테이블 또는 진행 중 테이블 선택
2. 버페/하이브리드일 경우 게스트 수 입력
3. 메뉴 탐색 후 주문 항목 추가
4. 장바구니 검토 후 주문 전송
5. 필요 시 기존 주문에 추가 주문 전송

기본 화면에 숨겨야 할 것:

- 테이블 이동
- 주문 전체 취소
- 서버 변경
- 드문 보정 기능

## 4.2 Cashier

| 항목 | 정의 |
| --- | --- |
| 역할 목표 | 결제 대상을 빠르게 선택하고 결제를 정확히 완료 |
| 주요 큐 | 결제 가능 주문 큐 |
| 선택 단위 | 결제 대상 주문 |
| 주 액션 | 결제 수단 선택, 결제 실행 |
| 보조 액션 | 영수증 출력, 증빙 업로드, 서비스 처리 |
| 상세 정보 | 주문 구성, 총액, 결제 상태, 전자세금계산서 후속 상태 |

핵심 태스크:

1. 결제 대상 주문 선택
2. 결제 수단 선택
3. 결제 실행
4. 필요 시 증빙 사진 업로드
5. 결제 후 영수증과 e-invoice 후속 상태 확인

기본 화면에 숨겨야 할 것:

- e-invoice 예외 처리 전체 이력
- 수동 재시도 도구
- 장기적인 감사 정보

## 4.3 Kitchen

| 항목 | 정의 |
| --- | --- |
| 역할 목표 | 주문 큐를 빠르게 처리하고 지연/대기 주문을 줄임 |
| 주요 큐 | 주방 주문 큐 |
| 선택 단위 | 주문 티켓 또는 주문 아이템 |
| 주 액션 | 상태 전진 |
| 보조 액션 | 리콜, 필터, 보기 전환 |
| 상세 정보 | 경과 시간, 테이블, 수량, 상태 |

핵심 태스크:

1. 새 주문 확인
2. 오래된 주문 확인
3. 아이템 상태를 `pending -> preparing -> ready -> served`로 전환
4. 준비 완료 주문을 빠르게 식별
5. 필요 시 전체 큐를 재정렬해 우선순위 확인

기본 화면에 숨겨야 할 것:

- 과도한 리포트성 지표
- 복잡한 설정
- 상세 운영 히스토리

## 5. 공통 운영 문법

## 5.1 화면 해부도

모든 운영 화면은 가능한 한 아래 구성 요소를 재사용한다.

1. Context Bar
2. Queue Pane
3. Work Pane
4. Primary Action Rail
5. Optional Detail Drawer

각 요소의 의미:

- Context Bar: 역할명, 현재 매장, 연결 상태, 최소 유틸리티만 표시
- Queue Pane: 지금 처리할 목록
- Work Pane: 선택한 항목의 작업 공간
- Primary Action Rail: 다음 핵심 행동 버튼
- Optional Detail Drawer: 필요할 때만 여는 상세/이력/고급 정보

## 5.2 선택 규칙

- 화면에는 항상 선택된 항목이 하나만 강조된다.
- 선택이 없으면 빈 상태가 아니라 "무엇을 선택해야 하는지"를 알려 주는 상태가 보여야 한다.
- 선택된 항목은 색상, 보더, 배지 중 최소 2개 수단으로 강조한다.

## 5.3 액션 계층 규칙

액션 우선순위는 아래와 같이 고정한다.

1. Primary
2. Affirm
3. Recovery
4. Secondary
5. Destructive

정의:

- Primary: 지금 가장 추천되는 다음 행동
- Affirm: 정상 완료/확정
- Recovery: 예외를 정상으로 돌리는 복구 행동
- Secondary: 보조 동작
- Destructive: 취소, 삭제, void, refund

이 계층은 `lib/core/ui/toast/toast_vocabulary.dart`의 `PosActionTone` 개념과 일치해야 한다.

## 5.4 오버플로 규칙

다음 조건에 해당하면 기본 화면에서 숨긴다.

- 사용 빈도가 낮다
- 실수 비용이 높다
- 메인 태스크의 성공에 직접 필요하지 않다
- 관리자 또는 상위 권한만 필요하다

숨기는 방식:

- 1차: 오버플로 메뉴
- 2차: 드로어
- 3차: 별도 워크스페이스

## 5.5 오프라인 및 비활성 규칙

오프라인 또는 선행 조건 미충족 시 버튼은 사라지지 않고 비활성화된다.

비활성 이유는 아래 표준 문구를 따른다.

- `Select a row to continue`
- `Not ready yet`
- `Not permitted for this role`
- `Waiting on upstream step`
- `Internet connection required`

이 규칙은 `toast_vocabulary.dart`의 `PosActionDisabledReason`과 맞물려야 한다.

## 5.6 상태 시각화 규칙

텍스트만으로 상태를 전달하지 않는다. 색상, 배지, 위치를 함께 사용한다.

기본 상태 세트:

- idle
- selected
- in-progress
- ready
- blocked
- exception
- resolved

운영 도메인별 매핑 예시:

| 공통 상태 | Waiter | Kitchen | Cashier | Admin/HQ |
| --- | --- | --- | --- | --- |
| selected | 선택된 테이블 | 선택된 티켓 | 선택된 주문 | 선택된 작업 항목 |
| in-progress | 주문 작성 중 | preparing | 결제 진행 중 | 승인/처리 중 |
| ready | 전송 가능 | ready | 결제 완료 | 처리 준비 완료 |
| blocked | 주문 불가 | 조리 대기 | 결제 불가 | 권한/데이터 부족 |
| exception | 주문 충돌 | 장기 대기 | 결제 실패/증빙 누락 | QC, inventory, e-invoice 예외 |
| resolved | 주문 전송 완료 | served | 후속 완료 | 예외 해소 |

## 5.7 매장 컨텍스트 규칙

멀티매장 구조에서는 현재 선택된 매장이 항상 보여야 한다.

- Context Bar 또는 상단 배지에 현재 매장명을 고정 노출
- HQ/Photo Ops는 선택 가능한 store scope를 항상 표시
- 선택된 매장이 바뀌면 Queue도 같이 바뀌어야 함

## 6. Layout Convention

버튼 위치는 디자인 토큰이 아니라 layout contract로 관리한다.

공통 규칙:

- Queue는 좌측 또는 상단
- Primary Action은 우측 하단 또는 우측 Action Rail
- Optional Detail은 우측 드로어 또는 하단 확장 패널
- 검색/필터는 Queue 가까이에 둔다
- 로그아웃, 설정, 리프레시 같은 유틸은 Context Bar 끝으로 보낸다

화면별 기본 계약:

| 화면 | Queue | Work | Primary Action | Optional Detail |
| --- | --- | --- | --- | --- |
| Waiter | 좌측 테이블 큐 | 중앙 메뉴/체크 | 우측 하단 또는 우측 패널 | 모달/오버플로 |
| Cashier | 좌측 결제 큐 | 중앙 주문/결제 | 우측 버튼 그리드 하단 | 결제 후 상세 또는 별도 상세 화면 |
| Kitchen | 상단 주의 요약 + 중앙 큐 | 카드 내부 | 카드 내부 또는 우측 상단 | 리콜/설정/필터 |
| Admin | 좌측 리스트/필터 | 중앙 리스트/선택 | 우측 또는 상단 액션 | 상세 드로어 |
| HQ | 상단 경고 큐 | 중앙 매장 리스트 | drill-down CTA | 상세 패널 |
| E-Invoice | 좌측 상태 필터 | 중앙 예외 큐 | 우측 복구 액션 | payload/log/portal link |

## 7. 라이브 운영층과 예외 관리층의 분리

이번 재설계는 아래 두 층을 혼합하지 않는다.

### 라이브 운영층

- Waiter
- Kitchen
- Cashier

특징:

- 속도 우선
- 클릭 수 최소화
- 결정 피로 최소화

### 예외 관리층

- Admin
- HQ / Photo Ops
- E-Invoice
- QC follow-up
- Delivery settlement
- Inventory approval / receiving

특징:

- 우선순위 큐
- 예외 분류
- 감사 가능성
- 드릴다운과 복구 중심

## 8. 다음 산출물 연결

이 문서 다음에는 아래 산출물이 따라와야 한다.

1. `waiter / cashier / kitchen` 와이어프레임
2. semantic token spec + badge/button mapping
3. 역할별 usability test pack
4. `admin / HQ / e-invoice` 확장 적용 문서

## 9. 참고 기준

- `lib/features/waiter/waiter_screen.dart`
- `lib/widgets/order_workspace.dart`
- `lib/features/cashier/cashier_screen.dart`
- `lib/features/kitchen/kitchen_screen.dart`
- `lib/core/ui/pos_design_tokens.dart`
- `lib/core/ui/toast/toast_vocabulary.dart`
