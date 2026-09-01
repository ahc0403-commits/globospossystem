# 설계 브리프: 직접 배달 기사용 영수증

Date: 2026-09-01
Source: 사용자 요구사항과 현재 직접 배달·영수증·프린트 큐 계약 조사
Status: 소스 구현·로컬 검증 완료 — migration 적용·배포·실프린터 검수 미실행

## 목표

캐셔가 승인된 직접 배달 주문에 대해 80mm 영수증 프린터로 기사용
운영 전표를 출력할 수 있게 한다. 전표에는 고객 배송지와 고객에게 청구된
Grab 배송비를 포함한 최종 결제액이 명확히 보여야 한다.

이 전표는 세금 영수증이나 고객 결제 영수증이 아니라 배달 수행을 위한
`PHIEU GIAO HANG`이다. 기존 고객 영수증, 디지털 영수증, MISA/meInvoice
계약은 변경하지 않는다.

## 금액 정의

- `메뉴 합계`: `direct_order_financials.menu_total`
- `서비스 요금`: `direct_order_financials.service_charge_total`
- `Grab 배송비`: `direct_order_financials.delivery_fee_total`
- `총 결제액`: `direct_order_financials.final_total`
- 서버 불변식: `final_total = menu_total + service_charge_total + delivery_fee_total`
  이며, 클라이언트나 프린터에서 재계산하지 않는다.
- `direct_order_dispatches.actual_grab_fee`와 `fee_variance`는 매장 내부 원가·분석
  값이므로 V1 기사용 전표에는 노출하지 않는다.
- 직접 배달은 입금 승인 후 생성되는 선결제 주문이므로 `결제 완료`와
  `고객 추가 결제 0 VND`를 함께 표시해 기사가 현금을 다시 받지 않게 한다.

사용자가 말한 “Grab 비용”은 V1에서 고객에게 확정·청구된 배송비
`delivery_fee_total`을 뜻한다. 실제 Grab 원가까지 출력해야 한다는 별도
운영 결정이 생기면 표시 필드만 후속 변경하되, 기존 결제 총액에는 다시
더하지 않는다.

## 출력 내용

### 머리말

- `PHIEU GIAO HANG`
- `DA THANH TOAN`
- 매장명
- 직접 주문 참조번호와 출력 시각

### 배송 정보

- 고객명
- 전화번호
- `formatted_address`
- `detail_address`

주소는 두 필드를 임의로 합치거나 축약하지 않고 각각 줄바꿈해 출력한다.
지도 좌표, 결제 증빙, 은행 메모, Grab 추적 URL은 출력하지 않는다.

### 주문과 금액

- 베트남어 snapshot 메뉴명, 수량, 단가, 행 합계
- 메뉴 합계
- 서비스 요금
- `Phi giao hang Grab`
- `TONG DA THANH TOAN`
- `Khach can tra: 0 VND`

긴 메뉴명·주소는 80mm 폭에서 줄바꿈하고 금액 열은 오른쪽 정렬한다. 고정
프린터 문구는 현재 출력 계약과 동일하게 베트남어 ASCII로 둔다.

## 사용자 흐름

1. 캐셔가 기존 직접 주문 입금 승인 절차를 완료한다.
2. 캐셔 직접 주문 상세의 재무 정보 영역에 `기사용 영수증 출력` 동작이
   나타난다.
3. 첫 출력은 batch 1을 멱등하게 생성한다. 중복 탭이나 응답 유실로 같은
   첫 사본이 중복 생성되지 않는다.
4. 출력 상태는 대기·완료·실패로 표시한다. 실패는 결제나 배차 상태를
   되돌리지 않는다.
5. 완료 후에는 명시적인 `기사용 영수증 재출력`으로 batch 2 이상을 만든다.

출력은 입금 승인이나 `direct_order_set_dispatch` transaction 안에서 자동
호출하지 않는다. 프린터 장애가 결제 성공, Grab 링크 저장, 조리·배차 상태를
막아서는 안 된다.

## 기존 구현 재사용과 변경 경계

### 그대로 재사용

