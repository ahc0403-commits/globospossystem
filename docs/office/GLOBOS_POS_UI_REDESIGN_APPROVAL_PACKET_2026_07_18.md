# GLOBOS POS 전 화면 UI 재설계 승인 패킷

상태: **DRAFT — 시각 방향 승인 전, 구현 금지**  
작성일: 2026-07-18  
범위: Flutter POS, Admin, Super Admin의 모든 라우트, 중첩 탭, 다이얼로그, 시트, 운영 상태

## 0. 문서 지위와 변경 금지선

이 문서는 새로운 디자인 시스템이나 source of truth가 아니다. 다음 단일 기준을 실제 GLOBOS POS 화면에 적용하기 위한 **감사 결과, 시각 방향 승인안, 격차 목록, 구현 순서**다.

- Governing authority: [TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md](TOAST_OPERATIONAL_UI_SOURCE_OF_TRUTH.md)
- Workflow contract: [ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md](../pos/ONE_WORKFLOW_PER_SCREEN_POS_PRIMARY_JOB_CONTRACT.md)
- Acceptance gate: [OFFICE_OPERATIONAL_UI_ACCEPTANCE_CHECKLIST.md](OFFICE_OPERATIONAL_UI_ACCEPTANCE_CHECKLIST.md)

아래 항목은 전 단계에서 변경하지 않는다.

- 비즈니스 로직과 업무 의미
- 라우트, 인증, 권한, 역할별 접근
- Riverpod provider와 상태 소유권
- Supabase 호출, RLS, RPC, 저장 계약
- 결제, 할인, 분할 결제, 증빙, 전자세금계산서 동작
- 계산, 통화, 재고, 주문, 주방 상태 전이
- 프린터, 카메라, 키오스크 등 하드웨어 통합
- i18n 키와 계약

변경 대상으로 승인받을 항목은 정보 위계, 셸과 내비게이션 구성, 화면 밀도, 공통 Flutter Material 3 표현, 상태 피드백, 터치·키보드 접근성뿐이다.

## 1. 감사 방법과 증거 신뢰도

### 1.1 사용한 세 스킬

- `ui-ux-pro-max`: 정확히 다음 질의로 권고안을 생성했다. `F&B restaurant POS operational system professional minimal light high-contrast touch-first data-dense Vietnamese`
- `audit-design-vs-code`: 캡처 화면과 Flutter 구현을 양방향으로 비교했다.
- `browser:control-in-app-browser`: 현재 로컬 Flutter Web을 1440×900, 1024×768, 390×844로 직접 실행·캡처했다.

`ui-ux-pro-max` 원출력 중 채택한 내용과 제외한 내용은 다음과 같다.

| 처리 | 내용 | 이유 |
|---|---|---|
| 채택 | Flat/Minimal operational UI, 고대비 light, 단일 blue accent, 4/8dp 리듬, 48dp 터치, 명시적 상태, 표·리스트 우선 | governing authority와 Flutter POS 운영 환경에 부합 |
| 채택 | 선형 차트는 시간 추세, 막대 차트는 카테고리 비교, 표 대체 수단과 직접 라벨 제공 | 리포트의 즉시 판독성과 접근성 개선 |
| 채택 | 안전 영역, 예측 가능한 back, 아이콘 라벨, 폼 라벨, 동적 상태 안내 | 모바일·키오스크·접근성에 적용 가능 |
| 제외 | Minimal Single Column/landing page/CTA 중심 구성 | 운영 큐 중심 POS와 충돌 |
| 제외 | 다크 팔레트 | light-first 기준과 충돌 |
| 제외 | Plus Jakarta Sans | 기존 Pretendard 고정 조건과 충돌 |
| 제외 | React, CSS, Tailwind, GSAP 및 웹 전용 구현 | Flutter Material 3 범위 밖 |

`--persist`는 사용하지 않았고, 별도 디자인 시스템 파일도 생성하지 않았다.

### 1.2 증거 등급

| 등급 | 의미 |
|---|---|
| L | 2026-07-18 현재 코드로 직접 실행한 live browser screenshot |
| R | 저장소에 보존된 실제 실행 screenshot; 캡처일을 함께 표기 |
| C | 현재 Dart 코드, 라우터, 토큰, 프리미티브에 대한 정적 감사 |
| M | 인증 또는 특정 하드웨어·데이터 조건 때문에 현재 live 재캡처가 아직 없는 상태 |

R 등급은 시각 증거로 유효하지만, 현재 코드와 차이가 생겼을 수 있다. 따라서 R에서 발견된 결함은 현재 코드의 C 증거가 함께 있을 때만 확정 결함으로 분류하고, 나머지는 구현 전 재확인 항목으로 분리한다.

### 1.3 대표 캡처

- [현재 로그인 desktop 1440×900](../../screenshots/ui_audit_2026_07_18/01-login-desktop-1440x900.png) — L
- [현재 로그인 mobile 390×844](../../screenshots/ui_audit_2026_07_18/02-login-mobile-390x844.png) — L
- [현재 로그인 tablet 1024×768](../../screenshots/ui_audit_2026_07_18/03-login-tablet-1024x768.png) — L
- [Waiter](../../screenshots/pos-terminal-after-01-waiter-2026-06-11.png) — R, 2026-06-11
- [Cashier](../../screenshots/pos-terminal-after-02-cashier-2026-06-11.png) — R, 2026-06-11
- [Kitchen](../../screenshots/pos-terminal-after-03-kitchen-2026-06-11.png) — R, 2026-06-11
- [Admin Tables](../../screenshots/pos-terminal-after-04-admin-tables-2026-06-11.png) — R, 2026-06-11
- [Inventory Purchase](../../screenshots/pos-terminal-after-05-inventory-2026-06-11.png) — R, 2026-06-11
- [QC employee mobile](../../screenshots/qsc_mobile/final_employee_qsc_input_after_loading_fix.png) — R, 2026-05-17
- [QC supervisor mobile](../../screenshots/qsc_mobile/final_sv_review_list.png) — R, 2026-05-17

### 1.4 승인용 목표 화면 시안

다음 이미지는 2026-07-18에 생성한 방향 승인용 bitmap mockup이다. 픽셀 단위 구현 명세나 별도 디자인 시스템이 아니며, 이 문서의 governing authority와 변경 금지선을 시각화한다.

- [QR 고객 메뉴 탐색](assets/ui_redesign_concepts_2026_07_18/01-qr-menu-vietnamese.png)
- [QR 고객 주문 검토](assets/ui_redesign_concepts_2026_07_18/02-qr-order-review-vietnamese.png)
- [QR 고객 주문 접수 완료](assets/ui_redesign_concepts_2026_07_18/03-qr-order-success-vietnamese.png)
- [Waiter 테이블 queue/select](assets/ui_redesign_concepts_2026_07_18/04-waiter-queue-selected.png)
- [Cashier 결제 execution](assets/ui_redesign_concepts_2026_07_18/05-cashier-payment-execution.png)
- [Kitchen queue/execution](assets/ui_redesign_concepts_2026_07_18/06-kitchen-queue-execution.png)
- [Admin Inventory 발주 queue/select](assets/ui_redesign_concepts_2026_07_18/07-admin-inventory-purchase.png)

QR 시안에는 현재 `QrOrderMenu`, `QrMenuItem`, `QrOrderResult` 계약이 제공하는 store/table/floor/category/name/description/price/quantity/order code/batch만 사용했다. 음식 이미지, modifier, coupon, online payment, live kitchen tracking처럼 현재 계약에 없는 기능은 추가하지 않았다.

---

# Deliverable 1 — Screenshot 기반 전 화면 감사

## 2. 전체 인상 요약

현재 화면은 색상과 기본 타이포그래피보다 **구조와 일관성** 때문에 개발 중인 시스템처럼 보인다.

잘된 기반은 명확하다.

