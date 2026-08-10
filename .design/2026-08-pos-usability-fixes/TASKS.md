# 구현 계획: 2026-08 POS 사용성 및 운영 개선

Generated from: 2026-08-10 사용자 요구사항
Date: 2026-08-10

## 범위와 완료 원칙

- QR 메뉴의 안내 문구, POS 메뉴명 언어, 프린트 스테이션, 분할 근무, 고객 결제 화면, 관리자 모바일 반응형을 각각 독립적으로 배포·검증 가능한 수직 작업으로 나눈다.
- 화면에서 선택한 POS 언어는 메뉴명의 유일한 표시 언어로 사용한다. 선택 언어 번역이 비어 있으면 다른 언어를 노출하지 않고 해당 언어의 일반 대체 문구(`메뉴`, `Món`, `Item`)를 사용한다.
- 고객 결제 화면과 고객용 영수증/프린터 출력은 기존 계약대로 베트남어 전용을 유지한다. POS 화면 언어 변경은 이 계약을 바꾸지 않는다.
- QR의 `부가세 8% 별도입니다`는 결제 계산 로직을 바꾸지 않는 고정 안내 문구로 취급하고, QR에서 선택한 언어에 맞춰 한국어·베트남어·영어로 표시한다.
- 관리자 모바일 대응은 정보나 기능을 숨기지 않는다. 좁은 화면에서는 줄바꿈, 세로 배치, 가로 스크롤, 전체 화면 다이얼로그/바텀시트를 사용해 동일 정보를 유지한다.
- DB 변경은 기존 마이그레이션을 수정하지 않고 새 additive migration, preflight, verify 스크립트로 추가한다. 배포 완료 판정은 `CLAUDE.md`의 정확한 pushed head SHA GitHub Actions 게이트를 따른다.
- 현재 작업 트리에 존재하는 프린트 계정 관련 미커밋 변경은 사용자 소유 작업으로 보존하고, 구현 시작 시 중복·충돌 여부를 먼저 확인한다.
- 여섯 요구사항을 한 번에 구현하거나 배포하지 않는다. 각 수직 작업은 별도 변경 묶음으로 완성하고 기존 기능 회귀가 0건임을 확인한 뒤에만 다음 묶음으로 진행한다.
- 기존 공용 컴포넌트·RPC·테이블의 기본 계약을 직접 바꾸는 대신 새 옵션, 새 helper, 새 additive migration으로 확장한다. 기존 호출자는 명시적으로 전환하기 전까지 동일하게 동작해야 한다.

## 0. 기존 기능 보호 게이트

- [ ] **변경 전 기준선 증거를 고정**: 현재 사용자 소유 dirty 파일을 별도로 식별한 뒤 `git diff --check`, `flutter analyze`, 관련 핵심 계약 테스트, 전체 `flutter test`, `bash scripts/check_repo.sh`를 실행하고 결과와 exact HEAD SHA를 기록한다. 기존 실패가 있으면 이번 요구사항과 무관한지 분류·기록하기 전에는 구현을 시작하지 않는다. _재사용: 현재 production gate와 test suite; 수정/신규 컴포넌트 없음; 산출물: baseline harness report._

- [ ] **각 버그를 수정 전에 테스트로 재현**: QR 활성/비활성 안내, POS 언어 혼용, 같은 날 두 번째 출근 거부, 8행 미표시, 관리자 휴대폰 overflow를 각각 현재 코드에서 실패하는 최소 test/fixture로 먼저 고정한다. 프린트 스테이션은 현재 권한과 매장 격리 상태를 성공/거부 테스트로 고정한다. _수정: 관련 contract/widget/SQL test만; 재사용: 기존 test harness; 신규: 요구사항별 최소 회귀 fixture._

- [ ] **변경 묶음별 중단 기준 적용**: 한 묶음에서 관련 테스트, 기존 인접 도메인 테스트, `flutter analyze` 중 하나라도 새로 실패하면 다음 묶음으로 넘어가지 않고 원인 제거 또는 변경 철회 후 기준선으로 복귀한다. 테스트를 삭제·완화하거나 unrelated 코드를 같이 고쳐 통과시키는 방식은 금지한다. _재사용: baseline report; 수정/신규 컴포넌트 없음._

