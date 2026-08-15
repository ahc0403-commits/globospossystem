# Build Tasks: KDS 주문 카드 메뉴·동시 동기화·오늘 완료 이력

Generated from: `.design/2026-08-kds-card-menu-sync/DESIGN_BRIEF.md`
Date: 2026-08-15

## 기준선과 데이터 계약

- [ ] **현행 실패를 회귀 테스트로 먼저 고정**: 카드에 메뉴명이 없고, upstream 미완료 주문이 트레이/층에서 숨겨지며, 최근 완료가 활성 세션의 주문단위 action만 포함하고, PDF에 raw 결제 코드/비베트남어 메뉴 label이 들어가는 fixture를 각각 실패 테스트로 만든다. _Modifies: `test/emergency_fulfillment_responsive_test.dart`, `test/emergency_digital_fulfillment_contract_test.dart`, `test/pos_paperless_receipt_contract_test.dart`; reuses current fixture notifiers and receipt snapshots._

- [ ] **표시 line과 처리 line을 분리한 모델 추가**: `EmergencyFulfillmentItem`의 처리 수량은 유지하고 콤보 component를 카드/상세용 display line으로 해석하는 모델과 station별 `isCompletedAt`/`isActionableAt` helper를 추가한다. 부모 음식 component는 부모 상태를 공유하고 floor-direct component는 `line_key`로 자신의 상태를 연결해 중복을 제거한다. _Modifies: `emergency_fulfillment_provider.dart`; reuses existing `combo_components`, route snapshots, localized name resolver; creates presentation-only display model._

- [ ] **호환 Snapshot payload 확장**: 새 additive migration에서 active order item에 콤보 component 다국어/route snapshot을 포함하고 기존 `items`/RPC 필드는 보존한다. 다른 매장·다른 층·취소 품목 격리와 구버전 payload 파싱을 검증한다. _Creates: a new timestamped Supabase migration and SQL preflight/verify fixture; modifies `get_emergency_station_snapshot` compatibly; reuses `order_items.combo_components` and current SECURITY DEFINER scope._

## 주문 카드와 세 화면 동시 노출

- [ ] **공통 카드에 메뉴명과 완료 색상 표시**: `_EmergencyOrderCard`에 display line 목록을 넣고 현재 station 단계 완료는 `PosColors.success`, 미완료는 `PosColors.textPrimary`로 표시하며 완료 아이콘/semantics를 함께 제공한다. 키친·트레이·층별이 같은 위젯을 사용하고 카드 탭 상세 진입은 유지한다. _Modifies: `emergency_fulfillment_screen.dart`; reuses `_EmergencyOrderCard`, `PosColors`, current 4/8-slot board; creates a private compact menu-line widget._

- [ ] **카드 내부 1열→2열 적응 배치 완성**: 사용 가능한 카드 높이와 display line 수를 기준으로 기본 1열, 공간 부족 시 2열로 순서를 보존해 배치하고, 두 열에도 못 들어가는 극단값은 누락 수와 상세 진입을 표시한다. 390×844 Phone 4슬롯과 768×1024/1024×768 Tablet 8슬롯에서 overflow를 막는다. _Modifies: private card menu-list widget; reuses `LayoutBuilder` and existing board sizing; creates no new route._

- [ ] **모든 스테이션에 주문을 즉시 보이게 분리**: active board의 가시성을 local actionability와 분리해 queue에 존재하는 모든 주문을 주방·트레이·해당 층에 표시한다. upstream 미완료와 직접 제공 음료는 읽기 전용으로 두고 기존 RPC 권한과 버튼 enable 조건은 그대로 유지한다. _Modifies: active/recent filters, `visibleItemsAt`/visibility helpers, status copy; reuses assignment/RLS and quantity-chain actionability._

- [ ] **세 화면 상태 갱신을 같은 흐름으로 통일**: queue, standard item, floor-direct item, completion/revert action 변화를 Snapshot으로 합치고 Realtime 후 동일 resolver로 상태를 재계산한다. 현재 page, recent 탭, 선택 주문을 갱신 중 보존하며 1초 polling을 fallback으로 유지한다. _Modifies: `EmergencyFulfillmentNotifier` subscriptions and snapshot reconciliation; reuses `LiveSyncScope`, current row patch, polling and IndexedDB outbox._

## 주문 경과 디지털 시계

- [ ] **카드 헤더에 실제 `MM:SS` 시계 구현**: 화면 단위 1초 ticker와 순수 elapsed formatter를 추가해 `queue.created_at` 기준 `00:00`, `59:59`, `60:00`을 표시하고 음수 경과는 0으로 clamp한다. 기존 상태 아이콘 자리에 작은 시계 아이콘과 tabular-number 디지털 텍스트를 배치한다. _Modifies: `EmergencyFulfillmentScreen` state lifecycle and `_EmergencyOrderCard`; reuses `PosNumericText`/font tokens where suitable; creates a testable formatter helper._

## 오늘 완료 전체 이력

- [ ] **오늘 완료 스테이션 조회 RPC 추가**: 베트남 00:00 영업일 범위의 모든 오늘 session에서 현재 수량이 station 완료 조건을 만족하는 주문과 최신 유효 완료 시각을 계산한다. 주문단위·품목별 완료를 모두 포함하고 원복/추가 주문은 현재 상태에 따라 제외하며 store/floor 권한을 강제한다. _Creates: additive `get_emergency_station_today_completed` RPC, indexes only if query evidence requires them, SQL preflight/verify; reuses append-only actions/events and existing fulfillment ledgers._

