# 배달 주문 인원·접수 중지·배달 앱 변경·방문 포장 전환 개선 계획

작성일: 2026-10-05, 베트남 시간.

상태: 현재 작업 디렉터리의 소스와 migration 순서를 조사하고 관련 Flutter 테스트 19건을 실행했다. 이 문서는 개선 계획이며 기능 구현, 운영 DB 조회·migration 적용, 앱 배포는 수행하지 않았다. 기존 수정 파일과 사용자 소유 untracked 파일은 유지했다.

## 1. 조사 결과

| 요구사항 | 현재 구현 | 판정 |
|---|---|---|
| 식사 인원 입력 및 일회용품 준비 수량 | 고객 폼·submit payload·Direct Order request에 인원 필드가 없다. 승인 시 일반 `orders.guest_count`도 NULL로 저장한다. | 미구현 |
| 배달 CLOSED 후 기존 주문 계속 처리 | Cashier의 OPEN/CLOSED는 `is_paused`만 변경한다. 신규 submit은 거절하고, 기존 요청의 견적·승인에서는 pause 조건을 제거했다. 고객 화면은 기존 주문 현황을 유지한다. | 소스상 구현됨, 관련 로컬 테스트 통과 |
| 신규 고객에게 주문량 안내 | 주문 현황이 없는 고객에게 KO/VI/EN 중지 안내와 ‘다시 확인’을 표시한다. 열린 화면에서 접수 중지가 발생해도 submit 거절 후 안내로 전환한다. | 구현됨 |
| Grab 외 BE 등 배달 링크 | Flutter URL 검사, dispatch RPC 두 경로, DB CHECK가 모두 Grab 도메인만 허용한다. 화면·고객 진행 단계·분석 항목에도 Grab 이름을 고정 사용한다. | 개선 필요 |
| 기사 미배정 시 방문 포장으로 전환 | 배송 방법 변경 RPC·고객 동의·포장 수령 완료 기능이 없다. `pickup_code`는 배달 티켓의 인계 코드이며 포장 전환 기능을 의미하지 않는다. | 미구현 |

### 주요 코드 근거

- `lib/features/direct_order/direct_order_storefront_screen.dart:245`: 현재 접수 폼 검증 및 제출. 인원 입력 없음.
- `lib/features/direct_order/direct_order_service.dart:141`: submit에 메뉴·주소·메모만 전달.
- `supabase/migrations/20260907130000_direct_delivery_manual_addresses.sql:19`: 현재 submit 본문. 재시도 결과 반환 후 `is_paused`를 검사하고 신규 요청만 생성.
- `supabase/migrations/20260821130000_direct_delivery_ordering.sql:2127`: 승인 시 `guest_count=NULL`로 일반 주문 생성.
- `supabase/migrations/20260907150000_cashier_direct_delivery_availability.sql:49`: Cashier pause RPC 및 기존 견적·승인 pause guard 제거.
- `lib/features/direct_order/direct_order_storefront_screen.dart:770`: pause 중에도 기존 주문 현황을 표시.
- `lib/features/direct_order/direct_order_copy.dart:15`: 신규 고객용 주문량 안내 및 기존 주문을 유지한다는 직원 설명.
- `lib/features/direct_order/direct_order_staff_service.dart:18`: `normalizeGrabTrackingUrl`의 Grab 도메인 제한.
- `supabase/migrations/20260821130000_direct_delivery_ordering.sql:409`: dispatch 테이블의 Grab 전용 URL CHECK.
- `supabase/migrations/20260907100000_direct_delivery_cash_payout_daily_closing.sql:24`: 실제 비용·현금 지급을 기록하는 dispatch 경로에도 Grab URL 제한.
- `supabase/migrations/20260908120000_direct_order_pilot_safety.sql:738`: 현행 앱이 호출하는 배송비 지급 방식별 dispatch RPC에도 Grab URL 제한.
- `supabase/migrations/20260910130000_direct_order_customer_payment_and_status.sql:606`: 현재 티켓 완료는 `dispatched -> completed`만 허용. 방문 포장 `ready -> completed` 경로 없음.
- `supabase/migrations/20260604001000_pos_payment_refund_void_adjustments.sql:74`: 기존 부분 환불 원장 RPC. 원결제를 수정하지 않으며 실제 은행 송금을 실행하지 않는다.

