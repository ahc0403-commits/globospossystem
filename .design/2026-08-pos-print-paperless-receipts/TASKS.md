# Build Tasks: 포스 프린트/페이퍼리스 운영 모드와 고객 영수증

Generated from: `.design/2026-08-pos-print-paperless-receipts/DESIGN_BRIEF.md`
Date: 2026-08-11

각 항목은 사용자에게 확인 가능한 한 개의 수직 슬라이스로 끝낸다. 앞 단계가 통과하지 않으면 뒤 단계의 기능 flag를 켜지 않는다.

## 0. 기준선과 보호 장치

- [ ] **현 작업 트리와 회귀 기준선 동결**: 사용자 소유 VAT 숫자화, USB/Wi-Fi 프린터, 프린터 설정 및 기존 KDS 변경을 덮어쓰지 않고 변경 파일·테스트 결과·현재 schema fingerprint를 기록한다. 단일/분할/통합/비매출 결제, 자동 영수증, 재출력, 고객표시, 레드인보이스, QR 주문, 정산, KDS의 기존 계약 테스트를 실행해 before evidence를 남긴다. _Reuses as-is: `scripts/check_repo.sh`, current Flutter/SQL contract tests; creates only a test evidence checklist. Done: 기준선 실패가 분류되고 이번 작업 때문에 생긴 실패와 기존 실패를 구분할 수 있음._
- [ ] **불변 계약 테스트를 먼저 추가**: `process_payment`가 디지털 영수증/고객표시/MISA에 의존하지 않음, 포스 프린트 모드의 자동 출력, receipt 목적지 예외, 레드인보이스 분리, `restaurants` Office 계약을 source/SQL contract test로 고정한다. _Modifies: focused payment/receipt/red-invoice/Office contract tests; no runtime behavior. Done: 이후 각 슬라이스가 이 계약을 깨면 즉시 실패._

## 1. 매장 운영 모드 — 기능은 아직 OFF

- [ ] **운영 모드 저장·조회·감사 슬라이스**: `restaurant_settings`에 `pos_print|paperless` additive 필드와 기본값을 추가하고 `store_settings` view, 권한 있는 조회/전환 RPC, 행 잠금, 요청 ID 멱등성, audit log를 완성한다. 기존 매장은 모두 `pos_print`로 backfill한다. _Creates: additive migration + preflight/verify/rollback SQL; modifies compatibility view only. Reuses: admin actor/store access helpers. Done: 관리자만 전환하고 타 매장/중복 요청은 안전하며 구버전 앱은 기존대로 동작._
- [ ] **Super Admin 운영 모드 카드 슬라이스**: 기존 비상 제어 UI를 `포스 프린트 모드/페이퍼리스 모드` 카드와 확인창으로 바꾸고 현재 모드, KDS 준비 상태, 진행 중 주문 수, 새 주문부터 적용됨을 표시한다. 실패·중복 탭·권한 없음·강제 전환 사유까지 실제 RPC와 연결한다. _Modifies: existing emergency control panel/provider and KO/VI/EN strings; reuses POS cards/dialogs. Done: 한 매장에서 전환해 새 설정을 재조회하고 감사 이력을 확인할 수 있음._

## 2. 주문별 모드 캡처

- [ ] **신규 주문 모드 스냅샷 슬라이스**: `orders.fulfillment_mode_snapshot`을 additive로 추가하고 모든 기존 주문은 `pos_print`, 새 주문은 생성 transaction 안에서 현재 매장 모드를 한 번 캡처한다. QR·웨이터·캐셔·서비스 주문 생성 경로를 fixture로 검증한다. _Creates/modifies: migration and central order creation RPC paths; reuses current order lifecycle. Done: 전환 중 동시 주문도 정확히 하나의 모드값을 가지며 기존 앱 insert가 실패하지 않음._
- [ ] **추가 주문/품목 스냅샷 슬라이스**: 현재 추가 주문 batch 모델을 preflight로 확인한 뒤 `order_items.fulfillment_mode_snapshot` 또는 기존 batch의 모드 필드를 최소 변경으로 추가한다. 전환 전 원 주문에 전환 후 품목을 추가한 시나리오를 출력/KDS 양쪽에서 검증한다. _Modifies: additive schema and every item-add path; reuses existing order/item IDs. Done: 한 주문 안의 품목도 추가 시점별로 정확히 한 전달 채널을 사용._

## 3. 운영 티켓 라우팅

