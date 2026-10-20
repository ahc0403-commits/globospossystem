# 운영 적용·복구 준비

**이번 작업에서는 실행하지 않았다.** 운영 release는 루트 CLAUDE.md와 [배포 runbook](/Users/andreahn/globos_pos_system/docs/pos/POS_PRODUCTION_DEPLOYMENT_RUNBOOK.md)을 따른다. GitHub Actions의 필수 검사가 정확한 pushed head SHA에서 통과한 뒤 `scripts/deploy_pos_production.sh`를 사용한다. 현재 로컬 PASS는 그 승인을 대신하지 않는다.

## 적용 순서

1. 운영의 현재 함수 정의·grant·RLS와 schema 버전을 읽고 복구용 SQL로 저장한다. `auth.users`의 `is_sso_user`, `users_instance_id_email_idx(instance_id,lower(email))`가 있는지 확인한다. MISA/FCM 현재 dispatcher 버전·진행 중 작업/attempts·cron 설정도 기록한다. Auth preflight가 실패하면 managed Auth schema/index를 임의 수정하지 않는다.
2. 신규 20261011 migration을 순서대로 적용한다. 기존 read API를 유지하므로 DB 먼저, 새 client/Edge 나중에 적용할 수 있다. index 생성에는 테이블 잠금과 쓰기 비용이 있으므로 운영 규모에서 실행 시간을 평가하고 적절한 변경 시간대를 사용한다. `restaurants` physical table/Office read 계약은 유지된다.
3. Flutter client를 일부 매장에 적용하고 초기 조회/검색·cursor·scope 전환·이벤트 100개/연결 복구를 확인한다. 같은 actor/store/date/revision으로 HTTP 수·전송량, 화면 지연, DB BUFFERS/temp를 비교한다. Photo 100/1,000/10,000행은 대표 POS 기기에서 측정하고 작은 파일의 worker 시작 비용도 기록한다.
4. Edge는 owned batch RPC가 설치된 뒤 적용한다. 새 푸시 claim 동안 구 completion은 claim_id가 있는 작업을 변경하지 못한다. 긴급 FCM의 분산 invocation 수·전체 vendor 동시성·429 빈도를 보고 cron/플랫폼 invocation 동시성을 제한한다. 소스의 4 worker 제한은 전역 제한이 아니다.
5. SePay는 실제 수신자·provider가 FCM일 때만 emergency dispatcher가 호출되는지 확인한다. Windows/polling 수신자의 기존 조회/알림은 계속 검증한다. 중복 webhook과 unmatched 이벤트는 새 push를 만들지 않아야 한다.
6. MISA는 구버전 dispatcher의 호출/cron을 중지하고 기존 invocation 종료를 확인한 뒤 교체한다. 구버전은 claim ownership을 모르므로 활성 상태에서 구/신 버전을 동시에 실행하면 중복 외부 발행을 막을 수 없다. 기존 비활성 기본값을 유지한다. 향후 활성화가 승인되면 vendor sandbox에서 token refresh 경쟁, 429, 발행 응답 유실/잘못된 JSON, 완료 RPC 유실을 확인한다. unknown 발행을 포털 조회 없이 pending으로 되돌리거나 자동 재발행하지 않는다.

## 복구 순서

1. 문제가 있는 client/Edge 버전을 먼저 되돌리거나 해당 dispatcher 호출을 일시 중지한다. 기존 read RPC는 남아 있으므로 신규 페이지/요약 함수를 즉시 DROP하지 않아도 된다.
2. 진행 중 소유 claim을 확인하고 최소 lease 90초와 invocation 45초가 끝나도록 기다린 뒤 작업 상태를 읽는다. 다른 owner의 완료를 강제로 허용하거나 일괄 attempts 초기화로 복구하지 않는다. MISA 만료/unknown 작업은 포털 확인 후 상태를 결정한다.
3. 읽기 SQL 회귀이면 적용 전 저장한 함수·grant·정책을 복구한다. 이번 변경에서 직접 교체한 menu analytics/cost/receipt·dashboard 정의는 운영의 실제 predecessor를 저장한 자료를 사용한다. 이 폴더의 timing용 `sql/*_before.sql`은 fixture 재현용이며 전체 운영 rollback 파일이 아니다.
4. 신규 index는 상태가 안정된 뒤 사용량·쓰기 비용을 확인해 필요하면 별도 migration으로 제거한다. 금융·증빙·queue 데이터나 작업 이벤트를 지우지 않는다. 새 claim 컬럼/RPC는 구 client와 호환되는 동안 보존한다.
5. 오류·중복 알림/발행·권한·정확한 금액·매장별 최신성을 재검증하고 실제 SHA, 적용 migration과 복구 상태를 기록한다.
