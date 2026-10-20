# Build Tasks: 관리자 메뉴 삭제

Generated from: 2026-09-18 사용자 요청과 현재 메뉴 관리 구현
Date: 2026-09-18
Status: 로컬 구현 완료 — Flutter 전체 회귀·정적 분석·웹 release build 통과. Docker 미실행으로 실제 Postgres runtime test는 미실행이며 운영 DB 적용·앱 배포는 수행하지 않음

## 확정 동작

- 관리자 `메뉴 등록 및 삭제` 화면의 각 메뉴 행에 삭제 버튼을 추가한다. 카테고리 삭제와 별개로 메뉴 하나만 삭제할 수 있어야 한다.
- 사용자에게는 삭제로 보이지만 DB에서는 `menu_items` 행을 물리 삭제하지 않고 `is_archived = true`, `is_available = false`, `is_visible_public = false`로 보관한다.
- 삭제 완료 메뉴는 관리자 메뉴 목록, 직원 주문 입력, 품절 관리, QR 주문, 프로모션 등 **신규 선택 목록**에서 즉시 사라진다.
- 기존 주문, 결제, 매출 리포트, 주방/트레이/층 처리, 재고 레시피 및 직접배달 이력의 기존 메뉴 ID와 표시명은 보존한다. 삭제가 진행 중인 주문의 상태나 수량을 변경하지 않는다.
- 활성 콤보의 구성 메뉴로 사용 중인 일반 메뉴는 먼저 콤보에서 제거하기 전까지 삭제를 거절한다. 콤보 메뉴 자체는 보관 삭제할 수 있다.
- 삭제된 메뉴의 사진 객체와 레시피·프로모션·주문 연결 데이터는 자동 삭제하지 않는다. 별도의 복원/영구 정리 기능은 이번 범위에 넣지 않는다.
- 마지막 메뉴를 삭제한 카테고리는 빈 상태로 남는다. 이후 카테고리 삭제를 실행하면 보관 메뉴의 `category_id`는 기존 FK의 `ON DELETE SET NULL`에 따라 해제되고 메뉴 이력은 유지된다.

## 기존 구성요소 판정

- **그대로 재사용**: `_ItemsPanel`의 반응형 행/액션 `Wrap`, `PosDataPanel`, `PosEmptyState`, `ToastStatusBadge`, `showSuccessToast`, `showErrorToast`, `AppColors`, `AppFonts`, `MenuService.fetchItems()`의 `is_archived = false` 필터, 현재 KO/VI/EN localization 생성 흐름.
- **수정 필요**: `lib/features/admin/tabs/menu_tab.dart`, `lib/features/admin/providers/menu_provider.dart`, `lib/core/services/menu_service.dart`, 세 ARB 파일, 관리자 메뉴 widget/contract test, 카테고리 삭제 RPC의 비어 있음 판정, 새 메뉴의 `sort_order` 계산.
- **새로 생성**: 보관 삭제 RPC와 카테고리 삭제 호환 변경을 담은 additive Supabase migration, SQL preflight/verify/rollback, 실제 Postgres runtime test.
- **변경 금지**: 주문행/결제/매출 원장, KDS 수량·상태, 재고 차감 이력, 배달 fulfillment, MISA, 기존 카테고리/메뉴 등록·수정·품절·QR 공개·Excel 교체 동작.

## Foundation & Server Contract

- [ ] **현재 결함을 실패 테스트로 고정**: 메뉴 행에 삭제 진입점과 확인 dialog가 없고 `MenuNotifier`에 사용자용 삭제 command가 없는 현재 상태를 focused widget/provider test로 재현한다. _Modifies: `test/admin_core_overlay_operational_test.dart`, `test/menu_management_images_contract_test.dart`; reuses existing menu notifier stub and admin overlay harness._