- [ ] **포스 프린트 호환 라우팅 슬라이스**: `pos_print` 품목의 kitchen/tray/floor/confirmation job 생성·claim·출력이 현재와 바이트/목적지/배치 수준에서 동일하도록 스냅샷 기반 라우터를 연결한다. _Modifies: print enqueue/claim contract minimally; reuses `print_jobs`, destinations, Print Station, Wi-Fi/USB agents. Done: 현재 print routing tests와 실프린터 dry run이 기준선과 동일._
- [ ] **페이퍼리스 KDS 전용 라우팅 슬라이스**: `paperless` 품목은 운영 job을 프린터가 claim하지 않으며 기존 KDS queue에 한 번만 편입한다. job을 삭제하지 않고 감사 가능한 `digitally_routed`/호환 hold 상태로 종료한다. _Modifies: existing emergency hold trigger/claim and queue sync; reuses KDS ledgers. Done: 같은 품목이 종이와 KDS 양쪽에 중복되지 않고 어느 쪽에서도 누락되지 않음._
- [ ] **혼합 주문과 빠른 모드 전환 슬라이스**: 같은 주문의 print 품목/paperless 추가품목, print→paperless→print 연속 전환, 구버전 앱, 재연결된 Print Station을 통합 fixture로 처리한다. 오래된 억제 job은 자동 출력하지 않는다. _Modifies: routing compatibility only as failures require. Done: captured mode와 실제 채널의 자동 대조가 100% 일치._

## 4. 페이퍼리스 KDS 승격

- [ ] **KDS 명칭·진입·대기 상태 슬라이스**: 사용자에게 노출되는 비상 용어를 페이퍼리스 운영으로 교체하고 역할 홈/라우팅은 호환성을 유지한다. paperless 활성, pos_print 대기, paperless 주문 마감 중 상태를 실제 설정과 주문 snapshot으로 구분한다. _Modifies: `/emergency` presentation, role labels/guards, auth/provider state; keeps legacy route/RPC aliases. Done: URL 직접 접근과 역할 격리를 유지하면서 비상 표현이 보이지 않음._
- [ ] **키친 4/8슬롯 실운영 슬라이스**: 기존 고정 보드를 paperless 키친 데이터와 연결해 Phone 4, Tablet 8슬롯, 페이지, 메뉴 상세, 주문 단위 완료/원복, 중복 탭, offline outbox를 끝낸다. _Modifies: existing emergency fulfillment screen/provider; reuses current grid/action RPCs. Done: 키친에서 완료한 delta만 트레이에 한 번 노출._
- [ ] **트레이 4/8슬롯 실운영 슬라이스**: 같은 보드를 트레이 단계에 연결해 전체 메뉴, 준비 상태, 완료 시 층 전달, downstream 전 원복을 완성한다. _Modifies shared station mapping; reuses board/detail and action ledger. Done: Phone/Tablet 모두 4/8 규칙과 수량 체인 통과._
- [ ] **층별 4/8슬롯 실운영 슬라이스**: 배정 층만 보이게 하고 전체 메뉴, 제공 완료, 허용 원복/거절 사유를 완성한다. _Modifies shared station mapping and floor filter; reuses assignment RLS. Done: 다른 매장/층 접근이 DB/UI 모두 차단되고 완료 수량이 캐셔 상태와 일치._
- [ ] **모드 종료 후 drain 슬라이스**: paperless→print 전환 뒤 기존 paperless 카드만 KDS에서 계속 처리하고 새 print 주문은 보이지 않게 하며, 마지막 카드 완료 후 자동 대기로 전환한다. _Modifies: session lifecycle compatibility and KDS state. Done: 전환 때문에 진행 주문이 사라지거나 새 print 주문이 KDS에 섞이지 않음._

## 5. 디지털 영수증 원장과 공개 조회

