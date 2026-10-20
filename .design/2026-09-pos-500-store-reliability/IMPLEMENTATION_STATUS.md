# 500매장 안정성 구현 상태

기준일: 2026-09-19

이 문서는 `source implemented / DB applied / client deployed / operationally verified`를 분리한다. 코드가 존재하거나 로컬 테스트가 통과했다는 이유만으로 500매장 운영 인증을 선언하지 않는다.

## 현재 판정

| 구분 | 상태 | 근거 |
| --- | --- | --- |
| source implemented | PARTIAL | 연결 상태 분류, polling 완화, KDS enrichment 집합화, cursor 복구, 일반 주문/KDS outbox 내구성의 첫 구현 완료 |
| DB applied | NOT APPLIED | `20260919010000_kds_set_based_enrichment.sql`은 격리 PostgreSQL에서만 검증했으며 운영 DB에는 적용하지 않음 |
| client deployed | NOT DEPLOYED | 운영 배포 요청과 clean release SHA가 없어 배포하지 않음 |
| operationally verified | NOT RUN | 500매장 staging 부하, 실제 quota, 장애 주입, PITR 복원, cohort 관측 미실행 |
| 500-store certified | **NO** | TASKS T01~T35 및 VALIDATION_PLAN의 운영 게이트가 아직 모두 충족되지 않음 |

## 구현 완료 범위

### 연결 상태와 사용자 표시

- `restaurants` 테이블을 10초마다 읽던 연결 확인을 Supabase health endpoint 기반 30초 jitter probe로 교체했다.
- 실제 네트워크 단절, 서버 지연/429/5xx, 인증 필요, Realtime 지연을 별도 상태로 분류했다.
- timeout과 서버 오류를 인터넷 단절로 오표시하지 않으며 마지막 성공 시각과 수동 재시도를 노출한다.
- cashier, waiter, attendance, 주문 workspace의 boolean 연결 소비를 상세 상태 소비로 전환했다.
- 배너의 재시도 버튼은 48dp 접근성 touch target을 유지한다.

### 요청 폭주와 중첩 실행 방지

- KDS legacy full snapshot의 1초 fallback을 제거하고 연결 여부와 무관하게 30초 ±5초 safety poll을 사용한다.
- order/table/payment/kitchen/admin table provider, customer display, bank-transfer alert, QR menu, 결제 상세, 배달 알림/추적의 고정 주기 poll을 느린 one-shot+jitter 안전망으로 변경했다.
- 주기 작업은 이전 요청 완료 뒤 다음 요청을 예약하며, 화면 scope와 generation이 바뀐 늦은 응답을 폐기한다.
- QR 메뉴는 Realtime을 fast path로 사용하고 background/hidden 상태에서는 safety timer를 중지한다.

### KDS SQL과 실시간 복구

- `emergency_enrich_start_ready_orders`의 주문별 PL/pgSQL 반복 조회를 set-based CTE/aggregate SQL로 교체하는 migration을 추가했다.
- migration에 preflight, verify, rollback, fixture parity 검증을 추가했다.
- v2 bootstrap은 저장 cursor보다 서버 revision이 뒤로 간 restore/rollback을 감지해 authoritative bootstrap cursor로 복구한다.
- batch/store/revision validation과 handler 성공 이후 cursor 저장 경계를 강화했다.

### 오프라인 명령 내구성

- 일반 주문 queue와 네이티브 KDS outbox를 checksum이 있는 schema v2 envelope, primary/backup 두 세대, 직렬화된 write/delete로 교체했다.
- 손상 데이터를 빈 queue로 위장하지 않고 오류로 보존하며, 한 복사본만 정상일 때 정상 복사본을 선택한다.
- KDS outbox 레코드에 매장 scope를 저장하고 다른 매장의 pending/replay에서 제외한다.
- Web IndexedDB write/delete는 request 성공이 아니라 transaction commit 완료까지 기다린다.

## 로컬 검증 결과

- `dart analyze --fatal-infos`: PASS, issue 0건.
- `flutter test --reporter compact`: PASS, 1,589 tests / 94 skipped / failure 0건.
- `bash scripts/check_repo.sh`: PASS, exit 0. 정적 분석, 전체 Flutter suite, SQL/API 계약, Deno/Node 보안·배포 계약, Flutter Web release build, whitespace gate를 포함한다.
- `flutter build web --debug`: PASS. `web/index.html`의 inline JavaScript도 `node --check`를 통과했다.
- KDS set-based migration: 격리 PostgreSQL에서 preflight→apply→fixture parity→verify→rollback→reapply PASS.
- 전체 fresh migration replay는 이 변경보다 앞선 `20260711090000_legal_entity_brand_store_hierarchy.sql`의 `public.stores` 부재로 중단되므로 staging 적용 전 별도 해소가 필요하다.

Web release build의 Wasm dry-run에서 `image 4.3.0` 의존성 lint와 Cupertino icon font 경고가 있었지만 현재 JavaScript Web build와 저장소 gate는 성공했다. 이는 향후 Wasm 전환 시 해소할 호환성 항목이며 이번 장애 대응의 배포 판정에는 포함하지 않는다.

## 아직 완료되지 않은 필수 항목

다음은 코드만으로 완료할 수 없거나 아직 추가 구현이 필요한 항목이다. 이 항목들이 남아 있는 동안 “다시는 장애가 없다” 또는 “500매장 보장”이라고 표현하면 안 된다.

1. 완료 이력 10,000건의 서버 keyset pagination과 bounded bootstrap(T10~T12).
2. 최신 tray/floor/customer-delivery 계약을 포함한 legacy/v2 ticket·ACK·shadow parity 및 private-channel 실제 JWT 시험(T03, T13~T17).
3. request ID 기반 화면→RPC→DB 관측, 비용 상한, store별 noisy-neighbor admission control(T08, T20~T22).
4. payment/KDS/general command의 서버 commit 후 응답 유실 대사와 실제 full-disk/multi-tab 시험(T23~T25).
5. 실제 Supabase compute/connection/Realtime quota와 비용 확인, staging 500매장·2배 burst·24시간 soak(T02, T28~T30).
6. PITR 독립 복원, RPO/RTO 계측, 회선/전원/cloud 24시간 단절 운영 훈련(T26~T27).
7. 정확한 clean SHA의 필수 check 이후 1→5→20→50→100→250→500 단계 배포와 관측(T31~T35).

## 다음 승인 게이트

1. 현재 dirty 작업을 기능별 commit으로 분리하고 exact SHA에서 전체 저장소 gate를 통과시킨다.
2. staging 전체 migration replay의 선행 실패(`20260711090000_legal_entity_brand_store_hierarchy.sql`에서 `public.stores` 부재)를 별도 수정한 뒤 최신 전체 schema로 재검증한다.
3. KDS migration을 staging에 preflight→apply→verify→rollback→reapply하고 golden parity 및 EXPLAIN/BUFFERS를 기록한다.
4. production을 명시적으로 거부하는 실제 SDK/JWT load harness로 100→250→500매장 증가 시험을 실행한다.
5. 모든 CRITICAL/HIGH가 닫힌 뒤에만 `scripts/deploy_pos_production.sh`와 cohort 절차를 사용한다.

운영 DB 변경과 운영 client 배포는 이 구현 작업에서 수행하지 않았다.
