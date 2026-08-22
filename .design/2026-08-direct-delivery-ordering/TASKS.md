# 직접 배달 주문 출시 보강 상세 계획

기준 문서: `.design/2026-08-direct-delivery-ordering/DESIGN_BRIEF.md`
안전 계약: `.design/2026-08-direct-delivery-ordering/REGRESSION_SAFETY.md`
작성일: 2026-08-21

## 현재 상태

H0-H3, Google 무트래픽 소스 spike, H4A, H4B와 H5 로컬 보강은 구현·검증
완료했다. storefront는 계속 기본 비활성화한다. 실제 Google test project,
브라우저 matrix와 비용 대사인 H4 외부 항목 및 H6 운영 출시는 실행하지
않았다. 이 계획은 운영 DB 반영, Edge 배포, Google Business Profile 링크
공개 또는 실제 매장 pilot을 승인하지 않는다.

표시 기준:

- `[x]`: 현재 로컬 소스와 테스트로 확인된 항목
- `[ ]`: 추가 구현·문서화·자동 검증 또는 운영 증거가 필요한 항목
- 소스 구현, migration 적용, production 배포, 실운영 검증은 서로 다른
  상태이며 한 상태의 증거를 다른 상태의 증거로 사용하지 않는다.

## 절대 불변식과 즉시 중단 조건

- 기존 QR, 캐셔, KDS, 결제, 재고, MISA/meInvoice, 출력, 리포트, 마감,
  프로모션, Deliberry, Photo, Office coupling 객체를 ALTER, DROP 또는
  CREATE OR REPLACE 하지 않는다.
- 직접 배달 기능에 맞추기 위해 기존 테스트 기대값을 낮추거나 변경하지
  않는다.
- 캐셔 승인 전에는 기존 주문·결제·재고·meInvoice·출력·KDS 쓰기가
  항상 0이어야 한다.
- 직접 주문에서 기존 재무 도메인으로 들어가는 유일한 경로는
  `direct_order_approve_payment`이며, 한 transaction 안에서 변경하지
  않은 `process_payment`를 정확히 한 번 호출해야 한다.
- 입금증, SePay 후보, 금액 일치 또는 고객 동작은 자동 승인을 만들 수
  없다.
- 신규 요청 알림은 조회·이동만 수행한다. 알림 표시, 소리 재생, 알림
  확인 또는 `/cashier/direct-orders` 이동은 quote·입금 승인·주방 ticket·
  기존 order/payment를 생성하거나 상태를 바꾸지 않는다.
- 알림 신호, UI, log와 브라우저 저장소에는 고객명·전화·주소·메시지·
  입금증 경로를 넣지 않는다. 기존 payload-free `pos_live_events` 원칙을
  유지하고 상세 정보는 기존 store-scoped RPC로 다시 조회한다.
- 직접 배달 알림을 위해 frozen `cashier_screen.dart`, 기존 cashier
  provider/queue/payment state 또는 기존 입금·SePay·주방·긴급 알림의
  coordinator/service/sound/copy를 수정하지 않는다. 신규 route-scoped
  host의 실패는 기존 캐셔 화면과 다른 알림에 전파되지 않아야 한다.
- Google 키, Supabase secret, 고객 주소·전화번호, 입금증 경로, signed
  URL과 실제 테스트 개인정보를 Git에 넣지 않는다.
- 실패주입·동시성 SQL은 명시적으로 이름을 지정한 disposable DB에서만
  실행하고 fixture와 test trigger를 rollback 또는 정리한다.
- frozen hash 불일치, 기존 회귀, 중복 재무 기록, 부분 승인 기록,
  cross-store 접근 또는 secret 노출이 하나라도 발견되면 다음 gate를
  중단한다.

## Gate H0 — 현재 기준선 동결

- [x] **격리 아키텍처 유지**: 요청, 정확한 주소, coarse location, 채팅,
  견적, 재무 연결, 배차와 조리 티켓은 신규 객체를 사용하고 수동 승인만
  기존 완료 재무 주문 1건을 생성한다. _재사용: 현재 direct migration과
  ADR; 수정: 없음._
- [x] **기존 핵심 파일 hash 유지**: QR, 캐셔, 기존 KDS,
  `process_payment`, payment calculator, report, print agent와 effective
  migration이 기록된 baseline과 일치한다. _재사용:
  `test/direct_delivery_regression_isolation_test.dart`; 수정: 없음._
- [x] **로컬 검증 기준선 유지**: 정적 분석, 전체 Flutter suite,
  Node/security 계약, 웹 release build, Edge 테스트, 반응형 storefront
  테스트와 12개 SQL smoke가 현재 통과한다. _재사용:
  `bash scripts/check_repo.sh`과 현재 evidence; 수정: 없음._
- [x] **보강 작업 시작점 기록**: exact commit SHA, 사용자 소유
  modified/untracked 파일, direct migration hash, Edge hash와 frozen legacy
  hash를 기록한다. _생성: `HARDENING_BASELINE.md`; 재사용: read-only Git
  명령; 수정: runtime 없음._