- [ ] **불변 영수증 snapshot 슬라이스**: `digital_receipts`와 authenticated `ensure_digital_receipt` RPC를 추가해 결제 완료 주문에서 품목·할인·서비스요금·VAT·합계·분할 결제·현금 수령/거스름돈·비매출 정보를 한 번 캡처한다. 같은 요청/주문 동시 호출은 한 행만 반환한다. _Creates: additive migration/RPC/RLS/preflight/verify/rollback; reuses paid order/payment sources and receipt numeric VAT contract. Done: 종이 `ReceiptBuilder` 결과와 fixture 금액이 완전 일치._
- [x] **공개 token 보안 슬라이스**: 별도 `digital_receipt_links`에서 raw token은 발급 응답에만 전달하고 DB에는 hash만 저장하며 anon table grant 없이 Edge allowlist 경계로 영수증을 조회한다. 링크는 90일 만료, 활성 3개 제한, 만료 후 hash 정리, 조회 쓰기 완화를 적용한다. revoked/만료/없는/변조 token은 같은 안전 오류를 반환하고 URL/token을 로그에서 제거한다. _Creates: token issue/lookup/revoke/rate-limit RPC, Edge Function and security tests. Done: 타 매장 직원·anon 직접 SELECT/RPC·token 추측이 차단되고 정상 token만 읽기 가능._
- [x] **공개 영수증 화면 슬라이스**: 인증 redirect보다 앞선 token 없는 `/receipt` route에서 fragment handoff를 사용해 모바일 우선 영수증, PDF 저장, 브라우저 인쇄, OS 공유를 제공하고 로딩·만료/폐기·오프라인·긴 품목 상태를 완성한다. _Creates: public receipt feature/screen/provider; modifies router public path handling; reuses POS receipt format and localization. Done: token을 서버 URL/탐색 이력에 남기지 않고 로그인 없이 Phone/Tablet/Desktop에서 동일 snapshot을 보고 출력 가능._
- [ ] **누락 보정과 결제 이력 복구 슬라이스**: 결제 성공 후 ensure 실패를 기록하고 안전하게 재시도하며 결제 상세에 `디지털 영수증 보기/QR 다시 표시`를 추가한다. 보정 작업은 누락 receipt만 생성하고 결제/주문을 수정하지 않는다. _Modifies: payment service/detail and retry worker/outbox; reuses existing payment detail access checks. Done: 인위적 RPC 장애 뒤에도 결제 이력에서 동일 영수증을 복구._

## 6. 고객표시 QR

- [ ] **고객표시 phase 데이터 계약 슬라이스**: `customer_payment_displays`를 `idle|payment|receipt|error`와 revision 기반 payload로 additive 확장하고 현재 `show/clear` 호출과 구버전 provider를 호환한다. receipt publish에는 공개 URL 또는 token presentation만 포함하고 전체 민감 snapshot을 복제하지 않는다. _Modifies: customer display migration/RPC/provider contract; reuses store-scoped Realtime and polling. Done: 기존 결제 표시가 그대로 동작하고 receipt phase도 독립적으로 전달._
- [ ] **결제 QR/영수증 QR 시각 분리 슬라이스**: 기존 은행 QR은 `payment`, 동적 영수증 QR은 `receipt` 전용 widget으로 분리하고 문구·색상·key·테스트를 달리한다. 90초 idle, 다음 결제 덮어쓰기, cashier 재표시를 구현한다. _Modifies: customer display screen/provider and KO/VI/EN strings; reuses `qr_flutter`. Done: 직원/고객이 두 QR을 혼동하지 않고 1024×768 및 세로 화면에서 잘림 없음._
- [ ] **고객표시 장애 fallback 슬라이스**: publish timeout/오프라인이면 캐셔 완료창에 동일 QR을 크게 표시하고, 고객표시 복구 시 같은 revision만 재전송한다. _Modifies: cashier completion state and display publisher; no payment changes. Done: 고객표시 전원을 끈 E2E에서도 고객이 영수증을 받을 수 있음._

## 7. 캐셔 영수증 선택