- Pretendard, Material 3, light canvas, dark text, blue accent가 이미 존재한다.
- Waiter, Cashier, Kitchen의 큰 방향은 queue → select → act에 가깝다.
- Admin의 사이드바 그룹, selected tint, 상태색은 학습 가능한 기반이 있다.
- 숫자용 tabular figure 토큰, surface role, touch state 토큰이 추가돼 있다.

전문성을 깎는 핵심은 다음 다섯 가지다.

1. 거의 모든 화면이 `큰 제목 + 4개 KPI 박스 + 여러 흰 카드` 템플릿으로 반복되어 실제 업무 우선순위가 흐려진다.
2. 동일 역할의 UI가 화면마다 다른 크기, radius, 상태 표현, 빈 상태, 로딩 표현을 쓴다.
3. desktop은 지나치게 작고 mobile은 지나치게 큰 밀도로 변해 하나의 제품이 아니라 별도 구현처럼 보인다.
4. 비어 있는 화면이 넓은 공백만 제공하고, 현재 상태·다음 행동·마지막 동기화 정보가 부족하다.
5. 34/44/46dp 제어, 색상만 있는 상태점, 직접 노출된 영문·오류문, 화면 잘림이 신뢰감을 떨어뜨린다.

## 3. 우선순위별 전역 발견 사항

### P0 — 승인 후 공통 기반에서 먼저 해결

| ID | 발견 사항 | 증거 | 영향 | 방향 |
|---|---|---|---|---|
| G-01 | 48dp 터치 계약이 동시에 34, 44, 46, 48로 구현됨 | `pos_design_tokens.dart:199, 253-260`, `app_theme.dart:248-260`, `app_nav_bar.dart:154-179`, `toast_sidebar.dart:581-586` | 주문·결제·주방에서 오작동 위험, 제품 일관성 저하 | 모든 interactive hit area를 최소 48dp로 통일. 시각 아이콘은 작아도 hit box는 48dp |
| G-02 | 동일 목적의 토큰·프리미티브가 중복되고 일부 이름이 의미와 다름 | `AppColors.amber500`이 blue accent를 가리킴; 두 metric strip과 여러 empty/loading primitive 공존 | 새 화면마다 다른 구현 선택, 스타일 drift | 새 색을 만들지 않고 기존 active token으로 alias를 수렴. deprecated 호환 심벌은 신규 화면에서 금지 |
| G-03 | 화면별 explicit accessibility 증거가 매우 적음 | `lib/features`+`lib/widgets` 68,329 LOC에서 `Semantics/Tooltip/Focus` 명시 사용 5건 | Material 기본 semantics만으로 복합 카드·custom InkWell·상태 변화 보장 불가 | label, role, selected, enabled, live update, focus order를 공통 primitive 계약에 포함 |
| G-04 | 시작 설정 오류가 `runApp` 전에 throw되어 사용자 오류 화면이 없음 | 실제 첫 실행 blank; `main.dart:16-50`, `app_constants.dart:31-48` | 운영 단말 설정 문제 시 흰 화면으로 보여 신뢰 손상 | 비즈니스 초기화는 유지하되 bootstrap error surface 계약을 정의. 구현은 별도 승인 후 |
| G-05 | 화면 로컬 스타일과 inline overlay가 대규모로 분산 | overlay 관련 정적 hit 224개; 실제 `showDialog`/`showModalBottomSheet`/`showGeneralDialog` 진입점 63개 | dialog/sheet가 서로 다른 크기·버튼 순서·위험 표현을 가질 가능성 | overlay 역할을 confirm/form/detail/critical/step sheet로 표준화하고 진입점별 시각 회귀 캡처 |

### P1 — 핵심 운영 화면

| ID | 발견 사항 | screenshot/코드 증거 | 영향 | 방향 |
|---|---|---|---|---|
| O-01 | POS 상단의 back/home/forward가 브라우저 크롬처럼 보임 | Waiter/Kitchen/Admin 캡처; authority가 browser-like POS chrome을 금지 | 제품 정체성 약화, 핵심 작업보다 탐색이 먼저 보임 | back는 업무 맥락에만 노출, home/store/language는 utility cluster로 축소. 라우트 동작은 유지 |
| O-02 | Waiter desktop은 테이블 선택 전 오른쪽 절반이 빈 패널, mobile은 상세 맥락이 사라짐 | Waiter desktop/mobile 캡처 | 선택 전에는 공백, 선택 후에는 화면 전환 규칙이 불명확 | desktop split pane, mobile drill-in을 같은 작업 모델로 명시. 빈 sidecar에는 다음 행동과 상태 설명 |
| O-03 | Kitchen은 큐는 좋지만 카드 안 정보와 오른쪽 설명 패널이 함께 과밀 | Kitchen 캡처 | 지연 티켓과 다음 조리 액션의 시선 경쟁 | ticket age/priority/action만 1차, 도움말·통계는 접힌 secondary detail |
| O-04 | Cashier empty state가 큰 공백을 차지하며 last sync/refresh/why-empty가 없음 | Cashier desktop/mobile 캡처 | 단말이 정상인지, 네트워크 문제인지 판단 어려움 | 정상 empty, filtered empty, offline stale, load error를 별도 표현 |
| O-05 | 결제의 dominant amount/action보다 상단 메트릭과 chrome이 먼저 읽힐 수 있음 | Cashier desktop 캡처, `cashier_screen.dart` | 고위험 결제에서 다음 행동 인지가 느림 | 선택 후 amount due → payment method → confirm을 고정 action zone에 배치 |
| O-06 | QC mobile은 큰 카드와 큰 글자 때문에 한 화면에 처리 가능한 정보가 너무 적음 | QC mobile employee/supervisor 캡처 | 반복 점검 작업의 스크롤·탭 비용 증가 | 16px body, compact section row, sticky progress/action, 사진 요구를 행 단위로 명시 |

### P1 — Admin/Back Office

| ID | 발견 사항 | screenshot/코드 증거 | 영향 | 방향 |
|---|---|---|---|---|
| A-01 | Dashboard/KPI-first 구성이 Inventory와 Reports의 첫 화면을 지배 | Admin inventory/report 캡처 | governing authority의 queue-first와 직접 충돌 | 처리 큐·예외·선택 업무를 먼저, 지표는 얇은 supporting strip 또는 분석 탭으로 이동 |
| A-02 | Admin 화면 대부분이 동일한 카드 헤더를 반복해 서로 다른 업무의 성격이 사라짐 | Tables/Menu/Staff/Attendance/Settings/E-Invoice 캡처 | template-generated 인상, 다음 행동 모호 | 각 탭의 primary job에 맞춰 queue, editor, review, configuration 패턴을 선택 |
| A-03 | Inventory는 두 단계 sidebar와 11개 업무가 한 거대 surface에 묶임 | Inventory 캡처; 관련 파일 6,716/7,135 LOC | 탐색 부담, 서로 다른 업무·대화상자·상태가 혼합 | catalog, purchase, receiving, count, analysis를 동일 shell 안의 명확한 work step으로 분리. 라우트/권한은 유지 |
| A-04 | 행마다 강한 빨간 `중지/삭제` 버튼이 반복 노출됨 | supplier/product/recipe 캡처 | 위험 액션이 primary action처럼 보이고 오탭 위험 | 기본 행에는 overflow/secondary action, destructive는 상세·확인 단계에서만 danger 강조 |
| A-05 | Settings는 작은 편집 폼 주위에 과도한 빈 공간, category cards는 별도 제품처럼 보임 | Settings 캡처 | 정보량과 surface 크기가 맞지 않음 | narrow form width, sticky save status, category rail/accordion의 선택 상태 통일 |
| A-06 | Admin mobile에서 많은 탭을 single dropdown으로 축약하고, inventory mobile에는 top horizontal + bottom nav가 중복 | `toast_sidebar.dart:170-321`, inventory mobile 캡처 | 현재 위치와 IA 이해가 어려움, 라벨 잘림 | 역할 그룹을 보존하는 section switcher + 현재 업무 title. top/bottom 중 하나만 primary navigation |

### P2 — 시각 품질·콘텐츠·증거 보강