H0 통과 기준:

- 기준선 파일을 같은 worktree에서 재현할 수 있다.
- 사용자 소유 파일을 신규 기능 변경으로 주장하거나 덮어쓰지 않는다.

## Gate H1 — DB 컬럼·제약·RLS·인덱스 계약 완성

- [x] **직접 주문 데이터 사전 작성**: 신규 테이블의 모든 컬럼에 대해
  타입, nullable, default, PK/FK/UNIQUE/CHECK, 삭제 규칙, writer, reader,
  PII 등급, 보존 정책과 legacy row 참조 허용 여부를 기록한다. 모든
  인덱스의 대상 query와 목적도 기록한다. _생성:
  `DIRECT_ORDER_DATA_CONTRACT.md`; 재사용:
  `20260821130000_direct_delivery_ordering.sql`; 수정: DB runtime 없음._
- [x] **default-deny RLS 모델 명문화**: 모든 direct table이 RLS ON이고
  client table policy가 없으며 `anon`·`authenticated` 직접 grant가
  제거되어 scoped `SECURITY DEFINER` RPC로만 접근한다는 계약을
  명시한다. service-role 예외와 private proof bucket도 포함한다. _추가:
  `DIRECT_ORDER_DATA_CONTRACT.md`; 재사용: 현재 RLS/revoke/grant;
  수정: 테스트로 결함이 확인되지 않는 한 policy 없음._
- [x] **catalog 기반 schema 계약 테스트 추가**: `information_schema`와
  `pg_catalog`에서 테이블, 컬럼 타입·nullability·default, FK 삭제 규칙,
  named CHECK/UNIQUE, partial unique index, queue/analytics index, RLS flag,
  table/function privilege와 proof bucket 제한을 검사한다. 접근 권한이
  넓어지면 실패해야 한다. _생성:
  `supabase/tests/direct_delivery_schema_contract_test.sql`; 재사용: 기존
  SQL fixture 방식; 수정: production 객체 없음._
- [x] **역할·매장별 부정 권한 matrix 확대**: `anon`, 일반 authenticated,
  타 매장 cashier, kitchen, admin, service role이 정확한 주소, 채팅,
  proof metadata, 재무, 분석, kitchen ticket과 settings에 접근할 때 각
  역할이 문서화된 RPC만 사용할 수 있는지 검증한다. _확장:
  `supabase/tests/direct_delivery_ordering_contract_test.sql`; 재사용:
  `direct_order_require_actor`; 수정: test first, 결함 확인 시 direct
  객체만._
- [x] **새 disposable DB에서 migration 재적용**: effective migration
  chain을 적용하고 direct SQL suite 두 개와 frozen-object 검사를 실행한
  뒤 명시한 disposable DB만 삭제한다. _생성: 로컬 SQL 실행 증거;
  재사용: 현재 migration 도구; 수정: disposable data만._

H1 통과 기준:

- direct 컬럼, 제약, 인덱스, RLS flag, grant, 함수 signature 또는 proof
  bucket limit가 달라지면 catalog 테스트가 실패한다.
- `anon`과 일반 authenticated client는 direct table을 직접 읽거나
  변경할 수 없다.
- `restaurants`와 Office coupling 컬럼은 direct migration 전후 정의가
  동일하다.

## Gate H2 — Edge API/RPC 입출력·에러 계약 고정

- [x] **공통 HTTP 계약 정의**: POST-only, exact origin, 64 KiB body 제한,
  JSON content type, no-store, public/staff/internal 인증, rate limit,
  Retry-After, 성공 `{data: ...}`, 실패 `{error: CODE}`와 log redaction을
  명문화한다. _생성: `DIRECT_ORDER_API_CONTRACT.md`; 재사용:
  `direct-order-public/index.ts`; 수정: runtime 없음._
- [x] **Edge action 15개 명세**: `storefront`, `create_session`,
  `places_autocomplete`, `place_details`, `reverse_geocode`, `submit`,
  `status`, `message`, `message_translations`, `cancel`, `proof_upload_url`,
  `proof_commit`, `staff_proof_url`, `staff_message`, `cleanup_expired_pii`
  각각에 actor, request field,
  validation limit, response field, side effect, idempotency, rate class와
  가능한 error code를 적는다. _추가: `DIRECT_ORDER_API_CONTRACT.md`;
  재사용: Flutter service/model과 Edge switch; 수정: 불일치가 발견된
  direct 코드만._
- [x] **public/staff RPC 전체 명세**: 각 `direct_order_*` 및
  `direct_delivery_*` 함수의 SQL signature, 역할, store scope, 선행
  상태, lock, 읽기·쓰기 테이블, 응답 형태, idempotency와 domain error를
  기록한다. _추가: `DIRECT_ORDER_API_CONTRACT.md`; 재사용: 현재 direct
  migration; 수정: 함수 정의 없음._
