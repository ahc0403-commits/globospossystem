# Build Tasks: 범용 매출 예측 제품 전체 완성

- 설계 v3 / 2026-09-16 / 38개 실행 단위
- 기준: [DESIGN_BRIEF.md](DESIGN_BRIEF.md),
  [MODEL_DATA_CONTRACT.md](MODEL_DATA_CONTRACT.md),
  [PRODUCT_DELIVERY_CONTRACT.md](PRODUCT_DELIVERY_CONTRACT.md).
- 상태: 1차 소스 구현 완료. 각 T 항목은 전체 수용 기준(실기기·운영·배포 포함)을
  모두 충족한 뒤에만 체크하므로 아직 체크하지 않는다.
- 소스 구현 증거와 남은 범위: [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md)
- 원칙: 모든 UI 작업에 모바일 배치, KO/VI/EN, 권한/오류 상태, 테스트를 함께 넣는다.
  후반의 기기/번역/접근성 작업은 마지막 검증이며 최초 구현을 미루는 항목이 아니다.
- 각 항목은 재사용/수정/신규 요소와 의존성을 명시한다.
  수용 기준을 만족하지 못한 항목은 체크하지 않는다.
- T번호는 이번 v3에서 재배열했다. v2의 번호/의존 목록을 함께 사용하지 않는다.

## A. 먼저 보이는 사용자 경험

- [ ] **T01 — 공통 예측 화면과 매장별 진입·복귀를 만든다.**
  매출 화면/Photo 화면에서 선택 매장·적용 기간을 전달하고 요약/조건/월별/근거를
  fixture로 탐색한다. 레스토랑에만 개선 영역을 제공한다. 직접 URL/새로고침,
  인증·매장 guard와 뒤로 복귀를 연결한다. UX01/UX02 통과.
  _재사용: GoRouter, SalesRevenueAnalyticsScreen, PhotoOpsScreen, PosPageHeader,
  ToastWorkSurface. 신규: ForecastScreen/요약 진입 패널. 의존: 없음._

- [ ] **T02 — 세 언어의 기능 문구와 현지화 기반을 먼저 연결한다.**
  신규 문구를 ARB와 generated AppLocalizations로 관리하고 enum/arguments를 번역한다.
  locale 복원·저장 실패, 키/placeholder 동등성, 숫자·날짜 의미 보존을 검사한다.
  기존 화면의 private 언어 map을 복제하지 않는다. LO01/LO03/LO04 기반 통과.
  _재사용: LocaleController, AppLanguage, intl. 수정: app_en/ko/vi.arb.
  신규: forecast copy/formatter tests. 의존: T01._

- [ ] **T03 — 모바일 우선 기간·목표·운영 폼을 완성한다.**
  320px·200% 글씨·키보드에서 라벨/오류/저장에 접근하게 한다. 전체 높이 편집,
  숫자 키패드·IME·붙여넣기·focus·미저장 표시를 fixture로 확인한다.
  모바일 목록/카드와 넓은 화면 배치를 함께 검증한다. UX03/MO01–MO03 통과.
  _재사용: ToastResponsiveScrollBody, 버튼/폼/토큰.
  신규: ForecastControls, ResponsiveProfileEditor. 의존: T01, T02._

## B. 데이터·운영 조건을 신뢰할 수 있게 연결

- [ ] **T04 — 매출 자료 진단과 조회 품질을 화면에 연결한다.**
  적용 기간의 원본 합계/채널/페이지를 대조하고 완료·0·누락·휴무·당일을 구분한다.
  조회 실패나 기간 밖 이동평균 자료를 0/학습값으로 바꾸지 않는다.
  데이터 진단 결과와 입력 보류 사유를 세 언어로 제공한다.
  _재사용: ReportSummary, DailyRevenue, fetchReportRows, PosDataPanel.
  신규: input adapter/service, ForecastInputQualityPanel. 의존: T01, T02._