8월 최초 함수만 보고 수정하면 안 된다. 이후 적용되는 운영시간, KDS routing, 현금 지급, 배송비 지급 방식, 고객 사진 재전송, 10월 직원 사진 확인 승인 변경까지 보존해야 한다.

## 2. 접수 중지에서 구분해야 할 두 스위치

| 동작 | 결과 | 운영 용도 |
|---|---|---|
| Cashier ‘배달 CLOSED’ / `is_paused=true` | 신규 접수 중지. 기존 요청·주문 현황·채팅·견적·입금 승인·조리·인계는 유지. | 주문량이 많을 때 사용할 스위치 |
| 관리자 ‘주문 페이지 활성화’ OFF / `is_enabled=false` | public storefront 조회가 실패한다. 고객 `_load()`가 주문 현황을 복구하기 전에 실패하고, 기존 미승인 요청의 견적·승인도 활성화 조건에서 차단된다. | 기술적 비활성화. 일시 접수 중지와 분리 필요 |

`is_enabled` 영향 근거는 storefront 조회의 활성화 조건, 고객 `_load()`의 storefront 우선 조회, 견적·승인 함수에 남아 있는 `is_enabled=true` 조건이다. pause migration은 `is_paused` 조건만 제거했다.

개선 방향:

1. 주문량 때문에 ‘닫기’는 기존 `is_paused` 계약을 사용한다. 이 기능을 새로 만들 필요는 없다.
2. 관리자 화면도 ‘신규 배달 접수 일시 중지’와 ‘주문 페이지 활성화’를 명확히 구분한다. 진행 중 요청이 있으면 기술적 비활성화로 기존 처리를 중단하지 않도록 서버에서 보호한다.
3. 유효한 저장 세션이 있는 고객은 storefront 조회 실패와 기존 주문 현황 복구를 분리한다. 기존 주문의 상태·채팅은 세션과 해당 주문 소유권을 검증해 접근한다.
4. 신규 주문 시작·메뉴/주소 탭 진입에서 접수 가능 여부를 다시 확인한다. 현재 polling은 주문 상태만 조회하므로, 처음 페이지를 열었을 때 OPEN이었다면 접수 버튼을 누를 때까지 CLOSED를 알지 못할 수 있다.
5. 화면 분기를 ‘기존 status가 있느냐’만으로 판단하지 않고 ‘기존 주문 보기 / 신규 주문 시작’으로 구분한다. CLOSED 중 기존 고객도 추가 주문은 막되 기존 현황·주문 목록으로 돌아갈 수 있게 한다. 장바구니 내용은 일시 중지 안내만으로 삭제하지 않는다.
6. 신규 submit과 CLOSED의 경합, 응답 유실 후 동일 `client_request_id` 재시도 계약을 유지한다. 이미 생성된 요청의 재시도는 CLOSED여도 같은 요청을 반환한다.

신규 안내 문구 초안: **“현재 주문이 많아 배달이 지연되고 있습니다. 잠시 후 다시 주문해 주세요.”** 기존 긴 안내를 이 문구로 정리하고 VI/EN도 같은 의미로 맞춘다.

기존 주문 복구는 해당 브라우저의 유효한 저장 세션을 기준으로 한다. 브라우저 저장소 삭제·다른 기기에서의 주문 복구는 현재 별도 인증 수단이 없으므로 이 기능의 보장 범위와 구분한다.

## 3. 식사 인원과 일회용품

고객의 주소·연락처 입력 화면에 필수 항목을 추가한다.

- 질문: **“몇 명이 식사하시나요?”**
- 설명: “입력하신 인원수에 맞춰 일회용품을 준비합니다.”
- 숫자 입력과 +/- 조작을 제공하고 임의로 1명을 확정하지 않는다. 초안은 정수 1~100명이며 실제 운영 상한은 구현 전에 정한다.
- 주문 확인 화면, 직원 주문 상세, 주방의 포장 준비 정보, 포장·인계 전표에 `식사 인원 N명 · 일회용품 N세트`를 표시한다. 세트별 구성은 매장 운영 기준을 따른다.

