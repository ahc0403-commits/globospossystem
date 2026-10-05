# Direct Order 배달 개선 구현 결과 — 2026-10-05

아래 검증·미배포 상태는 최초 구현 시점의 기록이다. 현재 릴리스는 최신 main의 기본 방문 포장·11:00–22:00 접수 시간·유료 포장 KDS 흐름을 보존하며, 신규 마이그레이션을 20261005070000/20261005080000으로 분리했다. 실제 운영 적용은 후속 배포 보고서로 확인한다.


근거: `docs/direct_order_delivery_fallback_improvement_plan_20261005.md`, 현재 체크아웃의 Flutter·Edge·migration·테스트.

## 구현된 동작

| 요구사항 | 동작 |
|---|---|
| 식사 인원 | 주소 입력에서 1~100명 필수 입력. 고객 현황·직원 상세·주방·새로 생성하는 전표에 인원/일회용품 세트 표시. 기존 NULL 주문은 미입력으로 표시하고 직원이 보충 가능. |
| 배달 CLOSED | 신규/추가 주문 진입 때 접수 상태 재확인. 기존 고객의 주문 현황·채팅·견적·사진 확인·조리·인계는 유지. 신규 화면에 “현재 주문이 많아 배달이 지연되고 있습니다. 잠시 후 다시 주문해 주세요.” 표시. |
| 관리자 비활성화 | 진행 중 요청이 있으면 외부 주문 활성화 OFF를 거절하고 신규 접수 일시 중지를 사용하도록 안내. 이미 비활성화된 설정도 기존 주문이 있는 유효 세션은 복구 가능. |
| Grab/BE/기타 | 직원이 업체를 선택하고 HTTPS 공유 링크 입력. 기타 업체는 이름 필수. 링크가 없는 업체는 기사 연락 정보로 인계 가능. Grab 도메인 제한 제거. |
| 방문 포장 | 직원 제안 → 고객 동의/거절 → 같은 요청·주문·티켓 유지 → ready에서 직원이 고객 수령 완료. 포장 현황은 배달 중 단계를 생략. |
| 배달비 | 송금 전 포장 동의는 기존 견적을 대체하고 배달비 0으로 새 견적. 이미 송금한 주문은 원견적·사진·원금을 보존하고 승인 후 받은 배달비만 환불 대상으로 표시. |
| 환불 | 실제 은행이체 후 직원이 거래 참조번호를 입력하여 기존 부분 환불 원장에 기록. 수령 완료와 환불 완료는 별도이며, 미환불 주문은 날짜가 지나도 직원 목록에 유지. |
| 중복 방지 | 요청 잠금·방법 버전·견적 ID·티켓 버전으로 제안/동의/인계/환불을 검증. 응답 유실 재시도는 같은 결과를 반환하고 결제·재고·환불·인계 메시지를 추가 생성하지 않음. |

기존 고객 복구는 현재 브라우저의 유효한 저장 세션을 기준으로 한다. 다른 기기 또는 브라우저 저장소 삭제 후의 복구 기능은 기존 인증 범위에 포함되지 않는다. 기사 호출과 은행 송금은 직원이 기존 앱/은행에서 직접 수행한다.

## 주요 변경

- `supabase/migrations/20261005070000_direct_order_delivery_fallback.sql`: 인원/수령 방법/버전, 배달 업체 정보, 고객 포장 제안, 승인 시 guest_count, 수령 완료, 환불 연결, 인계 감사 기록, 전표 정보, 분석과 안전장치.
- `supabase/migrations/20261005080000_direct_order_fallback_set_based_reads.sql`: 후속 N+1 감사에서 발견한 주방의 주문별 context 호출과 항목 집계를 페이지 단위 JOIN/GROUP BY로 교체. 주방은 필요한 인원/수령 방법/버전만 조회.
- `supabase/functions/direct-order-public`: `submit_v3`, `status_v3`, `resume_storefront`, `decide_pickup` 추가. 기존 submit/status/status_v2/orders_v2 유지.
- `lib/features/direct_order`: 고객·직원·주방·설정·분석·모델·서비스와 KO/VI/EN 문구.
- `lib/core/hardware/receipt_builder.dart`, `print_job_agent_service.dart`: 선택적인 Direct Order 인원/수령 방법/환불 정보 전달과 출력. 기존 전표의 기본 입력은 유지.
- `test/direct_order_delivery_fallback_test.dart`, `direct_order_staff_fallback_test.dart`: 실제 고객/직원 버튼 흐름, 세 언어, 모바일, API 모델과 인원 검증.
- `test/direct_order_delivery_fallback_sql_test.sh`와 SQL fixtures: 독립 PostgreSQL에서 유효 함수 적용, 실패 롤백·권한·결제/재고·동시 연결 검사. `scripts/check_repo.sh`에 포함.