- [ ] **물리 삭제 대신 보관 삭제 RPC 추가**: 새 timestamp migration에 `admin_archive_menu_item(p_item_id uuid)`를 추가한다. 관리자 매장 권한 확인, 매장 advisory lock, 대상 행 `FOR UPDATE`, 멱등 재호출을 처리한 뒤 세 상태 필드를 함께 갱신하고 기존 `admin_delete_menu_item` audit action에 `delete_mode = 'archive'`와 old/new values를 기록한다. 기존 `admin_delete_menu_item`은 신규 메뉴 생성 실패 시 보상 정리에만 남겨 현재 등록 흐름을 깨지 않는다. _Creates: one additive migration; reuses `require_admin_actor_for_restaurant`, `audit_logs`, existing audit visibility allowlist and `is_archived` column._

- [ ] **활성 콤보 구성 메뉴 보호**: archive RPC가 `menu_combo_components.component_menu_item_id`를 조회하고 부모 콤보가 아직 `is_archived = false`이면 `MENU_COMBO_COMPONENT_IN_USE`로 전체 transaction을 거절한다. 삭제 대상이 콤보 부모인 경우에는 구성 행을 지우지 않고 함께 보관해 기존 주문 snapshot과 추후 데이터 대사를 유지한다. _Modifies only the new RPC; reuses the existing error code and provider mapping._

- [ ] **카테고리 삭제와 보관 메뉴의 충돌 해소**: 최신 `admin_delete_menu_category`를 새 migration에서 재정의해 `MENU_CATEGORY_NOT_EMPTY` 검사는 `is_archived = false` 메뉴에만 적용한다. 활성 메뉴가 하나라도 있으면 계속 차단하고, 모두 보관된 카테고리는 삭제 가능하게 하며 archived item 행은 FK의 `ON DELETE SET NULL`로 보존한다. _Modifies the effective category RPC without changing its name/signature; preserves current UI and permissions._

- [ ] **삭제 후 메뉴 정렬 충돌 방지**: 메뉴 추가 시 같은 카테고리의 활성 행 개수가 아니라 현재 `sort_order` 최대값 + 1을 사용하도록 두 등록 경로를 공통 helper로 바꾼다. 중간 메뉴 삭제 뒤 새 메뉴가 기존 마지막 메뉴와 같은 순번을 받지 않고 항상 끝에 추가되어야 한다. _Modifies: `MenuNotifier.addMenuItem` and `addMenuItemWithPhoto`; reuses current item state and keeps existing visible order._

- [ ] **활성 카탈로그 경계 확인 및 보강**: 관리자/웨이터/캐셔 품절/QR/프로모션/재고 레시피 편집의 “새로 선택 가능한 메뉴” query를 전수 확인해 archived 메뉴를 제외한다. 이미 `MenuService.fetchItems` 또는 `qr_get_menu`를 재사용하는 경로는 건드리지 않고, 직접 조회하는 활성 picker에 필터가 빠진 경우에만 보강한다. 과거 주문·리포트·레시피 이력 조회에는 필터를 추가하지 않는다. _Reuses current active filters; modifies only uncovered live-selection projections discovered by tests._

## Core UI Vertical Slice

- [ ] **메뉴 행 삭제 진입점 추가**: 편집 아이콘 옆에 destructive 색상의 `Icons.delete_outline` 버튼을 배치하고 `admin_menu_delete_item_<id>` key, localized tooltip, 최소 48dp 터치 영역을 제공한다. 폭 760px 미만에서는 기존 action `Wrap` 안에서 자연스럽게 줄바꿈하며 사진·이름·가격·상태 switch의 현재 정렬을 유지한다. _Modifies: `_ItemsPanel`; reuses its desktop/phone layout and POS tokens; creates no new shared component._

- [ ] **안전한 삭제 확인 dialog 구현**: 메뉴명과 “신규 주문 목록에서는 제거되지만 과거 주문·매출 기록은 유지됨”을 KO/VI/EN으로 표시하고 취소/삭제 버튼을 제공한다. 확인 중에는 닫기와 중복 탭을 잠그고 progress를 표시하며, 성공하면 dialog를 닫고 성공 toast를 보여준다. _Modifies: `MenuTab` with `_showDeleteItemDialog`; reuses category dialog style, `FilledButton` destructive styling and toast primitives._