- [ ] **T05 — 매장 프로필 저장과 권한을 UI부터 RLS까지 구현한다.**
  업종·revision·유효일·출처를 표시하고 관리자만 저장한다. additive profile 및
  완전성 확인 schema/RPC를 추가한다. storeId/type 변조·권한 밖 읽기/저장을 거절한다.
  실제 거래는 생성/변경하지 않는다.
  _재사용: 기존 매장 capability, ToastStatusBadge.
  신규: profile schema/RPC/service, ProfileHeader/SQL tests. 의존: T04._

- [ ] **T06 — 테이블·층·영업시간의 실제 편집을 완성한다.**
  table/floor/seat를 불러오고 팀 크기·연결·사용 불가 일정·휴게·마감·요일을 편집한다.
  occupied도 자원에 포함하며, 3개 이상 층/누락 좌석/자정 통과/cutoff 충돌을 검증한다.
  모바일에서 항목 추가·수정·삭제 확인까지 가능해야 한다.
  _재사용: PosTable, store_setup_service, T03 폼.
  신규: RestaurantCapacitySettings. 수정: profile validation. 의존: T03, T05._

- [ ] **T07 — 주방·체커·층별 측정 근거를 읽고 설명한다.**
  읽기 전용 aggregate RPC로 단계/층/경로별 표본·coverage·분포를 반환한다.
  undo/취소/중복/미완료를 처리하고 경과시간과 처리능력이 다름을 표시한다.
  계정/프린터 수를 인력으로 오인하지 않는 fixture를 둔다.
  _재사용: paperless 이벤트와 route snapshots.
  신규: evidence RPC, StageEvidencePanel, SQL/adapter tests. 의존: T04, T05._

- [ ] **T08 — 자원·식사·회전의 가정과 근거를 입력한다.**
  실제 작업량/병렬 자원 또는 지속 처리량을 입력하고 공유 resource ID를 검증한다.
  착석→첫 제공→퇴장→정리를 겹치지 않게 분해하고 식사 대용값 한계를 표시한다.
  표본·기간·단위·확인자·필수값 누락을 보여주고 저장한다.
  _재사용: T03 폼, T07 근거 배지.
  신규: ResourceCapacityEditor/TableCycleEditor와 validation. 의존: T06, T07._

## C. 업종별 계산을 화면과 함께 완성

- [ ] **T09 — 회귀 수요와 비교 모델을 설명 가능한 결과로 제공한다.**
  기간·요일 회귀와 동요일 기준을 계산하고 식·계수·합계·고정 단가를 표시한다.
  28개 유효 영업일/요일별 표본, rank, 음수/전부 0/NaN, VND 스케일을 검증한다.
  한도 적용 전 값은 예상 실현 매출이 아니라 수요 추세로 표시한다.
  _신규: demand_regression.dart, ModelExplanationPanel, 수학 tests.
  재사용: T04 데이터와 T02 formatter. 의존: T04._

- [ ] **T10 — 홀 테이블·식사·회전 제약을 계산해 보여준다.**
  시간대 도착과 연속 테이블 예약을 구현하고 팀 크기/table-minutes를 보존한다.
  추가 주문/분할 결제를 새 방문으로 세지 않는다. 10테이블·60분·120분의 20팀,
  30분 경계·마감 fixture로 계산과 설명을 검증한다.
  _신규: restaurant_capacity_engine.dart, CapacityPreview.
  재사용: T08 프로필·T09 수요. 의존: T08, T09._

- [ ] **T11 — 공유 주방·체커의 경합을 반영한다.**
  작업량/병렬 처리와 접수·출고 지연을 구분한다. 체커가 막힌 상황에서 주방만
  늘려도 매출이 늘지 않는 결과를 표시하고 안전시간·무료/재조리 소비를 검증한다.
  _수정: restaurant engine/CapacityPreview.
  신규: resource scheduling/property tests. 의존: T10._