- [ ] **DB와 인증 변경의 하위 호환성 보장**: 기존 RPC signature, RLS store scope, `restaurants` 물리 테이블 및 Office app coupling을 유지한다. migration은 transaction/preflight/verify를 갖추고 기존 POS 클라이언트가 새 DB에서도 계속 동작하는지 확인한다. 운영 DB 변경은 자동 rollback에 기대지 않고 배포 전 데이터/계정 상태를 검증하며, 실패 시 사용할 forward-fix SQL과 계정 복구 절차를 준비한다. _재사용: production SQL gate와 기존 auth checker; 수정/신규 컴포넌트 없음._

## 1. 메뉴명 언어를 화면 선택 언어로 통일

- [ ] **다국어 주문 항목 모델을 하위 호환 방식으로 확장**: `OrderItem` 및 주방 주문 항목 모델이 `name/name_vi/name_en`을 모두 보존하도록 필드만 additive하게 확장하고, 기존 `label` 저장·가격·수량·상태 파싱은 그대로 둔다. 새 화면용 resolver는 선택 언어 하나만 반환하며, 다른 언어로 fallback하지 않고 선택 언어의 일반 대체 문구(`메뉴`, `Món`, `Item`)를 사용한다. _수정: `lib/features/order/order_model.dart`, `lib/features/kitchen/kitchen_provider.dart`; 재사용: `AppLanguage`, 현재 locale controller; 신규: opt-in 메뉴명 resolver와 단위 테스트._

- [ ] **활성 주문·검색·완료 주문 조회에 세 언어 필드를 일관되게 포함**: waiter/cashier/kitchen/table preview/payment detail의 Supabase select가 모두 `menu_items(name, name_vi, name_en)`을 가져오도록 하고, 정렬·가격·상태 데이터 계약은 그대로 유지한다. _수정: `lib/features/order/order_provider.dart`, `lib/features/payment/payment_provider.dart`, `lib/core/services/payment_service.dart`, `lib/features/kitchen/kitchen_provider.dart`, `lib/features/table/table_provider.dart`; 재사용: 기존 `OrderItem.fromJson`; 신규 컴포넌트 없음._

- [ ] **캐셔와 주문 검색 결과를 한 화면씩 전환**: 캐셔 선택 주문과 완료 주문 검색을 먼저 새 resolver로 전환해 `label` 주 이름+작은 번역 줄을 제거하고 회귀 테스트를 통과시킨다. 이후 합산 결제, 결제 완료 다이얼로그, QR 주문 원장 시트를 차례로 전환하며 각 화면마다 가격·할인·서비스 메뉴·취소 메뉴 표시가 그대로인지 확인한다. _수정: `lib/features/cashier/cashier_screen.dart`, `lib/features/cashier/payment_completion_dialog.dart`; 재사용: opt-in 메뉴명 resolver; 최종 제거: 모든 호출 전환 후 `_cashierTranslatedItemNames`._

- [ ] **주방·웨이터·테이블 미리보기를 독립적으로 전환**: 주방 카드/콤보 구성품, 웨이터 활성 주문, 테이블 미리보기를 각각 별도 변경 묶음으로 새 resolver에 연결한다. 각 전환 후 주문 정렬, 수량, 상태 변경, 품절/취소, 콤보 구성품과 실시간 갱신 테스트를 통과시킨 뒤 다음 화면으로 이동한다. 주방 하드코딩 번역 매핑은 데이터 기반 결과가 동등함을 테스트로 확인한 후에만 제거한다. _수정: `lib/features/kitchen/kitchen_screen.dart`, `lib/widgets/order_workspace.dart`, `lib/features/table/table_provider.dart`, 관련 preview 위젯; 재사용: opt-in resolver; 신규 컴포넌트 없음._

