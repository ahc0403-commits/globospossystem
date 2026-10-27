# 배달 주문 페이지 초기 로딩 오류 수정

> Current owner policy (2026-10-27): automated verification runs in Codex Cloud or a suitable isolated cloud executor under root `CLAUDE.md`. Preserve complete final-SHA evidence, exact-main, official deployment and operational gates. Historical results below do not certify this candidate.

## 원인과 변경

빈탄점 운영 고객 페이지의 메뉴 조회는 성공하지만 주문 목록 조회는 HTTP 503으로
실패했다. `direct_order_public_orders_v5`가 `STABLE`로 선언되어 PostgREST가
읽기 전용 트랜잭션을 시작하고, 기존 `orders_v4` → `direct_order_validate_session`
경로에서 `last_seen_at`을 UPDATE하려다 SQLSTATE `25006` / HTTP 405가 발생했다.
Edge Function은 이를 일반적인 일시 오류 HTTP 503으로 변환했다.

신규 마이그레이션 `20261011183000_direct_order_public_rpc_session_activity.sql`은
목록 `orders_v5`와 같은 세션 검증을 호출하는 상태 `status_v10`을 `VOLATILE`로
변경한다. 두 함수의 기존 본문 해시, SECURITY DEFINER, search_path와 실행 권한을
확인하고, 변경 뒤 `pg_proc`의 다른 속성이 보존되었는지 같은 트랜잭션에서 검사한다.
PostgREST 스키마 캐시 갱신 알림도 같은 커밋에 포함한다.

함수 본문, 소유자, 접근 범위, 응답 필드, 결제·재고·주문 데이터는 변경하지 않는다.
목록 상한 50개와 기존 일괄 조리 상태·배달 예약 조회 구조를 유지한다.

## 회귀 검증

기존 통합 SQL 테스트의 수령자 배달 마이그레이션 단계에서 실제 PostgREST POST
검증을 실행한다. 두 API의 수정 전 HTTP 405 / SQLSTATE 25006을 재현하고,
수정 뒤 빈 목록, 배달·포장 주문 목록과 상태, 세션 접속 시각 갱신을 검사한다.
잘못된 비밀값, 다른 세션의 주문, 없는 주문, 철회한 세션과 목록 상한 초과도
거부되는지 확인한다. 결제·재고 관련 행 수가 변하지 않는지 확인한다.

1·10·50행 목록에서 응답 크기와 시간을 기록하고, 조리 상태 일괄 함수 1회 및
개별 주문 상세·예약 스냅샷 함수 0회를 확인한다. 통제된 테스트 DB에서 롤백과
재적용, 중복 적용도 검증한다. 롤백 SQL은 기존 장애를 복원하므로 운영에서
자동 실행하지 않는다.

검증 명령:

```bash
bash test/direct_order_integrated_sql_test.sh
dart analyze --fatal-infos
flutter test test/direct_order_customer_payment_status_test.dart \
  test/direct_order_recipient_policy_test.dart \
  test/direct_order_requirements_test.dart \
  test/direct_delivery_storefront_widget_test.dart
```

## 운영 반영

DB만 변경하므로 정식 `scripts/deploy_pos_production.sh --db-only --migration`
경로를 사용한다. 기존 운영 이력의 `20261011140000`은 다른 배포
`pos_recipient_buyer_lookup_bounded_release`에 이미 사용되어 새 번호
`20261011183000`을 사용한다. PR의 필수 로컬 검증 통과와 병합 뒤 정확한 main SHA의
`POS release contract` 성공을 확인한 다음, 깨끗한 작업 사본에서 dry-run과
운영 적용을 실행한다. 기존 웹·Edge Function 버전은 그대로 사용한다.

운영 적용 후 함수 설정·본문·권한과 마이그레이션 이력을 확인하고,
고객 페이지에서 실제 빈탄점 메뉴가 표시되는지 검증한다.

PostgREST의 읽기 전용 실행 규칙:
[Function access mode](https://postgrest.org/en/stable/references/transactions.html#access-mode-on-functions).
