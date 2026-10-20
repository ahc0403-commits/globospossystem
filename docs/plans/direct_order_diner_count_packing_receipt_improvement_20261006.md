# 배달 주문 식사 인원·일회용품 수량의 영수증 표시 개선 계획

> **통합 문서로 대체됨 — 2026-10-06.** 현재 구현·검증·배포 기준은 [배달 주문 통합 개선 계획](direct_order_integrated_customer_and_packing_improvement_20261006.md)이다. 아래는 당시 조사와 개별 계획의 이력이며 별도 실행 계획으로 사용하지 않는다.

작성일: 2026-10-06, Asia/Ho_Chi_Minh.

작성 당시 상태: **계획 수립 완료, 구현 전**. 고객이 입력한 배달 주문 인원수를 포장 직원이 영수증에서 확인할 수 있게 하는 작업이다. 고객 Bill, 직접 재출력, 배달/방문포장 인계전표와 PDF 출력 경로를 확인했다. 운영 DB 조회·실제 영수증 재현·테스트 실행·구현·배포는 수행하지 않았다.

조사 기준은 HEAD `cc4de81adb8870fd479cb12edd773cda635a01cd`와 기존 로컬 수정이 포함된 작업 디렉터리다. 기존 수정·사용자 소유 untracked 파일은 보존한다.

## 1. 목표와 수량의 의미

**고객이 3명을 선택하면 포장에 쓰는 영수증 상단에 ‘식사 인원 3명 · 일회용품 3세트’가 표시되어야 한다.** 직원이 고객 화면이나 채팅을 별도로 확인하지 않아도 수량을 알 수 있어야 한다.

현재 고객 안내와 기존 모델의 계약은 **1명당 일회용품 1세트**다. 따라서 명수 N과 준비 세트 수 N을 함께 표시한다. 세트 구성은 매장 기준을 따르며, 개별 수저·젓가락·냅킨을 합쳐 N개로 해석하지 않는다. 일회용품을 새 유료 메뉴나 결제 항목으로 추가하지 않는다.

## 2. 조사 결과 — 이미 있는 기능과 빠진 경로

| 구간 | 현재 구현 | 판정 |
|---|---|---|
| 고객 입력·전송 | 1~100명을 입력하고 `submit_v3.payload.diner_count`를 전송한다. | 소스상 구현됨 |
| 요청·POS 주문 저장 | `direct_order_requests.diner_count`에 저장하고 승인 시 `orders.guest_count`로 전달한다. | 소스상 구현됨 |
| 직원·주방 화면 | 고객 현황, 직원 상세, Direct Kitchen에 인원/일회용품 세트가 표시된다. | 소스상 구현됨 |
| 신규 출력 작업 | `direct_order_enrich_print_fulfillment` INSERT trigger가 direct 금융 연결을 통해 인원·수령 방법을 payload에 추가한다. | 소스상 구현됨. 실제 누락 주문의 payload는 아직 조회하지 않음 |
| Print Station 고객 Bill | agent가 payload의 `diner_count`, `fulfillment_method`를 builder로 전달한다. 두 값이 있으면 인원/일회용품을 출력한다. | 소스상 구현됨. 현장 설치 프로그램과 실제 출력은 미검증 |
| 배달/방문포장 인계전표 | 전용 builder가 `dinerCount`를 받으면 인원/일회용품을 출력한다. | 소스상 구현됨 |
| 결제 상세의 직접 출력 | `fetchPaymentDetail()`의 주문 select에 `guest_count`와 direct 포장 정보가 없고, 네이티브 직접 출력의 builder 호출도 `dinerCount`·수령 방법을 전달하지 않는다. | 명확한 전달 누락 |
| 디지털 영수증·PDF 인쇄 | `DigitalReceipt` 모델과 화면/PDF에 인원·일회용품 필드와 표시가 없다. | 명확한 표시 누락 |
| 기존 문서 종류 | kitchen builder에는 인원 표시가 있으나 floor/tray/confirmation builder에는 없다. | 이 전표가 실제 direct 포장에 쓰이는지 확인하고 사용 경로만 보완 |
| 인원 미입력 | 종이 출력은 대부분 count가 NULL이면 줄 자체를 생략한다. | ‘미입력·직원 확인 필요’로 바꿔 수량 누락을 드러낼 필요 |
| 인원 수정 후 전표 | 직원 수정 RPC는 요청·`orders.guest_count`를 수정하지만 이미 생성된 출력 payload는 수정하지 않는다. | 과거 스냅샷과 최신 재출력을 구분해야 함 |

소스 근거:

- `lib/features/direct_order/direct_order_storefront_screen.dart:397`: 고객 인원 입력 검증·submit 전달.
- `lib/features/direct_order/direct_order_copy.dart:92`: 인원수와 일회용품 세트 계약.
- `supabase/migrations/20261005010000_direct_order_delivery_fallback.sql:7`, `:95`, `:153`, `:376`, `:446`: 인원 저장·수정, guest_count 전달, print payload 보강.
- `lib/core/hardware/receipt_builder.dart:11`, `:263`, `:428`: 고객 Bill, 인계전표, kitchen 출력.
- `lib/core/hardware/print_job_agent_service.dart:308`: queued receipt의 포장 정보 전달.
- `lib/core/services/payment_service.dart:232`: 결제 상세 조회의 주문 select.
- `lib/features/payment/payment_detail_screen.dart:827`: 플랫폼별 재출력 분기와 네이티브 builder 호출.
- `lib/features/digital_receipt/digital_receipt_model.dart:35`, `lib/core/services/digital_receipt_pdf_service.dart:48`: 디지털 모델과 PDF.
- `supabase/tests/direct_order_delivery_fallback_contract_test.sql:95`: 간단한 신규 print row의 인원 보강 검증.
- `test/direct_order_delivery_fallback_test.dart:377`: 방문포장 인계전표의 3세트 출력 검증. 전체 최초 Bill→agent 출력 경로의 증거와는 구분한다.

기존 운영 배포 보고서 `docs/operations/direct_order_deliberry_sample_release_20261005_70498547.md`에는 2026-10-05 웹·DB 반영과 Windows 패키지 빌드 성공이 기록되어 있다. 동시에 **물리 프린터 확인은 실행하지 않았다고 기록**되어 있다. 웹 배포나 Windows 빌드 성공만으로 현장의 출력 프로그램이 업데이트되었다고 판단하지 않는다.

현재 고객이 본 영수증의 정확한 누락 원인은 아직 확정하지 않았다. 단순히 ‘인원 저장 기능이 없다’거나 ‘운영 migration이 없다’고 판정하지 않고, 실제 출력 경로의 누락 지점을 먼저 확인한다.

## 3. 영수증 표시 사양

위치는 **주문번호·배달/방문포장 구분 바로 아래, 메뉴 목록 위**다. 금액·VAT·은행 안내 사이에 작은 글씨로 섞지 않는다.

```text
주문번호 DXXXXXXXX       배달 / 방문포장
──────────────────────────────────────
식사 인원: 3명
일회용품: 3세트         ← 굵고 큰 글씨
──────────────────────────────────────
메뉴명 · 메뉴 수량
...
```

현장 종이 출력은 기존 베트남어·ESC/POS 호환성을 따른다. 예:

```text
SO NGUOI: 3
DUNG CU: 3 BO           ← bold, 두 배 높이
```

두 줄로 분리해 100명에서도 잘리지 않게 하고, 큰 글씨의 세트 수는 각 전표에 한 번만 표시한다. 화면은 기존 KO/VI/EN 번역을 따르고 PDF는 기존 베트남어 영수증 정책을 따른다.

- 주문별 총 준비 수량이다. 메뉴별·조리 구역별 전표 수만큼 일회용품을 추가 준비하는 의미가 아니다.
- NULL인 과거 주문은 ‘인원 미입력 · 직원 확인 필요’로 표시한다. 0명이나 1명으로 추정하지 않는다.
- 일반 홀 주문의 `guest_count`를 자동으로 일회용품 수량으로 바꾸지 않는다. 이 포장 영역은 확인된 Direct Order 배달/방문포장에 적용한다.
- 세트 수를 계산할 때 메뉴 수량·송금액·배송비를 사용하지 않는다.

## 4. 구현 순서

### 1단계 — 실제 누락 구간 확인

문제가 발생한 매장·주문·전표에 대해 다음을 읽기 전용으로 대조한다. 확인에 필요한 주문 ID와 숫자만 기록하고 고객 이름·주소·전화번호는 진단 출력에 포함하지 않는다.

1. 요청의 `diner_count`와 승인된 주문의 `guest_count`.
2. 출력 문서 종류: 자동 고객 Bill, 배달 데스크 재출력, 결제 상세 직접 출력, PDF, 기사/포장 인계전표.
3. 해당 `print_jobs`의 `copy_type`, ticket 종류, `diner_count`, `fulfillment_method`, 생성·완료 시각. 이미 존재하던 스냅샷인지도 확인한다.
4. 해당 매장의 print enrichment 함수·trigger 활성 상태와 유효 migration 정의. 현재 폴더의 최초 파일 번호만 보고 운영 적용 여부를 판단하지 않는다. 운영 배포 기록의 renumbered migration과 연결해 확인한다.
5. 실제 Print Station 설치 패키지의 빌드 SHA·버전, 출력에 사용한 앱/브라우저/네이티브 경로.

