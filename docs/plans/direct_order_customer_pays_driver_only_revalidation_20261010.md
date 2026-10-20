# 배달비 고객 직접 지급 개선안 재검증

2026-10-10 · Asia/Ho_Chi_Minh · 범위: 현재 체크아웃의 소스·마이그레이션·관련 기존 검사, 영수증 출력 포함

이 문서는 구현 전 검토 시점의 기록이다. 이후 사용자 구현 요청에 따라 기능을 추가했으며, 현재 변경 사항과 새 검사 결과는 [구현 보고서](/Users/andreahn/globos_pos_system/docs/plans/direct_order_recipient_delivery_implementation_20261010.md)를 따른다. 아래의 기존 코드/검사 결과는 당시 근거로 보존한다.

**정책 방향은 유지하며 구현 계획의 필수 누락을 보완했다.** 고객은 매장에 음식 등 주문 대금만 결제하고 배달비는 수령 시 기사에게 직접 지급한다. 배달비 지급 방식 선택/협의 확인, 매장 선지급, 추가 배달비 수금과 차액 부담은 새 주문 흐름에 추가하지 않는다.

현재 코드에는 이전 정책이 남아 있으므로 구현 준비가 완료된 제품으로 판단할 수 없다. 이번 작업은 [활성 개선 계획](/Users/andreahn/globos_pos_system/docs/plans/direct_order_customer_pays_driver_only_improvement_20261010.md)을 보완한 재검증이며 기능 구현/운영 배포 작업은 아니다. 이전 두 방식 보고 이미지는 폐기된 정책의 기록이다.

## 1. 구현 전 필수 보완 사항

| 중요도 | 확인한 문제 | 계획에 반영한 수정 |
| --- | --- | --- |
| HIGH | 최신 quote wrapper/구 facade는 여전히 매장 선결제가 기본값이며 후청구 표식도 직접 지급을 선결제로 정규화한다. | 서버 정책 표식/snapshot, 신규·미확정 주문의 직접 지급+수금 배송비 0, 구 진입점 차단을 명시했다. 확정/결제 주문의 재요청과 금액 잠금은 보존한다. |
| HIGH | 기사 전표가 `고객 결제 0동·추가 수금 금지`를 무조건 출력한다. | 음식값 재수금 금지와 배달비 수령자 직접 수금을 구분한다. 지급 방식/버전을 payload→모델→렌더러 전체 경로에 전달한다. |
| HIGH | 현재 dispatch 저장은 포장 완료 후 배차 등록·기사 인계·배송 알림을 동시에 처리한다. | 조리 완료 후의 별도 예약 기록과 포장 완료 후의 원자적 실제 인계를 분리한다. 예약만 저장하면 배송 중/인계 완료로 바뀌지 않는다. |
| HIGH | 고객 첨부는 일반 파일이 아니라 결제 증빙으로 저장되고 고객 PDF는 거부된다. | 일반 첨부 전용 계약과 작성 버튼을 추가한다. 기존 입금 증빙 계약은 유지한다. 매장 쪽 실제 전송 실패는 별도 재현한다. |
| MEDIUM | 조리 완료 집계는 emergency/KDS 수량에 한정되며 종이 주문 보드는 준비→포장 완료 상태만 있다. | 종이 주문 조리 완료 기록과 KDS 수량 집계를 연결한다. 대상 누락으로 배차가 막히거나 조기에 완료되지 않도록 검증한다. |
| MEDIUM | 기존 invoice/환불 SQL은 추가 결제 항목별 sync·집계·원장 호출을 반복한다. | 재사용 경로에 일괄 잠금/집계/환불 배분/기록과 invoice 일괄 갱신을 포함했다. SQL 내부의 항목별 조회도 측정한다. |
| MEDIUM | 예약 소요 시간을 나타낼 별도 이벤트가 없고 구 DTO는 응답 키를 엄격히 검사한다. | 조리/예약/실패/인계 시각을 분리하고 공개·직원 응답을 버전으로 관리한다. 기존 인계 시각을 호출 시각으로 재해석하지 않는다. |

코드 근거:

- 지급 방식 기본값/구 facade: [최신 견적 wrapper](/Users/andreahn/globos_pos_system/supabase/migrations/20261010040000_direct_order_confirmed_requirements.sql:141). 후청구 정규화/확정 금액 재요청: [최종 금액 계약](/Users/andreahn/globos_pos_system/supabase/migrations/20261009150000_direct_order_final_amount_and_access.sql:15). 캐셔의 현재 지급 방식/비용 입력: [캐셔 화면](/Users/andreahn/globos_pos_system/lib/features/direct_order/direct_order_cashier_screen.dart:1466).
- 배차 저장과 실제 인계 결합: [dispatch v3](/Users/andreahn/globos_pos_system/supabase/migrations/20261005010000_direct_order_delivery_fallback.sql:272), 현금 증빙 wrapper: [dispatch v4](/Users/andreahn/globos_pos_system/supabase/migrations/20261010010000_direct_order_money_reconciliation.sql:248). KDS 포장 완료를 인계와 분리하는 최신 보완은 [현재 ready 계약](/Users/andreahn/globos_pos_system/supabase/migrations/20261006030000_direct_order_customer_experience.sql:219)이며 이 구분을 유지한다.
- 조리 완료 범위: [집계 함수](/Users/andreahn/globos_pos_system/supabase/migrations/20261010030000_direct_order_customer_progress_and_utensils.sql:26), 종이 주문 주방 동작: [주방 보드](/Users/andreahn/globos_pos_system/lib/features/direct_order/direct_order_kitchen_screen.dart:281).
- 고객 일반 첨부와 증빙의 충돌: [첨부 commit](/Users/andreahn/globos_pos_system/supabase/migrations/20261008020000_direct_order_support_and_payments.sql:606). 고객 상태 조건의 추가 완화도 메시지 종류를 일반 첨부로 바꾸지는 않는다. PDF/확장자 제한: [Edge 첨부 규격](/Users/andreahn/globos_pos_system/supabase/functions/direct-order-public/index.ts:869), 바이트 검증: [이미지 규격](/Users/andreahn/globos_pos_system/supabase/functions/direct-order-public/index.ts:92). `.jpeg` 경로 허용과 `jpg` 바이트 검증 분기의 정규화도 계획에 추가했다.
- invoice 항목별 sync: [invoice 동작](/Users/andreahn/globos_pos_system/supabase/migrations/20261008020000_direct_order_support_and_payments.sql:443). 환불 항목별 잔액 조회와 adjustment: [환불 동작](/Users/andreahn/globos_pos_system/supabase/migrations/20261008020000_direct_order_support_and_payments.sql:498). 현재 analytics v3는 기존 매출/환불 요약을 감싼다: [분석 함수](/Users/andreahn/globos_pos_system/supabase/migrations/20261005010000_direct_order_delivery_fallback.sql:433).

## 2. 영수증 출력 검증 결과

**기사 전달표와 고객 영수증 모두 수정 범위가 있다.** 배달비 입력을 숨기는 것만으로 종이/전자 출력은 바뀌지 않는다.

### 기사 전달표 — 필수 변경

[현재 renderer](/Users/andreahn/globos_pos_system/lib/core/hardware/receipt_builder.dart:285)는 다음을 출력한다.

- `DA THANH TOAN`: 결제 완료의 대상이 음식값인지 배달비까지인지 구분되지 않는다.
- `Phi giao hang Grab`와 `TONG DA THANH TOAN`: 매장이 받은 배송비 행과 결제 합계를 출력한다.
- `Khach can tra: 0 VND`, `KHONG THU THEM TIEN CUA KHACH`: 기사에게 배달비도 받지 말라는 의미로 읽힐 수 있다.

새 직접 지급 주문의 기사 전표는 음식값 결제 완료/재수금 금지와 배달비만 직접 수금을 명시한다. 예:

```text
PHIEU GIAO HANG
TIEN MON DA THANH TOAN TAI CUA HANG
KHONG THU LAI TIEN MON
CHI THU PHI GIAO HANG TU NGUOI NHAN
```

주문번호·고객 연락처·배송지·메뉴·포장/식기·확인된 요청사항은 보존한다. 기사 참고 요금이 미정이면 0동으로 쓰지 않는다. 매장 결제액과 기사 참고 요금을 합치지 않는다. 현재 [queued 모델](/Users/andreahn/globos_pos_system/lib/core/hardware/receipt_builder.dart:1308)에는 지급 방식이 없으며 [전표 payload](/Users/andreahn/globos_pos_system/supabase/migrations/20260901120000_direct_delivery_driver_receipt.sql:481)도 `customer_due=0`과 `paid=true`로 일반화되어 있다. 새 지급 주체/버전 데이터를 검증 trigger와 모델에 전달해야 한다.

### 고객 종이·전자 영수증·PDF — 안내와 데이터 전달 변경

[종이 영수증](/Users/andreahn/globos_pos_system/lib/core/hardware/receipt_builder.dart:11), [전자 영수증 모델](/Users/andreahn/globos_pos_system/lib/features/digital_receipt/digital_receipt_model.dart:45), [전자 화면](/Users/andreahn/globos_pos_system/lib/features/digital_receipt/digital_receipt_screen.dart:255), [PDF](/Users/andreahn/globos_pos_system/lib/core/services/digital_receipt_pdf_service.dart:83)에는 배달/픽업·인원·식기 정보는 있으나 지급 방식/별도 배달비 안내가 없다.

매장 결제액 200,000동이면 고객 영수증에도 200,000동만 출력하고, 배달비는 별도·수령 시 기사 직접 지급임을 표시한다. 신규 직접 지급 영수증에 배송비 0동 행이나 무료 배송 표시를 추가하지 않는다. 전자 snapshot과 print payload의 동일한 지급 주체를 읽어 자동/수동/재출력 경로를 일치시킨다. 기존 VAT/할인/환불·발행 금액과 MISA 금액은 그대로 보존한다.