- `direct_order_staff_detail`이 제공하는 exact 주소, 품목 snapshot, 재무 연결
- `direct_order_financials`의 불변 금액 snapshot
- 기존 `print_jobs` claim/retry/complete 수명주기
- 기존 `purpose='receipt'` 프린터 목적지와 Wi-Fi/USB native print agent
- 기존 캐셔/admin 매장 범위 권한 검사와 직접 주문 화면 토큰

### 수정

- 최신 additive migration에서 `print_jobs.copy_type`에
  `delivery_driver_receipt`를 추가한다.
- 해시로 동결된 `PrintJobAgentService`는 그대로 유지한다. 에이전트의 기존
  unknown-ticket fallback이 호출하는 `ReceiptBuilder.buildKitchenTicket`에서
  새 ticket을 전용 builder로 안전하게 분기한다.
- `direct_order_staff_service.dart`와 `direct_order_cashier_screen.dart`에
  출력·재출력·상태 표시를 추가한다.
- `DirectOrderCopy`에 KO/VI/EN 캐셔 UI 문구를 추가한다.

### 신규

- `enqueue_direct_delivery_driver_receipt(store, request, reprint)` RPC
- 필요 시 최신 출력 상태를 반환하는 store-scoped read RPC
- 전용 payload parser와 `ReceiptBuilder.buildDeliveryDriverReceipt`
- 출력 payload PII 정리 trigger/cleanup
- SQL, builder, agent, widget 계약 테스트

기존 `enqueue_receipt_print_job`, `buildPaymentReceipt`, 결제 RPC, 직접 주문
승인 RPC는 재정의하지 않는다. 고객 영수증에 배송 주소를 섞지 않고 별도
copy type으로 격리한다.

## 보안·PII 계약

- enqueue RPC는 같은 매장 cashier/admin 계열만 호출할 수 있다.
- 승인된 직접 배달 주문과 `direct_order_financials` 연결이 없으면 거절한다.
- payload에는 출력에 필요한 고객명·전화·주소만 넣고 proof, 은행 reference,
  Grab URL, 좌표, session secret은 넣지 않는다.
- 출력 완료·취소 시 `print_jobs.payload`의 고객명·전화·주소는 즉시 redaction
  하고 금액, batch, 상태, 주문 참조만 audit용으로 남긴다.
- 실패 job은 재시도를 위해 PII를 임시 보존하되 제한 시간 후 cancel+redaction
  한다. 재출력은 이전 payload 복제가 아니라 아직 보존 중인 직접 주문 원본에서
  새 snapshot을 만든다.
- exact 주소 보존기간이 지난 주문은 재출력을 안전한 오류로 거절한다.

## 실패 처리

- 영수증 프린터 미설정: `NO_DESTINATION`, 결제·배차 영향 없음
- 승인 전 주문: 출력 거절
- 다른 매장 또는 kitchen 역할: 권한 거절
- 주소가 이미 정리됨: `DIRECT_ORDER_DRIVER_RECEIPT_ADDRESS_UNAVAILABLE`
- 총액 구성 불일치: job을 만들지 않고 데이터 계약 오류 반환
- 프린터 실패: 기존 retry 정책 사용, 캐셔 화면에 실패와 재시도 안내

## 완료 조건

1. 출력물에 배송지 두 필드와 고객 청구 Grab 배송비, 최종 결제액이 존재한다.
2. 최종 결제액은 `direct_order_financials.final_total`과 정확히 같고 Grab
   배송비를 이중 합산하지 않는다.
3. 첫 출력 중복 요청은 print job 한 건만 만들며 재출력만 batch를 증가시킨다.
4. 출력 실패가 payment/order/ticket/dispatch 상태를 변경하지 않는다.
5. 매장·역할 경계와 PII redaction 계약 테스트가 통과한다.
6. 기존 고객 영수증, 직접 주문, 출력 라우팅 회귀 테스트와 전체 repository
   검증이 통과한다.
7. production 반영은 exact pushed SHA의 GitHub Actions 성공과 별도 배포
   승인 뒤에만 수행한다.
