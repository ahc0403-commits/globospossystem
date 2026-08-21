# 설계 브리프: 구글맵 유입형 직접 배달 주문

Date: 2026-08-21
Source: 사용자 요구사항과 현재 QR 주문·캐셔·KDS·결제·SePay·리포트 계약 재점검
Status: 소스·결합형 migration·테스트 구현 완료 — production 반영·외부 링크·storefront 활성화는 미실행

## 재검토 결론

기존 계획의 `선결제 주문을 기존 KDS 수명주기에 끼워 넣는 방식`은 위험하다. 기존 결제·주문상태·재고·마감·MISA 함수에 예외 분기가 필요하고, 그 분기가 일반 홀·포장·QR 주문을 깨뜨릴 가능성이 있기 때문이다.

개정안은 다음 두 도메인을 완전히 분리한다.

1. **재무 주문**: 캐셔가 입금을 승인하는 순간 기존 POS 계약만 사용해 생성되고 즉시 결제 완료된다.
2. **배달 조리 티켓**: 승인과 동시에 새 전용 테이블에 생성되며, 이후 주방 진행상태와 고객 진행상태만 관리한다.

승인 전에는 POS 주문이 없고, 승인 후에는 기존 POS 주문상태를 다시 변경하지 않는다. 주방 진행이 끝나도 재고·결제·MISA를 두 번째로 실행하지 않는다.

소프트웨어에 절대적인 무결함을 수학적으로 보장할 수는 없다. 대신 이번 기능의 회귀 허용치는 0으로 두고, 기존 기능 baseline과 전체 회귀 게이트가 하나라도 실패하면 다음 단계나 배포를 중단한다. 세부 기준은 `REGRESSION_SAFETY.md`에 고정한다.

## 제품 결정

- 별도 배달 앱과 Grab API 연동을 만들지 않는다.
- Google Business Profile/Google Maps 주문 링크는 매장별 공개 웹 storefront로 연결한다.
- 고객은 회원가입 없이 메뉴, 주소, 채팅, 계좌이체 증빙, Grab 추적 링크를 한 세션에서 이용한다.
- 주소는 `주소 한 줄 검색 후 지도 확인`과 `지도에서 직접 핀 선택` 두 경로를 제공한다. 상세주소는 고객이 직접 입력한다.
- 주소와 연락처는 고객 동의가 있을 때 같은 브라우저·매장 범위에만 저장한다.
- 증빙 이미지나 SePay 후보는 참고자료일 뿐이다. 캐셔의 수동 승인 없이는 주문·결제·주방 티켓이 생성되지 않는다.
- 캐셔가 고객 주소를 보고 Grab 앱에서 배송비를 확인하고 확정 금액을 입력한다.
- 증빙 제출 뒤 고객 청구 배송비는 잠근다. 실제 Grab 비용이 더 높으면 매장이 부담하고 더 낮아도 자동 환불하지 않는다.
- 캐셔와 주방은 기존 계정을 사용하되 직접 주문 전용 화면으로 진입한다. 새 직원 ID를 만들지 않는다.
- 직접 배달 POS 매출은 기존 총매출에 정확히 한 번 포함되고, 별도 분석 패널에서 직접 배달로 분리한다.
- 정확한 주소 PII와 지역·시간대 분석용 coarse location은 분리 저장한다.
- 고객·캐셔·주방·관리 화면은 각각 현재 사용자가 선택한 `ko/vi/en`으로
  표시한다. 주문 locale은 기록일 뿐 다른 사용자의 화면 언어를 바꾸지
  않으며, 자유 입력 채팅·상세주소·요청사항은 원문을 보존한다.

## 절대 불변식