- [ ] **Service/Provider 삭제 command 연결**: `MenuService.archiveMenuItem()`이 새 RPC만 호출하고, `MenuNotifier.archiveMenuItem()`은 성공 후 `fetchItems()`를 완료한 다음 true를 반환한다. 실패 시 현재 목록을 유지하고 기존 권한·not-found·combo-in-use mapping으로 화면 error를 전달한다. 생성 실패 보상용 `deleteMenuItem()` 호출은 변경하지 않는다. _Modifies: menu service/provider and `_ItemsPanel` callback wiring; keeps rollback and all existing commands intact._

- [ ] **삭제 직후 화면 상태 정합성 유지**: 삭제된 행만 목록에서 사라지고 선택 카테고리는 유지한다. 마지막 메뉴 삭제 시 기존 `PosEmptyState`가 나타나며, 다른 카테고리 수량/선택/스크롤 상태와 등록·수정·품절·QR switch는 변하지 않아야 한다. 다른 단말이 먼저 삭제한 경우 멱등 성공 후 최신 목록으로 수렴한다. _Modifies menu state reconciliation only; reuses current fetch-and-render flow._

## Localization, Errors & Accessibility

- [ ] **KO/VI/EN 문구 추가 및 생성 파일 갱신**: 메뉴 삭제 tooltip/title/확인 설명/성공 문구를 세 ARB에 같은 placeholder 계약으로 추가하고 Flutter localization을 재생성한다. soft delete인데 “영구 삭제” 또는 “되돌릴 수 없음”이라고 오해시키는 문구는 사용하지 않는다. _Modifies: `lib/l10n/app_ko.arb`, `app_vi.arb`, `app_en.arb` and generated localization files; reuses `menuDelete` for the confirm button._

- [ ] **실패 상태를 사용자 행동으로 연결**: 콤보 사용 중이면 “콤보 편집에서 이 메뉴를 먼저 제거”하도록 안내하고, 권한/대상 없음/네트워크 오류는 dialog를 열린 채 유지해 재시도 또는 취소할 수 있게 한다. 서버 원문과 UUID는 노출하지 않는다. _Modifies provider error fallback and dialog busy/error handling; reuses global admin error toast behavior._

- [ ] **접근성과 반응형 검증**: 삭제 버튼에 tooltip/Semantics label을 부여하고 키보드 focus 및 Enter/Space 동작을 확인한다. 390×844, 768×1024, 1024×768, 1440×900과 100%/130%/200% text scale에서 메뉴명·경고문·action 영역 overflow가 없어야 한다. _Modifies only the new action/dialog where needed; reuses existing responsive breakpoints._

## Regression & Integrity Tests

- [ ] **Service/Provider 단위 테스트**: RPC 이름/parameter, 성공 후 fetch, 실패 시 행 유지, `MENU_COMBO_COMPONENT_IN_USE` mapping, 연속 confirm 멱등성, 삭제로 sort gap이 생긴 뒤 새 메뉴가 max + 1에 추가되는지 검증한다. _Creates or extends focused menu provider/service tests; reuses mocked Supabase/notifier patterns._

- [ ] **관리자 Widget 테스트**: 삭제 버튼 노출, tooltip, 취소 무변경, 확인 command 1회, busy 중 재탭 차단, 성공 toast/행 제거/마지막 행 empty state, 서버 실패 시 dialog와 메뉴 유지, 작은 화면 및 큰 글자 overflow를 검증한다. 카테고리 삭제·메뉴 편집·두 switch의 기존 test도 함께 통과해야 한다. _Modifies existing admin overlay and menu management tests; no source-string-only assertion for the main behavior._

- [ ] **실제 Postgres archive 테스트**: 정상 관리자 삭제, 타 매장/비관리자 거절, 없는 ID, 중복 호출, audit 1회, active combo component 거절, combo 부모 archive, 사진/레시피/프로모션/주문/직접배달 참조 보존, 세 상태 필드 변경, active catalog 제외, 과거 join 유지, 마지막 active item archive 후 category delete를 실행 SQL로 검증한다. _Creates: focused `supabase/tests` runtime SQL; reuses current auth/store fixtures where possible._

