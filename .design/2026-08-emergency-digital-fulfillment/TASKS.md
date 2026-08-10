# Build Tasks: 전체 웹 반응형 전환과 비상 디지털 제공 흐름

Generated from: `.design/2026-08-emergency-digital-fulfillment/DESIGN_BRIEF.md`
Date: 2026-08-10

## Foundation

- [ ] **기준선과 회귀 예산 고정**: 현재 변경사항을 보존한 상태에서 정적 분석, 전체 Flutter 테스트, Node/보안 검사, 로컬 웹 빌드 결과를 기록하고 기존 18개 라우트·Admin 10개 탭·Inventory 11개 화면·전체 오버레이 목록을 테스트 매트릭스로 고정한다. _Reuses: `scripts/check_repo.sh`, 기존 route/overlay coverage tests._
- [ ] **공통 반응형 화면 등급 도입**: Phone `<600`, Tablet `600–1199`, Desktop `>=1200`과 글자 확대 판정을 공통 API로 만들고 산발적인 폭 조건을 점진적으로 대체한다. 정보량은 유지하고 표는 가로 스크롤, 명령은 Wrap/스택, 상세는 시트/분할 화면으로 전환한다. _Modifies: Toast/Pos responsive primitives and navigation shells._
- [ ] **실제 데이터 웹 반응형 테스트 하네스 강화**: 빈 화면 렌더링 확인에 그치지 않고 긴 메뉴명, 8개 이상 품목, 긴 금액, 오류, 로딩, 오프라인, 팝업을 포함한 Phone/Tablet/Desktop 브라우저 및 100%/130%/200% 글자 확대 테스트 픽스처를 만든다. _Modifies: routed surface, admin/inventory, overlay operational tests._
- [ ] **Flutter Web 단일 런타임 고정**: 모든 역할 화면이 동일 HTTPS Flutter Web 배포본에서 동작하도록 web manifest, 역할별 deep link, 브라우저 새로고침 복구, 캐시 버전과 Service Worker 공존 계약을 고정하고 네이티브 앱 빌드·앱스토어 배포를 범위에서 제외한다. _Modifies: `web/`, router and web build contracts; reuses existing Flutter Web release pipeline._

## 전체 웹 반응형 화면

- [ ] **인증·공개 웹 화면 반응형 전환**: QR 주문, 로그인, 최초/일반 비밀번호 변경, 개인정보 동의, 온보딩의 입력 폼·키보드 인셋·확인창을 작은 브라우저 화면에서 한 열로 구성하고 모든 정보와 동작을 유지한다. _Modifies: existing auth/QR/onboarding web screens; reuses responsive primitives._
- [ ] **웨이터·캐셔·결제 웹 화면 반응형 전환**: 테이블 선택, 주문 작성, 주문 검색, 복합 결제, 결제 완료, 취소/복구, 적색 세금계산서 및 모든 관련 시트를 Phone 브라우저에서 한 손 조작 가능한 목록→상세 흐름으로 만든다. _Modifies: existing waiter, cashier, order workspace, payment web screens and dialogs._
- [ ] **현장 운영 웹 화면 반응형 전환**: 고객 결제 표시, 출퇴근 키오스크, QC 점검/검토, Photo Ops의 촬영·검토·상태 화면을 세로/가로 Phone 브라우저에 맞추고 웹 카메라 권한·키보드·오프라인 상태를 검증한다. _Modifies: existing operational web screens; reuses Toast responsive bodies._
- [ ] **관리·설정 전체 웹 반응형 완성**: Super Admin, Admin 10개 탭, Inventory 11개 화면, Store Setup, Print Station 설정, 매출/적색 세금계산서 내보내기의 실제 데이터·다이얼로그까지 작은 브라우저 화면에 맞춘다. _Modifies: existing management web screens; preserves every current field/column through reflow or horizontal scroll._
- [ ] **웹 접근성 마감**: 모든 대상 화면에서 48dp 터치 영역, 포커스 순서, 키보드 닫기, 스크린리더 레이블, 긴 KO/VI/EN 문자열, 200% 글자 확대와 세로/가로 회전을 검증한다. _Modifies: shared and page-specific web widgets as findings require._

## 비상 데이터·권한 기반

- [ ] **비상 세션과 스테이션 배정 원장 추가**: 매장별 단일 활성 세션, 활성화/종료 감사, 사용자별 `kitchen`/`tray`/`floor` 배정과 floor_label 격리를 additive migration으로 구현한다. _New tables/RPCs; reuses users, user_store_access and audit_logs._
- [ ] **수량 기반 비상 이행 원장 추가**: 세션 내 순차 주문번호, 주문 품목별 주방완료→트레이수령→층발송→층제공 수량, append-only 이벤트와 멱등성 키를 구현하고 단계 수량 제약을 DB에서 강제한다. _New tables/RPCs; reuses orders/order_items without changing their lifecycle status semantics._
- [ ] **활성 세션 주문 동기화 구현**: 비상 활성화 시 열린 주문을 스냅샷하고 이후 신규/추가 주문·취소·수량 변경을 원자적으로 동기화한다. 취소 수량보다 이미 하위 단계 처리된 수량이 많으면 조용히 덮지 않고 정정 필요 상태를 만든다. _New database trigger/RPC slice; depends on the two emergency ledgers._
- [ ] **매장·층 RLS와 동시성 방어**: Super Admin만 활성화/강제 종료할 수 있게 하고, 각 스테이션은 배정 매장·배정 층만 읽고 정해진 단계만 변경하도록 한다. 중복 탭, 재전송, 두 장치 동시 처리 테스트를 통과시킨다. _Modifies/creates RLS and SECURITY DEFINER RPC guards._