현재 [영수증 항목 보정](/Users/andreahn/globos_pos_system/supabase/migrations/20261008010000_direct_order_receipt_requests.sql:7)은 픽업의 배송비 항목을 숨기고 이름/메모를 일괄 정렬한다. 이 기존 개선과 [확인된 요청사항 context wrapper](/Users/andreahn/globos_pos_system/supabase/migrations/20261010040000_direct_order_confirmed_requirements.sql:310)를 보존하면서 지급 정보를 확장한다.

### 주방·포장·픽업 — 계산 변경 불필요

주방/포장 전표는 기존 준비 정보를 유지하며 배달비 수금 업무를 넣지 않는다. 픽업에는 기사 지급 안내를 출력하지 않는다. 인원·식기·일반 요청사항은 이번 정책과 별개로 보존한다. 종이 주문 조리 완료 기록은 배차 흐름에 필요한 화면/서버 변경이며 주방 전표의 금액 변경은 아니다.

### 호환성과 출력 운영

기존 선결제 전표는 해당 주문의 지급 계약을 존중하고 기존 직접 지급 전표의 재출력은 저장된 지급 방식으로 정확히 안내한다. 완료된 출력 이력과 발행된 금융 snapshot을 새 정책으로 덮어쓰지 않는다. 구 에이전트가 새 payload를 받아도 기존 고정 문구를 출력하는 문제가 있어 renderer 교체/지원 버전 확인/claim 제한을 정책 활성화 전 검증한다. 베트남어 종이 출력 계약을 유지하고 80mm 실물 출력에서 줄바꿈·강조·잘림을 확인한다. 출력 장애는 결제와 분리해 큐로 재시도한다.

## 3. 이번에 실행한 검사와 한계

| 검사 | 실제 결과 | 의미 |
| --- | --- | --- |
| Flutter: 첨부·증빙 재시도·채팅 호출·일반 요청사항·종이/기사 영수증·PDF·베트남어 출력 관련 8개 파일 | **95 passed, 0 failed** | 현재 체크아웃의 관련 기존 계약 통과. 새 정책 기능 검사가 아니다. |
| direct-order-public Edge 테스트 | **25 passed, 0 failed** | 현재 경계·인증·파일 규격·증빙·요청사항 계약 통과. 고객 일반 PDF/첨부 신설 완료를 뜻하지 않는다. |
| 임시 PostgreSQL 통합 스크립트 | **exit 0, 통합 PASS** | 기존 결제·환불·현금·출력 snapshot·진행·요청사항·동시성 회귀와 기존 일괄 조회 fixture 통과. 운영 DB에는 접속하지 않았다. |

실행 명령:

```sh
flutter test test/direct_order_support_test.dart test/direct_order_proof_retry_test.dart test/direct_order_chat_latency_contract_test.dart test/direct_order_requirements_test.dart test/receipt_builder_contract_test.dart test/direct_delivery_driver_receipt_contract_test.dart test/digital_receipt_pdf_service_test.dart test/vietnamese_printer_output_contract_test.dart --reporter expanded
deno test --config supabase/functions/direct-order-public/deno.json supabase/functions/direct-order-public/index_test.ts
bash test/direct_order_integrated_sql_test.sh
```

DB fixture에서 확인한 기존 경로: 직원 목록 1/50/100/200건의 context helper 0회, 고객 진행 목록 1/10/50건의 cooking batch 1회/상세 0회, 영수증 메뉴 1/100/500개의 order-item scan 1회/상관 subplan 0회. 이 수치는 기존 fixture의 특정 경로만 증명한다. 새 예약 조회/첨부 URL/환불·invoice 처리의 호출 수나 전체 저장소의 N+1 부재를 증명하지 않는다.

특히 [현재 기사 영수증 테스트](/Users/andreahn/globos_pos_system/test/receipt_builder_contract_test.dart:346)는 예전 `배송비 포함·추가 수금 금지` 출력을 기대하므로 테스트 통과와 새 사업 정책이 충돌한다. 구현 시 지급 방식별 행동 검사를 추가하고 기존 선결제 사례를 보존해야 한다.

운영 마이그레이션 적용 여부·배포 버전·실제 배차 상품의 수령자 지급 지원·실기기 첨부 장애·실물 80mm 출력은 이번 검증에서 확인하지 않았다. 전체 저장소 검사/웹 빌드/정확한 pushed HEAD의 필수 GitHub Actions/생산 배포도 실행하지 않았다. 운영 완료는 구현·배포 후 이 검증을 별도로 통과해야 한다.

## 4. 확정된 다음 구현 순서

1. 서버 직접 지급 정책/이전 주문 보존 + 영수증 지급 주체/호환 에이전트 계약.
2. 고객·캐셔 결제 화면 단순화 + 종이/전자/PDF/기사 전표 변경.
3. 양방향 일반 첨부 API·UI·Storage·재시도와 실제 오류 재현/수정.
4. 종이/KDS 조리 완료 + 별도 예약/재배차 + 포장 후 실제 인계.
5. 환불/invoice 일괄 처리·운영 지표·회귀/실물 검증·프로젝트 배포 절차.
