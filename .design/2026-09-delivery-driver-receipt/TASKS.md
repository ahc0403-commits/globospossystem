# Build Tasks: 직접 배달 기사용 영수증

Generated from: `.design/2026-09-delivery-driver-receipt/DESIGN_BRIEF.md`
Date: 2026-09-01

## Foundation

- [x] **출력 snapshot 계약을 SQL fixture로 고정**: 승인된 직접 주문 한 건에
  대해 베트남어 메뉴 snapshot, 고객명·전화·배송지, `menu_total`,
  `service_charge_total`, `delivery_fee_total`, `final_total`을 한 payload로
  만들고 총액 항등식을 검증한다. _재사용: `direct_order_financials`,
  `direct_order_request_addresses`, `direct_order_request_items`; 신규: driver
  receipt SQL fixture._

- [x] **기사용 print job enqueue와 상태 경계를 추가**: 최신 additive migration에
  `delivery_driver_receipt` copy type, store-scoped enqueue/status RPC, batch 1
  멱등성, 명시적 재출력 batch 증가, 기존 receipt 목적지 선택, 권한과 승인
  선행조건을 구현한다. _재사용: `print_jobs`, `purpose='receipt'`, 기존
  claim/retry/complete; 수정: copy-type constraint; 신규: 전용 RPC._

- [x] **출력 payload PII 수명주기를 구현**: 완료·취소 job은 주소·전화·고객명을
  즉시 redaction하고, 실패 job은 제한 시간 뒤 cancel+redaction하며, 원본 주소가
  정리된 뒤의 재출력은 거절한다. _재사용: direct-order retention 원칙;
  신규: driver-copy 전용 trigger/cleanup 및 감사 필드._

## Core Output

- [x] **80mm 기사용 전표 builder를 구현**: `PHIEU GIAO HANG`, 결제 완료,
  주문번호, 고객 연락처, 전체 배송지, 메뉴·수량·단가, 메뉴 합계, 서비스
  요금, 고객 청구 Grab 배송비, 총 결제액, 고객 추가 결제 0 VND를 줄바꿈과
  금액 정렬 규칙에 맞게 출력한다. _재사용: `ReceiptBuilder`의 ESC/POS
  profile·VND formatting·text sanitization; 신규: driver payload model과
  `buildDeliveryDriverReceipt`; 기존 `buildPaymentReceipt`는 수정하지 않음._

- [x] **native print agent에 새 전표 유형을 연결**: 동결된 agent의 기존 fallback을
  유지하고 `ReceiptBuilder.buildKitchenTicket`가 새 ticket payload를 전용 builder로
  분기한다. 한 요청당 한 장만 기존 receipt 목적지로 출력한다. _동결 유지:
  `print_job_agent_service.dart`; 수정: `receipt_builder.dart`; 재사용: endpoint
  fallback, retry, completion._

## Cashier Interaction & States

- [x] **staff service에 출력 API를 추가**: 첫 출력, 재출력, 최신 상태 조회를
  타입이 명확한 메서드로 제공하고 안전한 오류 코드를 기존 직접 주문 오류
  매핑에 연결한다. _수정: `direct_order_staff_service.dart`,
  `direct_order_copy.dart`; 재사용: Supabase RPC·KO/VI/EN copy 패턴._

- [x] **직접 주문 상세에 기사 영수증 동작을 추가**: 재무 승인 후에만 버튼을
  보이고 대기·완료·실패·주소 만료 상태, 중복 탭 방지, 첫 출력과 재출력의
  구분을 제공한다. Grab 링크 저장과 출력은 서로 독립적으로 유지한다.
  _수정: `direct_order_cashier_screen.dart`; 재사용: 기존 `_Section`, `_act`,
  store scope와 직접 주문 detail; 신규 화면 없음._

## Verification

- [x] **금액·권한·멱등 SQL 계약 테스트**: 같은 매장 cashier/admin 성공,
  kitchen/타 매장 거절, 승인 전 거절, 주소 없음 거절, 배송비 포함 총액 일치,
  실제 Grab 원가 비노출, 첫 출력 동시 호출 한 건, 재출력 batch 증가,
  `NO_DESTINATION`, PII redaction을 검증한다. _확장: `supabase/tests/` direct
  delivery 계약 suite; 재사용: direct delivery fixture._

- [x] **builder와 print agent 회귀 테스트**: 주소·상세주소, 메뉴·금액,
  베트남어 diacritic sanitization, cut command, 전용 builder fallback, 목적지
  실패·재시도를 검증한다. 동결 agent 해시와 기존 고객 영수증 계약이 그대로
  통과한다. _확장: `test/receipt_builder_contract_test.dart`, 전용 contract test;
  기존 agent 기대값 수정 없음._

- [x] **캐셔 상태/현지화 계약 테스트**: 승인 후에만 영역이 생성되는 화면 구조,
  대기 중 비활성화, 완료 후 재출력 전환, 실패 안내, KO/VI/EN 문구를 검증한다.
  _확장: direct delivery UI contract tests; 재사용: 기존 locale matrix._

- [x] **전체 회귀와 release preflight 실행**: 변경 Dart format,
  `flutter analyze`, 관련 Flutter/SQL 테스트, `bash scripts/check_repo.sh`를
  실행하고 기존 결제·고객 영수증·직접 주문·print routing baseline이 모두
  통과해야 한다. _재사용: 현재 production gates; 수정 없음._

## Operational Review

- [ ] **실프린터 매장 검수**: 80mm receipt 목적지에서 주소 가독성, 절단,
  한 장 출력, 최종 결제액과 고객 청구 Grab 배송비를 원 주문과 대사하고,
  프린터 단절 후 재시도와 재출력을 확인한다. _재사용: 기존 Print Station;
  신규 운영 체크리스트._

- [ ] **배포 승인 후 production gate 통과**: additive migration 적용 상태와
  앱 버전을 분리 기록하고, exact pushed head SHA GitHub Actions 성공 후에만
  `scripts/deploy_pos_production.sh`로 배포한다. _재사용: CLAUDE.md release
  gate; 별도 승인 필요._