| ID | 발견 사항 | 증거 | 방향 |
|---|---|---|---|
| V-01 | Login desktop/tablet의 brand panel은 좋지만 mobile에서 제품·매장 신뢰 문맥이 완전히 사라짐 | L 캡처 3종 | mobile에도 compact brand mark, secure-workspace copy, 도움 경로를 유지 |
| V-02 | 한 화면의 작은 10–13px label과 mobile의 28–40px title 사이 격차가 큼 | theme/sidebar 코드, 캡처 | 최소 body 14, control label 13–14, page title 24–28 범위로 좁힘. Vietnamese diacritic line-height 검증 |
| V-03 | 상태 점만으로 table availability를 표시하는 곳이 있음 | Waiter/Admin tables 캡처 | 색각 이상·저시력 사용자는 상태 해석이 어려움 | 점 + 짧은 label/shape 또는 accessible name을 항상 결합 |
| V-04 | 과거 실행 캡처에 raw English와 직접 오류가 보임 | QC `Failed to load follow-ups.`, Delivery `No settlements` | i18n 계약은 유지하되 이미 존재하는 키로 오류 구조·표현 일관화. 누락 키는 별도 i18n 결함으로 분류 |
| V-05 | Reports 캡처에 Flutter overflow indicator가 남아 있음 | `admin-composite-sidebar-04-reports-2026-05-18.png` | R 증거이므로 현재 live에서 재검증. 모든 breakpoint golden에 overflow 0 조건 추가 |
| V-06 | 상태와 action chip이 너무 많이 한 줄에 나열돼 시선 소음 발생 | Staff, Delivery, QC, Inventory | 항상 보일 정보는 status 1개+primary action 1개. 보조 metadata와 드문 action은 detail/overflow |

## 4. 현재 구현 규모와 drift 위험

다음 수치는 비즈니스 복잡도를 평가한 것이 아니라, 시각 통일을 screen-local 수정만으로 달성하기 어려운 지점을 찾기 위한 것이다. `local style hits`는 `TextStyle`, `BoxDecoration`, `EdgeInsets`, 직접 `Color` 사용의 줄 수이며, `a11y hits`는 명시적 `Semantics/Tooltip/Focus`, `shared state hits`는 공통 empty/loading/offline primitive 사용 수다.

| Surface | LOC | Local style hits | A11y hits | Shared state hits | Overlay hits |
|---|---:|---:|---:|---:|---:|
| Inventory Purchase | 7,135 | 53 | 0 | 0 | 51 |
| Admin Inventory | 6,716 | 191 | 0 | 0 | 23 |
| Cashier | 3,165 | 41 | 0 | 4 | 26 |
| Reports | 2,785 | 59 | 0 | 4 | 0 |
| Order Workspace | 2,532 | 51 | 1 | 6 | 6 |
| Super Admin | 2,422 | 48 | 1 | 0 | 4 |
| Kitchen | 2,394 | 46 | 0 | 5 | 4 |
| Admin QC | 2,367 | 49 | 0 | 0 | 12 |
| Settings | 2,118 | 29 | 0 | 0 | 14 |
| E-Invoice | 2,114 | 21 | 0 | 2 | 3 |
| Tables | 1,960 | 30 | 0 | 3 | 14 |
| Staff | 1,814 | 37 | 0 | 3 | 11 |
| Waiter | 1,456 | 9 | 1 | 3 | 17 |

해석:

- 큰 화면부터 직접 스타일만 바꾸면 중복이 늘어난다. 먼저 공통 계약을 정리해야 한다.
- `a11y hits 0`은 반드시 “접근 불가”를 뜻하지 않는다. Material 위젯의 기본 semantics가 있을 수 있다. 다만 custom composite와 동적 상태의 명시적 증거가 부족하다는 뜻이다.
- `overlay hits`는 dialog/sheet 관련 builder, action, style까지 포함한 정적 감사 hit이며 실제 overlay 개수와 같지 않다. 현재 실제 show entry point는 63개다.
- overlay가 많은 화면은 일괄 치환이 아니라 진입점별 업무 의미를 유지하며 시각 wrapper만 통일해야 한다.

## 5. 라우트와 화면별 감사 매트릭스

### 5.1 Auth/Public/Role routes

| Surface | 증거 | Primary job 유지 | 주요 시각 결함 | 승인 후 target pattern |
|---|---|---|---|---|
| `/login` | L+C | 인증 후 역할 workspace 진입 | mobile brand context 소실, startup error 별도 surface 없음 | compact trust panel + focused form + explicit validation/loading/error |
| `/privacy-consent` | C+M | 필수 개인정보 동의 | 긴 법률 문맥, accept/decline hierarchy·scroll completion 재확인 필요 | readable document pane + sticky explicit actions |
| `/onboarding` | C+M | super admin의 첫 store 설정 | step loading/error 및 완료 후 next context 재확인 필요 | short stepper + progress + resumable error |
| `/qr/:token` | C+M | 고객 QR 주문 | token invalid/expired/offline/cart state의 시각 계약 분산 | guest-focused menu/cart, invalid/expired/retry 상태 명시 |
| `/super-admin` | C+M | store 선택·운영 범위 관리 | 2,422 LOC, mixed monitoring/config risk | store queue → selected store → scoped action → detail |
| `/restaurant-sales-export` | C+M | 기간·store 선택 후 export | empty/loading/export progress/error 계약 보강 필요 | filter bar + preview summary + single export action |

### 5.2 Live operational routes

| Surface | 증거 | Primary job 유지 | 주요 시각 결함 | 승인 후 target pattern |
|---|---|---|---|---|
| `/waiter` | R+C | 테이블 선택/서비스 계속 | 빈 sidecar, browser chrome, color-dot 상태 | responsive floor/list queue + explicit selected context |
| `OrderWorkspace` take | R+C | 선택 테이블에 item 입력 | menu/cart/history/action 경쟁 가능 | menu browser + unsent cart + sticky review action |
| `OrderWorkspace` review/send | C+M | 주문 확인 후 kitchen 전송 | 일반 order console로 확장될 위험 | focused review list + validation + send/back |
| `/kitchen` queue | R+C | 다음 ticket 결정 | helper panel/metric/ticket 정보 경쟁 | age-prioritized lanes + compact ticket summary |
| `/kitchen` execution | R+C | 선택 ticket item 진행 | queue와 selected execution의 focus 충돌 | selected ticket focus panel + explicit item actions |
| `/cashier` queue | R+C | 다음 결제 order 선택 | empty state가 정상/오류/오프라인을 구분하지 않음 | payable queue + amount/status + last sync |
| `/cashier` execution | C+M | 선택 order 결제 완료 | amount/action dominance와 26 overlay drift 위험 | amount anchor + methods + safe confirm + supporting actions |
| `/payments/:paymentId` | R+C | 한 결제/증빙/invoice 검토 | raw diagnostic가 기본 노출될 위험 | status-first summary + linked evidence + collapsed diagnostics |
| `/print-station` | C+M | 인쇄 queue 처리 | hardware unavailable/offline/retry 상태 재캡처 필요 | print queue + printer health + retry/cancel action |
| `/attendance-kiosk` | C+M | 출퇴근 capture | native camera 전용, permission/device/offline 상태 필요 | full-screen single action + camera permission/recovery |
| `/qc-check` | R+C | 오늘의 점검 입력 | mobile 세로 과밀, section label 품질 | compact checklist + progress + sticky save/submit |
| `/qc-review` | R+C | supervisor review | 큰 카드, badge 과다, 반복 primary button | review queue + evidence sidecar/sheet + one decision action |
| `/photo-ops` | C+M | 요구 사진 작업 처리 | capture/upload/retry/offline 상태 계약 보강 | photo task queue + capture status + upload progress |

### 5.3 Admin shell와 10개 탭

