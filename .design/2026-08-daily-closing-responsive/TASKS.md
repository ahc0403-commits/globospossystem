# Build Tasks: 모바일·태블릿 일일 마감 전용 화면

Generated from: `.design/2026-08-daily-closing-responsive/DESIGN_BRIEF.md`
Date: 2026-08-13

## Foundation

- [ ] **현재 일일 마감 회귀 기준 고정**: 기존 desktop 표, Provider 상태, open/closed action, 현금 시재 계산, `create_daily_closing` 호출과 관련 테스트를 먼저 실행해 변경 전 기준을 기록한다. _Reuses as-is: `ReportsTab`, `_DailyClosingSection`, `DailyClosingRecord`, `DailyClosingService`, existing daily-closing tests; no production mutation._
- [ ] **표시와 action 소유 경계 분리**: `_DailyClosingSectionState`에 묶인 조회·마감 실행 흐름을 desktop 표와 compact 전용 화면이 같은 callback/controller로 사용할 수 있게 최소 추출하고, 계산·RPC payload·Provider invalidate 순서는 그대로 보존한다. _Modifies: `lib/features/admin/tabs/reports_tab.dart`; reuses current provider/service; creates no DB abstraction._

## Core UI

- [ ] **compact 일일 마감 진입 카드 구현**: 리포트의 `width < 1080` 및 큰 글자 compact 분기에서 기존 인라인 표를 최근 마감 상태와 `일일 마감 열기` 동작이 있는 카드로 교체하고, desktop 분기에는 영향을 주지 않는다. _Creates a private responsive launcher widget; modifies only the compact composition in `ReportsTab`; reuses app card/button tokens._
- [ ] **앱 내부 전체 화면 진입 구현**: 진입 카드가 `storeId`를 전달해 `Navigator.push(MaterialPageRoute(...))`로 전용 화면을 열고 AppBar·뒤로가기·조회 상태를 제공하도록 한다. _Creates a dedicated daily-closing screen under the admin reports feature; reuses the current authenticated Navigator and provider scope; does not modify `app_router.dart` or role permissions._
- [ ] **Phone 기록 카드 완성**: 날짜별 1열 카드에 상태, 주문, 결제수단, 현금 대사, action을 의미 그룹으로 배치하고 긴 금액/담당자명과 loading/error/empty/open/closed 상태를 처리한다. _Creates responsive record-card presentation; reuses `DailyClosingRecord` and existing action semantics; breakpoint: shortest side <600dp._
- [ ] **Tablet 기록 카드 완성**: 768×1024와 1024×768에서 주문·매출·현금 대사 그룹이 2~3컬럼으로 배치되고 좁아지면 자연스럽게 줄바꿈되도록 한다. _Modifies the new record-card layout using `LayoutBuilder`/`Wrap`; no 15-column row; reuses Phone card content and actions._

## Interactions & States

- [ ] **마감 실행 흐름 연결**: 전용 화면의 open 기록 action이 기존 미리보기→현금 시재 입력→제출→Provider 갱신 흐름을 그대로 실행하고 처리 중 중복 탭과 closed 잠금을 유지한다. _Modifies callback wiring only; reuses current service/RPC and feedback messages._
- [ ] **현금 시재 입력 반응형 마감**: Phone에서는 키보드와 큰 글자에서도 스크롤·제출이 가능한 전체 화면형 입력을 사용하고, Tablet/desktop에서는 현재 최대 폭 다이얼로그를 보존한다. _Modifies `_DailyClosingCashDialog` presentation; reuses denomination fields, keys, arithmetic and submit contract._
- [ ] **복귀와 상태 보존 확인**: 시스템/앱 뒤로가기로 리포트의 선택 기간·스크롤 문맥에 복귀하고, 전용 화면에서 마감 완료 후 양쪽 화면이 같은 최신 기록을 표시하도록 한다. _Reuses Navigator and provider invalidation; creates no persistent navigation state._

## Responsive & Accessibility

- [ ] **기기·방향·큰 글자 검증**: 390×844, 430×932, 768×1024, 1024×768, 1440×900과 100%/130%/200% 글자 크기에서 진입 방식, 그룹 줄바꿈, 버튼, 긴 VND 금액과 담당자명을 확인한다. _Modifies new layout only as findings require; desktop >=1080 remains inline._
- [ ] **현장 조작 접근성 적용**: 진입 카드, 뒤로가기, 날짜 카드, 마감 action에 최소 48dp 터치 영역, Semantics 레이블, 포커스 순서, 색상 외 상태 문구를 제공한다. _Modifies new launcher/screen/card widgets; reuses theme and existing status text._

## Verification & Release Safety

- [ ] **반응형 Widget 회귀 테스트 추가**: 390×844/768×1024/1024×768에서는 launcher만 표시되고 탭 후 전용 화면이 열리는지, 1440×900에서는 기존 inline 표가 유지되는지, 뒤로가기와 overflow 부재를 검증한다. _Creates focused reports daily-closing responsive tests; reuses existing test device-size conventions._
- [ ] **상태·action 테스트 보강**: loading/error/empty/open/closed 기록, 긴 값, 처리 중 중복 탭, cash dialog Phone/Tablet 레이아웃과 기존 row action key 계약을 테스트한다. _Modifies existing daily-closing contract tests only where the presentation boundary intentionally changes; preserves service/model tests._
- [ ] **저장소 검증 실행**: 변경 Dart 파일 포맷, `flutter analyze`, 관련 Widget/contract tests, 전체 `flutter test`, `bash scripts/check_repo.sh`, `git diff --check`를 통과한다. _Reuses project gates; no DB apply and no deployment in this planning task._
- [ ] **운영 배포 전 실데이터 점검**: 로그인된 관리자 계정으로 실제 Phone과 Tablet 세로/가로에서 최근 기록, 미마감일 action, 현금 시재 키보드, 복귀 동작을 확인한다. 이후 별도 배포 요청이 있을 때만 `scripts/deploy_pos_production.sh`를 사용하고 exact pushed head SHA의 GitHub Actions를 확인한다. _Reuses production gate in `CLAUDE.md`; no direct Vercel bypass._

## Review

- [ ] **UX 승인**: 현장 관리자가 Phone 1열 카드와 Tablet 그룹형 카드에서 날짜별 15개 값을 빠르게 찾고 마감 action을 오인하지 않는지 승인한다.
- [ ] **독립 회귀 검토**: 변경이 리포트의 다른 지표, desktop 일일 마감 표, 영업일 계산, 마감 RPC, 권한과 다중 매장 문맥을 건드리지 않았는지 Critical/High/Medium/Low/Confirmed 기준으로 검토한다.
