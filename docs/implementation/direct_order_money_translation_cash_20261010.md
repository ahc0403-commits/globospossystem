# 배달 입금 차액·자동 번역·기사 현금 지급 구현 기록

2026-10-10 · Asia/Ho_Chi_Minh

이 문서는 최초 구현과 키 등록 시점의 기록이다. 이후 운영 배포 준비에서 선행 스키마 호환성, 완료 주문 환불 접근, 번역 큐와 검증을 보완했다. 아래 최초 검사 결과와 미배포 상태는 당시 기록이며, 최종 릴리스 상태는 별도 배포 증거에서 확인한다.

입금 부족/초과 대응, 고객과 베트남어 캐셔 사이의 자동 번역, 기사 배달비 현금 지급과 마감 정산을 소스에 구현했다. [기존 통합 계획](/Users/andreahn/globos_pos_system/docs/plans/direct_order_and_cashier_integrated_improvement_20261009.md)에 세 항목을 추가했다. 새 OpenAI 키를 운영 서버 비밀 변수에 등록하고 실제 API 샘플을 확인했다. 기능의 운영 DB·Edge·웹 배포는 아직 실행하지 않았다.

## 구현한 동작

| 요청 | 구현 결과 |
|---|---|
| 부족 입금 | 캐셔가 은행과 대조한 실제 입금액을 기록한다. 서버가 남은 음식 대금을 계산하고 재입금 요청·사진 접수·추가 입금 확인을 연결한다. 임의의 음식 추가금은 거절한다. 전체 음식 금액이 모이면 기존 원자적 결제를 한 번 실행한다. |
| 초과 입금 | 실제 받은 금액과 주문에 적용한 금액을 분리한다. 초과액은 매출에 포함하지 않고 환불 잔액으로 관리한다. 고객은 자신의 환불 계좌를 입력할 수 있다. 캐셔가 환불 방식·거래 참조·사진·실제 지급 확인을 제출하면 환불을 기록하고 고객 채팅에서 사진을 확인할 수 있다. |
| 반복 요청·취소 | 증빙·입금 참조·작업 UUID로 중복 입금/환불/기사 지급을 차단한다. 전체 취소는 초과액부터 반환하고 주문 매출 부분만 기존 결제 조정으로 되돌린다. 배송비 감소·포장 전환 환불에도 사진 확인을 적용한다. |
| 고객 → 캐셔 번역 | 한국어·영어를 포함한 고객 자유 채팅, 주문 요청사항, 메뉴별 메모를 베트남어로 번역한다. 메뉴명과 고정 상태 문구는 기존 다국어 정보를 사용한다. |
| 캐셔 → 고객 번역 | 캐셔 자유 채팅과 견적 메모를 고객이 주문에서 선택한 한국어·베트남어·영어로 번역한다. 원문을 보존하고 화면에서 원문을 펼쳐 볼 수 있다. 실패/대기 중에는 원문과 상태를 표시한다. |
| 기사 현금 지급 | 새 견적의 기본 지급 방식을 매장 선지급으로 설정한다. 실제 배송비와 기사에게 건넨 현금을 별도 기록하며, 양수 지급은 증빙·참조·실제 지급 확인이 있어야 인계할 수 있다. 기존 고객 직접 지급 주문의 계약은 유지한다. |
| 지급 수정·회수 | 원장을 덮어쓰지 않는다. 관리자는 증빙을 첨부해 추가 지급 또는 기존 지급의 회수를 기록한다. 회수액은 아직 회수하지 않은 지급액 이내로 제한한다. 현금 회수와 은행 회수를 구분한다. |
| 마감 | 고객에게 받은 배송비, 실제 배송비, 기사 현금 지급/회수, 고객 현금 환불을 구분한다. 현금 기대액은 `준비금 + 현금 매출 - 기사 지급 + 현금 회수 - 고객 현금 환불`이다. 은행 회수는 금고 현금을 늘리지 않는다. 수동 마감의 확정 값과 미마감/자동 마감의 현재 원장 조회를 구분한다. |

예를 들어 음식 대금 108,000 VND에 처음 100,000을 받으면 재입금 요청액은 8,000이다. 재입금이 10,000이면 매출 결제는 총 108,000으로 한 번 처리하고, 별도 초과액 2,000을 환불 대상으로 남긴다. 같은 입금 확인을 반복해도 매출·재고·주방 주문은 중복 생성하지 않는다.

기사에게 현금 10,000을 지급한 후 현금 2,000과 은행 1,000을 회수하면 금고의 순감소는 8,000이다. 고객에게 현금 7,000을 환불하면 마감 기대액이 추가로 7,000 감소한다. 이 계산을 PostgreSQL 통합 검사에서 확인했다.

## 번역과 비밀키 경계