1. 승인 전 `orders`, `order_items`, `payments`, `print_jobs`, 재고, MISA, 기존 KDS에 영향이 없어야 한다.
2. 승인 권한은 현재 매장 범위의 cashier/admin에게만 있다.
3. 승인 함수는 요청 하나당 재무 주문·결제·조리 티켓을 정확히 하나만 만든다.
4. 재무 주문은 기존 `process_payment(order, store, amount, method)`를 변경하지 않고 사용한다.
5. 직접 배달 때문에 기존 결제, 주문상태, 품목상태, 마감, 프로모션, KDS, 출력, MISA, 리포트 함수를 재정의하지 않는다.
6. 승인 후 조리 진행은 새 직접 배달 티켓에만 기록한다. 완료 시 재고와 MISA를 다시 실행하지 않는다.
7. 증빙 업로드, SePay 수신, 금액 일치는 자동 승인을 만들 수 없다.
8. Grab 링크와 실제 Grab 비용은 이미 확정된 고객 결제금액을 바꿀 수 없다.
9. feature flag가 꺼져 있으면 새 공개 경로만 닫히고 기존 POS 화면과 업무는 이전과 동일해야 한다.
10. 기존 테스트 기대값을 직접 배달 기능에 맞추기 위해 변경하지 않는다. 실제 기존 결함을 별도 승인으로 수정하는 경우만 예외다.

## 동결할 기존 코어

다음 영역은 V1 구현 중 동작이나 시그니처를 변경하지 않는다.

- `process_payment` 및 현재 결제·할인·VAT·서비스차지 처리
- `recalc_order_status`, `update_order_item_status`, `complete_kitchen_order`
- 일일 cutoff/finalization 함수와 트리거
- scheduled promotion 동기화 함수와 트리거
- 기존 QR RPC, QR route와 `qr_order_screen.dart`
- 기존 KDS provider, paperless/emergency ledger와 화면
- 기존 `enqueue_print_jobs`, print agent와 출력 routing
- 재고 차감과 MISA/e-invoice enqueue 함수·트리거
- 기존 디지털 영수증과 캐셔 미결제 큐
- 기존 매출 view/RPC/query와 Deliberry·Photo·Office coupling

새 migration이 위 객체를 `ALTER`, `DROP`, `CREATE OR REPLACE`하면 자동으로 실패시키는 계약 검사를 둔다.

## 재사용·최소 수정·신규 구현

### 그대로 재사용

- 공개 메뉴 모델, 메뉴 판매 가능 여부와 가격 검증 규칙
- `PaymentTotalCalculator`와 현재 `process_payment`의 금액 계약
- `VietQrPayload.bankTransfer()`의 VietQR 생성 규칙
- `image_picker` 및 결제증빙 이미지 리사이즈·압축 방식
- Supabase, Riverpod, GoRouter, `shared_preferences`, `pos_live_events`
- 현재 인증, 역할, 매장 범위, HCM 시간대와 디자인 토큰
- 기존 POS order/payment/inventory/MISA/report 파이프라인
- 기존 SePay 입금 원장과 알림. 자동 승인에는 사용하지 않는다.

### 최소 수정

- `app_router.dart`: 공개 storefront, 캐셔 직접 주문함, 직접 배달 주방 화면 route 등록
- `role_routes.dart`: 기존 cashier/admin/kitchen 계정에 새 route 권한 추가
- 신규 기능이 안정화된 후에만 기존 캐셔·주방 헤더에 feature-flagged 진입 버튼 추가
- 새 리포트 패널을 독립 route 또는 격리된 섹션으로 추가

기존 QR 화면에서 컴포넌트를 추출하지 않는다. V1은 일부 UI 중복을 허용해 QR 회귀 위험을 없앤다. 초기 pilot은 기존 화면의 진입 버튼도 생략하고 직접 URL/bookmark로 운영할 수 있다.

### 새로 구현

- storefront, 주소 선택기, 기기 주소 캐시, 고객 세션
- 요청별 채팅, private 이미지 증빙, quote와 VietQR
- 캐셔 직접 주문함, 수동 승인, Grab 링크와 실제 비용 기록
- 직접 배달 전용 조리 티켓과 `/kitchen/direct-orders`
- 직접 배달 재무·지역·시간대 분석 RPC와 UI
- 공개 API rate limit, 토큰 만료, PII 보존·익명화

## 핵심 아키텍처

### 1. 승인 전: 요청 데이터만 저장

고객이 장바구니와 주소를 제출하면 `direct_order_*` 테이블만 사용한다.

- 요청 및 메뉴 snapshot
- exact address/contact와 coarse location fact
- 고객 session hash
- 채팅 메시지와 증빙 object reference
- 캐셔 quote와 SePay 후보 link
- 상태 event와 audit

