# 설계 브리프: KDS 주문 카드 메뉴·동시 동기화·오늘 완료 이력

Date: 2026-08-15
Source: 사용자 요청 및 첨부 화면, 현재 페이퍼리스 KDS/디지털 영수증 구현 조사
Status: 계획 전용 — 애플리케이션 구현·DB 적용·배포하지 않음

## 1. 목표

주방, 트레이, 배정 층 화면이 주문 접수 직후 같은 주문을 동시에 보여주고, 같은 주문의 메뉴 진행 상태를 Realtime과 1초 fallback polling으로 함께 갱신한다.

- 고정 4/8슬롯 주문 카드 안에 실제 메뉴명을 표시한다.
- 현재 스테이션 단계가 완료된 메뉴명은 초록색, 미완료 메뉴명은 검정색으로 표시한다.
- 시계 아이콘 영역은 주문 접수 후 실제 경과 시간을 `MM:SS` 디지털 형식으로 표시한다.
- 카드의 메뉴 목록이 한 열에 들어가지 않으면 카드 내부를 두 열로 사용한다.
- 콤보 부모 이름 하나로 축약하지 않고 콤보 구성 메뉴를 각각 표시한다.
- `최근 완료`는 현재 활성 세션 한 건이 아니라 베트남 영업일 기준 오늘 완료된 주문 전체를 주방·트레이·층별로 유지한다.
- 공개 디지털 영수증의 PDF 생성 문구와 코드값 표시는 베트남어로 고정한다.

## 2. 현재 구현에서 확인한 원인

1. `_EmergencyOrderCard`는 테이블, 층, 메뉴 종류 수, 상태만 그리고 메뉴명은 상세 화면에서만 표시한다.
2. 활성 보드는 `hasActionableQuantity(stationType)`가 true인 주문만 남기므로 트레이와 층 화면은 upstream 단계가 끝나기 전 주문을 숨긴다.
3. `get_emergency_station_snapshot()` 자체에는 해당 층 주문의 전체 큐가 들어오므로 동시 노출을 막는 주된 원인은 Flutter의 보드 필터다.
4. 표준 품목 변경은 Realtime row patch를 적용하고 직접 제공 품목은 전체 snapshot을 다시 읽으며, 1초 polling이 fallback으로 동작한다.
5. 현재 `최근 완료`는 활성 세션의 각 queue에서 unreverted 주문단위 complete action 하나만 반환한다. 품목을 하나씩 완료한 주문, 닫힌 세션, 오늘의 이전 세션은 누락될 수 있다.
6. 콤보의 음식 부분은 부모 `emergency_fulfillment_items` 한 행으로 처리되고, `combo_components`에는 구성 메뉴의 다국어 이름과 route snapshot이 이미 저장된다. 직접 제공 콤보 음료만 별도 logical line을 가진다.
7. 디지털 PDF의 고정 제목은 베트남어지만 snapshot의 메뉴 `label`, 결제수단 `method`, 일부 fallback 값은 한국어 또는 영문 코드가 들어갈 수 있다.

## 3. 제품 해석과 보존 계약

### 동시 노출

- 주문 queue가 생성되면 주방, 트레이, 해당 층의 활성 보드에 즉시 같은 주문을 표시한다.
- 동시 노출은 처리 권한을 앞당기지 않는다. 주방 완료 전 트레이, 트레이 발송 전 층의 음식은 검정색 읽기 전용이며 기존 DB 수량 체인이 허용하는 시점에만 조작 가능해진다.
- 직접 제공 음료는 주방·트레이에도 표시하지만 읽기 전용이고, 해당 층에서만 처리한다.
- 다른 층 주문과 다른 매장 주문은 기존 assignment/RLS 경계대로 노출하지 않는다.

### 메뉴 완료 색상

각 화면은 자기 단계의 완료 수량으로 색상을 계산한다.

| 화면 | 초록색 조건 | 검정색 조건 |
|---|---|---|
| 주방 | 음식의 `kitchen_done >= ordered` | 그 외 음식, 직접 제공 음료는 읽기 전용 검정 |
| 트레이 | 음식의 `tray_received`와 `tray_dispatched`가 현재 준비 수량까지 완료 | 그 외 음식, 직접 제공 음료는 읽기 전용 검정 |
| 층별 | 음식/직접 제공 품목의 `floor_served >= ordered` | 그 외 |