- [x] **명시적 에러 registry 도입**: 현재 문자열 포함 여부로 추론하는
  방식을 모든 알려진 SQL domain error의 고정 HTTP status/public code
  표로 바꾸고, 알 수 없는 오류만 sanitized 503으로 처리한다. 신규
  `DIRECT_ORDER_*` RAISE가 registry에 없으면 테스트가 실패해야 한다.
  _수정: `supabase/functions/direct-order-public/index.ts`; 생성:
  error-registry 계약 테스트; 재사용: `SafeHttpError`와 기존 envelope._
- [x] **action별 Edge 계약 테스트 추가**: 모든 action의 대표 성공과
  핵심 validation/auth/state 실패를 검사한다. malformed JSON, oversized
  body, client IP 없음, rate limit, foreign origin, upload path 위조,
  spoofed image, missing object, Google timeout/429/5xx와 unexpected
  Supabase error를 포함한다. _확장:
  `supabase/functions/direct-order-public/index_test.ts`; 재사용:
  dependency injection; 수정: 결함이 없으면 test helper만._
- [x] **Flutter model 호환 계약 고정**: 모든 고객 action의 성공/error
  fixture를 decode하고 필수 field 누락은 거부하며 문서화한 optional
  field만 허용한다. 모든 public error code의 한국어·베트남어·영어 처리와
  안전한 fallback을 검증한다. _확장: direct service/model 테스트와
  `test/direct_delivery_ui_contract_test.dart`; 재사용: 현재 model/copy;
  수정: direct feature만._
- [x] **Edge 계약 gate 실행**: Deno format check, lint, type check, 전체
  Edge test, Flutter direct service/model test와 secret scan을 수행한다.
  _재사용: 현재 Deno config와 repository security scan; 생성: 실행
  evidence; 수정: 없음._

H2 통과 기준:

- 모든 Edge action과 RPC에 단일 권위 문서와 실행 가능한 fixture가 있다.
- SQL 원문, 주소, session secret, proof path, 은행정보, Google 응답과
  signed URL이 예기치 않은 응답이나 log에 나오지 않는다.
- action, response field, RPC error 또는 privilege를 계약 변경 없이
  추가하면 CI가 실패한다.

## Gate H3 — 상태 전이·동시 승인·실패 원자성 증명

- [x] **실제 저장 상태 matrix 작성**: request의
  `awaiting_quote → quoted → awaiting_payment_review → approved`와
  `rejected/cancelled/expired`, quote 상태, ticket 상태를 고객·캐셔·주방
  동작에 연결한다. 설계 문서의 개념 상태명은 저장값 변경 없이
  대응표로 정리한다. _생성: `DIRECT_ORDER_STATE_CONTRACT.md`; 재사용:
  현재 CHECK와 RPC; 수정: 문서 우선._
- [x] **허용·거부 전이 전체 테스트**: cancel/reject, quote/requote/lock/
  expiry, approve, preparing/ready/dispatch/complete와 terminal replay의
  허용 edge 전체 및 대표 금지 edge를 검증한다. kitchen ticket의
  expected-version conflict도 포함한다. _생성:
  `supabase/tests/direct_delivery_state_contract_test.sql`; 재사용: 현재
  transition RPC; 수정: test로 drift가 확인된 direct 함수만._
- [x] **실제 2-connection 동시 승인 runner 작성**: 명시적으로 이름 붙인
  disposable DB에 요청 1건을 만들고 test-only trigger로 connection A를
  approval transaction 내부에서 지연시킨 뒤 같은 quote와 금액으로
  connection B를 시작한다. 두 결과가 같은 order/payment/ticket ID를
  반환하고 재무 graph가 정확히 1개인지 검사한다. _생성:
  `scripts/test_direct_delivery_concurrency.sh`와 SQL fixture; 재사용:
  advisory lock, row lock, unique, idempotent return; 수정: disposable
  fixture만._
- [x] **서로 다른 terminal 동작 race 테스트**: approve-vs-reject와
  approve-vs-cancel을 동시에 실행한다. 합법적인 terminal 결과 하나만
  승리하고 다른 호출은 문서화된 conflict를 받으며 혼합 상태나 부분
  graph가 없어야 한다. _확장: concurrency runner; 재사용:
  approve/reject/cancel RPC; 수정: disposable fixture만._
- [x] **승인 단계별 실패주입**: 각각 별도 rollback scenario에서 order
  insert 후, order-item/ticket-item 후, ticket 생성 후,
  `process_payment` 이후 financial link 전, financial link 후 audit
  완료 전에 test trigger로 예외를 발생시킨다. production에서 호출
  가능한 failpoint는 만들지 않는다. _생성:
  `supabase/tests/direct_delivery_approval_failure_contract_test.sql`;
  재사용: PostgreSQL transaction; 수정: test transaction trigger만._