- [ ] **최초 출력과 재출력 API 분리 슬라이스**: `printFirstReceiptCopy(p_reprint=false)`와 `reprintReceipt(p_reprint=true)`를 서비스/UI에서 구분하고 같은 최초 출력 요청은 batch 1 하나만 반환한다. _Modifies: `PaymentService`, completion callbacks, print queue contract tests; reuses existing SQL idempotency. Done: 중복 탭/재시도는 batch 1, 결제 이력의 명시적 재출력만 batch 2+._
- [ ] **포스 프린트 완료 흐름 회귀 슬라이스**: 단일·분할·비매출 결제에서 기존 자동 receipt enqueue, payment proof, RedInvoiceModal, 완료창 순서와 실패 처리를 유지하면서 shadow digital receipt만 연결한다. _Modifies minimally: cashier orchestration; reuses current dialogs and print service. Done: 기존 cashier receipt contract tests와 before screenshots/flows가 동일._
- [ ] **페이퍼리스 단일 결제 완료 슬라이스**: 자동 종이 출력을 생략하고 `QR 표시됨`, `종이 영수증 출력`, `QR 다시 표시`, `완료` 상태를 실제 ensure/publish/print API와 연결한다. _Modifies: `PaymentCompletionDialog` and cashier orchestration; reuses order summary and receipt queue. Done: QR 또는 종이 중 최소 하나의 제공 경로가 명확하고 결제 성공은 실패에 영향받지 않음._
- [ ] **분할·비매출 완료 슬라이스**: 최종 분할 결제 완료 뒤에만 한 영수증을 발행하고 모든 결제수단 금액을 표시한다. 비매출은 SERVICE 표기와 red invoice 미호출을 유지한다. _Modifies: split/non-revenue completion state; reuses one receipt per order. Done: 부분 결제에는 QR이 없고 최종 합계 뒤 한 번만 발행._
- [ ] **통합 테이블 완료 슬라이스**: 현재와 같이 주문별 영수증을 생성해 테이블별 QR 카드/선택 출력과 멱등 `전체 종이 출력`을 제공한다. _Modifies: combined completion dialog/orchestration; reuses `combined_payment_group_id` and per-order print. Done: N개 주문에 N개 영수증, 중복 출력 없음, 통합 결제 금액 합계 일치._

## 8. 적색 세금계산서와 결제 실패 격리

- [ ] **레드인보이스 비간섭 슬라이스**: 즉시 입력·명함·Zalo·기타 추후 접수와 MISA async dispatch를 변경하지 않고, QR 생성 성공/실패와 무관하게 같은 순서로 열리는지 검증한다. 영수증 snapshot/RPC에는 red invoice intake 또는 MISA lifecycle 필드를 넣지 않는다. _Reuses as-is: RedInvoiceModal/intake/export/MISA boundary; modifies only regression tests if needed. Done: MISA 강제 실패에서도 결제·QR·선택 출력 성공, QR 실패에서도 red invoice 접수 성공._
- [ ] **결제 성공 후 부가작업 실패 매트릭스 슬라이스**: receipt ensure, customer display, printer, payment proof storage, red invoice 각각을 실패시켜 결제 중복/롤백/무한 spinner가 없는지 검증하고 직원 복구 동작을 표시한다. _Modifies error-state orchestration only; reuses existing payment idempotency. Done: 모든 조합에서 결제 결과가 하나이고 재진입 가능한 복구 경로가 있음._

## 9. 보안·개인정보·접근성

- [x] **영수증 위협 모델과 자동 보안 테스트 슬라이스**: token entropy/hash, 만료/활성 제한, RLS, SECURITY DEFINER search path, 최소 grant, Edge rate limit, 로그/URL 유출, referrer/cache/indexing, revoked receipt를 검토하고 fixture로 공격 시나리오를 실행한다. _Creates: security contract/SQL/Edge tests and headers; reuses existing Supabase auth helpers. Done: 코드 수준 배포 차단 Critical/High 0건, 인프라 WAF/독립 침투 테스트는 운영 게이트로 명시._
- [ ] **영수증/KDS 반응형·접근성 슬라이스**: 390×844, 430×932, 844×390, 768×1024, 1024×768, 1440×900과 100/130/200% 글자 크기, KO/VI/EN, 키보드/스크린리더, 48dp 터치 영역을 검증한다. _Modifies new screens/components only as findings require; reuses app theme. Done: 정보 삭제 없이 overflow와 가려진 주요 동작 0건._

## 10. 관측·운영 도구

- [ ] **모드/전달/영수증 관측 슬라이스**: raw token 없이 모드 전환, captured channel mismatch, KDS 처리, digital receipt 누락/복구, 고객표시 실패, 선택 출력률을 관리 화면 또는 운영 쿼리에서 확인한다. _Creates/modifies: audit-safe metrics/read-only diagnostics; reuses audit logs. Done: 주문 ID로 전달 채널과 영수증 제공 상태를 추적 가능._
- [ ] **자동 경보와 런북 슬라이스**: 결제 후 receipt 없음, paperless 운영 job claim, pos_print job 누락, KDS 수량 위반을 탐지하고 `QR 재표시 → 종이 출력 → print 전환 → KDS drain` 순서의 복구 런북을 작성한다. _Creates: read-only health checks and operations document; no auto payment mutation. Done: 담당자가 데이터 수정 없이 장애를 분류·복구 가능._

