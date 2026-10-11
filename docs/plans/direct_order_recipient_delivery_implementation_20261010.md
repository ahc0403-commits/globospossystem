# 배달비 수령자 직접 결제 · 배차 · 채팅 첨부 구현 보고서

> 이 문서는 당시 소스 검증 기록이다. 최신 main 통합·운영 적용 절차와 API 버전은 [통합 배포 문서](../pos/POS_RECIPIENT_TAX_BOUNDED_RELEASE_20261011.md)를 참조한다.
2026-10-10 · Asia/Ho_Chi_Minh · 로컬 소스 구현/검증 · 운영 DB 미적용 · 미배포

신규 배달 주문은 음식·옵션·기존 세금/수수료만 매장에 결제한다. 배달비는 고객이 수령 시 기사에게 직접 지급한다. 지급 방식 질문, 매장 선결제, 배달비 추가 청구, 기사 현금 지급과 차액 부담은 신규 주문에서 UI와 서버 모두 차단한다. 기존 확정 견적·결제·발행 이력은 보존한다.

적용 계획: [최종 개선 계획](/Users/andreahn/globos_pos_system/docs/plans/direct_order_customer_pays_driver_only_improvement_20261010.md). 폐기된 두 방식 계획과 보고 이미지는 이번 구현의 기준이 아니다.

## 1. 구현 결과

| 범위 | 구현된 동작 |
| --- | --- |
| 고객/캐셔 결제 | 배달비 0동 금액 행 대신 별도 직접 결제 안내. 신규 주문의 배달비 지급 방식/비용/후청구 입력 제거. 기사 참고 요금은 매장 송금/청구/매출/비용 원장과 분리. 채팅 안내문도 요금 입력/고객의 배차 승인 없이 생성하며, 알려진 기사 요금만 참고로 표시. 픽업에는 기사 지급 안내를 표시하지 않음. |
| 조리 | 종이 주문에 권한·버전 검사를 거친 조리 완료 기록 추가. KDS는 단품/콤보의 주문·제외·취소·검토 수량으로 완료 판단. 포장 완료와 조리 완료 구분. |
| 배차 | 외부 배차 앱에서 호출한 예약 정보를 저장. 조리 완료 후 예약 가능. 예약 저장은 기사 인계나 배송 시작으로 처리하지 않음. 실패/취소/재배차 이력 보존. 통신 실패 재시도는 동일 작업 ID, 취소/실패 후 동일 정보의 새 배차는 새 작업 ID 사용. |
| 실제 인계 | 포장 완료·현재 예약·최신 버전·음식 대금 정산을 같은 트랜잭션에서 검사. 현금 지급 증빙 없이 인계. 실제 배송 완료는 별도 수동 이벤트. |
| 채팅 | 고객/매장 일반 사진·PDF 전용 upload/commit 계약 및 작성 UI. 청구/견적 ID 없이 열린 상담에서 전송. 기존 음식 대금 입금 증빙과 분리. |
| 첨부 복구/접근 | 파일 미리보기·취소·오류·동일 경로 재시도·상대 열기. 5 MiB 제한, MIME/바이트 검사, JPEG 정규화, 고객 세션/직원 권한/주문 소유 검사, private Storage URL 필요 시 발급. 주문 전환 시 임시 파일 상태 초기화. 미완료 업로드와 종료 후 개인정보 정리. |
| 고객 영수증 | 종이·전자 화면·80mm PDF·수동 재출력에 저장된 지급 주체 전달. 음식 결제 합계 보존, 배달비 별도/수령 시 기사 직접 지급 안내. |
| 기사 전표 | 음식값 매장 결제 완료/음식값 다시 수금 금지/배달비만 수령자 직접 수금 문구. 직접 지급 주문의 일괄 추가 수금 금지·고객 결제 0동·Grab 비용 행 제거. 기존 선결제/픽업 출력 계약 보존. |
| 출력 호환성 | 지급 주체를 snapshot에 저장. 신규 payload는 호환 에이전트만 claim. 기존 발행 snapshot/완료 이력은 유지하며 대기·실패 큐만 금융 원본 기준 보정. 출력 실패와 결제 분리. |
| 운영 지표 | 호출 필요·예약 실패/재시도·조리 완료→예약/인계 시간. 누락된 시간은 0으로 만들지 않음. 기사 참고 요금은 매출·비용 통계에서 제외. |
| 환불/MISA | 기존 환불 배분·한도·감사 이력·MISA 비동기 계약을 유지하고 추가 결제 집합을 일괄 처리. 음식 결제의 process_payment anchor 변경 없음. |

배차 API를 새로 연결한 것은 아니다. 캐셔는 배차 업체 앱에서 수령자 결제가 지원되는 상품으로 호출/취소한 후 POS에 기록한다. 고객이 배달비를 지급했는지 확인하는 새 완료 gate는 없다.

## 2. 주요 변경 경로