- [ ] **언어 전환 회귀 테스트 작성**: 한국어로 QR 주문한 동일 주문을 POS 한국어/베트남어/영어로 각각 열었을 때 정확히 한 언어만 보이는 widget/provider 테스트를 추가한다. 활성 주문과 완료 주문 검색을 모두 포함하고, 베트남어 선택 시 한글 주 이름·작은 베트남어 보조 줄이 없는지 검증한다. 고객 결제 화면과 프린터 출력은 베트남어 유지 여부를 별도 확인한다. _수정: `test/order_item_ordering_test.dart` 및 cashier/kitchen/payment 계약 테스트; 재사용: 기존 locale test harness; 신규: 언어별 주문 표시 fixture._

## 2. 매장별 프린트 스테이션과 프린터 설정

- [ ] **현재 프린트 계정 변경을 매장 코드 계약에 맞춰 완성**: 이미 진행 중인 `${short_code}_print` 계정 템플릿과 `bt_print@globos.world` 변경을 검토해 모든 신규 매장이 매장별 `device_print_station/print_station/store` 요구사항을 생성하도록 한다. 기존 `print@globos.world`가 미프로비저닝 상태면 비활성화하고, 프로비저닝 상태면 자동 덮어쓰기 없이 자격 증명 인계 절차로 분기한다. _수정/통합: 현재 dirty `store_setup_models.dart`, `workforce_setup_card.dart`, `20260810110000_store_scoped_print_station_accounts.sql`, 인증 계정 목록; 재사용: store short-code 및 fixed-account provisioning 흐름; 신규: 필요한 preflight/verify와 운영 인계 체크._

- [ ] **프린터 설정 UI를 공용 컴포넌트로 추출**: 관리자 설정 탭의 프린터 목적지 추가·편집·활성화·삭제·유선/무선 IP·포트·용도·층·테스트 출력 UI를 재사용 가능한 매장 단위 패널로 만들고 기존 설정 탭 동작을 유지한다. _수정: `lib/features/admin/tabs/settings_tab.dart`; 재사용: `printerDestinationsProvider`, `PrinterDestinationService`, 기존 localization; 신규: 공용 `PrinterDestinationSettingsPanel` 및 편집 다이얼로그._

- [ ] **프린트 스테이션 화면에서 자기 매장 프린터를 설정**: 목적지 조회/테스트만 가능한 현재 화면에 공용 설정 패널을 연결해 프린트 스테이션 계정이 자기 `storeId`의 프린터만 추가·수정·삭제·테스트할 수 있게 한다. 좁은 Windows 창과 태블릿 폭에서도 필드와 버튼이 겹치지 않게 한다. _수정: `lib/features/print_station/print_station_screen.dart`; 재사용: 공용 설정 패널과 기존 작업 큐/실패 재출력 UI; 신규 컴포넌트 없음._

- [ ] **프린터 전용 최소 권한 RPC를 추가**: 전역 `require_admin_actor_for_restaurant`에 `print_station` 역할을 추가하지 않고, 프린터 설정 RPC에서만 사용하는 store-scoped actor guard를 새 migration으로 만든다. admin 계열과 해당 매장의 print_station만 목적지 CRUD/test가 가능하고 타 매장 접근과 다른 관리자 mutation은 거부한다. _수정: 프린터 destination RPC의 새 additive migration; 재사용: `user_accessible_stores`, audit log; 신규: printer-config 전용 권한 helper, preflight/verify SQL._

- [ ] **프린터 변경을 backend와 UI 두 단계로 배포 가능하게 구성**: 1단계 migration 배포 후 기존 관리자 프린터 설정과 print agent가 전과 동일하게 동작하는지 확인하고, 2단계에서만 print station 설정 UI를 노출한다. UI가 배포되지 않아도 backend 변경이 기존 운영을 방해하지 않고, backend가 준비되지 않은 환경에서는 새 설정 액션이 안전하게 실패하도록 한다. _수정: printer provider의 오류 처리와 migration verification; 재사용: 기존 admin settings/print agent flows; 신규 컴포넌트 없음._

- [ ] **계정·매장 격리·설정 회귀 검증**: `bt_print@globos.world` 요구사항, 새 매장의 코드별 print 계정, 자기 매장 CRUD 성공, 타 매장 CRUD 실패, print_station의 일반 관리자 RPC 실패, 설정 저장 후 print agent가 같은 destination을 사용하는지 검증한다. _수정: `test/print_station_account_contract_test.dart`, printer routing/provider/widget 테스트, pilot auth checker; 재사용: production gate support; 신규: cross-store SQL fixture._