데이터와 검증:

1. `direct_order_requests.diner_count`를 추가하고 새로운 고객 앱의 submit에 포함한다. 인원은 주문별 정보이며 저장 주소에 포함하지 않는다.
2. Flutter·Edge·SQL에서 누락, 0, 음수, 소수, 문자열, 상한 초과를 검증한다. 메뉴 수량으로 인원을 추정하지 않는다.
3. 기존 request는 NULL을 유지하고 ‘미입력’으로 표시한다. 기존 주문과 진행 중 요청의 재시도를 차단하지 않는다. 새 submit 계약은 버전 또는 capability로 구분하여 새 앱에서 인원을 필수로 받는다.
4. 승인 시 `orders.guest_count`에 확정 인원을 기록하고 Direct Order 조회·주방·전표에는 같은 값을 전달한다. 인원은 VAT·음식 수량·결제 금액 계산에 사용하지 않는다.
5. 직원이 이전 주문의 미입력 인원을 확인해 보충하거나 포장 전에 수정할 경우 기존 매장 권한·버전 검증·변경 감사 기록을 사용한다. 배송 방법을 바꿔도 인원은 유지한다.

## 4. Grab·BE·기타 배달 앱 지원

기사 호출은 직원이 각 배달 앱에서 수행하는 현재 수동 운영을 확장한다. 배달 앱 API 연동이나 자동 배차 시스템을 새로 만들지 않는다. 배송지에 검증된 좌표가 없는 수동 주소 주문이므로 ‘가깝다’는 자동 거리 판정으로 전환하지 않는다.

직원 흐름:

1. Grab 기사 미배정 시 사유를 기록하고 BE·기타 앱으로 기사 호출을 시도한다.
2. 최종 배달 업체를 `Grab / BE / 기타`로 선택한다. 기타는 업체 이름을 함께 기록한다.
3. 확정된 기사의 공유 링크와 실제 배송비를 입력한다. 공유 링크가 없는 앱은 업체·기사 연락 정보로 인계를 기록할 수 있다.
4. 고객에게 업체명과 추적 링크 또는 기사 안내를 표시한다. 버튼·진행 단계·영수증·분석 이름은 ‘배송 추적’, ‘배달 기사에게 전달’, ‘실제 배달 비용’으로 정리한다.

서버와 호환성:

- 일반 배송 URL 검증으로 바꾼다. 유효한 HTTPS URL, 길이 상한, 호스트 존재를 검증하고 Grab 도메인 여부는 오류 조건에서 제거한다. 위험한 scheme·자격정보 포함 URL·잘못된 형식은 계속 거절한다.
- Flutter 검사뿐 아니라 dispatch RPC 두 경로와 `direct_order_dispatches_url_valid`를 함께 수정한다. 서버 CHECK가 남아 있으면 화면 변경만으로 BE 링크를 저장할 수 없다.
- direct dispatch에 업체 정보를 추가한다. 기존 `grab_tracking_url`, `actual_grab_fee` 물리 필드는 첫 단계에서 유지하고 새 API·모델·화면은 일반 배송 명칭으로 투영한다. 기존 데이터의 업체는 Grab으로 해석한다. 공유 링크 없는 배달은 새 RPC에서만 명시적으로 처리한다.
- 업체와 배송비 지급 방식은 별개다. `customer_direct`는 고객이 기사에게 직접 지급하며 매장 현금 지출을 만들지 않는다. `store_prepaid`는 실제 지급 비용과 기존 현금마감 대사를 유지한다.
- 기사 호출 실패만으로 배달비 지출이나 `dispatched`를 기록하지 않는다. 새 dispatch는 준비 완료와 실제 인계를 확인한 경로에서 버전 검증으로 한 번만 처리한다. 동일 요청 재시도로 중복 고객 메시지·현금 지급이 생기지 않도록 한다.
- 배달 앱 변경은 견적·결제·재고를 다시 생성하지 않는다. 이미 승인된 고객 청구액은 보존하고, 매장 실제 비용만 별도로 기록한다. 결제 전 고객 청구액 변경은 기존 재견적 흐름을 사용한다.