| Surface | 증거 | Primary job 유지 | 주요 시각 결함 | 승인 후 target pattern |
|---|---|---|---|---|
| `/admin`, `/admin/:storeId` shell | R+C | 올바른 관리 work area 이동 | mobile dropdown, browser chrome, 두 단계 nav 중복 가능 | grouped rail/section switcher + store context + one content title |
| Tables | R+C | layout config 또는 monitor | 두 mode가 동일 화면에서 경쟁 | explicit mode switch; config canvas와 monitor queue 분리 |
| Menu | R+C | category/item config 또는 live availability | config와 sold-out 관리 job 혼합 | category queue + selected menu editor; availability는 명시 mode |
| Staff | R+C | staff directory/profile | attendance/permission/activate가 한 detail에 과밀 | staff list + selected profile; exception review 별도 step |
| Reports | R+C | 기간별 performance 이해 | KPI-first, 과거 overflow, closing 혼합 | filter → chart/table → export; closing은 별도 work step |
| Attendance | R+C | attendance record/exception review | payroll/unlock context 경쟁 | exception-first list + selected log; payroll는 별도 step |
| Inventory | R+C | 선택 inventory step 완료 | giant mixed tab, duplicated inventory surfaces | work-step nav + selected task surface; 아래 11개 흐름 유지 |
| QC | R+C | template/review/follow-up 중 하나 수행 | 세 job이 같은 page에 있고 raw error 노출 | explicit work-step switch + queue-first child surface |
| Settings | R+C | 선택 config 편집 | 빈 공간, category card hierarchy, save status 부족 | category rail + constrained form + sticky save state |
| Delivery settlement | R+C | unsettled/disputed item 처리 | metric/alert/card/English empty 혼합 | exception queue + selected settlement + confirm/dispute |
| E-Invoice | R+C | invoice exception 해결 | 빈 화면이 과대하고 raw ref 위험 | issue queue + selected status + derived next action |

### 5.4 Inventory 중첩 work step

저장소 캡처와 현재 코드에서 확인한 inventory work step은 다음과 같다. 별도 디자인 언어를 만들지 않고 Admin shell과 동일한 queue/select/act/detail 규칙을 쓴다.

| Work step | Screenshot | 현재 인상 | target |
|---|---|---|---|
| Dashboard | [R](../../screenshots/inventory-purchase-dashboard-final-qa-2026-05-16.png) | KPI-first, quick menu 중심 | 오늘 처리할 risk/PO/receipt queue 우선 |
| Stock status | [R](../../screenshots/inventory-purchase-stock-status-final-qa-2026-05-16.png) | 읽기 쉬우나 행 선택·detail 약함 | sortable stock table + selected product sidecar |
| Purchase management | [R](../../screenshots/inventory-purchase-purchase-management-final-qa-2026-05-16.png) | 생성 action 3개가 동등, table+adjust list 중복 | recommendation queue → adjust → generate PO |
| Purchase history | [R](../../screenshots/inventory-purchase-purchase-history-final-qa-2026-05-16.png) | table와 반복 list가 같은 데이터 중복 | one list/table + selected PO detail/action |
| Supplier management | [R](../../screenshots/inventory-purchase-supplier-management-final-qa-2026-05-16.png) | destructive red 반복 | supplier queue + detail; stop는 guarded action |
| Product management | [R](../../screenshots/inventory-purchase-product-management-final-qa-2026-05-16.png) | status/action chip 과밀 | product list + selected editor + overflow |
| Recipe management | [R](../../screenshots/inventory-purchase-recipe-management-final-qa-2026-05-16.png) | 긴 flat list, delete 반복 | menu → ingredient mapping sidecar, bulk-safe hierarchy |
| Consumption analysis | [R](../../screenshots/inventory-purchase-consumption-analysis-final-qa-2026-05-16.png) | 여러 empty panel이 dashboard처럼 병렬 | date/filter → trend/table; empty는 하나의 설명으로 통합 |
| Cost analysis | [R](../../screenshots/inventory-purchase-cost-analysis-final-qa-2026-05-16.png) | metric-first, table는 좁게 사용 | cost exception table + comparison/detail |
| Physical stock count | [R](../../screenshots/inventory-purchase-stock-audit-final-qa-2026-05-16.png) | 입력 전 read-only table, 진행 상태 모호 | count session progress + row input + variance confirm |
| New menu registration | [R](../../screenshots/inventory-purchase-new-menu-registration-final-qa-2026-05-16.png) | stepper는 좋으나 현재 step action이 약함 | persistent step progress + current form + guarded next/back |

## 6. Overlay 감사

현재 Dart 코드에서 `showDialog`, `showModalBottomSheet`, `showGeneralDialog` 진입점 63개를 확인했다. 별도 modal 파일과 inline `AlertDialog`/`Dialog` 구현을 포함해, 구현 전 각 진입점을 아래 다섯 역할 중 하나로 분류하고 업무 callback과 mutation은 그대로 둔다.

| 역할 | 포함 surface | 감사 결론 |
|---|---|---|
| Transaction supporting dialog | Cashier discount, payment proof, red invoice, split/correction, receipt | 결제 완료에 필요한 supporting action이므로 cashier 안에 유지. amount와 confirm hierarchy를 침범하지 않게 함 |
| Manager authorization/confirm | PIN, cancel, deactivate, destructive inventory actions | 위험 설명, 대상명, 되돌릴 수 있는지, cancel/confirm 순서, processing lock 필요 |
| Form dialog | table/menu/staff/settings/inventory add/edit | desktop dialog, mobile full-height sheet로 같은 필드 순서 유지. validation summary와 sticky action 필요 |
| Detail/evidence overlay | payment/QC/photo/PO/receipt/audit detail | 기본 queue를 가리지 않는 sidecar 또는 sheet. raw diagnostic는 접어서 제공 |
| Step/bulk operation | inventory purchase/receiving/count/new menu | 진행 단계, 저장 여부, 이탈 경고, retry가 명시돼야 함 |

집중 대상 show entry point:

- Inventory Purchase 11
- Cashier 10
- Admin Inventory, Staff, Tables, Waiter 각 4
- Menu, Admin QC, Settings, Super Admin 각 3
- QC Check, QC Review, Order Workspace 각 2
- Attendance, E-Invoice, Kitchen, Customer QR, PIN 각 1

`ToastConfirmDialog`가 이미 있지만 모든 overlay가 이를 사용하지 않는다. 무조건 치환하지 않고 destructive/transaction/form/detail 역할을 먼저 판별한다.

## 7. 모든 상태 감사

### 7.1 공통 상태 계약

| State | 반드시 보여야 할 것 | 금지 |
|---|---|---|
| Loading | 무엇을 불러오는지, 부분 skeleton 또는 compact progress, 장기 지연 시 설명 | 화면 중앙의 의미 없는 작은 점, 전체 화면 무기한 spinner |
| Empty-normal | 정상적으로 0건이라는 제목, 다음 데이터가 생기는 조건, 가능한 action | 거대한 빈 흰 패널만 표시 |
| Empty-filtered | filter 때문에 0건임, filter 초기화 | 정상 empty와 같은 문구 |
| Error | 사용자 언어의 설명, 영향 범위, retry, 필요한 경우 support code | raw exception/영문 오류 직접 노출 |
| Disabled | label은 읽히고, 왜 비활성인지 tooltip/helper/semantics 제공 | opacity만 낮춰 의미를 숨김 |
| Offline | 연결 상태, stale/queued/blocked 구분, 마지막 동기화, 가능한 action | 일반 disabled와 동일 표현 |
| Selected | 배경+border+label/icon+semantics selected | 색상만 변경 |
| Destructive | 대상과 결과, guarded confirm, processing 중 중복 방지 | row마다 solid red primary button 반복 |
| Processing | action label 변화, spinner, input lock, 중복 제출 방지 | 버튼이 사라지거나 화면만 멈춤 |
| Success | 완료된 대상, 다음 안전 행동, 자동 사라지는 보조 toast | 색만 green으로 바뀌고 결과가 불명확 |

### 7.2 현재 공통성 판단

