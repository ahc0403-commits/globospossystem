# GLOBOS POS Phase 1 Operational Primitives Spec

## 1. 목적

이 문서는 실제 Flutter 구현의 첫 착수 단계인 `Phase 1 공통 operational primitive` 작업 명세서다. 목표는 `waiter / cashier / kitchen` 화면을 곧바로 갈아엎는 것이 아니라, 먼저 세 화면이 같은 운영 문법으로 보일 수 있도록 공통 프리미티브를 정리하는 것이다.

핵심은 "새 디자인 시스템을 만들기"가 아니라 "이미 존재하는 Toast-style 프리미티브를 운영 문법에 맞게 보강"하는 것이다.

## 2. 현재 기반

현재 이미 존재하는 주요 프리미티브:

- `ToastSplitPane`
- `ToastQueueTable`
- `ToastDenseList`
- `ToastMetricStrip`
- `ToastIssueActionSection`
- `ToastActionRail`
- `ToastStatusChip`
- `ToastOperationalEmptyState`
- `ToastOperationalLoadingState`
- `ToastWorkSurface`
- `ToastStatusBadge`
- `ToastShell`
- `ToastTopbar`
- `ToastActionStack`
- `ToastActionButton`

핵심 파일:

- `lib/core/ui/toast/toast_primitives.dart`
- `lib/core/ui/toast/toast_primitives_extended.dart`
- `lib/core/ui/toast/toast_vocabulary.dart`
- `lib/core/ui/pos_design_tokens.dart`

## 3. Phase 1 목표

Phase 1이 끝나면 아래가 가능해야 한다.

- selected state가 세 화면에서 같은 방식으로 보임
- primary action zone이 일관되게 표현됨
- blocked/disabled 이유가 공통 문법으로 노출됨
- queue pane이 공통 레이아웃으로 재사용 가능함
- optional detail drawer/modal 패턴의 기준이 생김

Phase 1에서 하지 않을 것:

- 도메인 서비스 로직 변경
- provider 구조 개편
- 전체 screen migration 완료
- 새로운 global theme 전면 교체

## 4. 필요한 프리미티브

## 4.1 Operational Queue Pane

목표:

- `ToastQueueTable`와 `ToastDenseList` 사이를 잇는 운영 큐 컨테이너 제공

책임:

- title / subtitle
- filter row slot
- scrollable queue content
- selected state affordance
- optional empty state

권장 이름:

- `ToastOperationalQueuePane`

필요 props 예시:

- `title`
- `subtitle`
- `filters`
- `child`
- `emptyState`
- `selectedSummary`

## 4.2 Selected Work Header

목표:

- 현재 선택한 테이블/주문/티켓의 컨텍스트를 공통적으로 보여 줌

책임:

- primary label
- secondary metadata
- status badges
- optional metric strip

권장 이름:

- `ToastSelectedWorkHeader`

기존 후보:

- `ToastSelectedContextHeader`가 이미 있으므로, 이를 확장하거나 래핑하는 방식이 우선

## 4.3 Primary Action Zone

목표:

- 화면별 primary / secondary / destructive CTA를 같은 문법으로 보여 줌

책임:

- hierarchy by `PosActionTone`
- disabled reason helper
- vertical or horizontal layout variants
- fixed primary placement

권장 이름:

- `ToastPrimaryActionZone`

기존 후보:

- `ToastActionRail`
- `ToastActionStack`
- `ToastActionButton`

Phase 1 방향:

- 새 위젯을 만들더라도 위 3개를 조합하는 thin wrapper여야 함

## 4.4 Operational Status Badge Set

목표:

- selected / in-progress / ready / blocked / exception / resolved 상태를 공통 색상 의미로 고정

책임:

- semantic state -> badge mapping
- compact / standard size
- optional icon

권장 이름:

- `ToastOperationalStateBadge`

기존 후보:

- `ToastStatusBadge`
- `ToastStatusChip`