## 계정과 라우팅

- [ ] **비상 스테이션 계정 템플릿 추가**: 기존 `bt_kit1`을 유지하고 `bt_tray1`, `bt_floor_1f`, `bt_floor_2f` 고정 계정 요구사항과 일반 매장 short-code 기반 동적 층 템플릿을 추가한다. 빈탄점에는 G층 계정이나 배정을 만들지 않는다. _Modifies: workforce presets, provisioning contracts, approved production account documents; creates assignment during provisioning._
- [ ] **계정별 전용 홈과 대기 게이트 구현**: 로그인한 계정의 스테이션 배정에 따라 주방/트레이/해당 층으로만 이동시키고 비상 모드 OFF에서는 잠금된 대기 화면만 보이게 한다. URL 직접 입력으로 다른 층이나 다른 화면에 접근할 수 없게 한다. _Modifies: auth state/provider, role routes, app router; creates emergency route guard._

## 비상 운영 UI

- [ ] **Super Admin 비상 제어 화면**: 매장 카드에서 장애 사유·열린 주문/품목 수를 확인하고 비상 모드를 켜며, 활성 계정/장치/미제공 수량을 모니터링하고 안전 종료 또는 감사되는 강제 종료를 수행한다. _Modifies: Super Admin store workspace; creates emergency controller service/provider. Depends on emergency session ledger._
- [ ] **주방 태블릿 화면 활성화**: 기존 보존된 `KitchenOperationalScreen`을 기반으로 세션 순차 대기번호 목록과 선택 주문 상세를 Tablet 2열로 만들고 품목 수량을 한 개씩 체크해 전체 완료를 판정한다. Phone을 주 레이아웃으로 설계하지 않고 600–1199dp 세로/가로를 검증한다. _Modifies: kitchen screen/provider; reuses kitchen ticket, alert, realtime and localization components._
- [ ] **트레이 모바일 화면 구현**: 조리 완료 품목을 준비 시각순으로 보여주고 `주방에서 수령`과 `층으로 발송`을 수량 단위로 처리하며 테이블·층·대기번호·추가 주문을 명확히 표시한다. _New `features/emergency_fulfillment/tray_*`; reuses responsive cards, realtime and offline banner._
- [ ] **층별 모바일 화면 구현**: 배정된 한 층의 주문 전체 품목과 현재 위치를 표시하고, 층으로 발송된 수량만 `테이블 제공 완료`로 체크하며 모든 수량이 끝나야 주문확인서를 완료한다. _New `features/emergency_fulfillment/floor_*`; depends on station assignment and fulfillment ledger._
- [ ] **웹 스테이션 주문 알람 구현**: 주방 신규/추가 주문, 트레이 신규 조리완료, 층별 신규 발송 이벤트를 대상으로 전경 Realtime+Web Audio+점멸과 백그라운드 FCM Web Push+Notifications API를 제공한다. `event_id`로 중복을 제거하고 알림 클릭 deep link, `알람 켜기`, 권한/Service Worker 상태와 알람 테스트를 제공한다. _Creates web emergency alert coordinator, `firebase-messaging-sw.js` and station token registration; reuses existing Firebase configuration patterns. Depends on station assignment and fulfillment events._
- [ ] **웹 outbox와 재연결 처리**: 각 스테이션의 탭을 UUID 멱등성 키로 브라우저 IndexedDB에 보관하고 낙관적 상태/동기화 대기/실패를 구분해 표시하며 재연결 시 순서대로 재전송한다. 서버 확인 전 수량은 하위 단계가 처리할 수 없게 한다. _New web emergency sync component; reuses connectivity service and web persistence patterns._

## 캐셔와 프린트 흐름

- [ ] **캐셔 미제공 경고 통합**: 비상 주문 목록·상세·결제 확인창에 `미제공 N` 및 미제공 메뉴/수량을 선택 언어 하나로 표시하고 Realtime로 즉시 해제한다. 경고는 표시하되 기존 결제 RPC를 차단하거나 변경하지 않는다. _Modifies: cashier screen/payment completion/provider; reuses current locale-only menu naming._
- [ ] **프린트 에이전트 비상 보류 구현**: 비상 모드에서 주방/트레이/층별/주문확인서 작업을 claim하지 않게 하고 영수증은 유지한다. 활성화 직전 미처리 운영 작업도 보류해 복구 중 중복 출력되지 않게 한다. _Modifies: print job enqueue/claim contract and print agent runtime; preserves immutable payload and receipt flow._
- [ ] **비상 종료 후 출력 정산 구현**: 디지털 완료 작업은 `비상 처리로 대체`로 감사 종료하고 미완료 작업은 Super Admin이 재출력 또는 감사 종료를 선택하도록 한다. 오래된 티켓의 자동 일괄 출력은 금지한다. _New recovery RPC/UI; depends on emergency controller and print hold states._