## 11. 통합 검증과 배포

- [ ] **실제 Postgres migration rehearsal**: 먼저 원격 migration history와 현재 uncommitted KDS/VAT/USB migration의 적용 여부를 대조해 새 timestamp 충돌을 막는다. 그 다음 빈 DB와 production-like snapshot에서 preflight→migration→verify→rollback rehearsal을 수행하고 기존 function signature, RLS/grant, views, Office coupling을 비교한다. _Reuses production-gate SQL conventions; creates isolated fixtures only; never edits an applied migration. Done: expand와 rollback 모두 데이터 손실 없이 반복 가능._
- [ ] **다중 장치 E2E 슬라이스**: 관리자 모드 전환 → 주문/추가 주문 → 키친 Tablet 8 → 트레이 Phone 4 → 층별 Tablet/Phone → 캐셔 결제 → 고객표시 QR → 공개 영수증/PDF → 선택 종이 출력 → 결제 이력 재표시를 서로 다른 계정으로 수행한다. print mode 동일 시나리오도 병행한다. _Modifies/creates focused integration harness; reuses existing role accounts. Done: 누락·중복·타 매장 노출 0건._
- [ ] **전체 저장소 게이트**: 변경 Dart 포맷, `flutter analyze`, 관련 테스트, 전체 `flutter test`, Web release build, SQL 검증, 보안/Node 계약, `bash scripts/check_repo.sh`, `git diff --check`를 통과한다. _Reuses project gates. Done: 로컬 PASS와 정확한 결과 로그가 있으며 운영 적용은 아직 하지 않음._
- [ ] **Shadow 배포 슬라이스**: feature flag OFF로 schema/app을 배포해 기존 출력은 유지하고 digital receipt/예상 라우팅만 shadow 생성·대조한다. exact pushed head SHA GitHub checks를 확인한다. _Modifies runtime flags only after explicit deployment approval. Done: 최소 한 영업 주기의 금액/라우팅 mismatch 0건._
- [ ] **파일럿 매장 활성화 슬라이스**: 한 매장 한 교대에서 paperless를 opt-in하고 직원 체크리스트, KDS heartbeat, QR/종이 fallback, 모드 복귀와 drain을 실측한다. _Uses existing mode toggle and runbook; no global default change. Done: 운영 누락/중복 0, 영수증 제공 100%, 담당자 승인._
- [ ] **점진 확대와 롤백 보존 슬라이스**: 매장별 승인 단위로 확대하고 즉시 `pos_print` 전환, 기존 paperless 주문 drain, 공개 영수증 유지가 가능한지 확인한다. 기존 schema/RPC 제거는 별도 승인 릴리스로 미룬다. _Reuses flags and compatibility layer. Done: 롤백 연습 성공 및 Critical/High 0건._

## Review

- [ ] **제품 의미 검토**: `새 주문/새 추가품목부터 모드 적용`, `통합 결제는 주문별 영수증`, `QR 90초`, `SMS/Zalo/이메일 제외`, `공개 링크 보존 기간` 기본값을 운영 책임자가 승인한다. _Reuses: design brief decisions; creates an approval record. Done: 미결 제품 결정 0건._
- [ ] **현장 UX 검토**: 키친·트레이·층별·캐셔 직원과 고객이 실제 Tablet/Phone으로 모드명, 4/8슬롯, 완료/원복, 은행 QR/영수증 QR 구분, 선택 출력 문구를 승인한다. _Reuses: implemented pilot screens and real device checklist; modifies copy/layout only through a new reviewed task. Done: 역할별 승인과 발견사항 기록 완료._
- [ ] **회계/보안 경계 검토**: 일반 디지털 영수증이 회사 내부 증빙용이며 적색 세금계산서가 아님을 문구와 데이터에서 확인하고, 공개 token·보존·revoke 정책을 승인한다. _Reuses: existing MISA boundary and new receipt threat model; creates a sign-off record. Done: 회계·보안 양쪽 승인 완료._
- [ ] **독립 회귀 검토**: Critical/High/Medium/Low/Confirmed 형식으로 결제 원자성, 출력/KDS 중복, 영수증 금액, RLS, MISA 비간섭, Office coupling을 검토한다. Critical/High 0건 전에는 파일럿 기능 flag를 켜지 않는다. _Reuses: full regression evidence; creates the independent review report. Done: Critical/High 0건과 priority fix list 종료._