- [ ] **기존 기능 회귀 매트릭스 실행**: 카테고리 등록·수정·정렬·삭제, 메뉴 등록(사진 포함) 실패 보상, 메뉴 수정·사진 교체/제거, 품절·QR 공개, 콤보 편집, Excel import/update와 archived ID 재사용, 웨이터 주문, QR 주문, 재고 recipe, 프로모션, 진행 중 KDS/배달 주문, 리포트가 모두 기존대로 동작하는지 확인한다. _Reuses current Flutter/SQL suites; changes expectations only for the new user-facing archive operation._

## Release Safety

- [ ] **운영 스크립트 준비**: migration 전 `is_archived`, FK, combo trigger, RPC signature와 audit dependency를 확인하는 preflight, 배포 후 RPC/권한/필터/audit를 읽기 전용으로 확인하는 verify, 앱 롤백 시 새 RPC를 비활성화할 수 있는 rollback 절차를 만든다. rollback이 기존 archived 행을 일괄 복원해서는 안 되며 복원이 필요하면 audit의 명시 ID만 대상으로 별도 승인한다. _Creates scripts under `scripts/`; reuses repository SQL safety conventions._

- [ ] **정적·전체 검증 통과**: 변경 Dart format, localization generation, focused Flutter/SQL tests, `flutter analyze`, 전체 `flutter test`, `bash scripts/check_repo.sh`, `git diff --check`, web release build를 통과한다. CRITICAL/HIGH 회귀가 0건인지 독립 검토하고 현재 사용자 소유의 tray/floor 변경 파일은 수정·포함하지 않는다. _Reuses project gates in `CLAUDE.md`; no production mutation in the implementation phase._

- [ ] **DB 선배포 후 앱 배포**: 별도 배포 요청을 받은 경우에만 additive migration을 먼저 적용·검증하고, exact pushed HEAD의 필수 GitHub Actions가 성공한 뒤 `scripts/deploy_pos_production.sh`로 앱을 배포한다. 관리자 1건 삭제 smoke에서 신규 주문 목록 제외, 기존 주문/리포트 유지, audit 기록, 빈 카테고리 삭제를 확인한다. _Reuses the sole approved production deployment path; no manual Supabase/Vercel bypass._

## 권장 구현 순서

1. 실패 테스트와 신규 archive RPC 계약
2. 콤보 보호·카테고리 삭제 호환·sort order 회귀 방지
3. Service/Provider command와 메뉴 행 삭제 dialog
4. KO/VI/EN·접근성·반응형 상태
5. 실제 Postgres 참조 보존 및 전체 기능 회귀
6. preflight/verify/rollback, exact-SHA CI, 승인 후 DB/app 배포

## 완료 판정

- 모든 관리자 메뉴 행에서 삭제 버튼을 찾을 수 있고 확인 전에는 어떤 데이터도 바뀌지 않는다.
- 확인 성공 후 대상 메뉴가 관리자·직원·QR의 신규 선택 목록에서 사라지고 마지막 메뉴 삭제 시 카테고리의 기존 빈 상태가 표시된다.
- DB의 `menu_items` 행과 사진·주문·결제·매출·KDS·재고·배달 참조는 유지되며 세 active 상태만 비활성화된다.
- 활성 콤보 구성 메뉴는 삭제되지 않고 명확한 해결 안내가 나오며, 콤보에서 제거한 뒤에는 삭제할 수 있다.
- 삭제된 메뉴만 남은 카테고리를 삭제할 수 있고 archived 메뉴는 category null 상태로 보존된다.
- 삭제 뒤 새 메뉴 추가 순서가 뒤섞이지 않고, 기존 등록·수정·품절·QR·Excel·카테고리·주문 기능의 회귀 테스트가 모두 통과한다.
- 운영 반영 시 migration, 앱, smoke 결과가 각각 보고되고 기존 사용자 소유 변경사항이 섞이지 않는다.

## 이번 범위 밖

- 삭제 메뉴 목록/복원 UI
- 사진과 archived 메뉴의 보존 기간 기반 영구 purge
- 다중 메뉴 일괄 삭제
- 진행 중 주문에서 메뉴를 취소하거나 기존 매출/재고/KDS 이력을 다시 계산하는 기능