번역은 비동기 작업으로 결제·주방 처리를 기다리게 하지 않는다. 한 번에 같은 주문의 최대 10개 텍스트(총 5,000자 이내)를 가져와 OpenAI Responses API를 한 번 호출한다. 서로 다른 고객 주문은 같은 제공자 문맥에 넣지 않는다. 오류가 있는 결과만 재시도하고 정상 결과는 유지한다. 기본 모델은 `gpt-4.1-mini-2025-04-14`이고 Edge 설정 `DIRECT_ORDER_TRANSLATION_MODEL`로 변경할 수 있다. `store:false`와 엄격한 JSON 응답 형식을 사용하며 작업 ID·숫자 보존을 검증한다. 원문은 덮어쓰지 않는다.

첨부 사진, 구조화된 계좌/연락처/주소, 인증 정보는 번역 입력으로 보내지 않는다. 자유 메시지에 고객이 직접 적은 주소·이름 등은 그 메시지의 일부로 번역될 수 있다. 입력과 외부 응답 본문을 로그에 남기지 않는다. API 오류·잘못된 응답은 최대 5회 재시도하며, 키가 없으면 작업 시도 횟수를 소비하지 않는다. 실패한 채팅 번역은 캐셔가 재시도할 수 있다.

작업 스케줄은 pg_cron/pg_net이 있는 환경에서 10초마다 실행하도록 준비했다. 주문별 최근 처리 순서로 다른 고객의 대기를 공평하게 처리한다. 실제 표시 시간은 작업 대기량·API 응답·기존 상태 갱신 주기에 따라 달라진다. 실시간 번역 속도나 번역 품질을 운영에서 확인했다고 주장하지 않는다.