- [ ] **T12 — 다층·음료 직행·배달 경로를 합친다.**
  floor_direct/combos/공유 직원/홀·포장·배달의 실제 경로를 구현한다.
  여러 층의 공용 용량 중복, 배달의 테이블 점유 오류, 인력 이동 중복을 막는다.
  _수정: restaurant engine/CapacityPreview.
  재사용: route snapshot. 신규: 다층·채널 fixture. 의존: T11._

- [ ] **T13 — 레스토랑 월매출·상한·목표를 완성한다.**
  실현 가능한 서비스×단가를 합산하고 이론 상한/운영 가용 한도를 구별한다.
  10억·15억/custom, 완전 월·3개월 유지·윤년·부분 월·상한 충돌을 검증한다.
  모바일 KPI에서도 전체 금액·단위·불가 사유에 접근 가능해야 한다.
  _신규: 월별/목표 result와 KPI. 재사용: PosStatCard/통화 포맷.
  수정: RevenueForecastPanel. 의존: T12._

- [ ] **T14 — Photo 기기와 신고 품질 입력을 연결한다.**
  실제 기기 수·시간·중단을 확인하고 8분/85,000동을 읽기 전용으로 표시한다.
  transaction-service 의미·수동 신고·명시적 0을 검증한다. observed machines를
  설치 수로 확정하지 않는다. 레스토랑 입력이 섞이지 않게 한다.
  _신규: PhotoCapacitySettings/PhotoInputAdapter.
  재사용: PhotoOpsService와 T03/T05. 의존: T03, T05._

- [ ] **T15 — Photo 회수 회귀·한도·목표를 완성한다.**
  회수 수요를 8분 스케줄에 배정하고 유료 완료 기대 회수×85,000을 계산한다.
  무료 회수의 용량 소비, 환산 회수 표시, 12시간 90회/765만동을 검증한다.
  응답/화면 어디에도 개선 제안을 생성하지 않는다.
  _신규: photo_forecast_engine.dart, PhotoForecastResult/tests.
  재사용: T09 회귀와 T13 공통 KPI. 의존: T09, T13, T14._

## D. 레스토랑 개선과 신뢰도

- [ ] **T16 — 회전·주방·체커 단독 개선 카드를 제공한다.**
  동일 수요/가격에서 정리·조리·체커 변화를 재계산한다. 추가 용량과 추가 매출,
  다음 병목, 실행조건, 품질 보호·비용 미반영을 함께 보여준다.
  _신규: restaurant_scenario_engine.dart, ImprovementComparisonPanel.
  재사용: restaurant engine, PosDataPanel/배지. 의존: T13._

- [ ] **T17 — 층별 제공·식사·영업시간 개선을 제공한다.**
  인력 이동의 원래 층 손실, 비식사 대기 축소, 새 시간대 수요/정책 제한을 검증한다.
  순수 식사 강제 단축을 기본 추천하지 않고 미분리 자료는 측정 필요로 표시한다.
  _수정: scenario engine/비교 카드. 재사용: 일정/자원 근거.
  신규: 층 이동·대기 중첩·시간 연장 tests. 의존: T16._

- [ ] **T18 — 공동 병목·복합 효과와 목표 변화를 비교한다.**
  관련 두 영역을 함께 재계산한다. 단독 0→복합 양수와 효과 중복을 시험하고,
  미측정 후보를 확정 순위에서 분리한다. 실제 운영 정책을 변경하지 않는다.
  _수정: scenario engine/비교. 신규: 조합·순위 tests. 의존: T17._

- [ ] **T19 — 과거 검증·장기 시나리오·범위를 설명한다.**
  fold 내부 가격/메뉴/시간대만 사용해 rolling-origin 오차를 비교한다.
  자료 부족·포화·현재 프로필 소급·장기 외삽을 밝히고 시나리오 범위와 통계 구간을
  구분한다. 근거 없이 95% 범위를 붙이지 않는다.
  _신규: forecast_validation.dart, ValidationDetails/tests.
  재사용: 기존 차트/배지. 의존: T13, T15._