## 5. 기사 미배정 후 방문 포장 전환

권장 흐름:

1. 직원이 배달 기사 미배정을 확인하고 **‘방문 포장 전환 제안’**을 누른다.
2. 고객의 기존 주문 페이지에 “배달 기사를 배정하지 못했습니다. 방문 포장으로 변경하시겠어요?”를 표시한다. 매장 주소·연락처, 주문번호, 준비 상태, 배달비 환불 여부를 함께 안내한다.
3. 고객이 **‘방문 포장으로 변경’ / ‘배달 대기 유지’**를 선택한다. 고객 동의 없이 음식 수령 방식을 바꾸지 않는다.
4. 동의 후 같은 주문을 포장으로 바꾸고 직원·주방에는 ‘방문 포장’ 표시를 갱신한다. 기존 인원·음식·메모·조리 진행을 유지한다.
5. 준비 완료 후 직원이 기존 주문번호/인계 코드를 확인하고 **‘고객 수령 완료’**를 처리한다. 포장 주문은 ‘배달 중’ 단계를 거치지 않는다.

데이터와 상태:

- 현재 인도 방법을 `delivery / pickup`으로 관리한다. 배달 업체, 배송비 지급 방식, 요청 승인 상태와 구분한다.
- 기존 request와 ticket을 계속 사용한다. 포장 전환 때문에 새 주문·payment·주방 티켓을 만들거나 이미 결제된 `orders.sales_channel`을 소급 변경하지 않는다.
- 승인 상태 `approved`는 유지하며 포장 티켓에는 `pending -> preparing -> ready -> completed`를 허용한다. 수령 완료는 직원 권한으로만 처리한다.
- 제안에는 요청·견적·현재 인도 방법/티켓 버전을 묶는다. 고객 동의 RPC는 세션·해당 요청 소유권을 검증하고 동일 제안 재실행에 같은 결과를 반환한다.
- 전환 제안·동의·거절·수령 완료는 처리자·시각·이전/변경 방법·사유를 감사 기록으로 남긴다. 제안 중에는 dispatch와 상충하는 변경을 직렬화한다.
- `dispatched`, `completed`, `cancelled` 또는 기사 지급/인계 사실이 이미 있는 주문은 단순 포장 전환을 차단한다. 배차 취소·지급 취소가 필요한 주문은 별도 정리 후 처리한다.
- CLOSED 중에도 기존 주문의 전환 제안·동의·수령 완료는 허용한다.

### 결제 단계별 배달비 처리

| 전환 시점/방식 | 처리 |
|---|---|
| 송금 전 `awaiting_quote / quoted` | 포장 동의 후 배송비 0으로 새 견적을 발행한다. 이전 견적·QR·사진 참조로 승인되지 않도록 버전을 검증한다. 고객이 이미 송금했다고 알리면 아래 결제 확인 경로를 사용한다. |
| 송금 사진 접수 `awaiting_payment_review` | 원견적과 원송금 금액을 보존한다. 직원이 현재 사진을 확인해 기존 금액을 승인한 뒤 필요하면 배달비 환불을 기록한다. 새 금액 송금이나 사진 재전송을 요구하지 않는다. |
| 승인 완료 + `customer_direct` | 매장 수취 배달비 0이므로 배달비 환불도 0. 포장 전환으로 기사 지급 기록을 만들지 않는다. |
| 승인 완료 + `store_prepaid`, 배달비 수취 있음 | 고객이 낸 배송비 전체를 환불 대상으로 표시한다. 실제 직원 환불 후 기존 `record_payment_adjustment`로 부분 환불 기록. 원결제·원견적은 보존한다. |

환불 구현 조건:

- 기존 환불 RPC는 은행 송금을 실행하지 않고 원결제 수단으로 원장만 기록한다. 처음에는 원결제가 BANKTRANSFER인 주문의 은행이체 환불 확인을 기준으로 연결한다. 현금으로 돌려주는 운영까지 지원하려면 실제 환불 수단·현금 출금·마감 대사를 별도로 설계해야 한다.
- Direct Order 전용 환불 연결 기록으로 전환/환불 ID, 기존 payment·배송비 item, 금액·처리자를 연결한다. 기존 환불 원장과 `process_payment` 본문을 변경하지 않는다.
- 새 확인 RPC는 요청과 payment를 잠그고 같은 전환에 환불을 두 번 등록하지 못하게 한다. 이미 다른 환불이 있는 경우 잔액과 배송비 귀속을 검증해 과다 환불을 막는다.
- ‘환불 대기’와 ‘환불 기록 완료’를 분리한다. 기록 없이 자동 완료로 표시하지 않고, 고객 수령 완료 후에도 미처리 환불은 직원 목록에 남긴다.
- Direct Order 분석과 고객 화면은 원결제, 배달비 환불, 최종 순수취액을 구분한다. 기존 분석은 financial의 원금만 합산하므로 환불 연결 기록을 반영하는 투영이 필요하다.
- 이미 발행된 세금계산서의 수정·취소는 MISA 포털 계약을 따른다. 포장 전환이나 환불 때문에 재고를 다시 차감하거나 음식 재고를 복구하지 않는다.

## 6. 변경 위치와 구현 순서

| 우선순위 | 작업 | 주 변경 위치 |
|---|---|---|
| P0 | 인원 입력·저장·직원/주방 포장 표시 | storefront, service, models, cashier, kitchen, direct-only SQL, 전표 payload/renderer |
| P0 | BE·기타 링크 및 일반 배달 명칭 | staff service, cashier, customer status, copy, analytics, dispatch RPC/CHECK |
| P0 | CLOSED 검증 보강 및 관리자 비활성화 구분 | cashier, settings, storefront bootstrap/신규 주문 진입, 관련 SQL guard |
| P1 | 고객 동의를 통한 방문 포장 전환·수령 완료 | 고객/직원/주방 화면, Direct Order 전용 전환 기록·RPC, Edge actions |
| P1 | 배달비 환불 연결·대사·전표 | 기존 환불 RPC를 호출하는 direct wrapper, direct analytics/status, 포장 인계 전표 |

방문 포장과 배송비 환불을 함께 완성해야 수취 배달비가 있는 기존 주문까지 안전하게 전환할 수 있다. 결제 전·고객 직접 기사 지급 주문만 지원하는 중간 상태를 전체 기능 완료로 보고하지 않는다.

API 배포 주의:

- `DirectOrderStatus` 등 모델은 알 수 없는 응답 필드를 거절한다. 기존 v2 응답에 필드를 바로 추가하면 열려 있는 구 고객 앱이 실패할 수 있다.
- 인원·업체·포장 방법·전환 제안·환불 정보를 제공하는 새 버전의 조회/접수 action과 RPC를 추가하고 기존 v1/v2 projection을 유지한다. 기본 앱은 새 계약을 사용한다.
- additive 서버 migration·새 Edge action 준비 → 새 앱 검증/배포 → 새 기능 활성화 순서로 진행한다. 구 앱·새 서버, 진행 중 기존 주문, 응답 유실 후 재시도를 함께 검증한다.
- 기존 source에 있는 고객 사진 확인 승인을 유지한다. SePay 필수 연결이나 별도 은행 자동 검증을 다시 도입하지 않는다.

## 7. 검증 계획과 완료 조건