- Loading/empty primitive가 `App*`, `Pos*`, `Toast*`로 여러 벌 존재한다.
- `OfflineBanner`는 Admin, Attendance Kiosk, Cashier, Kitchen, Print Station, Waiter에 보이지만 나머지 route에는 동일한 명시적 계약이 확인되지 않았다.
- selected, disabled, processing, destructive, offline-blocked 토큰은 이미 존재하나 화면별 채택이 고르지 않다.
- 현재 live 로그인에는 validation/error/loading/disabled 캡처가 없으므로 구현 시작 전 상태별 screenshot fixture가 필요하다.

---

# Deliverable 2 — 통합 시각 방향

## 8. 승인 제안: “Quiet Operational Console”

이 명칭은 새로운 디자인 시스템 이름이 아니라, governing authority를 화면에 적용할 때의 시각적 설명이다.

목표 인상:

- 전문적: 회계·결제·재고 수치가 안정적으로 정렬되고 화면이 흔들리지 않는다.
- 신뢰 가능: 상태, 동기화, 위험, 저장 결과가 숨지 않는다.
- 즉시 이해: 3초 안에 `해야 할 일 → 선택 → 다음 행동`을 찾는다.
- touch-first: 장갑·바쁜 환경에서도 48dp target과 8dp 간격을 지킨다.
- data-dense: 같은 정보를 카드로 크게 늘리지 않고 표·행·split pane으로 압축한다.
- Vietnamese-ready: Pretendard를 유지하고 긴 단어·성조·VND 숫자·날짜가 잘리지 않는다.

## 9. 화면 위계

모든 surface의 시선 순서는 다음 하나로 통일한다.

1. **Operational context**: 역할, 매장, 현재 업무, 연결 상태
2. **Queue**: 지금 처리할 항목과 우선순위
3. **Selected context**: 선택한 table/ticket/order/employee/exception
4. **Action zone**: 다음 안전 행동 1개, 필요한 경우 최대 2개
5. **Optional detail**: history, raw ID, diagnostics, analytics

Metric은 queue를 설명할 때만 얇게 보인다. metric 자체가 첫 화면의 목적이 되지 않는다.

## 10. 기존 토큰에 대한 시각 매핑

새 팔레트를 추가하지 않는다. 아래 existing token을 canonical role로 사용한다.

| Role | Existing token | 적용 |
|---|---|---|
| Canvas | `ToastColorTokens.canvas` / `canvasAlt` | 앱 배경, 스크롤 canvas |
| Operating surface | `PosSurfaceRole.operating` / `ToastColorTokens.surface` | queue, table, floor, form work area |
| Selected | `PosSurfaceRole.selected` / `selectedRow` | 선택 행·ticket·table |
| Primary action | `ToastColorTokens.accent` / `accentStrong` | 한 surface의 dominant action |
| Success | `success` / `successMuted` | 완료·online·ready |
| Warning | `warning` / `warningMuted` | 대기·주의·검토 필요 |
| Danger | `danger` / `dangerMuted` | 실패·파괴·차단 |
| Info | `info` / `infoMuted` | 중립 운영 안내 |
| Disabled | `PosSurfaceRole.disabled` | 사용 불가, 이유를 함께 표시 |
| Processing | `PosSurfaceRole.processing` | transaction lock, 저장 중 |

원칙:

- accent는 action과 selection에만 사용한다.
- semantic color는 상태 의미에만 사용한다.
- 카드마다 임의 pastel을 만들지 않는다.
- 색상은 항상 text/icon/badge/shape 중 하나와 함께 쓴다.

## 11. Typography와 숫자

- Font family: 기존 Pretendard만 사용.
- Page title: 24–28dp, 700–800.
- Section title: 18–20dp, 700.
- Body: 14–16dp, 400–600, line-height 1.4–1.5.
- Control label: 13–14dp, 600–700. 10–11dp는 badge 보조값 이외 사용 금지.
- Money/elapsed/quantity: 기존 `PosNumericText`의 tabular figure 사용.
- VND/₫/₩ 표기는 기존 i18n·calculation output을 바꾸지 않고 정렬·간격만 통일.
- KO/EN/VI에서 200% text scale, 긴 매장명, 긴 메뉴명, 성조가 있는 Vietnamese를 캡처한다.

## 12. Density, spacing, touch

- 기본 리듬: 4dp micro, 8dp control gap, 16dp section, 24/32dp major separation.
- 모든 interactive hit target: 최소 48×48dp.
- 인접 destructive/primary target: 최소 8dp separation.
- Desktop row: 기본 48–56dp. 복합 두 줄 행은 64dp 내외.
- Mobile: 카드를 키우는 대신 row를 56–72dp로 유지하고 detail은 drill-in/sheet로 보낸다.
- Radius는 existing 8/10/14/16/20 중 역할별로 제한한다. 같은 화면에서 모든 radius를 섞지 않는다.
- Shadow는 modal/selected elevated sidecar처럼 depth가 필요한 곳에만 사용한다.

## 13. Responsive composition

별도 mobile/kiosk 디자인 언어를 만들지 않는다. 같은 job model을 공간에 맞게 재배치한다.

| Width | Composition |
|---|---|
| ≥1200 | queue + selected work + optional sidecar의 2–3 pane |
| 720–1199 | queue + selected work 2 pane, detail은 drawer/sheet |
| <720 | queue 먼저, 선택 시 drill-in; sticky action; grouped section switcher |

Admin mobile에서 10개 기능을 모두 bottom navigation에 놓지 않는다. 현재 역할의 그룹과 선택 work step만 보이고, 전체 이동은 명시적인 section switcher에서 한다.

## 14. Component behavior 방향

- Page header: title, 한 줄 purpose, status/primary action만.
- Metric strip: 최대 2–4개, queue 보조. 작은 화면에서는 1열 카드 4개가 아니라 compact 2열/행.
- Queue row/ticket: identifier, urgency, 핵심 amount/time, selected state, next action.
- Sidecar: selected summary와 supporting action. 선택 전에는 empty guidance.
- Forms: label은 항상 보이고 placeholder로 대체하지 않음. validation은 field+summary.
- Dialog/sheet: 제목에 대상 포함, cancel은 왼쪽/secondary, confirm은 오른쪽/primary, destructive는 danger.
- Tables: sticky header, 숫자 우측 정렬, status text+badge, row action은 overflow/selected detail.
- Empty/error/offline: 공통 상태 계약을 사용하고 queue context를 유지.
- Navigation: 업무 이동과 browser history control을 시각적으로 분리.

## 15. Motion과 feedback

- 120–180ms의 짧은 Material transition만 사용.
- pressed feedback은 즉시, processing은 label+spinner로 유지.
- layout shift, bounce, decorative entrance animation은 사용하지 않는다.
- reduce motion 환경에서는 non-essential transition 제거.
- GSAP 및 web animation 권고는 적용하지 않는다.

## 16. Chart와 analytics

- trend: line chart, 직접 라벨 또는 hover 없이도 읽을 수 있는 요약.
- category/channel: sorted horizontal bar.
- stacked/pie는 카테고리가 적고 part-to-whole이 핵심일 때만 제한적으로 사용.
- 모든 chart는 동일 데이터를 읽을 수 있는 table 또는 summary를 제공.
- red/green만으로 비교하지 않고 label, marker, pattern을 결합.

---

# Deliverable 3 — Component/Token Gap Analysis

## 17. Token gap

