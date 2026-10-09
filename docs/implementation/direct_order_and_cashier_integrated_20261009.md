# 배달·포장 주문 및 캐셔 주문 수정 구현 기록

2026-10-09 · Asia/Ho_Chi_Minh

이 문서는 원래 사용자 작업 사본에서 수행한 구현 단계 기록이다. 이후 배포는 별도의 깨끗한 최신 main 작업 사본에서 검증하고 운영 반영 기록으로 구분한다.

[통합 계획](/Users/andreahn/globos_pos_system/docs/plans/direct_order_and_cashier_integrated_improvement_20261009.md)의 소스 구현과 로컬 검증을 완료했다. 운영 DB migration 적용, Edge·웹 배포, 실제 모바일·은행 이체·Windows 출력 확인은 실행하지 않았다. 기존 사용자 변경을 보존했으며 push·PR 생성도 하지 않았다.

## 구현 결과

| 문제 | 구현한 동작 |
|---|---|
| 입력한 금액의 숫자가 바뀜 | 금액 formatter가 숫자 기준 커서·선택 범위를 유지한다. 모바일 조합 입력은 조합이 끝난 뒤 형식을 적용한다. 중간 자리 수정·삭제·붙여넣기를 검증했다. 실제 입금액은 입력한 값을 사용하고 미수금 초과는 별도 대조가 필요하다고 안내한다. |
| 견적 재발행으로 증빙 접수 실패 | 최종금액/QR 발행 시 견적과 메뉴 금액을 잠근다. 동일 조건 재안내는 기존 견적 ID를 반환한다. 확정된 진행 중 견적의 표시 TTL 만료만으로 증빙 접수를 거절하지 않는다. 이미 올린 증빙은 같은 대상·경로로 접수 여부를 확인해 재시도하며 중복 업로드·접수를 막는다. |
| 캐셔가 최종금액을 임의 수정 | 자유 배송비 추가 청구를 차단한다. 실제 비용, 업체, 예약/거래 참조와 해당 주문에 직원이 올린 첨부를 요구하며 서버가 차액을 계산한다. 고객 동의 절차를 정산 조건으로 사용하지 않는다. 원 견적·음식 가격·세금·입금 증빙은 그대로 보존한다. |
| 실제 배송비 증가·감소 | 매장 선결제는 증가분만 별도 입금으로, 감소분은 환불 의무로 처리한다. 부분 입금 후 비용이 변경돼도 받은 금액을 회계 결제에 연결한다. 포장 전환 시 이미 환불한 배송비를 다시 환불하지 않는다. 고객이 기사에게 직접 지급하면 POS 추가 청구나 매장 기사 지급을 만들지 않는다. 미정산 상태의 인계는 차단한다. |
| 브라우저 종료 시 주문 복원 실패 | 주문 생성과 접근 키 발급을 하나의 서버 처리로 실행한다. 주소를 `/order/:slug/r/:requestId#access=…`로 전환하고 링크 복사 버튼을 제공한다. 같은 URL에서 캐시 없이 주문·결제·채팅·증빙을 복원한다. 일반 매장 URL의 캐시는 진행 중 주문을 찾는 보조 수단이다. |
| 완료 주문 링크·캐시가 계속 남음 | 수령/배송 완료와 필요한 환불 정산이 끝나면 접근 키를 무효화한다. 취소 주문은 받은 돈의 환불·상담 종료까지 접근을 유지한다. 포장 수령 후 환불이 남으면 링크와 갱신을 유지한다. 다음 상태 갱신·접속 때 해당 주문의 키·임시 화면·증빙·알림 캐시만 지우며 저장한 배송지와 다른 주문은 유지한다. |
| 합석하려면 취소 후 재주문 | 캐셔의 메뉴 행 이동과 여러 메뉴 일괄 이동을 제공한다. 빈 테이블과 주문이 있는 테이블 모두 선택 가능하다. 일반 메뉴는 수량 일부를 나눠 이동한다. 1103 소떡소떡을 1104로 옮긴 뒤 대상 주문에서 기존 서비스 제외를 적용할 수 있다. 이동 자체가 무료 처리를 실행하지 않는다. |
| 3개 중 1개 취소가 불가능 | 취소 수량과 `3→2` 및 메뉴 금액 차감을 확인하고 남은 수량만 변경한다. 부분 취소마다 별도 원장·행위자·고객 요청 사유·전후 수량·금액을 보존한다. 반복 부분 취소, 잔량 전체 취소, 안전한 실행 취소를 연결했다. |