판정 기준은 요청 값 없음 / 요청과 POS 값 불일치 / payload 누락 / renderer·설치 프로그램 누락 / 출력 문서 종류의 미지원으로 나눈다. 이미 구현된 큐 경로는 새로운 데이터 시스템으로 다시 만들지 않는다.

### 2단계 — 포장 정보 전달 통일

- 인원 원본은 `direct_order_requests.diner_count`다. `orders.guest_count`는 승인·직원 수정 시 동일 값으로 유지되는 POS 복사 값으로 사용한다.
- 큐 최초 Bill·명시적 재출력·인계전표 생성 시 동일 주문의 인원과 수령 방법이 payload에 들어가는지 실제 enqueue→trigger 경로로 검증한다. 간단한 수동 print row 삽입 테스트만으로 완료 판정하지 않는다.
- 결제 상세 직접 출력은 기존 프린터 사용 경로를 유지하면서, 권한을 검증하는 **단건 포장 context 조회**로 `diner_count`, 수령 방법, 주문 참조번호를 받아 builder에 전달한다. client에서 권한이 없는 direct 테이블을 직접 조회하거나 주문 메모 문자열로 연관 주문을 추정하지 않는다.
- 이 단건 조회는 해당 매장 접근·Direct Order 연결을 검증하고 필요한 포장 필드만 반환한다. 일반 주문은 포장 context 없이 기존 출력으로 처리한다. 목록의 주문마다 RPC를 호출하는 구조는 만들지 않는다.
- 이미 큐에 출력 작업을 넣은 뒤 네이티브에서도 같은 작업을 직접 출력하는 중복 경로는 만들지 않는다. context 조회는 출력 job을 생성하지 않는 읽기 동작이어야 한다.
- PDF/브라우저 인쇄에도 같은 계약을 적용한다. 새 direct 디지털 영수증 snapshot 생성에 포장 metadata를 더하는 additive helper/trigger와 optional 모델 필드를 사용한다. 기존 결제·금액 snapshot 계산 본문을 복제하지 않는다.
- 누락된 과거 디지털 영수증·이미 출력 완료된 payload를 일괄 수정하지 않는다. 과거 주문을 지금 포장해야 하면 확인된 인원으로 기존 전용 인계전표의 새 출력/재출력 경로를 사용한다.

현재 수량 column과 기존 공개 submit API는 이미 있다. 추가 migration은 필요한 **권한 검증 단건 조회·새 디지털 snapshot 보강·확인된 출력 누락 보완**에 한정한다. 기본 `process_payment` 본문, 승인 금액·재고·VAT·MISA 처리를 변경하지 않는다.

### 3단계 — 영수증 가독성과 직원 수정

- `ReceiptBuilder`의 고객 Bill·인계전표·kitchen에 동일한 포장 수량 영역을 사용한다. `dinerCount`가 있어도 `fulfillmentMethod` 누락 때문에 줄 전체가 조용히 사라지는 경우를 검증하고, direct context가 불완전하면 확인 필요 상태를 드러낸다.
- 실제 포장에 쓰이는 floor/tray/confirmation 경로가 있으면 같은 영역을 추가한다. 일반 홀 전표의 레이아웃은 유지한다. 기존 전표에 이미 결제 전 안내문이 있는 경우 그 문서를 유료 배달 포장에 새로 배정하지 않는다.
- 직원·Direct Kitchen 화면의 기존 수량 표시도 ‘일회용품 N세트’를 눈에 띄게 한다. 출력 없는 운영에서도 현재 수량을 확인할 수 있게 한다.
- 기존 직원 인원 수정 RPC를 재사용한다. 수정 후 이미 만든 전표에는 이전 수량이 남는다는 것을 표시하고, 기존 전용 출력 버튼으로 **최신 수량 재출력**을 제공한다. 재출력으로 신규 주문·결제를 만들지 않는다.
- `pending/failed/printing/done`별 스냅샷·재시도 정책을 확인한다. 이미 프린터가 읽는 payload를 덮어쓰지 않고, 수량 수정 이후 생성된 새 전표는 최신 수량과 재출력 표시를 사용한다. 오래된 전표와 최신 포장 전표를 직원이 구분할 수 있게 한다.
- 인계·완료 후 수정 제한과 버전 충돌 보호는 기존 계약을 유지한다.

### 4단계 — 설치와 실제 출력 확인