| Gap | 현재 | 목표 | 우선순위 |
|---|---|---|---|
| Touch size | `touchTargetMin=48`, `PosMetrics.touchTarget=44`, button 44/46, nav 34/46 혼재 | active minimum 48 하나로 수렴; compact는 visual size만 축소 | P0 |
| Color namespace | `ToastColorTokens`, `PosColors`, `PosTerminalColors`, `AppColors` 공존 | `ToastColorTokens`/`PosSurfaceRole`가 active. legacy alias는 신규 사용 금지 | P0 |
| Misleading alias | `AppColors.amber500` → blue accent | 신규 코드에서 semantic `accent` 사용; alias는 호환만 | P0 |
| Dark legacy | `PosTerminalColors.dark*`, `paymentPad=darkShell` 존재 | dark를 baseline으로 사용하지 않음; 실제 필요한 terminal contrast는 authority 승인 아래 제한 | P1 |
| Typography | 10.5 sidebar group/badge, 12 label, 46px button | operational minimum scale와 Vietnamese line-height 규칙 고정 | P0 |
| Surface roles | 좋은 active role이 있으나 adoption 불균일 | background/operating/action/selected/danger/disabled/processing만 화면에서 선택 | P0 |
| Responsive | screen-local breakpoint와 nav fallback | 세 composition 범위와 동일 job model | P1 |
| Focus/semantics | custom composite의 명시적 토큰·계약 부족 | focus ring, selected semantics, live region, traversal behavior | P0 |
| Chart | 화면별 chart presentation 규칙이 분산 | 기존 semantic colors를 쓰는 line/bar/table contract | P2 |

## 18. Component gap

새 widget 이름을 이 문서에서 source of truth로 고정하지 않는다. 승인 후 기존 `Toast`/`Pos` primitive 중 하나를 canonical implementation으로 선택하거나 확장한다.

| Behavior contract | 기존 자산 | Gap |
|---|---|---|
| Operational shell | `ToastShell`, `ToastSidebar`, `ToastTopbar` | browser-like nav, mobile section IA, 48dp 일관성 |
| Queue/list | `ToastOperationalQueuePane`, `ToastDenseList`, `PosListRow`, `PosTicketCard` | selected/priority/action slot의 일관된 semantics |
| Split/sidecar | `ToastSplitPane`, `PosSplitContent`, `PosInspectorPanel` | breakpoint와 empty-selected guidance 통일 |
| Metric | `ToastMetricStrip`, `ToastMetricItemStrip`, `PosStatCard` | 중복 제거, supporting-only weight, 최대 개수 |
| Empty | `AppEmptyState`, `PosEmptyState`, `ToastOperationalEmptyState` | normal/filter/error/offline의 의미 구분과 action slot |
| Loading | `AppLoadingView`, `ToastOperationalLoadingState`, raw spinner | skeleton/partial loading, long wait, accessibility announcement |
| Error | `AppErrorState`, `ErrorToast`, inline text | user-language structure, retry, support code, section/full-screen variant |
| Offline | `OfflineBanner`, `PosTouchStateTokens.offlineBlockedOpacity` | stale/queued/blocked, last sync, per-action reason |
| Action | `PosPrimaryButton`, `PosSecondaryButton`, `ToastActionButton`, `PosActionButton` | 48dp, primary budget, processing/disabled reason |
| Destructive | `PosDestructiveButton`, `ToastConfirmDialog` | repeated row danger 제거, target/result/undo 가능 여부 |
| Dialog/sheet | global DialogTheme + 224 overlay-related static hits / 63 show entry points | role taxonomy, mobile sheet, width/scroll/sticky actions |
| Table | `ToastDenseDataTable`, `PosTableShell`, `PosDataGridRow` | sticky header, numeric alignment, row selection/action overflow |
| Form | Material InputDecoration + screen-local forms | persistent label, validation summary, save status, keyboard order |
| Photo/file | QC/Photo/Proof implementations | camera permission, upload progress, offline queue, retake consistency |
| Hardware | Print/Attendance primitives | device unavailable, permission, disconnected, retry guidance |

## 19. 구현 시 금지할 패턴

- 새 active 디자인 시스템 문서 또는 별도 팔레트 생성
- screen-local color/radius/typography로 새 표준 발명
- KPI/card-heavy dashboard를 첫 화면으로 사용
- 모든 업무를 bottom nav에 나열
- icon-only action에 accessible name이 없음
- row마다 solid destructive button 반복
- placeholder를 field label로 사용
- 정상 empty, filter empty, offline, error를 같은 화면으로 처리
- UI 정리를 이유로 provider, callback, mutation, route, permission을 이동하거나 변경
- React/CSS/Tailwind/GSAP 코드를 Flutter 작업에 도입

---

# Deliverable 4 — 화면별 구현 순서

## 20. 순서 원칙

화면 파일 순서가 아니라 **공통 계약 → 저위험 shell → 핵심 운영 → 고위험 transaction → 복합 back office** 순서로 진행한다. 각 phase는 screenshot diff, state matrix, 48dp, KO/EN/VI, keyboard/touch, 기존 test를 통과해야 다음으로 간다.

## 21. Phase 0 — 승인·baseline·비회귀 장치

구현 전 필수:

1. 이 문서의 시각 방향 승인.
2. 인증된 현재 데이터로 모든 protected route의 desktop/tablet/mobile baseline 캡처.
3. 각 surface의 primary job, primary action, secondary detail을 테스트 checklist로 고정.
4. loading/empty/error/disabled/offline/selected/destructive fixture 또는 재현 절차 작성.
5. callback/provider/route/permission/Supabase 호출 checksum 또는 characterization test 확보.

Deliverable: 코드 변경 없는 baseline packet. 현재 단계가 여기에 해당한다.

## 22. Phase 1 — active token과 공통 state/action 수렴

대상:

- `app_theme.dart`, `pos_design_tokens.dart`
- Toast/Pos shell, action, queue, table, state, dialog primitive
- `AppNavBar`, `ToastSidebar`, `OfflineBanner`

순서:

1. 48dp conflict 제거.
2. active semantic token과 legacy compatibility 경계 명시.
3. selected/disabled/processing/destructive/offline behavior 정규화.
4. empty/loading/error variants와 accessibility contract.
5. dialog/sheet role wrappers와 responsive behavior.

첫 적용 범위는 Phase 2 QR에 필요한 token, action, state, responsive shell만으로 제한한다. 이 단계에서 저장소 전체 legacy symbol을 일괄 치환하거나 63개 overlay 진입점을 한 번에 옮기지 않는다. QR 수직 슬라이스에서 실제 사용성과 회귀 검증을 통과한 contract만 후속 phase에 확장한다.

비회귀: visual only. callback signature와 mutation은 변경하지 않는다.

## 23. Phase 2 — Customer QR ordering, 최우선

1. QR 진입, store/table/floor 확인, menu category와 item 탐색.
2. 수량 조정과 sticky cart summary.
3. 기존 confirm dialog를 명확한 주문 검토 단계로 표현.
4. 주문 접수 성공, order code/batch/item 확인, 추가 주문.
5. invalid/expired/payment-in-progress/unavailable/rate-limit/network retry.
6. loading/empty/disabled/offline/processing과 중복 제출 방지.
7. KO/EN/VI, Vietnamese diacritic, VND, 긴 메뉴명, 200% text scale.

고정: `qr_get_menu`, `qr_place_order`, token, client order id, item/quantity, payment-at-cashier 계약. 음식 이미지, modifier, coupon, online payment, live kitchen tracking처럼 현재 계약에 없는 기능은 추가하지 않는다.

## 24. Phase 3 — Auth/Public

1. Login desktop/tablet/mobile + validation/loading/error.
2. Privacy consent document/action state.
3. Onboarding step states.

목적: QR에서 검증한 form/state/responsive 계약을 역할 workspace 진입 화면에 확장.

## 25. Phase 4 — Waiter와 OrderWorkspace

1. Waiter table queue/floor, selected table, mobile drill-in.
2. Guest count/staff meal/PIN/transfer/cancel overlay 시각 통일.
3. Order taking composition.
4. Order review/send composition.
5. Offline queued/blocked/send retry.

고정: order callbacks, quantity semantics, kitchen send, PIN permission, table status 계산.

## 26. Phase 5 — Kitchen

1. Kitchen queue lanes와 delay priority.
2. Selected ticket execution.
3. item start/ready/ticket ready processing/disabled state.
4. offline/stale/empty/error.

고정: item/ticket 상태 전이와 kitchen provider.

## 27. Phase 6 — Cashier와 Payment