조사 주문의 두 견적은 모두 171,720 VND였다. 금액 입력 오류와 동일 견적 재발행에 따른 증빙 거절은 각각 확인했으며, 금액 입력 오류가 캐셔의 재발행을 유발했다는 인과관계는 여전히 확인되지 않았다.

## 금액·권한·주방 처리 경계

주문 접근 키는 난수로 생성하며 서버에는 해시를 저장한다. 내부 세션 검증 자료는 Edge 내부에서만 교환하고 고객에게 반환하지 않는다. 조회·채팅·이미지·결제·푸시 모두 같은 주문으로 범위를 제한한다. URL 키를 탐색 이력에 기록하지 않으며 유효한 진행 중 주문 링크는 기존 브라우저 세션 만료와 분리해 복원한다. 키 종료는 고객 접근 종료이며 POS 금융 기록 삭제가 아니다.

테이블 이동은 단가·VAT·옵션·메모·서비스 승인과 조리·트레이·층 제공 이력을 보존한다. 새 음식 주문 이벤트를 만들지 않으며 기존 준비 수량·준비 묶음을 새 목적지와 함께 이동한다. 이동 후 할인은 기존 규칙으로 재검토하고 고객 결제 표시도 새 금액으로 갱신한다. 테이블과 주문의 잠금 및 변경 직전 상태 검증으로 결제와 이동이 동시에 진행될 때 안전하게 거절한다.

부분 취소는 실제 제공 이력을 청구 수량으로 덮어쓰지 않는다. 취소 전후 조리·제공 snapshot과 감사 원장을 남기고 남은 작업만 줄인다. 조리됐거나 소비한 취소 수량은 결제 시 재고 소비량에 한 번 반영한다. 반복 부분 취소 후 잔량 전체 취소·복원·재취소에서도 소비 수량이 사라지거나 중복되지 않는다. 기존 원자적 `process_payment` 경로와 금융 계산을 유지하며 재고 수량 입력에 소비한 취소 수량만 추가했다. MISA는 기존 비동기 경로를 사용한다.

결제된 주문의 메뉴 변경은 기존 조정·환불 기능을 사용한다. 부분 취소 이력이 있는 메뉴의 이동, 수량을 정확히 나눌 수 없는 콤보 또는 조리 검토 이력은 남은 행 전체 이동으로 제한한다. 이때 화면에 제한 사유를 표시한다. 서비스 제외의 기존 조건과 관리자 PIN을 유지한다. 실행 취소는 이후 수량·조리 상태가 바뀌지 않은 경우에만 허용한다.

기존 개인정보 보존 기간과 정리 작업을 유지한다. 열린 주문·미환불 주문은 나이만으로 정리하지 않는다. 종료 후 보존 기간이 지난 첨부·주소는 정리하되 입금·환불·실비 변경 원장은 보존한다. 닫힌 브라우저의 캐시는 서버가 즉시 지울 수 없으므로 다음 접속 때 정리한다.

## 파일과 검증

신규 migration은 다음 순서다.

1. [최종금액·증빙·주문 링크](/Users/andreahn/globos_pos_system/supabase/migrations/20261009150000_direct_order_final_amount_and_access.sql)
2. [실제 배송비 차액·환불 정산](/Users/andreahn/globos_pos_system/supabase/migrations/20261009151000_direct_order_verified_delivery_cost.sql)
3. [캐셔 메뉴 이동·부분 수량 취소](/Users/andreahn/globos_pos_system/supabase/migrations/20261009152000_cashier_item_move_and_partial_cancel.sql)