- [x] **전체 rollback graph 검사**: 각 실패에서 direct financial, order,
  order item, payment, ticket/item, 승인 message, audit, inventory 수량과
  `inventory_transactions`, `meinvoice_jobs`가 모두 남지 않는지
  검증한다. trigger 제거 후 재시도는 정확히 1건을 만들어야 한다.
  _확장: failure contract test; 재사용: process-payment fixture; 수정:
  disposable data만._
- [x] **금액·운영 선행조건 matrix 확대**: 정확한 금액과 1 VND 차이,
  만료 quote, proof 없음/위조, 메뉴 가격·노출 변경, 잘못된 매장·역할,
  disabled/paused storefront, 회계 승인 없음, cutoff, non-`pos_print`,
  active emergency와 active promotion을 검사한다. _확장: direct SQL
  contract suite; 재사용: 현재 guard; 수정: test first._

H3 통과 기준:

- 같은 2-client race를 50회 반복해도 중복이 0이고 두 호출의 최종
  financial identity가 동일하다.
- 모든 실패주입에서 재무·재고·meInvoice·조리·message·audit 부분
  side effect가 0이다.
- production migration과 Edge runtime에 test wait, trigger, secret 또는
  failpoint가 남지 않는다.

## Gate H4 — Google 주소/지도 spike 완성

- [x] **명시적 현재 위치 UX 구현**: 지도 직접 선택 모드에 고객이 누르는
  `현재 위치 사용` 동작을 추가한다. 성공하면 지도 이동 후 reverse
  geocode하고, 거부·미지원·timeout이면 매장 중심과 수동 pin fallback을
  유지한다. 첫 화면에서 자동으로 위치 권한을 요청하지 않는다. _생성:
  web/stub 조건부 browser-location adapter와 테스트; 수정: direct
  storefront만; 재사용: 현재 map loader와 reverse-geocode service._
- [x] **Places 검색 session token 적용**: 검색 시작 시 UUIDv4 token을
  생성하고 Autocomplete (New)와 이를 종료하는 Place Details (New)에 같은
  token을 전달한다. 선택 완료 후 새 token으로 교체하고 중단된 검색
  token은 폐기한다. 현재 최소 field mask와 debounce는 유지한다. _수정:
  direct storefront/service와 Edge Places 요청; 재사용: 현재 server key와
  Places (New); 생성: token lifecycle 테스트._
- [x] **Google 트래픽 없는 장애 테스트 추가**: browser/server key 없음,
  Maps JS load 실패, autocomplete 400/429/5xx, empty suggestion, 잘못된
  place detail, reverse geocode 결과 없음, 위치 거부·미지원·timeout,
  오래된 async 응답, cached address 재확인과 manual-pin fallback을
  검증한다. _확장: Edge/storefront 테스트; 재사용: 주입 가능한 adapter;
  수정: 기존 POS 화면 없음._
- [x] **반응형·접근성 재검증**: 주소 두 경로, 현재 위치 상태, keyboard
  focus, screen-reader label, loading/error announcement와 overflow를
  390×844, 768×1024, 1024×768, 1440×900에서 검사한다. _확장:
  `test/direct_delivery_storefront_widget_test.dart`; 재사용: 디자인
  token; 수정: direct widget만._
- [ ] **flag-off Google test project 준비**: 하나의 Google Cloud
  project에 browser/server key를 분리하고 browser referrer와 server API를
  제한한다. Maps JavaScript, Places API (New), Geocoding만 활성화하고
  quota·budget alert를 설정하며 값을 Git 밖에 둔다. _생성: 외부 test
  config; 재사용: runbook의 Edge secret 이름; 수정: production
  storefront 없음._
- [ ] **실제 브라우저 matrix 실행**: Android Chrome, iPhone Safari,
  desktop Chrome/Safari에서 베트남 주소 통째로 붙여넣기, 아파트 상세주소,
  건물·상호명 검색, 검색 선택, pin 미세조정, 지도 직접 선택, 현재 위치
  허용/거부, cached address 재확인과 강제 quota/API 실패 복구를
  검증한다. _생성: 개인정보를 제거한
  `GOOGLE_MAPS_SPIKE_EVIDENCE.md`; 재사용: flag-off route; 수정: test
  data만._
- [ ] **주소 품질·비용 대사**: 완료/중단 검색당 request 수, Google
  metrics의 session-token pairing, 예상하지 않은 Pro/Enterprise Places
  field가 없는지 확인하고 주소 성공률·latency·월 비용의 go/no-go 기준을
  기록한다. _추가: `GOOGLE_MAPS_SPIKE_EVIDENCE.md`; 재사용: Google
  usage report; 수정: quota/alert만._

공식 구현 기준:

- [Google Places session token](https://developers.google.com/maps/documentation/places/web-service/place-session-tokens)은
  검색마다 새 token을 만들고 Autocomplete와 종료 Place Details에 같은
  token을 사용하도록 권장한다.
- [Google Maps 브라우저 위치](https://developers.google.com/maps/documentation/javascript/geolocation)는
  HTML5 geolocation과 사용자 권한을 사용한다. 거부는 정상 fallback이며
  주문 자체의 오류가 아니다.
- server key는 브라우저로 보내지 않는다. browser key는 브라우저에서
  보이는 값이므로 exact referrer와 API 제한으로 보호한다.

H4 통과 기준:

- 실제 Google project와 브라우저 matrix에서 주소 두 경로가 모두
  동작한다.
- 권한 거부, quota, network 실패 또는 invalid result가 안전하게
  복구되며 확인되지 않은 좌표로 주문할 수 없다.
- direct route를 즉시 끌 수 있고 Google 장애가 기존 POS·QR·캐셔·KDS에
  영향을 주지 않는다.

## Gate H4A — 화면 사용자 기준 언어 경계

언어는 주문에 고정하지 않고 **현재 화면을 보는 사람**에게 적용한다.
고객·캐셔·주방·관리자는 각자 한국어·베트남어·영어 중 하나를 선택하고,
자신이 선택한 언어로 화면을 본다. 고객이 어떤 언어로 주문했는지는 다른
사용자의 화면 언어를 바꾸지 않는다. 시스템 label·status·error·menu
name·알림은 현재 viewer locale로 번역한다. 고객/직원이 직접 쓴 채팅은
원문을 보존하면서 서버 생성 KO/VI/EN 사본 중 viewer locale을 표시하고,
상세주소와 요청사항은 데이터 원문을 보존한다.

| 화면/데이터 | 허용 언어와 결정 기준 |
|---|---|
| 고객 `/order/:slug` | 고객이 현재 선택한 `ko`, `vi`, `en` 중 하나 |
| 고객 status/chat의 시스템 문구 | 화면을 보고 있는 고객의 현재 `ko/vi/en` |
| 캐셔 `/cashier/direct-orders` | 해당 캐셔가 현재 선택한 `ko/vi/en` |
| 직접 배달 주방 화면 | 해당 주방 직원이 현재 선택한 `ko/vi/en` |
| 관리자/분석/설정 화면 | 로그인한 운영자 POS의 현재 locale |
| 고객/직원 자유 채팅 | 원문 보존 + 현재 viewer locale의 서버 번역 표시 |

- [x] **viewer-locale 계약 문서화**: `request.locale`은 고객이 요청을
  만들 때 사용한 언어 기록일 뿐 캐셔·주방 UI locale을 바꾸지 못한다는
  우선순위를 고정한다. system code는 viewer locale로 번역하고 chat
  free text는 원문과 3개 언어 사본을 함께 보존한다. _생성:
  `DIRECT_ORDER_LOCALE_CONTRACT.md`; 수정:
  `DESIGN_BRIEF.md`, `UI_SPEC.md`, API/state contract의 언어 절; 재사용:
  현재 app locale과 direct snapshot; runtime 수정: 없음._
- [x] **모든 direct 화면의 3개 언어 selector 보장**: storefront, 고객
  status/chat, 캐셔, 주방, 관리자/분석/설정 화면에서 기존
  `LanguageSwitcher`와 `LocaleController`를 재사용해 `KO/VI/EN`을 모두
  선택할 수 있게 한다. 언어 선택은 현재 viewer의 기기에서 유지되고
  화면을 바꾸거나 새로고침해도 보존되어야 한다. 특정 role, 주문 locale,
  route가 언어를 강제로 덮어쓰거나 선택지를 숨기면 실패다. _재사용:
  전역 language switcher/controller와 SharedPreferences; 수정: selector가
  누락된 direct 화면의 navigation wiring만; 생성: 화면별 locale contract
  tests; 기존 POS 언어 선택 수정: 없음._
- [x] **서버 locale 허용값 3개 고정**: Edge `create_session`, locale 변경과
  `submit`, direct session/request CHECK가 `ko`, `vi`, `en`을 모두 허용하고
  그 외 값만 고정 validation error로 거부하는지 계약으로 고정한다.
  고객이 선택한 locale은 요청 metadata와 고객 화면 복구에만 사용하며
  staff 응답 locale 결정에는 사용하지 않는다. _확장: direct Edge/SQL
  locale tests와 API contract; 재사용: 현재 3-locale CHECK; runtime 수정:
  drift가 없으면 없음._
- [x] **화면별 localized snapshot 선택 통일**: 고객 메뉴는 고객 locale의
  `name_vi/name_en`, 캐셔·주방·관리 화면은 현재 staff locale에 맞는
  snapshot을 선택하는 direct-only helper를 사용한다. cashier detail에는
  이미 저장된 `name_ko/name_vi/name_en`을 사용하고, direct fulfillment
  ticket item에는 같은 snapshot 3개를 additive column으로 복사해 live
  menu를 다시 조회하지 않는다. 현재 `display_name_vi`는 호환용으로
  보존하며 staff locale이 `vi`이면 표시 결과가 완전히 동일해야 한다.
  고객의 주문 locale을 staff helper에 전달하지 않는다. _생성:
  direct-order localized-name helper와 unit tests; 수정: direct-only ticket
  migration 및 storefront/cashier/kitchen item label; 재사용: request item의
  `name_ko/name_vi/name_en`; 수정: 기존 QR/KDS/menu model 없음._
- [x] **system message·주소·채팅 언어 경계 적용**: DB에는 고정 system code를
  보존하고 고객과 직원 화면이 각자의 locale로 해석한다. Places/Geocoding
  요청 language는 현재 고객의 `ko/vi/en`을 사용하지만 Google 고유 지명은
  응답 그대로 보존한다. 고객/cashier chat은 Edge만 Google Translation을
  호출해 원문과 KO/VI/EN을 원자적으로 저장하고, 상세주소와 note는 원문
  표시한다. _수정: direct customer/staff message
  renderer와 direct Edge Google language parameter; 재사용: system code와
  exact address; 생성: viewer-locale fixtures; 타 채팅/지도 수정: 없음._
- [x] **교차 언어 E2E matrix 추가**: 고객 locale `ko/vi/en` × 캐셔 locale
  `ko/vi/en`의 9개 조합과 주방·관리 화면 각각 3개 locale을 검증한다.
  주문 후 viewer가 언어를 바꾸면 버튼·상태·system message·menu name과
  신규 알림은 즉시 새 viewer locale로 바뀌고, 다른 사용자의 선택에는
  영향이 없어야 한다. chat free text는 원문을 유지하면서 viewer 번역을
  표시한다. _확장: direct
  storefront/cashier/kitchen/admin UI, Edge와 SQL tests; 재사용: locale
  fixtures; 수정: 기존 POS locale tests 없음._

H4A 통과 기준:

- 모든 direct 화면에서 사용자는 `KO/VI/EN`을 선택할 수 있고 모든 시스템
  UI·menu·status·error·alert가 그 viewer의 현재 locale을 따른다.
- 고객 request locale이 무엇이든 캐셔·주방·관리 화면은 각 운영자가
  선택한 언어만 사용한다.
- 고객도 현재 선택한 `ko/vi/en`으로 UI를 보고, 채팅은 모든 화면에서
  원문을 보존하면서 선택 언어 번역을 표시한다. 주소와 note는 원문이다.
- 기존 전역 POS의 3개 언어 선택과 다른 화면의 언어 동작은 그대로다.

## Gate H4B — 캐셔 신규 외부 배달 알림 (receiver locale)

범위는 로그인된 캐셔가 `/cashier` 또는 `/cashier/direct-orders`를 열고
있는 동안 새 외부 배달 요청을 알리는 전용 in-app 알림뿐이다. 알림 문구는
주문 고객의 locale이 아니라 **알림을 받는 캐셔의 현재 POS locale**을
따른다. 캐셔가 알림을 받은 뒤 언어를 바꾸면 이후 알림도 새 선택을 따른다.

| 용도 | `ko` viewer | `vi` viewer | `en` viewer |
|---|---|---|---|
| 제목 | `배달 주문` | `Đơn giao hàng` | `Delivery order` |
| 신규 1건 본문 | `새 배달 주문이 들어왔습니다.` | `Có đơn giao hàng mới.` | `A new delivery order has arrived.` |
| 신규 여러 건 본문 | `새 배달 주문 {count}건이 들어왔습니다.` | `Có {count} đơn giao hàng mới.` | `{count} new delivery orders have arrived.` |
| 대기 chip | `배달 주문 · {count}` | `Đơn giao hàng · {count}` | `Delivery order · {count}` |
| 확인 동작 | `주문 확인` | `Xem đơn` | `View order` |

기존 계좌이체·SePay·주방·긴급 알림과 그 음원·문구·cursor·ack는 이 gate의
수정 범위가 아니다. 신규 알림음은 언어가 없는 독립 chime으로 제한한다.

이 gate의 구현 중 수정 금지 대상은 최소 다음 파일을 포함한다:

- `lib/main.dart`
- `lib/features/cashier/cashier_screen.dart`
- `lib/features/kitchen/kitchen_screen.dart`
- `lib/core/services/bank_transfer_alert_coordinator.dart`
- `lib/core/services/bank_transfer_alert_service.dart`
- `lib/core/services/bank_transfer_alert_sound.dart`
- `lib/core/services/bank_transfer_alert_sound_io.dart`
- `lib/core/services/bank_transfer_alert_sound_web.dart`
- `lib/core/services/sepay_push_notification_service.dart`
- `lib/core/services/emergency_order_voice_message.dart`
- 기존 alert 관련 test와 generated localization

- [x] **수정 범위와 frozen alert baseline 고정**: 기존 alert source/test의
  exact hash와 동작을 기록하고 신규 기능에서 import·공통화·refactor하지
  않는다. `main.dart`의 bank alert builder와 frozen cashier/KDS도 그대로
  유지한다. _생성: `DIRECT_ORDER_ALERT_CONTRACT.md`의 do-not-touch manifest
  및 hash regression test; 재사용: read-only 조사; 수정: 기존 alert 없음._
- [x] **알림 상태·표시 언어 계약 고정**: 새 request가
  `awaiting_quote`로 commit된 때만 알리고 replay, quote, chat, proof,
  approve/reject/cancel은 알리지 않는다. 주문의 `request.locale`을 읽어
  알림 언어를 정하지 않고 host의 `Localizations.localeOf(context)`만
  사용한다. 500ms burst는 한 번의 plural 알림으로 묶고 표시·닫기·이동은
  request 상태를 바꾸지 않는다. _생성: alert contract; 수정:
  direct-delivery design/UI/safety 문서의 알림 절만; 재사용: H4A locale
  우선순위와 수동 승인 불변식._
- [x] **payload-free 실시간 신호와 catch-up RPC 추가**:
  `direct_order_requests AFTER INSERT`에 기존
  `emit_pos_live_event('direct_orders')`를 연결하고, store-scoped cashier가
  cursor 이후 `(created_at,id,state)`와 현재 대기 수만 읽는 alert RPC를
  추가한다. event/RPC에는 고객 locale과 PII도 넣지 않는다. rollback,
  idempotent replay, UPDATE는 신규 event 0개여야 한다. _생성: additive
  direct alert migration/RPC/SQL tests; 재사용: payload-free feed와 actor
  guard; 수정: 기존 Realtime/alert DB 객체 없음._
- [x] **전용 cursor service와 route host 구현**:
  `DirectOrderArrivalAlertService`가 store별 cursor를 저장하고 Realtime과
  10초 safety poll을 drain한다. `DirectOrderArrivalAlertHost`는
  `/cashier`와 `/cashier/direct-orders` builder만 감싸고 role `cashier`일
  때만 작동한다. mixed-domain `*` event도 안전하게 재조회하며 network,
  storage, UI 오류는 host 내부에서 끝낸다. _생성: direct-only service,
  host와 injectable seams; 수정: `app_router.dart`의 두 builder만; 재사용:
  `posLiveEventsProvider`, SharedPreferences; 수정: `main.dart`, frozen
  cashier, 기존 alert coordinator 없음._
- [x] **receiver-locale 배너와 독립 chime 구현**: alert copy는 H4A의
  staff viewer locale로 제목/body/plural/chip/action을 선택한다. 같은
  주문이라도 캐셔가 `ko`를 선택하면 `배달 주문`, `vi`를 선택하면
  `Đơn giao hàng`, `en`을 선택하면 `Delivery order`를 표시한다. 확인
  동작은 승인 없이 direct queue로만 이동한다. sound는 별도 web/IO
  service의 짧은 비언어 chime이며 autoplay 실패가 시각 알림/cursor를
  막지 않는다.
  _생성: direct alert copy/widget/sound files; 재사용: POS design token과
  공개 audio API; 수정: ARB, `DirectOrderCopy`, 기존 alert sound 없음._
- [x] **locale·중복·장애·기존 알림 무변경 test**: 고객 주문 locale
  `ko/vi/en` × cashier viewer locale `ko/vi/en` 9개 조합에서 alert/UI/menu가
  항상 cashier locale만 따르는지 검사한다. 2초 Realtime, 10초 fallback,
  replay/reconnect/route/app restart 중복 0, burst plural,
  store/logout/dispose와 오류를 검증한다. 기존 입금 알림과 동시 발생해도
  기존 문구·음성 금액·cursor·ack·push와 source hash가 동일해야 한다.
  _생성: direct alert service/host/widget/integration tests; 재사용: 기존
  alert suite를 변경 없이 실행; 수정: 기존 expected value 없음._
- [x] **관측·운영 runbook 추가**: PII나 customer locale 없이 direct event
  수신·표시·chime 결과와 latency만 기록한다. 3개 cashier locale 전환,
  서로 다른 customer locale, Realtime 단절 복구와 storefront OFF를
  rehearsal한다.
  _추가: direct-delivery rollout/evidence 문서; 수정: 기존 alert monitoring
  없음._

H4B 통과 기준:

- 새 `awaiting_quote`는 정상 Realtime 2초 이내, 단절 시 10초 이내 알린다.
- 고객 주문 언어와 무관하게 캐셔가 `ko/vi/en` 중 선택한 언어로만 알림이
  표시되고, 언어 전환 후 다음 알림은 즉시 새 locale을 따른다.
- 같은 request는 같은 device에서 reconnect, polling, route 전환과 앱
  재시작 후 다시 울리지 않으며 알림 동작은 자동 승인을 만들지 않는다.
- 기존 계좌이체·SePay·주방·긴급 알림의 hash, test, 문구, 소리, cursor,
  ack와 호출 횟수는 baseline과 완전히 동일하다.

## Gate H5 — 전체 회귀와 release gate 재실행

- [x] **보강 suite 집중 실행**: schema, role/RLS, API/RPC, state,
  concurrency, failure injection, Google adapter, direct-order arrival
  alert의 viewer-locale UI, 전체 화면 `ko/vi/en` 경계, 기존 alert 무변경 회귀와
  frozen hash 테스트를 실행하고
  명령·결과 수·환경·exact source SHA를 기록한다.
  _수정: `IMPLEMENTATION_EVIDENCE.md`; 재사용: H1–H4B suite; runtime
  수정: 없음._
- [x] **변경하지 않은 저장소 gate 실행**:
  `bash scripts/check_repo.sh`, `git diff --check`, Deno check, disposable
  DB의 direct SQL suite와 웹 release build를 수행한다. 기존 scanner와
  expected value를 약화하지 않는다. _재사용: repository gate; 생성:
  실행 evidence; 수정: 없음._
- [x] **독립 harness review 수행**: design 문서와 code structure를 읽고
  security/data/state/UI/regression 범주를 검사한 뒤
  CRITICAL/HIGH/MEDIUM/LOW/CONFIRMED와 우선 수정 목록을 작성한다.
  CRITICAL/HIGH가 하나라도 남으면 pilot을 중단한다. _생성:
  `HARDENING_HARNESS_REPORT.md`; 재사용: CLAUDE.md review 형식; 수정:
  없음._
- [x] **상태 문서 동기화**: design status, API/data/state contract,
  checkbox, evidence와 rollout runbook을 소스 완료·로컬 검증·배포·실운영
  검증 상태로 구분해 갱신한다. _수정: direct-delivery design 문서만;
  재사용: exact test evidence._

H5 통과 기준:

- 모든 집중 suite와 기존 repository gate가 같은 runtime manifest에서
  로컬 및 분리 worktree로 통과한다. exact pushed Git SHA 검증은 H6다.
- frozen legacy hash가 유지된다.
- CRITICAL/HIGH finding이 남지 않는다.
- storefront는 여전히 disabled이며 production 완료로 보고하지 않는다.

## Gate H6 — 별도 승인이 필요한 매장 pilot과 출시

- [ ] **회계·운영·보안 승인**: 배송비 세무/service-line 처리, 은행정보,
  PII 보존, Google 예산, support 담당자와 emergency-stop 담당자를
  확정한다. _생성: 승인 evidence; 재사용: settings accounting gate;
  수정: 고객 데이터 없음._
- [ ] **exact-SHA GitHub check와 guarded deployment**: 별도 배포 요청이
  있을 때만 review된 SHA를 push하고 필수 GitHub check 성공 후
  `scripts/deploy_pos_production.sh`을 사용한다. _재사용: production
  gate; 수정: 명시적 승인 후 production만._
- [ ] **Google 링크 비공개 상태로 1개 매장 20건 pilot**: 주소 두 경로,
  현재 위치 허용/거부, requote, proof, SePay 보조, 동시 승인,
  reject/cancel, cutoff, 고객 청구보다 높은/낮은 Grab 비용, dispatch,
  complete, 고객·캐셔 `ko/vi/en` 교차 조합, 각 viewer의 언어 전환,
  Realtime 단절 fallback, 중복 알림 방지, 기존 알림 무변경과 session
  복구를 실행한다. 매 scenario마다
  request/order/payment/inventory/meInvoice/report/ticket을 대사한다.
  _생성: 개인정보 제거 pilot evidence; 재사용: private URL의 1개 enabled
  store; 수정: 통제된 pilot record만._
- [ ] **Google Business Profile 링크를 마지막에 공개**: pilot에서 중복,
  누락, 부분 재무 graph와 기존 회귀가 모두 0일 때만 유입을 연다.
  rollback은 link 제거와 storefront disable/pause이며 schema downgrade를
  하지 않는다. _재사용: rollout runbook; 수정: 최종 승인 후 외부
  link와 feature flag만._

H6 통과 기준:

- 20개 pilot case가 중복·누락·부분 record 0으로 대사된다.
- 기존 매장 업무에 관측 가능한 회귀가 없다.
- monitoring, support, budget alert와 emergency stop 담당자가 정해지고
  실제로 검증된다.

## 권장 실행 순서

1. H0 기준선 기록
2. H1 schema 계약과 부정 권한 matrix
3. H2 API/RPC 문서·에러 registry·전체 계약 테스트
4. H3 상태 matrix·진짜 동시성·단계별 실패주입
5. H4 Google spike와 H4A viewer-locale 경계를 먼저 완성
6. H4B 캐셔 알림의 receiver-locale·실시간·polling·기존 알림 무변경 완료
7. H5 전체 로컬/CI 회귀와 독립 review
8. 별도 운영·배포 승인 후에만 H6

H1과 H2의 문서 작업은 병행할 수 있다. H3는 live pilot 전에 반드시
완료한다. H4는 flag-off test route에서 진행할 수 있고 H4A가 고객/직원
언어 경계를 확정한 뒤 H4B가 receiver locale을 소비한다. 모두 storefront를
켜기 전에 완료해야 한다. H5는 H1–H4B의 마지막 source 변경 후 재실행해야
한다.