- 웹·DB 반영과 별도로 정확한 release SHA의 Windows Print Station 패키지를 확인하고 현장 설치본을 갱신한다. 기존 매장 printer destination·IP·USB 설정을 유지한다.
- 승인된 테스트 fixture 또는 안전한 미리보기 출력으로 3명/3세트를 실제 종이에 확인한다. 테스트를 위해 운영에서 가짜 주문·결제·입금 승인을 만들지 않는다.
- 포장 직원이 종이에서 세트 수를 읽을 수 있고, 메뉴 수량이나 출력 부수와 혼동하지 않는지 확인한다. 이 확인까지 끝나야 ‘현장 해결’로 판정한다.

## 5. 완료 기준과 검증

| 항목 | 통과 기준 |
|---|---|
| 최초 흐름 | 고객 3명 입력 → request 3 → 승인된 order 3 → 최초 Bill payload 3 → 종이에 3세트가 나온다. |
| 경로별 동일성 | 자동 Bill, 배달 데스크/결제 상세 재출력, 인계전표, PDF 인쇄에서 동일 주문의 인원·세트 수가 일치한다. |
| 수령 방법 | 배달과 방문포장 모두 수량이 나오며 포장 전환만으로 인원 값이 사라지지 않는다. |
| 범위 | 1·3·10·100명이 정확히 표시되고, 큰 숫자가 잘리거나 말줄임되지 않는다. |
| 누락·오류 | NULL은 미입력 안내. 0·음수·소수·100 초과는 기존 검증으로 거절된다. 일반 홀 손님 수를 일회용품으로 출력하지 않는다. |
| 수정·재출력 | 인계 전 3→5명 수정 후 화면과 새 인계전표는 5세트. 기존 출력 이력은 보존되고 신규 결제·티켓·재고 차감이 없다. |
| 대기 작업 | 인원 수정·재시도 시 과거 snapshot과 최신 전표가 명확히 구분되며 같은 job 재시도와 새 재출력의 수량 계약이 일관된다. |
| 권한 | 다른 매장·고객 세션이 직원용 포장 context를 읽지 못하며 인원 추가 때문에 주소·전화가 주방에 노출되지 않는다. |
| 일반 POS 회귀 | 홀·QR·합산 결제·서비스 영수증의 금액·VAT·출력 부수와 기존 기본 입력의 출력이 유지된다. |
| 현장 | 실제 설치된 출력 프로그램에서 80mm 종이 상단에 굵은 ‘DUNG CU: 3 BO’가 나오는 것을 확인한다. |

구현 후 검증은 변경 Dart 파일 format·`flutter analyze`, 관련 receipt builder/agent/payment detail/digital PDF 행동 테스트 순서로 진행한다. `receipt_builder_contract_test.dart`, `direct_delivery_driver_receipt_contract_test.dart`, `direct_order_delivery_fallback_test.dart`, `payment_detail_contract_test.dart`, `digital_receipt_pdf_service_test.dart`, `direct_delivery_regression_isolation_test.dart` 및 관련 기존 출력 테스트를 실행한다.

SQL 검증은 실제 승인→자동 enqueue→print enrichment→payload 경로와 단건 조회 권한·재출력을 격리 DB에서 확인한다. migration 전후 `process_payment` 정의와 결제·재고·티켓 생성 횟수가 유지됨을 확인한다. 운영 DB에는 실패 주입을 하지 않는다.

그다음 `bash scripts/check_repo.sh`, 정확한 배포 대상 SHA의 필수 GitHub Actions와 Windows 패키지 빌드를 확인한다. 운영 반영은 `scripts/deploy_pos_production.sh`를 사용한다. 로컬 검증·독립 리뷰는 사전 증거이며, 웹 배포·출력 프로그램 설치·실물 출력 확인을 각각 기록한다.

## 6. 우선순위와 판정

| 분류 | 내용 | 우선순위 |
|---|---|---|
| CONFIRMED | 인원 입력·저장·주방 표시와 일부 종이 수량 출력은 현재 소스에 있다. | 기존 계약 재사용 |
| HIGH | 결제 상세 네이티브 직접 출력과 PDF의 인원 전달/표시가 누락되어 있다. | 1: 누락 경로 보완 |
| MEDIUM | 수량이 NULL이면 일부 종이 전표에서 줄 자체가 생략되어 포장 직원이 확인 필요 상태를 알 수 없다. | 2: 수량 영역·미입력 안내 |
| MEDIUM | 현재 테스트는 단순 payload 보강과 한 인계전표 출력 중심이며, 실제 최초 Bill의 전체 경로·현장 설치를 완료 증거로 제공하지 않는다. | 3: 전체 경로·실물 검증 |

사용자가 겪은 특정 영수증의 원인은 구현 전 1단계에서 확정한다. 성공 기준은 **고객이 선택한 수량이 포장 직원이 사용하는 실제 영수증에 정확하고 눈에 띄게 출력되는 것**이다.