| 검사 | 결과 |
|---|---|
| 고객 링크·캐시·주문·채팅·환불 화면 | 50개 통과. [로그](/Users/andreahn/globos_pos_system/docs/implementation/evidence/direct_order_and_cashier_20261009/customer-tests.log) |
| 입력·증빙 재시도·정산·캐셔 화면 | 27개 통과. 직원 배차 9개도 통과. [관련 테스트](/Users/andreahn/globos_pos_system/docs/implementation/evidence/direct_order_and_cashier_20261009/payment-cashier-tests.log) |
| 주문·정산 SQL | 통과. 동일 견적, 임의 수정 차단, 확정 견적 TTL, 주문 범위, 세션 만료, 취소/배송 종료, 실비 증가/감소, 부분 입금, 기사 직접 결제, 포장 순환 환불과 개인정보 정리를 검증했다. [로그](/Users/andreahn/globos_pos_system/docs/implementation/evidence/direct_order_and_cashier_20261009/direct-order-sql.log) |
| 캐셔 SQL | 통과. 사용 중 테이블, 메뉴 분할, 준비 묶음, 서비스 승인, 콤보, 제공 이력, 반복 취소/복원과 재고를 검증했다. 별도 두 PostgreSQL 연결에서 결제와 이동의 경쟁 상태도 검증했다. [로그](/Users/andreahn/globos_pos_system/docs/implementation/evidence/direct_order_and_cashier_20261009/cashier-sql.log) |
| Edge | 24개·format·lint 통과. 주문 범위·내부 키 교환·첨부·오류 정제를 포함한다. [로그](/Users/andreahn/globos_pos_system/docs/implementation/evidence/direct_order_and_cashier_20261009/edge.log) |
| 정적 검사/format | 14개 대상 No issues found. 변경 Dart 17개 format 추가 변경 없음. [로그](/Users/andreahn/globos_pos_system/docs/implementation/evidence/direct_order_and_cashier_20261009/analysis.log) |
| 웹 release build | 통과. 기존 외부 패키지 wasm dry-run와 Cupertino font 경고 유지. [로그](/Users/andreahn/globos_pos_system/docs/implementation/evidence/direct_order_and_cashier_20261009/web-build.log) |
| 전체 Flutter | 1,804개 통과 / 94개 skip / 기존 불일치 2개 실패. [로그](/Users/andreahn/globos_pos_system/docs/implementation/evidence/direct_order_and_cashier_20261009/flutter-full.log) |
| 전체 저장소 검사 | 기존 감사용 Dart 정적 문제 4건에서 중단. 전체 검사·release gate 통과 아님. [로그](/Users/andreahn/globos_pos_system/docs/implementation/evidence/direct_order_and_cashier_20261009/check-repo.log) |

SQL은 삭제 가능한 Docker PostgreSQL에서 실행했다. MISA intake는 기존 테스트 경계에서 확인했으며 실제 외부 발행은 호출하지 않았다. 기존 KDS 1/100/500개 목록 검사에서 기반 조회는 각각 1회다. 메뉴 이동은 선택 항목을 하나의 RPC로 처리하며 캐셔 목록마다 주문 상세 RPC를 추가하지 않았다.

시작 시점 백업과의 [구현 단계 patch](/Users/andreahn/globos_pos_system/docs/implementation/evidence/direct_order_and_cashier_20261009/task-only.patch)와 [변경 파일 해시](/Users/andreahn/globos_pos_system/docs/implementation/evidence/direct_order_and_cashier_20261009/changed-files.json)를 보관했다. 이전 턴에서 완료한 금액 formatter 수정은 이 patch에 중복 포함하지 않았다. 사용자 소유의 ARB를 포함한 관련 없는 변경은 유지했다.

전체 Flutter의 남은 두 실패는 `direct_order_arrival_alert_test.dart`의 생성 번역 파일 고정 해시와 `route_operational_state_coverage_contract_test.dart`의 Admin 테스트 제목 불일치다. [이전 구현 기록](/Users/andreahn/globos_pos_system/docs/implementation/direct_order_support_and_payments_20261008.md)에도 같은 실패가 기록돼 있다. 이번 구현에서 ARB와 Admin 테스트는 수정하지 않았다. 캐셔 이동·수량 취소로 변경된 cashier source의 고정 해시만 갱신했다.

390×844 모바일 대화상자는 실제 폰트로 이미지를 생성해 확인했다. [수량 취소 화면](/Users/andreahn/globos_pos_system/docs/implementation/evidence/direct_order_and_cashier_20261009/cashier-partial-cancel.png), [사용 중 테이블 이동 화면](/Users/andreahn/globos_pos_system/docs/implementation/evidence/direct_order_and_cashier_20261009/cashier-move-occupied-table.png). 실제 모바일 키보드·브라우저 앱 종료는 현장 확인이 남아 있으며, 캐시 삭제 후 동일 URL 복원은 widget에서 검증했다.

## 운영 반영 상태

| 상태 | 결과 |
|---|---|
| 소스 구현 | 완료 |
| 임시 DB migration 적용·검증 | 완료 |
| 운영 DB migration 적용 | 미실행 |
| 운영 Edge·클라이언트 배포 | 미실행 |
| 실제 모바일·이체·Windows 출력 확인 | 미실행 |

배포할 때 선행 migration과 신규 세 migration을 먼저 통합 검증하고 DB → Edge → 클라이언트 순으로 적용해야 한다. 정확한 pushed HEAD의 필수 GitHub Actions 성공과 `scripts/deploy_pos_production.sh`의 gate가 필요하다. 기존 불일치를 무시해 release PASS로 보고하지 않는다. 이미 발급된 주문 링크·확정 견적·입금·취소 원장을 삭제하는 롤백은 사용하지 않는다.