Phase 1 방향:

- 도메인 상태를 공통 상태 세트로 매핑하는 helper 추가

## 4.5 Optional Detail Surface

목표:

- payload, history, settings, overflow details가 메인 작업을 밀어내지 않도록 표준 surface 제공

책임:

- side drawer variant
- modal sheet variant
- title + close + content slot

권장 이름:

- `ToastOptionalDetailPanel`

Phase 1 방향:

- full implementation보다 contract 문서화와 1개 thin container가 우선

## 5. 코드 작업 단위

## 5.1 toast_primitives.dart

우선 보강 대상:

- `ToastQueueTable`
  - stronger selected affordance option
  - optional filter/header slot
- `ToastSelectedContextHeader`
  - richer metadata rows
- `ToastActionRail`
  - disabled reason presentation
- `ToastStatusChip`
  - semantic state helper mapping

## 5.2 toast_primitives_extended.dart

우선 보강 대상:

- `ToastStatusBadge`
  - common operational state factories
- `ToastActionStack` / `ToastActionButton`
  - role-agnostic action layout variants
- `ToastTopbar`
  - active store/status slot guidance

## 5.3 toast_vocabulary.dart

우선 보강 대상:

- action verbs
- disabled reasons
- empty state copy
- loading copy

주의:

- vocabulary는 실제 화면에서 쓰는 말만 추가
- 추상적인 새 용어를 invented하지 말 것

## 5.4 pos_design_tokens.dart

우선 보강 대상:

- common operational state alias
- selected/blocked/exception surface nuances
- spacing for action groups if 부족할 경우만 보강

주의:

- 화면 문제를 토큰 추가로 과잉 해결하지 말 것

## 6. 구현 순서

1. selected state 공통 affordance 보강
2. primary action zone wrapper 정의
3. common state badge mapping helper 정의
4. queue pane wrapper 정의
5. optional detail thin surface 정의
6. waiter pilot 적용
7. cashier pilot 적용
8. kitchen pilot 적용

## 7. 수용 기준

Phase 1 완료 기준:

- 3개 핵심 화면 중 최소 1개 파일에서 새 프리미티브 조합이 실제 사용 가능
- 나머지 2개 화면에도 동일 문법 적용 경로가 명확함
- 색상/배지/버튼 톤이 semantic meaning을 공유
- disabled reason이 표준 방식으로 노출 가능
- 새 프리미티브가 기존 비즈니스 로직을 건드리지 않음

## 8. 금지 사항

- `App*` 계열과 경쟁하는 새 전역 시스템 만들기
- Toast primitive와 중복되는 위젯을 이름만 바꿔 추가하기
- provider/service/RPC 변경을 Phase 1에 끌어오는 것
- e-invoice/HQ 예외 복잡성을 먼저 primitive에 넣는 것

## 9. 첫 적용 추천 순서

### Pilot 1: Waiter

이유:

- `queue -> select -> act`가 가장 명확함
- `OrderWorkspace` 분해 효과가 큼

### Pilot 2: Cashier

이유:

- primary action zone 규칙 검증에 적합
- post-payment handoff 문법 검증 가능

### Pilot 3: Kitchen

이유:

- card/column hybrid에 대한 적합성 확인 가능
- state badge 규칙 검증 가능

## 10. Phase 1 이후 연결

Phase 1이 끝나면 바로 이어질 작업:

1. `waiter` structural refactor
2. `cashier` payment action/handoff separation
3. `kitchen` attention + queue mode structuring
4. token/vocabulary freeze

## 11. 연계 문서

- `docs/GLOBOS_POS_FLUTTER_REFACTOR_PRIORITY_ROADMAP.md`
- `docs/GLOBOS_POS_DETAILED_SURFACE_SPEC.md`
- `docs/GLOBOS_POS_ROLE_TASK_MATRIX_AND_OPERATIONAL_GRAMMAR.md`