## E. 모바일 사용성과 모든 상태를 끝까지 연결

- [ ] **T20 — 차트·월별 목록·상세 수치를 모든 입력 방식에 제공한다.**
  실적/예측/한도 범례, tap/키보드 tooltip, 월별 접근 가능한 표/목록을 완성한다.
  24개월 시각 샘플링은 표시만 바꾸고 금액은 동일 snapshot에서 읽는다.
  tooltip 경계/큰 글씨/긴 번역과 MO04를 검증한다.
  _재사용: fl_chart, PosTableShell. 신규: ForecastMonthlyList/ChartDetail.
  수정: 공통 결과 패널. 의존: T13, T15, T19._

- [ ] **T21 — 모바일 개선 비교·조건 편집을 실사용 형태로 다듬는다.**
  표를 축소하지 않고 현재→변경→효과 카드로 전환한다. 펼침/비교 선택·근거·주의를
  큰 글씨에서도 읽을 수 있고 화면 회전 후 상태가 유지되어야 한다.
  _수정: ImprovementComparisonPanel와 profile editor.
  재사용: Toast layout/토큰. 신규: 비교 responsive/golden tests.
  의존: T18, T20._

- [ ] **T22 — 전체 로딩·빈 상태·오류·보류 상태를 완성한다.**
  제품 계약의 상태 표를 모두 구현하고 필드 오류·재시도·다음 행동을 제공한다.
  미계산을 0으로 표시하거나 비활성 이유를 숨기지 않는다. 취소·연타를 검증한다.
  _재사용: PosEmptyState, PosExceptionAlert, ToastStatusBadge.
  신규: typed UI states/실패 fixture. 의존: T05, T18, T19._

- [ ] **T23 — 실행 중 언어 전환의 전 영역을 검증·수정한다.**
  여섯 방향 전환에서 열린 폼/오류/tooltip/semantics까지 바뀌고 값·draft·모델 결과는
  유지되어야 한다. 초기 복원·저장 실패·숫자 입력 모호성·긴 번역을 검사한다.
  _수정: localization bindings/필요 최소 controller 경계.
  재사용: AppLocalizations, i18n_locale_contract_test.
  신규: LO01–LO05 동적/widget tests. 의존: T20, T21, T22._

- [ ] **T24 — 뒤로가기·재진입·앱 수명주기를 완성한다.**
  앱/브라우저 Back·새로고침·재로그인·미저장 이탈·background 복귀를 검증한다.
  draft 보존/폐기 정책을 적용하고 권한·원천 버전을 재확인한다.
  _수정: route/provider/lifecycle. 재사용: 기존 auth/history.
  신규: UX01/UX02/UX04/ST03 여정 tests. 의존: T22, T23._

- [ ] **T25 — 네트워크 장애와 취소 복구를 구현한다.**
  offline/timeout/429/일시적 서버 오류에 제한된 재시도와 지연 안내를 제공한다.
  최신성 경고·세션 내 draft·취소 token·dispose를 처리하고 지연 응답을 무시한다.
  _수정: forecast service/provider. 신규: failure injection/ST02/ST04 tests.
  재사용: 오류/상태 패널. 의존: T24._

- [ ] **T26 — 프로필 동시 편집·저장 결과 불확실성을 해결한다.**
  expected revision/operation ID를 서버와 UI에 연결한다. 충돌 비교·다시 로드·명시적
  재적용을 제공하고 응답 유실 후 먼저 저장 결과를 조회한다. 중복 revision을 막는다.
  _수정: profile RPC/service/editor. 신규: SQL concurrency/ST05 tests.
  재사용: ToastConfirmDialog. 의존: T05, T25._