- 서버 정책/조리/예약/일반 첨부/조회·지표: [20261010050000](/Users/andreahn/globos_pos_system/supabase/migrations/20261010050000_direct_order_recipient_delivery.sql).
- 영수증 snapshot/구 에이전트 격리: [20261010051000](/Users/andreahn/globos_pos_system/supabase/migrations/20261010051000_direct_order_recipient_receipts.sql).
- 환불/invoice 일괄 처리: [20261010052000](/Users/andreahn/globos_pos_system/supabase/migrations/20261010052000_direct_order_batch_refund_invoice.sql).
- 인증·Storage·파일 경계: [direct-order-public](/Users/andreahn/globos_pos_system/supabase/functions/direct-order-public/index.ts).
- 운영 UI: [캐셔](/Users/andreahn/globos_pos_system/lib/features/direct_order/direct_order_cashier_screen.dart), [주방](/Users/andreahn/globos_pos_system/lib/features/direct_order/direct_order_kitchen_screen.dart), [고객](/Users/andreahn/globos_pos_system/lib/features/direct_order/direct_order_storefront_screen.dart), [첨부/상담](/Users/andreahn/globos_pos_system/lib/features/direct_order/direct_order_support.dart).
- 출력: [종이 영수증/기사 전표](/Users/andreahn/globos_pos_system/lib/core/hardware/receipt_builder.dart), [PDF](/Users/andreahn/globos_pos_system/lib/core/services/digital_receipt_pdf_service.dart), [전자 영수증 모델](/Users/andreahn/globos_pos_system/lib/features/digital_receipt/digital_receipt_model.dart), [프린터 에이전트](/Users/andreahn/globos_pos_system/lib/core/hardware/print_job_agent_service.dart).

기존 strict DTO 응답 키는 바꾸지 않고 공개 status v6/orders v4, 직원 detail/list v5, 주방 list v4, analytics v4를 추가했다.

## 3. 실행한 검사

| 검사 | 결과 | 검증 범위/한계 |
| --- | --- | --- |
| 임시 PostgreSQL 통합 | PASS | 기존 결제/요청사항/증빙/환불/출력 회귀 + 신규 정책/조리/예약/첨부/영수증/일괄 처리. 운영 DB 접속 없음. |
| 실제 두 세션 배차 경합 | PASS | 동일 예약 동시 저장은 1건. 인계/취소 경합은 한 작업만 성공. |
| 직원/주방 목록 | PASS | 1/50/100/200건에서 건별 상세/예약 helper 호출 0회. |
| 고객 목록 | PASS | 1/10/50건에서 건별 helper 호출 0회. 현재 API 상한 유지. |
| 추가 결제 환불/invoice | PASS | 추가 결제 1/10/50건에서 per-payment 함수 0회, 각 batch 1회. 실제 invoice/intake 테이블·발행/내보내기 잠금 검사. |
| direct-order-public | 26 passed, 0 failed | fmt/lint/type check 포함. 일반 고객 PDF·JPEG/파일·권한·명시적 action 계약. |
| 최종 기능 회귀 Flutter | 167 passed, 0 failed | 최종 채팅 안내 보완 후 고객/캐셔/정책/종이·전자·기사 전표/PDF/인쇄 계약 9개 파일. 조리 후 예약·포장 전 인계 차단, 첨부 복구와 기존 선결제/픽업 계약 포함. |
| 앱/테스트 정적 분석 | PASS, No issues found | 최종 변경 후 `dart analyze --fatal-infos lib test`. |
| 전체 Flutter | 1,876 passed / 94 skipped / 2 failed | 전체 실행의 실패는 아래 기존 계약 불일치 2건. 이후 채팅 안내 최종 보완은 위 167건으로 다시 검사. 전체 PASS로 보고하지 않음. |
| 프로젝트 검사 스크립트 | FAIL, 정적 분석 단계에서 중단 | 의존성 lock 검사 통과. 기존 감사용 Dart 문서의 warning 1건/info 3건으로 중단. 뒤 단계 전체 PASS로 보고하지 않음. |
| 최종 웹 release 빌드 | PASS, Built build/web | 마지막 예약 작업 ID 변경까지 포함한 소스 컴파일. 운영 업로드 없음. 기존 의존성의 Wasm dry-run 및 Cupertino font 경고는 남으며 JavaScript release 빌드는 성공. |
| 변경 공백/테스트 shell 문법 | PASS | `git diff --check`, 변경된 SQL 통합/동시성 runner의 `bash -n`. |

통합 fixture에서 기사 참고 요금은 매장 결제 108,000동을 바꾸지 않고 dispatch 실비/현금 지급/차액 원장도 만들지 않는다. 예약만 저장한 상태는 배송 중이 아니며 포장 전에 인계할 수 없다. legacy quote facade 및 지급 방식 생략 재요청, 신규 주문의 지급 방식 생략 기본값, 구 status 응답 키, 픽업/취소·부분 환불, 인쇄 claim 호환성, 첨부 replay·타 actor·PII 정리를 검사했다.