이 단계에서는 POS/KDS/출력/재고/MISA side effect가 0이어야 한다.

### 2. 수동 승인: 기존 결제 계약 안에서 원자 처리

`approve_direct_delivery_request`는 새 함수지만 기존 코어를 수정하지 않는다. 한 DB transaction에서 다음 순서로 처리한다.

1. cashier/admin, 매장 범위, feature flag, 요청 상태, proof, locked quote, version, idempotency를 검증한다.
2. 안전 운영 조건을 검증한다: 승인 시각 21:30 이전, `pos_print` 매장, active emergency session 없음, V1에서 active scheduled promotion 없음.
3. table 없는 일반 POS 재무 주문을 `sales_channel='delivery'`, `order_source='staff'`로 생성한다.
4. 검증된 메뉴 품목을 기존 허용 타입으로 만들고, 결제가 허용되도록 모든 재무 품목 상태를 `served`로 둔다.
5. 고객 청구 배송비는 기존 허용 타입 `service_charge` 행, 표시명 `Phí giao hàng`으로 만들고 그 행 ID와 금액 snapshot을 `direct_order_financials`에 연결한다.
6. 새 `direct_delivery_fulfillment_tickets`와 item snapshot, request-order-ticket link를 만든다. 아직 transaction이 commit되지 않았으므로 주방에는 보이지 않는다.
7. 기존 `process_payment(..., 'BANKTRANSFER')`를 transaction의 마지막 핵심 단계로 그대로 호출한다.
8. 주문이 `completed`가 되었고 결제 총액이 locked quote와 정확히 일치하는지 검증한 뒤 payment link를 기록한다. 다르면 전체 rollback하고 새 quote를 요구한다.
9. 승인자, event, 고객 system message를 기록하고 transaction을 commit한다.

어느 단계든 실패하면 주문·결제·티켓이 모두 rollback된다. 중복 요청과 동시 승인은 unique constraint와 idempotency key로 같은 결과를 돌려준다.

`process_payment`가 재무 주문을 완료하므로 재고 차감과 MISA enqueue는 기존 규칙대로 이 순간 한 번만 발생한다. MISA는 현재와 같이 결제를 막지 않는 비동기 계약을 유지한다.

### 3. 승인 후: 별도 조리 티켓만 진행

주방은 `/kitchen/direct-orders`에서 새 ticket provider/RPC만 사용한다.

- `pending → preparing → ready → dispatched → completed`
- 품목별 준비 상태와 전체 ticket 상태
- 고객에게 필요한 coarse progress event
- cashier의 Grab 링크와 dispatch 기록

이 상태 변경은 기존 `orders`와 `order_items`를 업데이트하지 않는다. 따라서 기존 `recalc_order_status`, KDS ledger, inventory, payment, MISA, daily cutoff를 재호출하지 않는다.

기존 주방 화면과 새 직접 배달 화면 사이에는 provider/state mutation을 공유하지 않는다. 새 화면 오류가 기존 KDS에 전파되면 release blocker다.

### 4. 출력은 보조 수단

직접 배달 KDS 티켓을 조리 업무의 source of truth로 삼는다. 초기 V1은 기존 print agent나 `enqueue_print_jobs`를 변경하지 않는다.

신규 객체만으로 안전한 전용 enqueue가 가능하다는 계약 테스트가 통과한 뒤 kitchen slip을 best-effort로 추가할 수 있다. 출력 실패는 재무 승인이나 티켓 생성을 취소하지 않고 새 화면에 재출력 경고를 표시한다. 기존 출력 계약 수정이 필요하면 V1에서 출력 기능을 제외한다.

## 금액 계약

