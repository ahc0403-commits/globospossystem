# GLOBOS POS Flutter Refactor Priority Roadmap

## 1. 목적

이 문서는 운영 UI 재설계를 실제 Flutter 코드 변경 순서로 내린 로드맵이다. 목표는 한 번에 모든 화면을 갈아엎는 것이 아니라, 현재 코드 구조를 유지하면서도 화면 책임과 공통 운영 문법을 단계적으로 반영하는 것이다.

범위:

- `waiter / cashier / kitchen` 우선
- 이후 `admin / HQ / e-invoice`
- 서비스/RPC 경계는 유지
- 주로 화면 구조, 공통 컴포넌트, 토큰 해석층을 정리

## 2. 현재 코드 기준 핵심 파일

### Waiter

- `lib/features/waiter/waiter_screen.dart`
- `lib/widgets/order_workspace.dart`
- `lib/features/order/order_provider.dart`
- `lib/features/table/table_provider.dart`

### Cashier

- `lib/features/cashier/cashier_screen.dart`
- `lib/features/payment/payment_provider.dart`
- `lib/core/services/payment_proof_service.dart`

### Kitchen

- `lib/features/kitchen/kitchen_screen.dart`
- `lib/features/kitchen/kitchen_provider.dart`

### 공통 UI

- `lib/core/ui/pos_design_tokens.dart`
- `lib/core/ui/toast/toast_vocabulary.dart`
- `lib/core/ui/app_theme.dart`
- `lib/widgets/offline_banner.dart`
- `lib/widgets/error_toast.dart`

## 3. 리팩터링 원칙

- 비즈니스 로직보다 화면 구조를 먼저 정리
- screen 파일에서 역할을 분리하고, component로 작업 영역을 추출
- semantic token은 재사용하고, layout contract는 컴포넌트 계층으로 구현
- 새로운 디자인 시스템을 만들기보다 기존 토큰 스캐폴드 위에 확장

## 4. 단계별 우선순위

## Phase 1. 공통 운영 프리미티브 정리

목표:

- 3개 핵심 화면이 같은 문법으로 보이게 할 최소 컴포넌트 준비

우선 작업:

1. `QueuePane` 성격의 공통 리스트/카드 컨테이너 정리
2. selected row/card 상태 표현 공통화
3. primary action zone 스타일 공통화
4. optional detail drawer/modal 규칙 정리

후보 파일:

- `lib/core/ui/toast/toast_primitives.dart`
- `lib/core/ui/toast/toast_primitives_extended.dart`
- 새 파일 후보:
  - `lib/core/ui/toast/operational_queue_pane.dart`
  - `lib/core/ui/toast/operational_action_zone.dart`
  - `lib/core/ui/toast/operational_status_badge.dart`

산출물:

- 공통 선택 상태
- 공통 action hierarchy UI
- blocked/empty/loading 표현 통일

## Phase 2. Waiter 화면 재구성

목표:

- `table queue -> menu browser -> check panel` 구조를 명확히 분리

핵심 문제:

- `waiter_screen.dart`와 `order_workspace.dart`가 함께 역할을 너무 많이 가진다

작업 순서:

1. `WaiterScreen`을 context + queue orchestration 역할로 축소
2. `OrderWorkspace`를 구조적으로 분해
3. table queue를 독립 widget으로 추출
4. cart/check panel의 action zone을 고정 위치화
5. overflow 액션을 별도 메뉴로 분리

권장 새 컴포넌트:

- `lib/features/waiter/widgets/waiter_table_queue.dart`
- `lib/features/waiter/widgets/waiter_check_panel.dart`
- `lib/features/waiter/widgets/waiter_guest_gate_dialog.dart`
- `lib/features/waiter/widgets/waiter_overflow_menu.dart`

유지할 것:

- `order_provider.dart`의 offline queue 로직
- `table_provider.dart`의 realtime 구독

## Phase 3. Cashier 화면 재구성

목표:

- `payment queue -> selected order -> payment actions -> post-payment handoff`

핵심 문제:

- 현재 `cashier_screen.dart`가 queue, selection, payment, proof, red invoice modal, detail 이동까지 모두 직접 조정

작업 순서:

1. payment queue pane 추출
2. selected order summary pane 추출
3. payment method grid/action zone 추출
4. post-payment handoff stepper 또는 flow controller 분리
5. proof/e-invoice 후속을 결제 메인 액션에서 시각적으로 분리

권장 새 컴포넌트:

- `lib/features/cashier/widgets/cashier_payment_queue.dart`
- `lib/features/cashier/widgets/cashier_selected_order_panel.dart`
- `lib/features/cashier/widgets/cashier_payment_method_grid.dart`
- `lib/features/cashier/widgets/cashier_post_payment_handoff.dart`

유지할 것:

- `payment_provider.dart`의 realtime/payment orchestration
- `payment_proof_service.dart`의 queue/flush 동작

주의:

- WeTax handoff를 UI 단계로 끌어오지 말 것
- payment completion은 modal 성공 여부와 분리되어야 함

## Phase 4. Kitchen 화면 재구성

목표:

- `attention strip + status queue + single next action`

핵심 문제:

- 현재 카드형은 이미 나쁘지 않지만, attention summary와 ticket action 문법을 더 분명히 나눌 필요가 있음

작업 순서:

1. attention strip를 독립 영역으로 추출
2. ticket card 또는 status column view를 분리 가능하게 구조화
3. item status chip/action tone 통일
4. view mode 전환 가능성 대비