사용자는 로컬 `.env.local` 저장을 승인하지 않고, 로그인된 OpenAI 브라우저에서 키를 생성해 POS 서버 비밀 변수에만 등록하는 방식을 명시적으로 승인했다. 보안 커넥터의 재인증 오류가 계속되어 승인된 브라우저 경로를 사용했다. Default project에 `globos-pos-translation` 키를 만들었으며 권한은 Restricted의 Responses API Write, 만료는 없음이다. POS 프로젝트 `ynriuoomotxuwhuxxmhj`의 `OPENAI_API_KEY`에 등록하고 값의 일치를 메모리에서 대조했다. 키 값은 채팅·로그·명령 인자·환경 파일에 쓰지 않았다. 메모리에서 암호화해 전송한 뒤 표준 입력으로 서버에 전달했으며 임시 전송 파일은 삭제했다. `.env.local`에는 `OPENAI_API_KEY` 항목이 없다. 서버 관리 권한이 있는 사람과 서버 함수는 키에 접근할 수 있다. [Supabase 비밀 변수 안내](https://supabase.com/docs/guides/functions/secrets#production-secrets)

실제 Responses API 요청 3회를 실행했다. 첫 요청에서 베트남어 답변의 일부 문장이 한국어로 바뀌지 않았고, 다음 요청에서는 `20,000`이 `2만`으로 바뀌어 기존 숫자 검증이 거절했다. 모든 문장의 목표 언어와 숫자·통화 표기를 그대로 유지하도록 지시를 보완했다. 최종 샘플 3건은 한국어·영어→베트남어, 베트남어→한국어가 모두 확인됐고 숫자와 `VND`도 유지됐다. 입력은 가상의 주문 문장으로 실제 고객 정보는 사용하지 않았다. 3회 사용량은 총 1,217 tokens이며 운영 채팅 전체의 번역 품질을 보증하는 검사는 아니다. [샘플과 확인 기록](evidence/direct_order_money_translation_20261010/openai-key-server-verification.json)

## 변경과 검증 근거

새 migration은 선행 배달 지원 migration 뒤에 아래 순서로 적용한다.

1. [입금·환불·현금 원장과 마감](/Users/andreahn/globos_pos_system/supabase/migrations/20261010010000_direct_order_money_reconciliation.sql)
2. [자동 번역 작업·조회·갱신](/Users/andreahn/globos_pos_system/supabase/migrations/20261010020000_direct_order_automatic_translation.sql)

[번역 Edge](/Users/andreahn/globos_pos_system/supabase/functions/direct-order-translation-dispatcher/index.ts), [번역 표시 위젯](/Users/andreahn/globos_pos_system/lib/features/direct_order/direct_order_translation.dart), [입금·환불 화면](/Users/andreahn/globos_pos_system/lib/features/direct_order/direct_order_support.dart), 캐셔/고객/주방 화면과 마감 보고서를 연결했다. 배포 스크립트에는 새 Edge 검사·배포 대상과 `OPENAI_API_KEY` 이름 확인을 추가했다. API 키는 출력하거나 파일에 저장하지 않는다.

| 검사 | 결과와 한계 |
|---|---|
| 최종 관련 Flutter | 42개 통과. 입금 대조·환불 사진·모바일 KO/VI/EN·기사 지급 참조·번역 원문 전환 등을 확인했다. [로그](evidence/direct_order_money_translation_20261010/flutter-focused.log.gz) |
| PostgreSQL 통합 | 통과. 신규 두 migration, 부족/초과/취소 환불, 재시도, 실제 지급 확인, 현금·은행 회수, 마감, 타 고객 계좌 접근 차단, 환불 후 고객 접근, 개인정보 정리와 금융 원장 보존, 양방향 번역·원문·주방 메모를 검사했다. 삭제 가능한 Docker DB만 사용했다. [로그](evidence/direct_order_money_translation_20261010/sql.log.gz) |
| 목록 확장 검사 | 캐셔·주방 목록 1/50/100/200건에서 건별 상세/지원/번역 상세 helper 호출이 모두 0회였다. 새 조회는 페이지별 일괄 조회를 사용한다. [SQL 로그](evidence/direct_order_money_translation_20261010/sql.log.gz) |
| 번역 Edge | 4개 통과. 인증·키 없음·한 번의 batch 호출·응답 ID/숫자 검사·API 오류 재시도를 mock으로 확인했다. 지시 보완 후 format/lint/typecheck와 4개 검사를 다시 통과했다. 실제 API 최종 샘플 3건도 확인했다. [기존 로그](evidence/direct_order_money_translation_20261010/translation-tests.log.gz), [최종 로그](evidence/direct_order_money_translation_20261010/translation-tests-key-provisioning.log.gz) |
| 기존 고객 Edge | 24개 통과. [로그](evidence/direct_order_money_translation_20261010/public-edge.log.gz) |
| 정적 검사 | `dart analyze --fatal-infos lib test` 통과. [로그](evidence/direct_order_money_translation_20261010/analysis.log.gz) |
| 웹 release build | 최종 소스 빌드 통과. 기존 wasm dry-run/Cupertino font 경고 유지. [로그](evidence/direct_order_money_translation_20261010/web-build.log.gz) |
| 배포 gate fixture | clean-worktree 및 DB-only fixture 통과. 실제 GitHub/운영 release 통과를 의미하지 않는다. [clean-worktree](evidence/direct_order_money_translation_20261010/deploy-checks.log.gz), [DB-only](evidence/direct_order_money_translation_20261010/deploy-db-only.log.gz) |
| 전체 Flutter | 1,808개 통과 / 94개 skip / 기존 불일치 2개 실패. 전체 실행 후 지급 참조/화면 fixture 수정은 위 관련 42개로 다시 검증했다. [로그](evidence/direct_order_money_translation_20261010/flutter-full.log.gz) |
| 필수 저장소 검사 | `bash scripts/check_repo.sh` 실행. 기존 `docs/audits/n_plus_one_20261005`의 정적 문제 4건에서 중단했다. 전체 PASS 아님. [로그](evidence/direct_order_money_translation_20261010/check-repo.log.gz) |

전체 Flutter의 두 실패는 생성 번역 파일 고정 해시와 Admin 화면 테스트 제목 불일치다. [직전 구현 기록](/Users/andreahn/globos_pos_system/docs/implementation/direct_order_and_cashier_integrated_20261009.md)에도 같은 실패가 기록되어 있다. 관련 없는 사용자 ARB·감사 파일·테스트 변경은 보존했다. `process_payment` 유효 정의의 해시는 통합 SQL 실행 전후 동일하다. Deliberry와 Photo Objet 자동 수집을 재활성화하지 않았다.

실제 Pretendard 폰트로 [캐셔 정산 화면](evidence/direct_order_money_translation_20261010/cashier-reconciliation.png)을 생성하고 열어 확인했다. 금액·환불 버튼·계좌·기사 현금 지급 표시가 보인다. [키 발급 목록](evidence/direct_order_money_translation_20261010/api-key-created-server-secret.jpg)도 열어 확인했다. 실제 은행 이체, 기사 인계, 현장 번역·마감·기기 사용은 검증하지 않았다.

시작 시 백업이 있는 기존 파일과 새로 만든 파일만 [작업 patch](evidence/direct_order_money_translation_20261010/task-only.patch.gz)에 포함했다. 작업 전 백업이 없는 기존 테스트 파일은 patch에서 제외하고 [변경 파일 manifest](evidence/direct_order_money_translation_20261010/changed-files.json)에 현재 해시와 제외 사유를 기록했다. 사용자 작업과 이번 변경 전체를 동일시하는 Git diff는 만들지 않았다.

## 운영 반영 상태

| 상태 | 결과 |
|---|---|
| 소스 구현·관련 로컬 검증 | 완료 |
| 임시 DB migration 적용·검증 | 완료 |
| 새 OpenAI 키 생성/서버 secret 등록 | 완료. Mac 파일·Git에 키 값 저장 안 함 |
| 실제 OpenAI API 확인 | 완료. 최종 가상 샘플 3건, 숫자·통화 보존 확인 |
| 운영 DB migration | 미실행 |
| 운영 Edge·웹 배포 | 미실행 |
| 실제 번역·은행·기사·마감 현장 확인 | 미실행 |

운영 적용 시 선행 migration과 새 두 migration을 검증하고 DB → Edge → 클라이언트 순으로 적용해야 한다. 등록된 Edge secret를 함수가 읽는지와 번역 cron 실행을 확인해야 한다. 정확한 pushed HEAD의 필수 GitHub Actions 및 `scripts/deploy_pos_production.sh` gate가 필요하며 현재 전체 실패를 release PASS로 취급하지 않는다. 이미 생성된 입금·환불·현금 원장 삭제를 롤백 수단으로 사용하지 않는다.