- 색상만으로 상태를 전달하지 않고 완료 아이콘 또는 semantics 상태를 함께 제공한다.
- 부분 수량 완료는 미완료로 보고 검정색을 유지하며 상세 수량은 기존처럼 표시한다.

### 콤보 표시

- 결제·수량 원장의 부모 콤보 행은 유지해 금액과 action 수량을 바꾸지 않는다.
- snapshot에 이미 저장된 `order_items.combo_components`를 표시 전용 line으로 내려준다.
- 카드와 상세에서 콤보 부모명 대신 구성 메뉴명을 각각 표시한다.
- 음식 component는 부모 음식 line의 단계 완료 상태를 공유하고, 직접 제공 component는 자신의 floor-direct line 상태를 사용한다.
- 직접 제공 component가 별도 line으로도 반환될 때 `line_key`로 중복 표시하지 않는다.
- 구성 메뉴를 보여주는 변경이 구성별 독립 완료 기능을 의미하지는 않는다. 기존 부모 action과 route별 권한을 보존한다.

### 디지털 시계

- 기준 시각은 서버가 저장한 `emergency_order_queue.created_at`이다.
- 한 화면에 하나의 1초 ticker를 두고 모든 카드가 같은 `now`를 사용한다. 카드마다 Timer를 만들지 않는다.
- 표시는 총 경과 분과 초를 `MM:SS`로 출력한다. 초는 `00–59`, 분은 최소 두 자리이며 60분을 넘으면 `60:00`처럼 증가해 되감기지 않는다.
- 기기 시각이 서버 시각보다 앞선 예외는 `00:00`으로 clamp한다.

### 카드 내부 메뉴 배치

- 기본은 한 열이며 메뉴 한 개를 한 줄로 표시한다.
- 현재 카드 높이에 전체 메뉴가 한 열로 들어가지 않을 때 순서를 유지한 채 두 열로 균등 분배한다.
- Phone 4슬롯과 Tablet 8슬롯 모두 카드 경계 밖 overflow가 없어야 한다.
- 두 열에도 들어가지 않는 극단적인 주문은 카드 안에서 조용히 누락하지 않고 마지막 행에 남은 메뉴 수를 명시하고, 카드 탭 상세에서 전체 구성 메뉴를 제공한다.

## 4. 데이터와 동기화 설계

### Snapshot 확장

적용된 migration을 수정하지 않고 새 additive migration에서 호환 RPC를 확장한다.

- 활성 주문 payload에 표시 전용 `display_items` 또는 각 base item의 `combo_components`를 추가한다.
- 기존 `items` 배열과 필드는 그대로 유지해 구버전 앱의 완료/원복 동작을 보존한다.
- active session 주문은 actionable 여부와 무관하게 station assignment 범위 전체를 반환한다.
- 주문 정렬은 기존 queue 순서를 유지하고 신규 주문 도착으로 사용자가 보고 있는 페이지/상세를 강제로 바꾸지 않는다.

### 오늘 완료 전체 이력

별도 중복 원장을 새로 만들기보다 기존 append-only action/event와 현재 수량 원장을 authoritative source로 사용한다.

- `get_emergency_station_today_completed()` 또는 snapshot v2의 `completed_orders`가 `Asia/Ho_Chi_Minh` 오늘 00:00부터 다음 00:00 전까지의 완료를 반환한다.
- 현재 활성 세션뿐 아니라 오늘 생성·종료된 모든 paperless session을 포함한다.
- 주문단위 완료와 품목별 완료 양쪽을 포함하며, 현재 수량이 해당 스테이션 완료 조건을 만족하는 주문만 반환한다.
- 완료 시각은 해당 단계의 누적 delta가 최종 완료 수량에 도달한 유효 event/action 시각으로 계산한다.
- 완료 후 원복되거나 추가 주문이 들어와 다시 미완료가 된 주문은 활성 보드로 돌아가고, 재완료하면 최신 완료 시각으로 오늘 목록에 다시 나타난다.
- 층 계정은 자신의 `floor_label`, 모든 계정은 자신의 accessible store만 읽을 수 있다.
- 목록은 최신 완료 순으로 정렬하고 자정 경계는 프로젝트의 고정 베트남 영업일 계약을 따른다.