## 3. 같은 날 분할 근무 출퇴근 지원

- [ ] **출퇴근 상태 머신을 ‘하루 1회’에서 ‘열린 근무 1개’로 변경**: 기존 migration 파일과 RPC signature는 유지하고 새 migration에서 함수만 교체한다. employee row lock, 최신 이벤트 정렬, 권한, 사진 wrapper는 그대로 두고 같은 베트남 날짜의 이전 출근 검색만 제거한다. `clock_out` 뒤에는 같은 날 다시 `clock_in`할 수 있고, 연속 `clock_in`·연속 `clock_out`은 계속 거부하며 자정 이후 열린 근무의 퇴근도 허용한다. _수정: 새 attendance migration; 재사용: `record_employee_attendance`와 photo wrapper; 제거: 새 함수 정의 안의 `v_has_clock_in_today` 일일 차단._

- [ ] **오류 코드와 안내 문구를 현재 상태 기준으로 교체**: `..._TODAY` 메시지를 ‘현재 이미 출근 중’ 또는 ‘먼저 출근 필요’ 의미로 바꾸고 한국어·베트남어·영어 문구와 kiosk 매핑을 갱신한다. 사진 업로드·필수 사진 계약은 유지한다. _수정: `attendance_kiosk_provider.dart`, `attendance_kiosk_screen.dart`, ARB/generated l10n; 재사용: 기존 kiosk 상태 처리; 신규 컴포넌트 없음._

- [ ] **분할 근무 SQL/Flutter 회귀 테스트 추가**: 09:00 in → 14:00 out → 18:00 in → 22:00 out 성공, in → in 실패, out without open shift 실패, 첫 근무가 전날 시작된 overnight out 성공, 두 기기의 동시 중복 요청 중 하나만 성공하는 시나리오를 검증한다. 관리자의 근태 조회와 급여 합산이 두 구간을 모두 포함하는지도 확인한다. _수정: 기존 attendance contract tests와 verification SQL; 재사용: employee row-lock fixture; 신규: split-shift fixture._

## 4. QR 메뉴 프로모션/부가세 안내

- [ ] **프로모션 영역에 항상 한 개의 주 안내와 부가세 안내를 표시**: 활성 프로모션이면 기존 프로모션 문구 바로 아래에 아주 작은 `부가세 8% 별도입니다`를 표시하고, 비활성 기간이면 같은 위치에 `정성껏 만들었습니다. 맛있게 드세요.`를 주 안내로 표시한 뒤 동일한 부가세 문구를 붙인다. 테이블 확인 안내는 유지한다. _수정: `lib/features/qr_order/qr_order_screen.dart`; 재사용: `_buildHeader`, `QrOrderCopy`, 현재 promotion model/tokens; 신규 컴포넌트 없음._

- [ ] **세 언어 카피와 시각 우선순위 검증**: 주 안내는 기존 프로모션 badge 수준을 유지하고 부가세 문구는 보조 색상·작은 글씨로 배치하되 접근 가능한 최소 가독성을 확보한다. ko/vi/en에서 활성/비활성 프로모션, 긴 프로모션명, 320px 폭을 테스트한다. _수정: QR screen/operational UI tests; 재사용: QR locale selector test harness; 신규: active/inactive promotion fixtures._

## 5. 고객 결제 화면 밀도와 베트남어 고정

- [ ] **결제 내역 행의 글씨와 여백을 30% 축소**: 메뉴명·수량·금액 typography를 현재 크기의 약 70%로 조정하고 행 vertical padding, 열 간격, 패널 내부 여백을 함께 줄인다. 제목·합계·QR의 시각적 우선순위와 44px 이상 조작 영역(로그아웃)은 유지한다. _수정: `lib/features/customer_display/customer_display_screen.dart`; 재사용: `CustomerDisplaySnapshot`, 고정 QR asset, POS color tokens; 신규 컴포넌트 없음._

