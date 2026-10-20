# 빈탄점 배달 주문 로딩 오류 운영 반영 기록

## 원인과 수정 범위

고객 페이지 https://globospossystem.vercel.app/#/order/bunsikclub-binh-thanh 에서 메뉴 77개 조회는 가능하지만 주문 목록 API가 HTTP 503으로 실패했다. 운영 DB에서 목록 orders_v5와 상태 status_v10은 STABLE로 선언돼 있었다. PostgREST가 읽기 전용 트랜잭션을 사용하고, 하위 세션 검증 함수가 last_seen_at을 UPDATE하면서 SQLSTATE 25006이 발생했다.

두 함수만 VOLATILE로 바꾸고 PostgREST 스키마 캐시를 갱신한다. 기존 함수 본문, SECURITY DEFINER, search_path, 실행 권한, 응답 계약과 데이터 접근 범위를 원자적 마이그레이션 안에서 검증한다. 결제, 재고, 주문 업무 데이터는 수정하지 않는다.

적용할 마이그레이션: 20261011183000_direct_order_public_rpc_session_activity.sql. 처음 지정했던 20261011140000은 기존 운영 배포 pos_recipient_buyer_lookup_bounded_release에 이미 사용되어 번호를 바꿨다. 기존 운영 이력은 보존한다.

## 소스와 사전 검증

- 구현 PR: https://github.com/ahc0403-commits/globospossystem/pull/558
- 번호 충돌 정정 PR: https://github.com/ahc0403-commits/globospossystem/pull/559
- 정정 PR의 최종 head 4bb06c68c308dc7c8f0b4b0a426ea3d2747f1e01 필수 CI 통과: https://github.com/ahc0403-commits/globospossystem/actions/runs/38135653907/job/114458856236
- 최종 병합 main: c998d7e89712293caae50340ccc9063bed6288c1 (2026-10-11 18:43:08 Asia/Ho_Chi_Minh). 운영 배포는 이 SHA의 필수 CI 성공을 확인한 뒤 수행했다.
- 로컬 dart analyze --fatal-infos: 통과.
- 관련 Flutter 테스트 4개 파일: 94개 통과.
- 통합 SQL 및 실제 PostgREST 회귀 검사: 변경 전 목록/상태 HTTP 405, SQLSTATE 25006 재현. 변경 후 빈 목록, 배달/포장 주문 목록 및 상태 HTTP 200 확인. 잘못된 세션 비밀값, 다른 세션 소유 주문, 없는 주문, 철회한 세션, 조회 상한 초과 거부 확인.
- 세션 활동 갱신, 결제/재고/주문 관련 행 수 보존, 롤백 후 동일 정의 복원, 재적용 및 중복 적용 확인.
- 목록 1/10/50행: 각각 489/4890/24450바이트, 로컬 PostgREST 약 0.004/0.006/0.006초. 별도 통제 SQL에서 일괄 조리 상태 함수 호출 1회, 상세/예약/지원 개별 함수 호출 0회. 운영 응답 시간과 혼합한 수치가 아니다.
- 첫 병합 SHA 82e2e4b의 main 검사는 관련 없는 영수증 테스트 임시 PostgreSQL의 소켓 연결 실패로 중단됐다. 해당 로컬 검사는 재통과했다. 번호 수정으로 대상 SHA가 바뀌어 이전 재실행은 취소했다. 운영 반영에는 최종 main SHA의 성공 검사만 사용한다.

## 운영 배포 증거

운영자: 이 대화에서 사용자의 운영 반영 요청을 수행한 Codex.
대상: Supabase ynriuoomotxuwhuxxmhj.
정식 경로: scripts/deploy_pos_production.sh --db-only --migration ... --yes.