- [ ] **T27 — 권한 회수·캐시·로그 보호를 종단간 확인한다.**
  매출/관리/export capability별 UI·route·RPC를 시험한다. 매장 전환/로그아웃/권한
  회수 시 민감 내용을 제거하고 URL/로그/오류에서 비밀·매출 원문을 제외한다.
  _수정: guard/provider/export gate. 신규: SE01–SE03 tests.
  재사용: 기존 auth/RLS. 의존: T26._

## F. 파일과 사용자 인계

- [ ] **T28 — 예측 전용 XLSX와 결과 재현 정보를 제공한다.**
  실적/예측/조건/품질을 분리하고 언어·기간·모델·profile snapshot을 고정한다.
  Photo 개선 시트 없음, 숫자 셀·Unicode·시트명·수식 주입 방지를 검증한다.
  _신규: forecast_export.dart/tests. 재사용: 기존 excel/다운로드 adapter.
  수정: export UI. 의존: T19, T23, T27._

- [ ] **T29 — 모바일 웹·앱의 파일 저장·취소·실패를 완성한다.**
  Safari/Chrome/Android/iOS의 생성→전달→저장/열기를 확인한다. void 반환만으로
  실제 디스크 저장 완료를 단정하지 않는다. locale/매장 변경과 임시 자원 해제를 시험한다.
  _신규: forecast file-result adapter/EX01–EX03 통합 tests.
  재사용: ReportExcelFileSaver, core PlatformInfo. 의존: T28._

- [ ] **T30 — 세 언어 도움말·측정 안내·운영 대응을 제공한다.**
  최초 설정/자료 부족/수요 대 용량/추가 매출 대 이익/Photo 고정 기준을 안내한다.
  입력 담당 역할·버전 수정·오류 코드·파일 확인·복구 절차를 운영 자료에 정리한다.
  _신규: ForecastHelp 및 운영 안내. 재사용: ARB/기존 도움말 UI 패턴.
  수정: 품질/오류 다음 행동 링크. 의존: T22, T29._

## G. 출시 증거를 만드는 검증

- [ ] **T31 — 자동 접근성·키보드 검증을 통과한다.**
  Semantics, 라벨/단위, focus 순서·복귀·가림, 키보드 trap, 버튼 크기, 대비를 검사한다.
  웹 semantics DOM의 자동 결과와 Flutter tests의 범위를 구분한다.
  _수정: 필요한 신규 UI 접근성. 신규: AC01/자동 AC02·AC03 tests.
  재사용: framework focus/semantics primitives. 의존: T20, T21, T30._

- [ ] **T32 — 보조기술 실사용 검증과 사용자 영향을 해소한다.**
  VoiceOver/TalkBack/NVDA와 200%/400% 확대·고대비·reduced motion·음성/스위치로
  전체 여정을 시험한다. 가능하면 관련 사용자 검토를 진행하고 참여 여부를 기록한다.
  _재사용: 모든 feature UI. 신규: AC01–AC04 수동 증거/결함 목록.
  수정: 발견된 접근 차단. 의존: T31._

- [ ] **T33 — 플랫폼별 성능·취소·메모리 예산을 충족한다.**
  참조 fixture/장치/망에서 release/profile p50/p95를 측정한다. 웹 compute만으로
  비차단을 가정하지 않고 yield/필요한 실행 adapter를 구현한다. 20회 반복 자원 누적을 본다.
  _신규: performance harness/PE01–PE02 증거. 수정: calculator 실행 adapter.
  재사용: 동일 순수 모델. 의존: T25, T29._

- [ ] **T34 — 반응형·폰트·번역·실기기 행렬을 통과한다.**
  지정 폭/경계·가로세로·분할·IME·safe area·세 언어·실제 지원 테마를 확인한다.
  golden뿐 아니라 모바일 웹/앱·데스크톱에서 동작을 검증하고 번역 의미를 검수한다.
  _신규: MO01–MO05/LO05/RG02 증거. 수정: 결함 있는 feature UI/문구.
  재사용: 기존 theme/font와 widget fixture. 의존: T23, T29, T32, T33._