공유 링크가 없는 새 dispatch는 이전 고객 앱의 `dispatch` projection을 null로 제공한다. 새 앱은 별도 `delivery` 정보에서 업체와 연락처를 읽는다. 오래된 API 응답에 새 필드를 삽입하지 않는다.

## 결제 보호

- `process_payment` 본문을 수정하지 않는다. 테스트 DB에서 migration 전후 함수 hash가 같음을 확인한다.
- 기존 사진 확인 승인과 원결제/원견적을 계속 사용한다. 포장 전환으로 주문, payment 또는 재고 거래를 재생성하지 않는다.
- 이미 송금한 유료 배달 견적은 사진 확인 전에 배달비 0 재견적으로 덮어쓸 수 없다.
- 매장 수취 배달비가 없는 customer_direct 주문은 기사 현금 지급/환불을 만들지 않는다.
- 은행이체 환불은 원결제 금액 중 배달비만 기존 `record_payment_adjustment`에 기록한다. 이미 다른 환불/취소가 있는 결제는 별도 대사 필요 오류로 중단한다.
- 인계 또는 완료된 배달을 단순 포장 전환하지 않는다. 제안 중에는 기사 인계를 차단한다. 주방의 조리 진행은 계속 가능하다.
- 기존 출력 완료 전표는 역사적 기록이다. 현재 수령 방법/인원을 반영한 포장 인계 전표는 새 출력 또는 재출력으로 생성한다.

## 검증 결과

- `bash scripts/check_repo.sh`: 종료 코드 0. 전체 정적 분석, Flutter 1,625건, SQL/API·Edge·Node·배포 스크립트 계약·웹 release build·whitespace 검사 통과. 외부 환경 조건에 따른 Flutter 94건은 기존 조건대로 skip.
- 최종 결제 보호/API 모델 보완 후 전체 Flutter **1,627건 통과, 94건 조건부 skip**, `dart analyze --fatal-infos` 문제 없음, 독립 SQL 행동·동시 처리 재검증 통과. 최종 소스의 웹 release build 재검증 통과.
- Deno Edge: 19건 통과. format/lint/check 통과.
- 독립 SQL: 인원 검증/수정, CLOSED 재시도와 신규 거절, 비활성화 보호·세션 복구, 다른 세션/매장/역할 차단, 견적 변경 시 오래된 제안 거절, 송금 전/송금 후 포장, 원결제·재고·단일 티켓, 부분 환불 및 실패 롤백, BE/링크 없는 업체, 구 projection, 분석/전표/주방 정보 검사 통과.
- 실제 독립 연결 경합: 동일 동의/환불/기사 인계 두 번 호출, 포장 제안 대 기사 인계에서 단일 결과 확인.
- 직원 입력 팝업의 닫힘 중 controller 해제 오류를 실제 버튼 테스트로 재현하고, 팝업 자체가 controller 생명주기를 관리하도록 수정.

웹 빌드의 기존 `image` 패키지 WASM dry-run 및 Cupertino font 경고는 일반 JavaScript release build 성공과 구분한다.

## 적용 상태와 다음 배포

| 상태 | 결과 |
|---|---|
| 소스 구현 | 완료 |
| 독립 테스트 DB migration 적용 | 완료·검증 통과, 테스트 후 DB 삭제 |
| 운영 DB migration 적용 | 미실행 |
| 운영 Edge/앱 배포 | 미실행 |
| 실제 매장 기사 배정·은행 환불·프린터 업무 확인 | 미실행 |

배포 순서: 기존 고객 사진 확인 migration을 포함한 선행 migration 확인 → 신규 additive migration 적용 → 새 Edge actions 배포 → 새 Flutter 앱 배포 → 매장 시나리오 확인.

운영 release는 정확히 push한 head SHA에서 필수 GitHub Actions 성공을 확인하고 `scripts/deploy_pos_production.sh`로 진행한다. 이번 로컬 검증을 운영 release gate 통과로 보고하지 않는다. 기존 사용자 수정/미추적 파일을 보존하며 이 작업에서 commit/push/운영 배포를 실행하지 않았다.

## Harness 판정

- **CONFIRMED**: 네 가지 요청에 대한 소스 구현과 관련 런타임 회귀 검증.
- **CONFIRMED / N+1 후속 감사**: 새 주방 목록의 context 호출이 100건에서 100회였음을 재현하고 0회로 수정. 1/50/100/200건, 실제 실행계획, 응답 parity, 기존 SQL 행동/경합과 관련 Flutter 38건 검증 통과. 상세 근거: [N+1 감사 결과](direct_order_n_plus_one_audit_20261005.md).
- **MEDIUM 미해결**: 기존 직원/고객 목록 SQL의 행별 집계와 고객 알림의 조건부 API 반복 호출. 전체 주문 조회에서 N+1이 모두 제거됐다는 판정은 아님.
- **우선 후속 작업**: 남은 목록·알림의 일괄 조회 개선, 정식 release gate와 운영 적용, 매장의 실제 기사 링크/포장 수령/은행이체 환불/전표 확인.