| 검증 시나리오 | 완료 조건 |
|---|---|
| 인원 입력 3명 | customer/request/직원/주방/전표가 3명·3세트로 일치. 결제액 변화 없음. |
| 인원 누락·0·음수·소수·상한 초과 | 새 submit에서 서버까지 차단. 기존 NULL 주문·동일 요청 재시도는 정상. |
| OPEN에서 고객 접수와 CLOSED 동시 실행 | 서버 잠금 순서에 따라 신규 거절 또는 기존 접수 중 하나. 중복 요청 없음. |
| CLOSED + 기존 awaiting_quote/quoted/payment_review/approved | 재접속·상태·채팅·기존 견적·사진 확인 승인·조리·배달/포장 완료 가능. |
| CLOSED + 신규/추가 주문/완료 이력 고객 | 신규 입력 대신 요청 문구 표시. 기존 주문 목록·완료 이력 접근 가능. |
| 관리자 활성화 OFF 시도 + 진행 중 요청 | 기존 주문 처리를 중단하는 비활성화 방지. 기존 세션 주문 현황 복구 검증. |
| Grab 실패 후 BE 또는 기타 HTTPS 링크 | Flutter·RPC·DB 모두 저장 성공. 고객은 업체명과 같은 링크로 배송 확인. |
| 잘못된 URL / 공유 링크 없는 업체 | 잘못된 URL은 구체적 형식 오류. 링크 없는 업체의 명시적 기사 인계는 처리 가능. |
| 기사 호출 실패/중복 dispatch | 실패만으로 지출·인계 상태 생성 없음. 실제 인계 재시도는 비용·메시지·버전 중복 없음. |
| 포장 제안 거절 | 배송 방식·견적·결제·조리 진행 변화 없음. |
| customer_direct 포장 동의 | 같은 주문/티켓 유지, 환불 0, ready에서 고객 수령 완료 가능. |
| 송금 전 / 사진 확인 대기 포장 동의 | 송금 전은 새 견적. 이미 송금한 주문은 원금 승인·필요한 환불 경로 사용. 중복 송금 요구 없음. |
| store_prepaid + 수취 배달비 포장 동의 | 배달비 환불 대기/완료와 순수취액 정확. 같은 전환의 중복·과다 환불 차단. |
| 포장 동의 vs dispatch/승인/주방 ready 경합 | 버전·잠금으로 하나의 일관된 결과. 주문·결제·재고·티켓 중복 없음. |
| 다른 세션·다른 매장·권한 없는 계정 | 전환·동의·dispatch·환불·수령 완료 차단. |
| 인원·링크·포장 흐름 KO/VI/EN 및 모바일/태블릿 | 의미 일치, 넘침 없음, 버튼 동작 확인. |
| 정상 POS·QR 포장·KDS·결제·현금마감·Deliberry | 기존 동작 유지, Direct Order 변경이 기존 영역을 우회하거나 중복 기록하지 않음. |

구현 후 검증: 관련 Flutter 동작 테스트와 분석, Deno Edge 테스트, 독립 테스트 DB의 유효 migration 적용·SQL 상태/환불/경합 테스트, `bash scripts/check_repo.sh`. 운영 배포는 정확히 push한 head SHA의 필수 GitHub Actions 성공을 확인하고 `scripts/deploy_pos_production.sh`로 진행한다. 소스 구현, migration 적용, 앱 배포, 매장 실제 업무 확인을 각각 기록한다.

## 8. 이번 조사에서 실행한 검증

명령:

```sh
flutter test --no-pub test/direct_delivery_availability_sql_contract_test.dart test/direct_delivery_storefront_widget_test.dart test/direct_order_grab_link_test.dart --reporter expanded
```

결과: **19건 통과**. CLOSED 신규 안내·기존 주문 화면 유지·접수 경합 응답·세 언어와 화면 크기·현재 Grab URL 제한을 확인했다.

Flutter fixture와 migration 소스 계약 검증 결과다. 운영 DB 함수가 같은지, availability migration이 운영에 적용되어 있는지, 실제 고객 페이지가 현재 배포되어 있는지는 이번 조사에서 확인하지 않았다. SQL 런타임·실제 BE 기사·실제 환불·방문 포장은 구현 및 배포 후 별도 검증 대상이다.

## 9. 구현 결과

2026-10-05 사용자 요청에 따라 구현했다. 기능·결제 보호·검증·운영 적용 상태는 [구현 결과](direct_order_delivery_fallback_implementation_20261005.md)에 기록했다. 운영 migration/Edge/앱 배포는 별도 단계다.