1. Cashier payment queue.
2. Cashier payment execution amount/method/action zone.
3. Discount modal.
4. Payment proof modal.
5. Red invoice modal.
6. split/correction/cancel/receipt/retry inline dialogs.
7. Payment detail route.
8. transaction processing, duplicate-block, offline, failed/retry, success.

고정: payment behavior와 Non-Split Rule. supporting action은 결제 화면에서 제거하지 않는다.

## 28. Phase 7 — Device/Field workflows

1. Print Station queue/device status/retry.
2. Attendance Kiosk camera permission/capture/offline.
3. Photo Ops task/capture/upload/retry.
4. QC Check checklist/progress/photo/memo/submit.
5. QC Review queue/evidence/decision/follow-up.

고정: native capability guards와 hardware integration.

## 29. Phase 8 — Admin shell와 기본 관리 탭

1. Admin shell desktop/tablet/mobile, grouped navigation/store context.
2. Tables mode split, floor/list, add/edit dialogs.
3. Menu category/list/editor/availability mode and dialogs.
4. Staff queue/profile/add/edit/activate/deactivate dialogs.
5. Settings category/form/save/test/PIN/printer dialogs.

고정: 역할별 tab visibility, store scoping, permission.

## 30. Phase 9 — Admin exception/review tabs

1. Attendance review와 exception detail.
2. Admin QC template/weekly review/follow-up work steps.
3. Delivery settlement queue/detail/confirm/dispute.
4. E-Invoice exception queue/detail/retry/portal.

고정: approval, settlement, invoice lifecycle와 권한.

## 31. Phase 10 — Inventory 전체

다음 순서로 공통 table/form/overlay 패턴을 재사용한다.

1. Stock status.
2. Product management.
3. Supplier management.
4. Recipe management.
5. Physical stock count.
6. Purchase recommendation/management.
7. Purchase history/PO detail/print.
8. Receiving/receipt confirmation 및 관련 dialogs.
9. Consumption analysis.
10. Cost analysis.
11. New menu registration stepper.
12. Dashboard를 “오늘의 inventory work queue”로 재구성.

각 work step마다 Inventory Purchase 11개와 Admin Inventory 4개의 현재 show entry point를 역할별로 하나씩 검증한다. 계산·단위·PO·receipt·inventory mutation은 변경하지 않는다.

## 32. Phase 11 — Reports, Super Admin, Export, closure

1. Reports period analysis/chart/table/export.
2. Daily closing work step을 report 분석과 시각적으로 분리.
3. Super Admin store queue/selected store/detail.
4. Restaurant Sales Export filter/progress/result.
5. 모든 route와 overlay의 KO/EN/VI, text scale, keyboard/touch, responsive screenshot.
6. `flutter analyze`, 전체 `flutter test`, 관련 integration/smoke test.
7. [OFFICE_OPERATIONAL_UI_ACCEPTANCE_CHECKLIST.md](OFFICE_OPERATIONAL_UI_ACCEPTANCE_CHECKLIST.md) 전 항목 증거 첨부.

## 33. 각 화면의 완료 정의

각 route, nested tab, dialog/sheet는 다음을 모두 만족해야 완료다.

- 3초 안에 primary job과 next safe action을 찾을 수 있음.
- queue → select → act → optional detail 순서가 시각적으로 유지됨.
- dominant action은 최대 2개이며 destructive는 기본 dominant가 아님.
- 최소 48dp target, keyboard focus, semantics label/selected/enabled 상태가 있음.
- loading, normal empty, filtered empty, error, disabled, offline, selected, destructive, processing이 명시적임.
- KO/EN/VI와 200% text scale에서 overflow 없음.
- mobile은 같은 job model의 drill-in이고 별도 디자인 언어가 아님.
- 기존 business logic, route, permission, provider, Supabase, payment, calculation, hardware, i18n contract diff가 없음.

## 34. `think_A` 압박 검토 결론

### 34.1 문제를 다시 정의

이 작업을 하지 않으면 기능 자체가 즉시 중단되지는 않는다. 그러나 다음 운영 손실이 계속 누적된다.

- QR 고객은 메뉴 탐색, 주문 확인, 접수 여부를 확신하기 어렵고, 이는 주문 포기·중복 제출·직원 호출로 이어진다.
- Waiter, Kitchen, Cashier는 하루 수십~수백 번 같은 화면을 사용하므로 작은 위계·터치·상태 불일치가 교육 비용과 오조작 위험으로 증폭된다.
- Admin, Inventory, Closing, E-Invoice는 빈도는 낮아도 한 번의 잘못된 destructive/transaction action의 영향이 크다.
- loading, empty, offline, error가 비슷하게 보이면 정상 0건과 장애를 구분하지 못해 제품 전체의 신뢰도가 낮아진다.

따라서 핵심 문제는 “화면이 덜 예쁘다”가 아니라 **업무 위계와 상태 계약이 화면마다 달라 사용자가 다음 안전 행동을 즉시 확신하지 못한다**는 것이다. 해결책은 새 플랫폼이나 새 디자인 시스템이 아니라, 기존 Flutter Material 3·Pretendard·POS token·Toast primitive를 단일 운영 규칙에 맞게 수렴시키는 것이다.

### 34.2 실제 사용자와 사용 빈도

| 사용자 | 대표 surface | 빈도/위험 | 계획상 우선순위 |
|---|---|---|---|
| QR 고객 | 메뉴, 주문 검토, 접수 완료, invalid/expired/offline | 주문마다 사용, 첫 인상과 매출에 직접 영향 | 최우선 수직 슬라이스 |
| Waiter | 테이블 queue, 주문 입력/검토/전송 | 매우 빈번, 빠른 터치와 오프라인 중요 | QR 다음 |
| Kitchen | ticket queue, item execution | 매우 빈번, 시간·우선순위 오독 위험 | Waiter 다음 |
| Cashier | 결제 queue/execution, proof, invoice | 매우 빈번, 금액·중복 결제 위험이 가장 큼 | 운영 패턴 검증 후 별도 고위험 gate |
| Field/QC | 인쇄, 출퇴근, 사진, 점검/검토 | 장치·권한·오프라인 실패 경로가 핵심 | 운영 화면 다음 |
| Admin/Manager | 설정, 예외 검토, 정산, 전자세금계산서 | 중간 빈도, 권한·파괴 작업 위험 | shell 안정화 후 |
| Inventory/Reports/Super Admin | 재고 12단계, 분석, 마감, store scope | 낮은~중간 빈도, 데이터량·multi-tenant 영향 큼 | 후반 고복잡도 묶음 |

## 35. 접근법 비교

| 평가 | A. 전 화면 big-bang 재작성 | B. 공통 primitive 전면 정리 후 화면 적용 | C. 최소 기반 + QR 수직 슬라이스 + 위험도별 확장 |
|---|---|---|---|
| Build 복잡도 | 매우 높음 | 높음 | 중간 |
| Operate 복잡도 | 전환 시 매우 높음 | 중간 | 낮음~중간 |
| 되돌리기 | 어려움 | 중간 | phase/PR 단위로 쉬움 |
| Blast radius | 모든 route·role 동시 | 모든 공통 consumer | 해당 수직 슬라이스로 제한 |
| Supabase/schema 비용 | 원칙상 0이지만 회귀 탐지가 어려움 | 0 | 0, 명시적 gate |
| 첫 usable 결과 | 가장 늦음 | 늦음 | QR에서 가장 빠름 |
| 시각 일관성 | 완료 시 높지만 중간 검증 불가 | 높음 | 검증된 contract를 확장해 높음 |
| 과설계 위험 | 매우 높음 | primitive 추상화 과잉 위험 | 실제 화면으로 contract를 검증해 낮음 |
| 권고 | 기각 | 단독 방식으로 기각 | **채택** |

접근법 C를 채택한다. 다만 “수직 슬라이스”는 QR만 예쁘게 별도 구현한다는 뜻이 아니다. QR에 필요한 최소 token/state/action/responsive contract를 먼저 만들고, 승인된 contract를 Waiter 이후 모든 route와 중첩 surface에 재사용한다.