## Interactions & States

- [ ] **정정·취소·추가 주문 상태 처리**: 상위 단계만 진행된 품목은 취소/되돌리기를 허용하고, 하위 단계가 확인한 품목은 권한 있는 정정과 사유를 요구한다. 추가 주문은 같은 주문 대기번호 아래 새 배치로 강조한다. _Modifies: emergency RPCs and all three station UIs; covers concurrency, cancellation and supplemental batches._
- [ ] **대기·빈 화면·오류·오프라인 상태 완성**: 비상 OFF, 활성 주문 없음, 권한/배정 없음, Realtime 지연, outbox 대기, 서버 거절, 강제 종료 상태를 각 화면에서 행동 가능한 안내로 표시한다. _Creates shared emergency state presentation; reuses Toast empty/error/status components._
- [ ] **언어와 실제 층 계약 적용**: 모든 스테이션과 캐셔 경고는 현재 선택 언어만 표시한다. 빈탄점의 실제 운영층은 1F/2F이며 G층 변환을 제거한다. 구현 전 DB 테이블·프린터 목적지 preflight로 legacy 저장층을 확인하고 실제 층 배정과 화면 표시를 일치시킨다. _Reuses locale-only item helpers; modifies floor-label mapping only after data preflight._

## Verification & Release Safety

- [ ] **SQL 계약 및 로컬 DB 검증**: migration preflight/verify/rollback을 추가하고 활성화, 단계 순서, 수량 상한, 중복 멱등성, 추가/취소 주문, 매장/층 격리, 강제 종료, 출력 보류/복구를 실제 로컬 Postgres에서 검증한다. _Creates SQL harness tests and production-gate fixtures._
- [ ] **화면별 반응형 회귀 테스트**: 전체 기존 화면과 새 주방/트레이/층별 화면을 실제 데이터로 Phone 390×844·430×932, Tablet 768×1024·1024×768, Desktop 1440×900, 100%/130%/200% 글자에서 검증하고 모든 오버레이를 실제로 연다. _Modifies operational widget/integration coverage; no screenshot-only acceptance._
- [ ] **웹 알람 전달 회귀 테스트**: Chrome/Edge와 Safari 기준으로 전경·백그라운드·탭 복귀·Service Worker 갱신·Realtime 재접속·Push 중복·권한 거부·Web Audio 미활성·토큰 갱신·알람 테스트를 검증한다. 매장/스테이션/층이 다른 계정에는 알림이 전달되지 않아야 한다. _Creates browser notification/service-worker/widget/integration contracts; reuses Firebase web test seams._
- [ ] **다중 계정 E2E 검증**: Super Admin 활성화 → `bt_kit1` 조리 → `bt_tray1` 수령/발송 → 각 `bt_floor_*` 제공 → 캐셔 `미제공` 해제까지 동시에 로그인한 계정으로 검증하고, 비상 OFF에서 모든 계정이 대기 게이트에 막히는지 확인한다. _Extends multi-account integration smoke tests._
- [ ] **기존 기능 불변 검증**: 비상 모드 OFF에서 기존 프린트 작업, 주문 상태 재계산, 결제, 취소/복원, QR 추가 주문, 주방 출력, 트레이 출력, 층별 주문확인서가 기준선과 동일함을 계약 테스트로 고정한다. _Modifies existing print/order/payment regression tests._
- [ ] **최종 웹 저장소 게이트**: 포맷, `flutter analyze`, 전체 Flutter 테스트, Web Service Worker/Push 계약, Node 계약/보안 검사, 실제 Chrome 기반 Flutter Web E2E, 로컬 웹 릴리스 빌드, `git diff --check`를 통과한다. Android/iOS 네이티브 앱 빌드는 수행하지 않고 실제 운영 계정 생성·DB migration 적용·배포는 별도 승인 전 금지한다. _Reuses: `scripts/check_repo.sh`; no deployment._

## Review

- [ ] **운영 시나리오 검토**: 주방·트레이·각 층·캐셔 담당자가 실제 동선으로 눌러보고 용어, 버튼 순서, 수량 처리, 정정 절차를 승인한다.
- [ ] **장애 복구 검토**: 프린터 복구 중 중복 출력, 비상 세션 미종료, 인터넷 단절, 미제공 품목이 남은 결제를 실제 시나리오로 확인한다.
- [ ] **배포 전 독립 검토**: Critical/High/Medium/Low/Confirmed 분류의 독립 회귀 검토를 수행하고 Critical/High 0건일 때만 별도 배포 승인을 요청한다.