- quote RPC는 canonical menu와 현재 매장 VAT/service-charge 정책을 읽어 예상 금액을 계산한다.
- 기존 service-charge 정책은 그대로 적용한다. 직접 배달 예외를 만들지 않는다.
- 배송비는 별도 `service_charge` 행으로 결제 총액에 포함하고 `direct_order_financials.delivery_fee_item_id`로 식별한다.
- 기존 POS 화면에서 일반 service charge 합계에 배송비가 포함될 수 있으므로 고객·직접 주문 화면의 breakdown은 `direct_order_financials`를 기준으로 별도 표시한다.
- 배송비의 MISA/e-invoice 표현은 현재 service item 계약을 그대로 따른다. 세무상 이 계약을 사용할 수 있는지 운영·회계 승인을 받아야 하며, 허용되지 않으면 pilot을 시작하지 않는다.
- inclusive/exclusive VAT, 음식/주류, service charge, 배송비, VND 반올림 fixture에서 quote와 실제 `process_payment` 결과를 rollback transaction으로 비교한다.
- quote 계산 drift로 재무 주문이 완납되지 않거나 금액이 다르면 승인 전체를 rollback한다.
- scheduled promotion은 trigger 간섭으로 quote drift 위험이 있으므로 V1에서 활성 프로모션 매장은 storefront/승인을 차단한다. 프로모션 지원은 별도 검증 작업이다.

## 상태 모델

| 요청 상태 | 고객 화면 | 캐셔 동작 | 기존 POS 영향 | 직접 조리 티켓 |
|---|---|---|---|---|
| `draft` | 메뉴·주소 작성 | 없음 | 없음 | 없음 |
| `submitted` | 요청 접수·채팅 | 주소/메뉴 확인 | 없음 | 없음 |
| `quoted` | 배송비·최종금액·VietQR | 재견적/문의 | 없음 | 없음 |
| `awaiting_payment_review` | 수동 입금 확인 대기 | proof/SePay 검토 | 없음 | 없음 |
| `approved` | 접수·조리 대기 | Grab 수동 호출 가능 | 완료 주문·결제 1건 | 생성됨 |
| `preparing` | 조리 중 | 진행 확인 | 추가 변경 없음 | 진행 중 |
| `ready` | 배차/픽업 대기 | Grab 링크 발송 | 추가 변경 없음 | 준비 완료 |
| `dispatch_link_sent` | Grab 링크 확인 | 실제 Grab 비용 기록 | 추가 변경 없음 | 배차됨 |
| `completed` | 배달 완료 | 완료 보관 | 추가 변경 없음 | 완료 |
| `rejected/cancelled/expired` | 사유·재주문 안내 | 거절/정리 | 승인 전이면 없음 | 없음 |

증빙 업로드나 SePay 후보 연결은 `approved` 전환 권한이 없다.

## 고객 경험

### Google Maps 유입과 메뉴

- 공개 URL은 `/order/:storeSlug?source=google_maps`를 사용한다.
- 로그인 화면으로 리다이렉트하지 않는다.
- stable slug, 매장 enable/open 상태, 최소주문과 마감 상태를 서버가 검증한다.
- QR 화면 코드를 수정하지 않고 독립 storefront를 만든다. 메뉴 모델과 디자인 규칙만 재사용한다.
- direct request는 `qr_place_order`를 호출하지 않는다.

### 주소 입력 두 경로

1. `주소 한 줄 검색`: Google Places 후보 선택 → 지도 핀 확인/미세조정 → reverse geocode 확인
2. `지도에서 선택`: browser 위치 허용 시 현재 위치, 거부 시 매장 중심 → 탭/드래그 → 주소 확인

공통 필수값은 좌표, 표시 주소, 상세주소, 고객명, 전화번호, 위치 확인 체크다. 위치 권한 거부는 정상 fallback으로 처리한다. 지도/Places 장애는 직접 주문만 중단하며 기존 POS에는 영향이 없어야 한다.

### 같은 기기 주소 기억

- 명시적 동의가 있을 때만 store-scoped, versioned local storage에 저장한다.
- 표시주소, 상세주소, 좌표, place id, 이름, 전화번호, 확인시각을 저장한다.
- 다음 방문에 prefill하고 `지도에서 다시 확인`과 `저장주소 삭제`를 제공한다.
- 계정 동기화나 기기 간 복구는 V1 범위 밖이다.

### 자체 채팅과 증빙

- 계정을 만들지 않고 192-bit 이상 난수 secret을 발급하며 DB에는 SHA-256 hash만 저장한다.
- secret은 해당 브라우저의 store-scoped 저장소에만 두고 URL query,
  navigation history, log 또는 Realtime payload에 넣지 않는다. 공유 가능한
  재개 링크가 향후 추가될 때만 서버로 전송되지 않는 일회성 URL fragment
  handoff를 별도 설계한다.