- [ ] **T35 — 매장별 데이터 대조와 운영자 UAT를 완료한다.**
  레스토랑(다층·배달)과 Photo에서 실제 입력·실적·처리량을 대조하고 목표/개선/
  오류 복구/파일을 담당자가 확인한다. 가정과 미검증 수치를 분리한다.
  _재사용: 실제 보고서/paperless/Photo 수동 신고. 신규: F/C/P/T/U 및 제품 행렬
  UAT 기록, OP01 확인. 의존: T30, T34._

- [ ] **T36 — 코드·DB·기존 기능 회귀와 배포 전 gate를 완료한다.**
  gen-l10n, 변경 Dart format, analyze, 계산/SQL/RLS/widget/export/integration,
  flutter test, check_repo 및 대상 web/native build를 검증한다. migration 누락/구앱·신앱
  혼합도 시험한다. 기존 사용자 변경/실패를 구분하고 exact SHA 필수 CI를 확인한다.
  _재사용: 기존 scripts/tests/workflows. 신규: RG01/OP02 및 preflight 증거.
  수정: 이번 기능의 차단 결함. 의존: T35._

- [ ] **T37 — 승인된 절차로 단계적 공개와 복구를 검증한다.**
  승인 후 공식 production script만 사용하고 DB 적용/웹 배포/앱 배포를 구분한다.
  feature 비활성화/직전 앱 복귀를 확인하며 원장·프로필을 삭제하지 않는다.
  _재사용: deploy_pos_production.sh와 기존 release gate.
  신규: 승인·SHA·배포·복구 기록. 의존: T36. 현재 계획 단계 실행 금지._

- [ ] **T38 — 배포 후 실제 사용 확인과 최종 인계를 끝낸다.**
  레스토랑/Photo·모바일/데스크톱에서 언어·권한·조회·계산·파일 smoke를 수행한다.
  초기 1영업일 오류/지연을 확인할 담당 역할과 기록을 갖추고 잔여 이슈를 인계한다.
  _재사용: 운영 화면·진단 코드·runbook. 신규: G6 운영 확인 및 최종 상태표.
  의존: T37. 실제 검증 전에는 운영 완료 표시 금지._

## 추적표와 최종 완료 조건

| 필수 영역 | 주된 작업 | 검증 근거 |
| --- | --- | --- |
| 계산·운영 제약 | T04–T19 | MODEL_DATA_CONTRACT의 29개 F/C/P/T/U 사례 |
| 탐색·UI·상태 | T01/T03/T20–T26 | UX01–UX05, ST01–ST05 |
| 모바일 | T03/T21/T24/T29/T34 | MO01–MO05, EX02 |
| 언어 | T02/T23/T28/T30/T34 | LO01–LO05 |
| 권한·보안 | T05/T26/T27 | SE01–SE03 |
| 접근성 | T31/T32 | AC01–AC04 |
| 파일 | T28/T29 | EX01–EX03 |
| 성능 | T33 | PE01–PE02 |
| 회귀·인계·출시 | T30/T35–T38 | RG01–RG02, OP01–OP02, G0–G6 |

각 결과는 PASS/FAIL/BLOCKED/NOT RUN으로 기록하고 소스 SHA, 장치/OS/브라우저,
locale, 자료/프로필 버전, 재현 절차, 증거 위치를 남긴다.
계획 체크박스나 문구만으로 PASS를 만들지 않는다.

모든 필수 작업과 행렬이 충족되고 CRITICAL/HIGH 및 핵심 여정 차단 MEDIUM이 해소되어야
“이 기능 완료”로 보고한다. 일부 환경이 미검증이면 해당 사실과 영향을 남기고 전체 완료로
확대하지 않는다. 기존 원장/결제/MISA/Office/Photo 수동 신고는 변경하지 않는다.