호출 수 검사는 해당 실제 RPC 경로와 임시 DB fixture 범위를 증명한다. 저장소 전체의 모든 접근 경로에 N+1이 없다고 주장하지 않는다. `process_payment`는 통합 검사에서 전후 정의 MD5가 동일했다. MISA 원격 응답을 기다리는 경로는 추가하지 않았다.

전체 검사에 남은 불일치:

- [arrival alert 계약 검사](/Users/andreahn/globos_pos_system/test/direct_order_arrival_alert_test.dart): 생성된 `lib/l10n/app_localizations.dart`의 고정 SHA 기대값과 현재 생성 파일이 다름. 이번 변경에서 locale 생성 파일이나 이 고정값을 수동 수정하지 않았다.
- [라우트 운영 상태 계약 검사](/Users/andreahn/globos_pos_system/test/route_operational_state_coverage_contract_test.dart): 기존 Admin 테스트 이름 `all ten Admin tabs ...`를 기대하지만 현재 해당 테스트는 `all nine Admin tabs ...`임. 해당 Admin 테스트와 검사 기대값은 이번 변경에서 수정하지 않았다.
- [kds_probe.dart](/Users/andreahn/globos_pos_system/docs/audits/n_plus_one_20261005/kds_probe.dart:35)와 [scan.dart](/Users/andreahn/globos_pos_system/docs/audits/n_plus_one_20261005/scan.dart:71): 테스트 전용 멤버 사용 warning, print/interpolation info. 이번 구현 범위와 별개인 기존 감사용 문서다.

이 문제들을 피해 전체 검사를 통과한 것으로 만들지 않았다. 운영 release gate는 통과하지 않은 상태다.

실행 명령:

```sh
bash test/direct_order_integrated_sql_test.sh
deno fmt --check supabase/functions/direct-order-public/index.ts supabase/functions/direct-order-public/index_test.ts
deno lint supabase/functions/direct-order-public/index.ts supabase/functions/direct-order-public/index_test.ts
deno check --config supabase/functions/direct-order-public/deno.json supabase/functions/direct-order-public/index.ts supabase/functions/direct-order-public/index_test.ts
deno test --cached-only --allow-read --allow-env --allow-net supabase/functions/direct-order-public/index_test.ts
flutter test --no-pub
dart analyze --fatal-infos lib test
bash scripts/check_repo.sh
flutter build web --release --no-pub
git diff --check
```

최종 기능 회귀 명령:

```sh
flutter test --no-pub test/direct_order_staff_fallback_test.dart test/direct_order_recipient_policy_test.dart test/direct_order_customer_experience_test.dart test/direct_delivery_storefront_widget_test.dart test/receipt_builder_contract_test.dart test/direct_delivery_driver_receipt_contract_test.dart test/digital_receipt_pdf_service_test.dart test/vietnamese_printer_output_contract_test.dart test/print_routing_contract_test.dart
```

## 4. 운영 적용 전 확인

소스 구현, 운영 migration 적용, 배포, 실사용 검증은 별도 상태다. 현재는 소스와 임시 DB/로컬 검사 단계다.

- 실제 업체/매장 계정에서 수령자 결제가 가능한 상품 확인.
- 호환 POS 클라이언트·프린터 에이전트와 세 마이그레이션·Edge 배포 순서 확인. 구 에이전트는 version 2 작업을 가져오지 못하므로 업데이트 전에는 해당 작업이 대기한다.
- 모바일 양방향 사진/PDF에서 운영 인증·Storage·CORS·상대 열기 확인. 이전 실환경 장애 원인이 이번 소스 검사만으로 확정되지는 않는다.
- 80mm 실제 프린터에서 베트남어 안내·기사 수금 문구·줄바꿈/잘림 확인. PDF/ESC-POS byte 검사는 실물 인쇄 검사를 대신하지 않는다.
- 전체 저장소의 남은 검사 실패를 확인하고 정확한 pushed HEAD의 필수 GitHub Actions가 성공한 뒤 [생산 배포 스크립트](/Users/andreahn/globos_pos_system/scripts/deploy_pos_production.sh) 사용. 이번 요청에서는 commit/push/운영 배포를 수행하지 않았다.

사용자 소유의 기존 수정/미추적 파일은 보존했다. 기존 확정/결제 주문의 지급 방식이나 발행된 금융 이력을 새 정책으로 덮어쓰지 않았다.

## 후속 POS 원장 계획

이 보고서의 배달비 개선 이후 전달된 영수증 원장·구매자 정보 계획도 구현했다. [POS 원장 구현·최종 통합 검증 보고서](/Users/andreahn/globos_pos_system/docs/plans/pos_receipt_ledger_buyer_information_implementation_20261010.md)에 530/540 마이그레이션, 원장·공통 양식, 최종 기능 검사 203건, 전체 검사 실패 5건 중 변경 관련 3건 수정/재검증 및 기존 2건 잔존을 기록했다. 이 문서 위의 167건/전체 2건 실패는 원장 작업 전 검사 이력이다. 운영 DB 적용·배포 상태는 여전히 미수행이다.