- 고객 public API는 Edge Function에서 secret body 검증, rate limit, 만료 검증 후 접근한다.
- 메시지는 append-only `text`, `image`, `system`, `quote`, `grab_link`다.
- 증빙 이미지는 private bucket, 제한된 MIME/크기, one-time signed upload, 짧은 signed read를 사용한다.
- 고객 화면은 polling, 캐셔 화면은 store-scoped event signal과 polling fallback을 사용한다.
- 항상 `입금 캡처 전송은 주문 확정이 아님`을 표시한다.

### 화면 사용자 기준 언어

- 모든 direct 화면은 기존 전역 `LanguageSwitcher`, `LocaleController`,
  기기 SharedPreferences를 재사용한다.
- 시스템 UI·상태·오류·고정 system code·메뉴 snapshot은 현재 viewer
  locale을 따른다. 고객 request/session locale은 staff 화면에 전달하지
  않는다.
- request와 fulfillment ticket은 `name_ko/name_vi/name_en`을 모두
  snapshot으로 보존하며, 캐셔와 주방은 live menu가 아니라 자신의 현재
  locale에 맞는 snapshot을 선택한다.
- 세부 우선순위와 번역 금지 데이터는 `DIRECT_ORDER_LOCALE_CONTRACT.md`가
  권위 문서다.

## 캐셔·주방·Grab 운영

### 캐셔

- 기존 cashier/admin 로그인과 store scope를 사용한다.
- `/cashier/direct-orders`는 `신규 / 배송비 전달 / 입금 확인 / 조리·배차 / 완료`로 구분한다.
- desktop은 목록/상세/채팅 3영역, 작은 화면은 목록→상세 전환으로 구성한다.
- 승인 확인창에 주소, 상세주소, 품목, 배송비, 최종금액, proof, SePay 후보를 함께 표시한다.
- 단일 `입금 확인 및 주문 확정` 동작만 승인을 만든다.
- 초기 pilot은 기존 `/cashier`를 수정하지 않고 직접 URL로 진입한다.
- 새 요청 INSERT만 별도 in-app 배너와 비언어 chime으로 알린다. 배너는
  현재 캐셔 viewer locale을 사용하고 확인 동작은 direct queue로 이동만
  하며 승인하지 않는다. 기존 cashier 소스와 기존 알림은 수정하지 않고
  router host로만 격리한다.

### 주방

- 기존 kitchen 계정으로 `/kitchen/direct-orders`에 진입한다.
- 주소·전화·증빙·결제정보는 주방 화면에 노출하지 않는다.
- DIRECT DELIVERY/PAID, 주문번호, 경과시간, 메뉴와 옵션만 표시한다.
- 기존 KDS와 상태 저장소를 공유하지 않는다.

### Grab

- 매장이 Grab 앱에서 기사와 요금을 직접 확인한다.
- cashier가 allowlist를 통과한 HTTPS Grab 추적 URL을 채팅에 보낸다.
- 실제 Grab 비용은 선택적으로 기록하고 `actual - charged`를 매장 부담 차이로 분석한다.
- Grab 링크/비용 입력은 payment/order total을 수정할 수 없다.

## 데이터 계약

새 additive 객체만 만든다. 기존 core table의 constraint나 column을 바꾸지 않는다.

- `direct_order_storefronts`
- `direct_order_sessions`, `direct_order_public_access_limits`
- `direct_order_requests`, `direct_order_request_items`, `direct_order_events`
- `direct_order_request_addresses`, `direct_order_location_facts`
- `direct_order_messages`, private storage path metadata
- `direct_order_quotes`, `direct_order_sepay_candidates`
- `direct_order_financials`: request/order/payment/delivery-fee-item 연결과 금액 snapshot
- `direct_delivery_fulfillment_tickets`, `direct_delivery_fulfillment_items`
- `direct_order_dispatches`

기존 `orders`, `order_items`, `payments`에는 승인 transaction이 현재 허용값과 현재 함수 계약으로 insert한다. `order_source='staff'`, `sales_channel='delivery'`, 배송비 `item_type='service_charge'`를 사용하므로 기존 constraint 변경이 필요 없다.

## 매출·주소 빅데이터