- [ ] **8개 메뉴가 보이는 반응형 레이아웃 완성**: 1024×768 landscape에서 8개 주문 행이 스크롤 없이 표시되도록 하고, 600×1024 portrait 및 작은/큰 화면에서는 주문 패널과 QR 패널 비율·padding·금액 열 폭을 유동적으로 계산해 overflow 없이 모든 정보에 접근 가능하게 한다. _수정: `CustomerPaymentContent`, `_CustomerOrderPanel`, `_CustomerQrPanel`; 재사용: 기존 `LayoutBuilder`; 신규 컴포넌트 없음._

- [ ] **베트남어 고정 및 밀도 회귀 테스트 확대**: 앱 locale과 payload locale이 ko/en이어도 모든 고정 문구와 메뉴명 payload가 베트남어로만 보이는지 확인하고, 정확히 8개 및 12개 메뉴 fixture로 row visibility/scroll/overflow를 검사한다. 360, 600, 760, 1024px 폭과 text scale 1.0/1.3을 포함한다. _수정: `test/customer_payment_display_contract_test.dart`; 재사용: 기존 Vietnamese-copy assertions; 신규: 8/12-item responsive fixtures._

## 6. 관리자 전체 화면의 휴대폰 반응형

- [ ] **기존 기본 동작을 건드리지 않는 모바일 opt-in primitives 추가**: 360–599px에서만 호출자가 선택하는 responsive page header, key-value row, dense table adapter를 추가한다. 기존 `ToastResponsiveBody`, `PosPageHeader`, `ToastDenseDataTable`, `PosListRow`의 기본 생성자와 desktop/tablet 렌더링은 변경하지 않는다. 새 adapter는 label/value 두 줄, 최소 폭+가로 스크롤 또는 모든 필드를 담은 카드, 명확한 단일 scroll owner를 제공한다. _수정: `lib/core/ui/toast/toast_primitives*.dart`; 재사용: 현재 tokens/primitives; 신규: opt-in responsive variants와 기존 생성자 회귀 테스트._

- [ ] **테이블·메뉴·직원·근태 탭을 모바일화**: 검색/필터/추가 버튼을 wrap 또는 세로 toolbar로 바꾸고, 데스크톱 split inspector는 모바일에서 inline detail 또는 scrollable bottom sheet로 제공한다. 직원·근태의 급여/상세/편집 다이얼로그는 휴대폰에서 전체 화면에 가깝게 열리며 모든 기존 필드와 액션을 유지한다. _수정: `tables_tab.dart`, `menu_tab.dart`, `staff_tab.dart`, `attendance_tab.dart`; 재사용: 공용 mobile primitives와 기존 dialogs/providers; 신규: 필요한 mobile detail presentation만 추가._

- [ ] **보고서·재고·QC 탭을 모바일화**: metric strip/grid는 1–2열로 재배치하고, 차트는 의미 있는 최소 높이를 유지하며, 표·예외 목록·승인/입고/QC 상세는 가로 스크롤 또는 전체 필드 카드로 제공한다. 기존 지표, 금액, 상태, 필터, 승인 액션을 하나도 숨기지 않는다. _수정: `reports_tab.dart`, `inventory_tab.dart` 또는 `InventoryPurchaseScreen`, `qc_tab.dart`; 재사용: 공용 responsive primitives와 기존 데이터 providers; 신규: 필요한 mobile metric/table adapters._

- [ ] **설정·배달 정산·전자세금계산서 탭을 모바일화**: 설정 카테고리, 프로모션/프린터 폼, 정산 목록/상세, 전자세금계산서 이벤트·상세 행을 휴대폰에서 한 열로 배치하고 긴 ID·이메일·주소는 안전하게 줄바꿈/선택 가능하게 한다. 모든 저장·재시도·내보내기 액션은 화면 안에서 접근 가능해야 한다. _수정: `settings_tab.dart`, `delivery_settlement_tab.dart`, `einvoice_tab.dart`; 재사용: 공용 responsive primitives와 기존 dialogs; 신규 컴포넌트 없음._