- [ ] **Provider에 active와 today-completed 컬렉션 분리**: Snapshot과 오늘 완료 응답을 한 refresh cycle에서 일관되게 로드하고, 같은 주문이 active/recent 양쪽에 중복되지 않게 queue/order ID와 최신 completion timestamp로 병합한다. 활성 세션이 바뀌거나 닫혀도 오늘 완료 이력을 유지한다. _Modifies: `EmergencyFulfillmentState` and notifier load/reconcile; reuses current error/outbox handling; creates no duplicate client cache._

- [ ] **최근 완료 UI를 오늘 전체 목록으로 전환**: selector count, 빈 상태, 최신 완료 정렬, 상세 메뉴 색상과 허용 가능한 원복 진입을 새 completed collection에 연결한다. 과거 session 완료는 보되 원복 허용 여부는 서버 응답을 기준으로 비활성/사유 표시한다. _Modifies: `_BoardModeSelector`, `_buildActive`, recent order details; reuses existing recent tab and revert RPC._

## 콤보 표시와 상호작용 보호

- [ ] **콤보 구성 메뉴를 카드와 상세에서 개별 표시**: 부모 콤보명이 아닌 fixed/selected component를 snapshot 순서대로 표시하고 route별 상태를 적용한다. 직접 제공 음료 logical line은 중복 제거하고, 구성 행 탭이 부모 action을 여러 번 실행하지 않도록 display row와 action target을 분리한다. _Modifies: shared card/detail menu rendering; reuses combo route/name snapshots and existing parent/floor-direct actions._

- [ ] **콤보·일반·혼합 주문 회귀 매트릭스 추가**: 일반 메뉴, 음식 콤보, 선택 음료 콤보, 같은 음료 수량 2+, 혼합 주문을 kitchen/tray/floor에서 검증해 표시 line 수·색상·중복·완료/원복 payload가 정확한지 고정한다. _Modifies: emergency widget and floor-direct contract tests; reuses current combo fixtures; creates focused display-status fixtures._

## PDF 베트남어 고정

- [ ] **PDF 전용 베트남어 값 resolver 추가**: 결제수단/서비스/분할/기타 코드와 시스템 품목명을 베트남어로 변환하고 PDF build가 화면 locale을 읽지 않게 한다. 고유명사는 보존하되 생성 문구에 한국어/영어 fallback을 사용하지 않는다. _Modifies: `digital_receipt_pdf_service.dart` and digital receipt presentation helpers; reuses existing PDF font, currency and immutable snapshot; creates a pure Vietnamese resolver._

- [ ] **영수증 snapshot에 베트남어 메뉴명을 고정**: 새 additive migration에서 `ensure_digital_receipt`가 menu `name_vi`/주문 시점 베트남어 snapshot을 사용하도록 호환 확장하고, 번역 누락 시스템 품목은 베트남어 fallback을 사용한다. 기존 발행 영수증 snapshot은 불변으로 유지하고 새 발행분부터 적용한다. _Creates: new receipt migration and SQL verification; modifies snapshot creation only; preserves payment, VAT, amount and MISA contracts._

- [ ] **PDF 언어·금액 회귀 테스트 추가**: 앱 locale ko/vi/en, cash/card/bank transfer/split/service/other, 콤보/긴 메뉴/번역 누락 fixture에서 PDF 추출 텍스트의 시스템 문구와 메뉴 선택이 베트남어인지, 기존 합계·VAT·수량이 동일한지 검증한다. _Modifies: `test/pos_paperless_receipt_contract_test.dart` and focused PDF tests; reuses current receipt builder numeric fixtures._

## 통합 검증과 릴리스 안전

- [ ] **반응형·접근성 Widget 검증**: 390×844, 430×932, 844×390, 768×1024, 1024×768에서 4/8슬롯, 1/2열 메뉴, 긴 VI/KO/EN 이름, text scale 100%/130%/200%, 초록/검정+semantics, timer tick을 검증한다. _Modifies: `test/emergency_fulfillment_responsive_test.dart` and visual fixtures; reuses current router/locale harness._

- [ ] **다중 계정 동기화 E2E 검증**: 같은 주문을 kitchen, tray, 1F/2F 브라우저에 동시에 열어 최초 동시 노출, kitchen→tray→floor 색상/권한 전이, 직접 제공 음료, 콤보, 원복, 추가 주문, offline 복구, 오늘 완료 이력을 확인한다. _Modifies/creates focused multi-account integration smoke tests; reuses fixed station accounts and current Realtime/polling setup._

- [ ] **저장소 및 프로덕션 게이트 실행**: 변경 Dart format, 관련 테스트, `flutter analyze`, 전체 `flutter test`, SQL preflight/verify, Flutter Web build, `bash scripts/check_repo.sh`, `git diff --check`를 통과한다. 운영 DB 적용/배포는 별도 승인 후 `scripts/deploy_pos_production.sh`만 사용하고 exact pushed head SHA의 필수 GitHub Actions 성공을 확인한다. _Reuses: project production gates; creates no runtime component._

## 권장 구현 순서

1. 실패 재현 테스트와 표시/처리 line 계약
2. 호환 Snapshot 및 오늘 완료 RPC
3. 공통 카드 메뉴·색상·1/2열과 동시 가시성
4. Realtime/polling reconciliation과 디지털 시계
5. 콤보 display/action 분리
6. PDF 베트남어 snapshot/resolver
7. Widget, SQL, 다중 계정 E2E, 전체 릴리스 게이트
