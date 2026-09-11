# QSC v2 Staging Preflight Observation (2026-05-07)

## 1. 실행 목적

QSC v2 draft migration을 실제 apply하기 전에 linked staging 환경의 현재 상태를 비파괴 조회로 확인하려고 했다.

## 2. 확인한 사실

### 2.1 linked project ref

로컬 Supabase 작업 디렉터리 기준 project ref는 아래였다.

```text
ynriuoomotxuwhuxxmhj
```

### 2.2 Office wrapper views 미배포

linked query 한 건은 정상 응답했고, 그 결과 아래 wrapper view가 아직 존재하지 않음을 확인했다.

```text
v_office_qsc_dashboard = null
v_office_qsc_store_latest = null
v_office_qsc_issue_queue = null
```

즉, 현재 linked 환경에는 QSC v2 Office wrapper view가 아직 배포되지 않았다.

## 3. 실행 중 만난 환경 이슈

추가 linked query를 병렬로 시도했을 때 Supabase temp role 연결에서 아래 에러가 반복 발생했다.

```text
FATAL: (ECIRCUITBREAKER) too many authentication failures, new connections are temporarily blocked
```

최종 메시지:

```text
Connect to your database by setting the env var: SUPABASE_DB_PASSWORD
```

## 4. 해석

현재 환경에서는 다음 두 가지가 동시에 성립한다.

1. linked query 자체는 원칙적으로 가능하다
2. 단일 linked query는 성공했지만, 여러 linked query를 짧은 시간에 병렬로 실행하면 temp role 인증 circuit breaker에 걸릴 수 있다

따라서 QSC v2 staging smoke/apply는 아래 원칙으로 다시 시도해야 한다.

- 병렬 query 금지
- 순차 query만 사용
- 가능하면 `SUPABASE_DB_PASSWORD`를 준비해서 direct DB URL 경로까지 확보

## 5. 다음 권장 액션

1. `SUPABASE_DB_PASSWORD` 확보 또는 staging DB direct connection 확인
2. [qsc_v2_staging_runbook.md](/Users/andreahn/globos_pos_system/docs/qsc_v2_staging_runbook.md) 기준으로 순차 preflight 재실행
3. `20260507000007`부터 file 단위 apply 시작
4. apply 후 [qsc_v2_office_pos_bridge_checklist.md](/Users/andreahn/globos_pos_system/docs/qsc_v2_office_pos_bridge_checklist.md) 기준으로 Office wrapper query smoke 수행

## 6. 결론

이번 시도는 production-impacting mutation까지 가지 않았고, linked staging 환경의 현재 제약을 확인하는 단계에서 멈췄다.  
중요한 수확은 “Office wrapper view는 아직 없고, remote smoke는 순차/단일 연결 전략으로 다시 시도해야 한다”는 점이다.
