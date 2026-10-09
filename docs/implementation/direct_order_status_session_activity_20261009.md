# 포장·배달 금액 확인 후 주문 현황 조회 실패 수정

2026-10-09 · Asia/Ho_Chi_Minh

## 원인과 운영 확인

11:04:08의 `direct-order-public` 요청은 HTTP 503을 반환했다. 같은 시각 DB 로그는
`cannot execute UPDATE in a read-only transaction` (SQLSTATE `25006`)을 기록했다.
호출 경로는 `direct_order_public_status_v5` → v4 → v3 → v2 → 기존 status →
`direct_order_validate_session`이다. 마지막 함수는 세션의 `last_seen_at`을 갱신한다.
v5의 `STABLE` 선언 때문에 PostgREST가 전체 RPC를 읽기 전용 트랜잭션으로 실행했다.
고객 앱은 접수 RPC 성공 후 이 조회 RPC를 호출하므로 접수된 주문을 표시하지 못했다.

운영 카탈로그와 현재 main(`8170e3c0`)의 함수 본문 해시가 일치한다.
운영 DB의 신규 migration 사전 검사는 읽기 전용으로 통과했다.
운영 주문, 결제, 재고, 고객 세션을 수정하는 진단 호출은 실행하지 않았다.

## 수정 범위

신규 `20261009010000_direct_order_status_session_activity.sql`은 v5의 선언을
`VOLATILE`로 바꾸고 PostgREST schema cache를 갱신한다. 기존 migration은 수정하지 않는다.
마이그레이션은 본문 해시·권한·search_path를 검사하고, 적용 전후 `pg_proc`의
volatility 외 모든 필드가 동일한지 확인한다. 주문·결제·재고 데이터 변경은 없다.
사전 검사, 적용 후 검사와 롤백 SQL을 공식 배포 스크립트의 파일명 규칙으로 제공한다.
롤백은 원래 읽기 전용 오류를 되살리므로 긴급 복원 용도다.

## 검증

- 삭제 가능한 PostgreSQL + 실제 PostgREST v14.5에서 접수 성공 후 현황 조회의
  HTTP 405 / SQLSTATE 25006을 재현했다. Edge는 이 오류를 공통 HTTP 503으로 변환한다.
- 수정 후 배달·포장 현황 조회 HTTP 200, 세션 갱신, 잘못된 secret·다른 세션의
  주문 접근 차단, 동일 접수 요청 재시도의 주문 1개 유지, 기존 v3/v4 응답을 검증했다.
- 함수 정의의 volatility 외 변경 없음, 결제·POS 주문·재고 데이터 변화 없음,
  롤백 및 재적용을 검증했다. 이 API 회귀 검사는 기존 support SQL suite에 포함된다.
- 관련 Flutter 테스트 51개 통과. `dart analyze --fatal-infos`, shell syntax,
  `git diff --check` 통과.

## 운영 반영

이 문서 작성 시점은 소스 수정·로컬 검증 상태이며 운영 적용 전이다.
정확한 pushed SHA의 필수 GitHub Actions를 확인하고, main 통합 후
`scripts/deploy_pos_production.sh --db-only --migration supabase/migrations/20261009010000_direct_order_status_session_activity.sql`
의 gate를 통해 적용한다. 웹·Edge 재배포는 필요하지 않다.
