# 직접 주문 영수증 요청사항·배달비 수정

2026-10-08. 소스 구현 및 로컬 검증 완료. 운영 DB와 출력 담당 POS 앱에는 미반영.

## 확인된 원인

- 포장·픽업 주문도 회계 기록에 0원 배달비 항목을 생성한다. 메뉴 연결이 없는 이 항목을 베트남어 메뉴명 강제 변환 트리거가 `Món`으로 바꾸면서 영수증에 의미 없는 줄이 출력됐다.
- 주문 전체 요청사항은 `direct_order_requests.customer_note`에 저장되지만 기존 영수증 payload에 포함되지 않았다. 메뉴별 요청사항도 결제 영수증 모델과 출력기가 읽지 않았다.

## 반영한 동작

- `fulfillment_method = pickup`: 고객 영수증에서 배달비 항목 제외. 원래 배달 주문에서 픽업으로 전환한 경우도 동일하다.
- `fulfillment_method = delivery`: POS에서 고객에게 청구한 그랩 배달비를 기존 금액 그대로 `Phí giao hàng`로 표시한다. 실제 기사에게 지불한 비용과 고객 청구 금액이 다를 때에는 고객 청구 금액을 사용한다. 고객이 기사에게 별도로 낸 금액은 현재 POS에 저장되지 않으므로 추정하지 않는다.
- 주문 전체 요청사항을 메뉴 목록 위에, 메뉴별 요청사항을 해당 메뉴 아래에 출력한다. 큐를 통한 종이 출력, 네이티브 재출력, 전자 영수증 화면 및 PDF에 연결했다.
- 배달비 제거 전에 원래 항목을 일괄 매칭하고 `item_id`를 보존한다. 배달비가 두 메뉴 사이에 있어도 다음 메뉴의 이름이나 요청사항이 앞당겨 붙지 않는다. 무료 메뉴는 계속 표시한다.
- 금액·VAT·결제·재고 및 기존 발급 영수증과 출력 작업은 변경하지 않는다. 새 재출력 작업은 현재 요청사항을 가져온다. 합산 전자 영수증은 기존 계약을 유지한다.

## 검증

- 수정 전의 `Món / 0 VND` 및 주문 요청사항 누락을 실제 선행 함수·트리거로 재현했다.
- `bash test/direct_order_delivery_fallback_sql_test.sh`: 포장/배달, 배달→픽업 전환, 첫 출력/재출력, 메뉴 순서/무료 메뉴/취소 메뉴, 요청사항, 전자 스냅샷 및 결제·재고 보존 통과.
- SQL EXPLAIN ANALYZE: 메뉴 1/100/500개 각각 `order_items` 스캔 1회, 상관 서브플랜 0개. 항목별 RPC를 추가하지 않았다.
- 영수증·프린터 및 직접 주문 회귀 관련 Flutter 테스트 91개 통과.
- `dart analyze --fatal-infos lib test`: 통과. 저장소 전체 정적 검사에는 기존 `docs/audits/n_plus_one_20261005` 분석용 Dart 파일의 진단 4건(경고 1, 정보 3)이 남아 있다.
- `flutter build web --release --no-pub`: 통과. 포장·배달 PDF를 생성해 글자 줄바꿈과 배달비/요청사항 위치를 육안 확인했다.
- 실제 영수증 프린터 출력 및 운영 반영은 검증하지 않았다.
- 최종 전체 Flutter 테스트: 1,751개 통과, 94개 건너뜀, 기존 불일치 2개 실패. `direct_order_arrival_alert_test.dart`의 생성 번역 파일 해시와 `route_operational_state_coverage_contract_test.dart`의 기존 Admin 테스트 제목이 현재 사용자 변경 내용과 맞지 않는다. 영수증 수정과 무관한 해당 파일은 고치지 않았다. 이번 수정에 따른 결제 서비스/출력 에이전트 해시와 재출력 구조 검사는 갱신해 통과했다.

## 적용 파일

- DB: `supabase/migrations/20261008010000_direct_order_receipt_requests.sql`
- 종이 영수증: `lib/core/hardware/receipt_builder.dart`, `lib/core/hardware/print_job_agent_service.dart`
- 네이티브 재출력: `lib/core/services/payment_service.dart`, `lib/features/payment/payment_detail_screen.dart`
- 전자 영수증: `lib/features/digital_receipt/digital_receipt_model.dart`, `lib/features/digital_receipt/digital_receipt_screen.dart`, `lib/core/services/digital_receipt_pdf_service.dart`

운영 적용 시 DB 마이그레이션과 출력 담당 네이티브 POS 앱 업데이트가 함께 필요하다. 웹 빌드 성공만으로 실제 프린터의 요청사항 출력이 적용되지는 않는다. 배포에는 프로젝트의 정식 배포 게이트를 사용해야 한다.