- 필수 main 검사: c998d7e89712293caae50340ccc9063bed6288c1, POS release contract 성공. 2026-10-11 19:03:05 Asia/Ho_Chi_Minh 완료.
- 검사 링크: https://github.com/ahc0403-commits/globospossystem/actions/runs/38136587846/job/114461598961
- 깨끗한 배포 작업 사본에서 HEAD == freshly fetched origin/main과 정확한 SHA의 필수 CI 성공을 정식 스크립트가 dry-run 및 실제 배포에서 확인했다.
- dry-run 확인 후 운영 적용 시작: 2026-10-11 19:04:21 Asia/Ho_Chi_Minh.
- 운영 적용 및 이력 확인 완료: 2026-10-11 19:05:35 Asia/Ho_Chi_Minh 시점 확인. 정식 배포 스크립트 종료 코드 0, DB-only release flow completed.
- 마이그레이션 20261011183000 / direct_order_public_rpc_session_activity 운영 등록 확인. 기존 20261011140000 / pos_recipient_buyer_lookup_bounded_release 이력 보존.
- 두 운영 함수 provolatile=v. 본문 해시 orders_v5=933d1228242d1506dad4468e9cbc8cd0, status_v10=e8c04b1d2c6127020983a3aa11a52151 보존. SECURITY DEFINER=true, search_path=public, pg_catalog, anon/authenticated 실행 불가, service_role 실행 가능 보존.
- 별도 고객 API 검증: storefront HTTP 200, 메뉴 77개, 38929바이트, 2.066초. 정상 방문자 임시 세션 생성 HTTP 200, 0.664초. orders_v5 HTTP 200, 빈 목록, 11바이트, 0.736초. CORS 운영 origin 확인. 주문·결제·재고 생성 없음.
- 기존 빈탄점의 유효한 세션과 주문을 DB 내부에서 선택해 상태와 목록 응답의 주문 소유 관계 확인: PASS. 세션 비밀값과 주문 본문을 밖으로 내보내지 않았고, 검증 함수의 쓰기는 처리한 예외의 하위 트랜잭션에서 모두 롤백했다.
- UI 검증: 변경 전 오류 화면에서 다시 시도 버튼을 눌러 BunsikClub Binh Thanh 제목, 메뉴 카테고리, 배달/포장 선택과 메뉴 카드 정상 표시를 확인했다. 오류 문구가 사라졌다.

실행 명령(비밀값 없음):

```bash
ENV_FILE=/Users/andreahn/.config/globos/pos-production.env \
TEST_TARGETS="test/direct_order_customer_payment_status_test.dart test/direct_order_recipient_policy_test.dart test/direct_order_requirements_test.dart test/direct_delivery_storefront_widget_test.dart" \
bash scripts/deploy_pos_production.sh --db-only \
  --migration supabase/migrations/20261011183000_direct_order_public_rpc_session_activity.sql \
  --yes
```

동일 명령에 --dry-run을 추가해 사전 경로를 확인했다. 정식 스크립트가 잠금 의존성 설치, 분석, 필수 Edge/retirement 검사 및 Flutter 검사, 롤백 준비, 원자적 적용·내장 검증·이력 등록을 수행했다. 독립 사용자 변경이 많은 원래 작업 폴더는 소스 편집이나 전환을 하지 않았으며, 별도 작업 사본에서 반영했다.

운영 화면 증거: [정상 주문 화면](/Users/andreahn/globos_pos_system/docs/operations/direct_order_binh_thanh_restored_20261011.jpg).

로컬 실행 기록:

- [dry-run](/tmp/globos-direct-order-rpc-deploy-dry-20261011.log)
- [운영 적용](/tmp/globos-direct-order-rpc-deploy-production-20261011.log)
- [운영 API 확인](/tmp/globos-direct-order-rpc-live-smoke-result-20261011.log)
- [번호 수정 후 통합 SQL 회귀 검사](/tmp/globos-direct-order-rpc-migration-id-test-20261011.log)

main 검사 성공은 GitHub check-run API에서 확인했다. 이후 원시 전체 로그 다운로드는 GitHub 로그 호스트의 TLS handshake timeout으로 실패해 해당 원시 로그 파일은 증거로 사용하지 않는다. PR 로그와 로컬 SQL 회귀 로그는 확보되어 있다.

웹/Edge 코드 재배포와 POS 로그인 검증은 DB-only 배포 범위에 포함되지 않는다. 별도 고객 페이지 HTTP/API와 UI 검증 결과를 기록한다.

배포 문서는 DB-only 연결을 공유 세션 풀러로 제한한다고 설명하지만 현재 정식 스크립트는 고정 프로젝트의 direct 5432 임시 CLI 로그인도 허용한다. 공식 Supabase link와 정식 스크립트가 획득한 자격 증명을 사용하며, 메타데이터 복사나 대상 재지정은 하지 않는다.