권장 새 컴포넌트:

- `lib/features/kitchen/widgets/kitchen_attention_strip.dart`
- `lib/features/kitchen/widgets/kitchen_ticket_card.dart`
- `lib/features/kitchen/widgets/kitchen_status_column.dart`
- `lib/features/kitchen/widgets/kitchen_view_mode_toggle.dart`

유지할 것:

- `kitchen_provider.dart`의 realtime + polling fallback
- optimistic status update 흐름

## Phase 5. Token and Vocabulary Freeze

목표:

- 3개 핵심 화면에서 검증된 상태/배지/버튼 톤 규칙을 코드 기준선으로 고정

작업 순서:

1. `pos_design_tokens.dart`에 semantic mapping 보강
2. `toast_vocabulary.dart`의 action/state copy 보강
3. 필요 시 status badge widget 공통화
4. core surfaces에서 같은 토큰을 재사용하도록 정리

주의:

- 새 색상을 무분별하게 추가하지 말 것
- 구현 convenience보다 semantic consistency 우선

## Phase 6. Admin 확장

목표:

- KPI-first가 아닌 `list -> select -> act -> detail` 문법 적용

우선 대상:

1. Inventory
2. QC
3. Reports

후보 작업:

- admin tab별 queue pane 도입
- selected detail sidecar 도입
- long-form settings/history 분리

## Phase 7. E-Invoice / HQ 확장

목표:

- 예외 큐와 본사 관제 화면을 라이브 운영층과 구분된 문법으로 확장

우선 대상:

1. E-Invoice
2. Photo Ops
3. Super Admin

핵심 방향:

- `exception queue + recovery panel + optional detail`
- `priority queue + store list + drill-down`

## 5. 파일 단위 작업 지도

| 우선순위 | 파일 | 작업 |
| --- | --- | --- |
| P1 | `lib/widgets/order_workspace.dart` | waiter workspace 분해 |
| P1 | `lib/features/cashier/cashier_screen.dart` | queue/action/handoff 분리 |
| P1 | `lib/features/kitchen/kitchen_screen.dart` | attention/ticket 구조 분리 |
| P1 | `lib/core/ui/toast/toast_primitives_extended.dart` | 공통 operational primitive 보강 |
| P2 | `lib/features/waiter/waiter_screen.dart` | orchestration 정리 |
| P2 | `lib/features/payment/payment_provider.dart` | UI 분리 후 selection/payment flow 유지 |
| P2 | `lib/features/kitchen/kitchen_provider.dart` | view mode 대응 가능하게 유지 |
| P2 | `lib/core/ui/toast/toast_vocabulary.dart` | action/status copy 확장 |
| P3 | `lib/features/admin/admin_screen.dart` | tab shell을 queue-first 문법에 맞춤 |
| P3 | `lib/features/admin/tabs/inventory_tab.dart` | admin 확장 1순위 |
| P3 | `lib/features/admin/tabs/qc_tab.dart` | admin 확장 2순위 |
| P3 | `lib/features/admin/tabs/einvoice_tab.dart` | exception surface 문법 적용 |
| P4 | `lib/features/photo_ops/photo_ops_screen.dart` | HQ queue-first 재구성 |
| P4 | `lib/features/super_admin/super_admin_screen.dart` | drill-down 중심 재구성 |

## 6. 컴포넌트 경계 제안

리팩터링 후 이상적인 책임 분리는 아래와 같다.

### Screen

- 역할: route 진입, provider 구독, top-level orchestration

### Queue Widget

- 역할: 목록 렌더링, 필터, 선택

### Work Widget

- 역할: 선택 항목 중심 작업

### Action Widget

- 역할: primary/secondary/destructive CTA 묶음

### Detail Widget

- 역할: 상세/이력/예외 정보

금지:

- screen 파일 하나에서 queue + work + action + modal orchestration + detail navigation을 모두 직접 처리하는 것

## 7. 테스트 연계

각 phase마다 최소 아래 검증을 포함해야 한다.

- widget/integration smoke
- role path smoke
- blocked/offline UI regression
- selected state visibility check

특히 유지해야 하는 기존 계약:

- offline order queue behavior
- realtime order/payment refresh
- kitchen polling fallback
- payment proof queue flush
- route permission parity

## 8. 성공 기준

리팩터링이 성공했다고 보기 위한 기준:

- `waiter / cashier / kitchen` 각 화면이 queue-first로 읽힌다
- primary CTA가 화면당 하나로 느껴진다
- overflow 기능이 메인 작업을 방해하지 않는다
- 공통 상태/배지/버튼 톤이 3개 화면에서 일치한다
- 기존 business logic contract test를 깨지 않는다

## 9. 실행 추천 순서

1. 공통 operational primitive
2. waiter
3. cashier
4. kitchen
5. token/vocabulary freeze
6. inventory
7. QC
8. e-invoice
9. HQ/photo ops
10. super admin

## 10. 연계 문서

- `docs/GLOBOS_POS_ROLE_TASK_MATRIX_AND_OPERATIONAL_GRAMMAR.md`
- `docs/GLOBOS_POS_CORE_SURFACE_WIREFRAMES_AND_TOKEN_SPEC.md`
- `docs/GLOBOS_POS_INTERACTIVE_PROTOTYPE_SPEC.md`
- `docs/GLOBOS_POS_USABILITY_TEST_AND_EXTENSION_PACK.md`