- [ ] **관리자 모바일 정보 보존 테스트 매트릭스 구축**: 360×800, 390×844, 412×915에서 ko/vi/en 및 text scale 1.0/1.5로 모든 관리자 탭을 렌더링한다. Flutter overflow/예외가 없고, desktop fixture와 비교해 동일한 섹션·필드·지표·액션 key가 존재하며, 마지막 정보와 주요 버튼까지 스크롤 가능한지 검증한다. _수정: 기존 `admin_shell_redesign_contract_test.dart`, `web_scroll_contract_test.dart`, 각 admin tab contract/operational tests; 재사용: routed-surface test harness; 신규: desktop/mobile content-parity fixture._

- [ ] **관리자 탭은 한 그룹씩 승인 후 진행**: 테이블·메뉴 → 직원·근태 → 보고서 → 재고 → QC → 설정 → 배달 정산 → 전자세금계산서 순서로 나누고, 각 그룹마다 desktop 1440px와 tablet 1024px의 기존 레이아웃/정보/동작이 변하지 않았다는 비교 테스트를 통과시킨다. 한 그룹 승인 전에는 다음 그룹 파일을 수정하지 않는다. _재사용: desktop/mobile content-parity fixture; 수정/신규 컴포넌트 없음._

## 7. 통합 검증 및 릴리스 게이트

- [ ] **변경 묶음별 빠른 검증 실행**: 각 수직 작업에서 변경 Dart 파일을 `dart format`하고 관련 unit/widget/contract 테스트와 `flutter analyze`를 통과시킨다. DB 작업은 해당 preflight/verify SQL과 production migration gate test를 함께 실행한다. _재사용: 기존 test suite와 `scripts/check_repo.sh`; 신규 컴포넌트 없음._

- [ ] **핵심 사용자 여정 통합 확인**: 한국어 QR 주문 → 베트남어 POS 표시, 완료 주문 검색의 단일 언어 표시, 같은 날 2회 출퇴근, bt_print 로그인 후 자기 매장 프린터 설정/테스트, 8개 메뉴 고객 결제 표시, 휴대폰 관리자 전 탭 탐색을 한 번의 QA 체크리스트로 검증한다. _재사용: 실제 역할별 route와 pilot fixture; 신규: 통합 QA 체크리스트._

- [ ] **프로덕션 릴리스 게이트 통과**: 사용자 소유 dirty 파일을 보존한 상태에서 `bash scripts/check_repo.sh`와 관련 DB-only/production gate를 통과시키고, 승인된 배포 스크립트만 사용한다. 정확한 pushed head SHA의 필수 GitHub Actions 성공 전에는 완료로 보고하지 않는다. _재사용: `scripts/deploy_pos_production.sh`, 기존 production gates; 신규 컴포넌트 없음._

- [ ] **완료 보고에 검증 증거 첨부**: 기능별로 변경 파일, 재현 테스트, 신규 회귀 테스트, 기존 인접 테스트, 전체 analyze/test/repo check, DB preflight/verify, exact pushed head SHA의 GitHub Actions 결과를 표로 제출한다. 실행하지 못한 항목이 하나라도 있으면 PASS가 아니라 미검증으로 표시한다. _재사용: harness report 형식; 수정/신규 컴포넌트 없음._

## 권장 구현 순서

1. 전체 기준선과 요구사항별 실패 재현 테스트 고정
2. 메뉴명 언어 데이터 계약과 화면별 점진 전환
3. 프린트 스테이션 backend 최소 권한 후 설정 UI
4. 분할 근무 DB 상태 머신
5. QR 안내 문구
6. 고객 결제 화면 밀도
7. 관리자 opt-in 모바일 primitives 후 탭 그룹별 전환
8. 통합 QA와 프로덕션 게이트

언어와 프린터 작업을 먼저 두는 이유는 여러 화면·DB 권한에 걸쳐 있어 영향 범위가 가장 넓고, 뒤 작업이 이 계약을 재사용하기 때문이다. QR과 고객 결제 화면은 독립 배포가 가능하며, 관리자 모바일화는 공용 primitive가 안정된 뒤 탭별로 나누어 진행한다.