## 36. 압박 테스트와 방어선

| 공격/실패 조건 | 첫 방어 | 통과 증거 |
|---|---|---|
| UI 정리 중 callback/provider 의미가 바뀜 | 기존 callback signature, provider watch/read 위치, mutation 호출을 이동하지 않고 presentation 경계만 교체 | phase 전후 characterization/contract test, 기능 smoke |
| QR 중복 주문 또는 token 실패가 예쁜 화면에 가려짐 | client order id, submit lock, invalid/expired/rate-limit/network 상태를 별도 fixture로 검증 | 중복 탭, slow network, retry screenshot+test |
| multi-tenant store scope 누출 | `storeId`/token/role scope 전달을 변경하지 않고 selected store context를 항상 표시 | admin deep-link·role parity·RLS 기존 test 유지 |
| Cashier 시각 변경이 결제 의미를 바꿈 | amount/method/confirm 위계만 변경하고 Non-Split Rule과 payment mutation은 고정 | payment method/split/adjustment/receipt/proof/invoice contract tests |
| 10× queue/table 데이터에서 화면 정지·정보 붕괴 | provider query·pagination·sorting 의미를 유지하고 dense row/table, bounded pane, lazy detail 사용 | 10× fixture에서 scroll, selection, frame/overflow 확인 |
| KO/EN/VI 또는 긴 Vietnamese에서 잘림 | 기존 i18n key를 유지하고 3개 언어, 긴 매장·메뉴명, VND, 200% text scale 캡처 | breakpoint별 overflow 0, semantics label 확인 |
| offline/stale/queued/blocked가 같은 상태로 보임 | 공통 offline contract로 마지막 동기화와 가능한 action을 구분 | 각 상태 screenshot과 action-enabled assertion |
| camera/printer가 없는 환경에서 dead end | 기존 platform/capability guard 유지, unavailable/permission/retry surface만 개선 | 지원/미지원 platform fixture와 기존 hardware contract tests |
| 공통 primitive 변경이 미이관 화면까지 깨뜨림 | 기존 호환 API 유지, 한 phase에서 이관한 consumer만 active contract 사용 | phase별 golden/screenshot diff와 legacy compatibility budget test |
| 재설계가 새 디자인 시스템으로 변질 | 이 문서는 계속 비권위 승인 패킷으로 유지하고 새 palette/token namespace를 만들지 않음 | source-of-truth/search gate PASS |

## 37. 전 화면 실행 단위와 승인 gate

한 phase를 거대한 PR 하나로 만들지 않는다. 아래 단위는 독립적으로 되돌릴 수 있어야 하며, 각 단위가 승인 gate를 통과한 뒤 다음 단위로 이동한다.

| Work package | 포함 surface | 필수 상태/overlay | 완료 gate |
|---|---|---|---|
| WP-00 Baseline | 17 GoRoute, Admin 10탭, Inventory 전체 work step | 모든 route의 default + 재현 가능한 loading/empty/error/offline | 코드 변경 없는 baseline, primary job/callback/provider/route 목록 고정 |
| WP-01 Minimal foundation | active token, 48dp action, state surface, responsive shell, dialog role wrapper | selected/disabled/processing/destructive/offline | QR에 필요한 최소 범위만 적용, legacy consumer 비회귀 |
| WP-02 Customer QR | `/qr/:token` menu → review → success | loading, empty, invalid, expired, unavailable, rate-limit, offline, retry, disabled, processing | mobile 우선 3언어·200%·중복 탭·slow network PASS, 시각 승인 checkpoint |
| WP-03 Auth/Public | `/login`, `/privacy-consent`, `/onboarding` | validation, consent scroll/action, resumable onboarding error | desktop/tablet/mobile, route redirect·auth contract PASS |
| WP-04 Waiter/Order | `/waiter`, OrderWorkspace take/review/send | guest/PIN/transfer/cancel/staff-meal, offline queued/blocked | table status·quantity·send·permission 의미 동일 |
| WP-05 Kitchen | `/kitchen` queue/execution | delay, item processing, failed print, offline/stale/empty/error | item/ticket state transition contract PASS |
| WP-06 Cashier/Payment | `/cashier`, `/payments/:paymentId` | discount, split, proof, red invoice, cancel/correction, receipt, retry | payment Non-Split Rule 및 전 결제 contract PASS; 별도 고위험 승인 |
| WP-07 Device/Field | `/print-station`, `/attendance-kiosk`, `/photo-ops`, `/qc-check`, `/qc-review` | permission, capture, upload, evidence, retry, offline, unavailable | 실제 지원 platform smoke + 미지원 recovery PASS |
| WP-08 Admin foundation | `/admin`, `/admin/:storeId`, Tables, Menu, Staff, Settings | mode switch, CRUD form, PIN, QR, printer, destructive confirm | 역할별 tab visibility·store scope·deep-link PASS |
| WP-09 Admin exception | Attendance, QC, Delivery, E-Invoice | review/evidence/resolve/dispute/retry/portal | 권한·approval·settlement·invoice lifecycle 동일 |
| WP-10 Inventory | stock, product, supplier, recipe, count, purchase, history, receiving, consumption, cost, new menu, dashboard | Inventory Purchase 11개 + Admin Inventory 4개 show entry point를 실제 역할별로 검증 | 단위·계산·PO·receipt·mutation contract PASS |
| WP-11 Reports/System | Reports, Daily Closing, `/super-admin`, `/restaurant-sales-export` | filter, chart/table, blocker, export progress/result, store selection | closing window·export·role/store scope PASS |
| WP-12 Closure | 전체 route/tab/dialog/sheet | 모든 공통 상태와 responsive variant | source-of-truth checklist, analyze, full test, integration smoke, screenshot matrix PASS |

### 37.1 각 work package의 고정 작업 순서

1. 현재 화면·상태·overlay를 fixture로 재현하고 screenshot을 저장한다.
2. primary job, 유지할 supporting action, 숨길 optional detail을 한 문장으로 고정한다.
3. 기존 provider/callback/mutation/route/permission 접점을 characterization test 또는 검색 가능한 체크리스트로 기록한다.
4. presentation만 queue → select → act → optional detail로 재배치한다.
5. loading, normal empty, filtered empty, error, disabled, offline, selected, destructive, processing, success를 해당 surface에 필요한 만큼 구현한다.
6. 390×844, 1024×768, 1440×900과 KO/EN/VI, 200% text scale을 검증한다.
7. 해당 contract/widget test, `flutter analyze`, 관련 smoke test와 screenshot diff를 통과시킨다.
8. 사용자 시각 승인 또는 phase gate를 받은 뒤 다음 work package로 이동한다.

### 37.2 중단·되돌림 기준

다음 중 하나라도 발생하면 해당 work package 확장을 멈추고 그 단위만 되돌리거나 수정한다.

- route, role/permission, provider ownership, Supabase 호출, 계산 결과가 baseline과 달라짐
- 결제·주문·주방·재고 상태 전이 또는 hardware guard가 달라짐
- 어느 breakpoint 또는 언어에서 overflow·가려진 primary action·48dp 미만 target이 남음
- 정상 empty와 장애/offline이 구분되지 않음
- screen-local token/색/타이포 또는 새 active 디자인 namespace가 추가됨
- 관련 test, analyze, screenshot acceptance 중 하나라도 실패함

## 38. 승인 요청

구현은 아래 세 항목을 명시적으로 승인받은 뒤에만 시작한다.

1. 통합 방향: **Quiet Operational Console** — light, high-contrast, queue-first, Pretendard, existing semantic tokens, 48dp.
2. 구조 원칙: KPI/card-first를 제거하고 queue/select/act/detail로 전 화면을 수렴.
3. 구현 순서: **최소 공통 기반 → Customer QR 승인 checkpoint → Auth → Waiter → Kitchen → Cashier → Field → Admin → Inventory → Reports** 순으로 진행.

승인 전에는 Flutter/Dart UI 코드, 라우트, provider, backend를 변경하지 않는다.