### 동기화

- queue 생성, 표준/직접 제공 item 변경, 완료/원복 action/event를 Realtime 갱신 대상으로 묶는다.
- Realtime 누락·브라우저 background 제한 시 현재 1초 polling이 같은 snapshot을 보정한다.
- row patch로 바뀐 수량과 전체 snapshot 응답이 같은 status resolver를 사용하도록 한다.
- 신규 snapshot이 와도 현재 page, `최근 완료` 탭, 선택 주문 ID를 보존하되 선택 주문이 권한 범위에서 사라지면 안전하게 보드로 복귀한다.
- 기존 IndexedDB outbox, UUID 멱등성, downstream 원복 거절 계약은 변경하지 않는다.

## 5. PDF 영수증 베트남어 고정

- PDF의 모든 시스템 라벨, 버튼과 안내 문구는 베트남어 상수만 사용한다.
- `CASH`, `CARD`, `BANK_TRANSFER`, `SPLIT`, `SERVICE`, `OTHER` 등 저장 코드값은 PDF에서 베트남어 표시명으로 변환한다.
- 디지털 영수증 snapshot은 메뉴의 `name_vi` 또는 주문 시점 베트남어 snapshot을 우선 사용한다. 선택 언어의 `label/display_name`을 PDF용 이름으로 그대로 재사용하지 않는다.
- 번역이 없는 시스템 품목은 item type별 베트남어 fallback을 사용하고, 일반 메뉴 번역 누락은 한국어/영어 fallback 대신 명시적인 베트남어 대체명으로 표시한다.
- 법인명, 상호, 주소, 세금번호, 직원 코드, 상품 고유 브랜드명 같은 고유명사는 원문 데이터로 유지한다. “베트남어만”은 시스템이 생성하는 문구와 선택 가능한 다국어 메뉴 표시를 뜻한다.
- 공개 화면의 선택 locale은 유지하되 PDF 결과는 화면 locale과 무관하게 동일한 베트남어가 되어야 한다.

## 6. 범위 제외

- 기존 음식 수량 체인, 결제 금액, 가격, VAT, 할인, MISA/적색 세금계산서 흐름 변경
- 콤보 component별 독립 조리 수량 원장 신설
- 다른 층 주문의 교차 표시
- 운영 DB 적용, 프로덕션 배포, 계정 변경
- 기존 4/8슬롯 보드 자체를 다른 레이아웃으로 재설계

## 7. 완료 판정

1. 새 주문이 주방, 트레이, 해당 층의 보드에 한 polling interval 이내 표시되고 권한 없는 층에는 보이지 않는다.
2. 세 화면의 같은 메뉴가 단계 수량 변경 후 Realtime 또는 fallback polling으로 일치하며, 현재 화면 단계 완료는 초록, 미완료는 검정이다.
3. 카드에 메뉴명이 표시되고 공간 부족 시 두 열로 배치되며 Phone/Tablet에서 overflow가 없다.
4. 콤보 부모명 하나가 아니라 모든 구성 메뉴가 표시되고 직접 제공 component가 중복되지 않는다.
5. 경과 시계가 `00:00 → 00:01 → 59:59 → 60:00`으로 진행하며 snapshot refresh와 무관하게 매초 갱신된다.
6. 품목별 완료, 주문 전체 완료, 원복, 추가 주문, 이전/닫힌 세션을 포함해 오늘 완료 목록이 세 스테이션별로 정확하다.
7. PDF의 시스템 문구, 결제수단, 다국어 메뉴 선택은 항상 베트남어이며 금액/VAT/품목 수량은 기존 snapshot과 동일하다.
8. 기존 완료/원복, offline outbox, 4/8슬롯, floor-direct 권한, print mode, 결제와 red invoice 회귀 테스트가 유지된다.
9. 관련 테스트, 전체 `flutter test`, `flutter analyze`, Web build, SQL preflight/verify, `bash scripts/check_repo.sh`, `git diff --check`를 통과한다.
10. 운영 적용과 배포는 별도 승인 후 `scripts/deploy_pos_production.sh`만 사용하고 exact pushed head SHA의 필수 GitHub Actions가 성공해야 한다.