- 기존 POS report view/query를 교체하지 않는다.
- 재무 주문의 기존 payment는 현재 delivery 매출에 한 번 포함된다.
- 새 direct analytics RPC가 `direct_order_financials`와 payment를 연결해 음식, 고객청구 배송비, 총수금, 실제 Grab 비용, 매장부담 차이를 보여준다.
- Deliberry `external_sales`와 `delivery_settlements`에는 쓰지 않는다.
- 지역 분석은 exact address가 아니라 district/ward/coarse cell × 요청시각/승인시각/hour/day-of-week를 사용한다.
- 요청수, 승인율, 매출, 평균주문액, 메뉴 선호, source를 집계한다.
- 소수 주문 셀은 최소 집계 기준 아래에서 숨긴다.
- exact address/contact는 운영 보존기간 뒤 익명화하되 coarse fact와 재무 audit는 보존한다.

## 마감·운영 제한

- 직접 주문 승인 마감은 21:30 이전으로 둔다. 21:30 이후 proof가 와도 다음 영업 안내 또는 거절만 가능하다.
- 기존 21:45 grace payment와 22:20 finalization 예외를 직접 주문에 만들지 않는다.
- 21:30 이전 승인된 직접 조리 티켓은 이후에도 새 테이블에서 진행할 수 있다.
- V1 enable 조건은 `pos_print`, emergency session 없음, active scheduled promotion 없음, 승인된 세금/은행 설정이다.
- paperless/emergency 매장, promotion 지원, 승인 후 고객 취소/자동 환불은 V1 밖이다.
- 승인 후 취소는 기존 관리자 refund/void 절차와 별도 ticket cancellation/reconciliation을 함께 수행한다. pilot 중 고객 self-cancel은 제공하지 않는다.

## 기능 플래그와 rollback

- 모든 storefront는 기본 `disabled`다.
- flag off는 신규 요청을 즉시 막고 기존 POS·QR·KDS·캐셔 업무에 영향을 주지 않는다.
- 열린 요청은 운영자가 거절·만료·정리할 수 있고 새 승인은 정책에 따라 차단할 수 있다.
- pilot 중 문제가 생기면 Google 주문 링크 제거와 storefront flag off로 유입을 중단한다.
- additive 데이터와 audit는 보존한다. 기존 DB 객체를 downgrade하거나 삭제하는 rollback은 하지 않는다.
- production은 별도 요청이 있을 때만 `scripts/deploy_pos_production.sh`와 exact pushed SHA GitHub Actions 성공 후 진행한다.

## V1 범위 제외

- Grab 견적·배차 API 자동화
- 입금 OCR 또는 자동 승인
- 고객 계정과 다기기 주소 동기화
- 기존 QR 컴포넌트 refactor
- 기존 KDS queue/provider에 직접 주문 병합
- 기존 `process_payment`, 상태함수, cutoff, promotion, MISA, report view 수정
- paperless/emergency 매장의 직접 주문
- scheduled promotion과 직접 주문의 동시 지원
- 자동 환불·추가청구·고객 self-cancel

## 완료 조건

1. 새 migration이 기존 core 객체를 변경하지 않는다는 정적 계약 검사가 통과한다.
2. feature flag off에서 기존 route, QR, cashier, KDS, 결제, 출력, MISA, reports baseline이 완전히 동일하다.
3. 승인 전 POS side effect 0, 수동 승인 후 order/payment/ticket 각 1건이 SQL 동시성 fixture로 증명된다.
4. quote와 실제 unchanged `process_payment`가 모든 금액 fixture에서 일치하고 mismatch는 완전 rollback된다.
5. 직접 ticket 상태 변경이 기존 orders/order_items/inventory/MISA를 변경하지 않는다는 테스트가 통과한다.
6. exact address/chat/proof의 cross-request·cross-store 접근이 차단된다.
7. 기존 기능 전체 회귀, 신규 unit/widget/SQL/integration, `scripts/check_repo.sh`가 모두 통과한다.
8. 한 매장 내부 pilot 20건을 payment, inventory, MISA job, 기존 총매출, direct breakdown, ticket과 대사해 중복·누락이 0이다.
9. 운영·회계·보안 승인 없이는 Google Maps 공개 링크와 production flag를 켜지 않는다.
