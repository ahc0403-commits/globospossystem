# QSC v2 Office Wrapper Smoke Report (2026-05-07)

## 1. 목적

QSC v2 wrapper view가 staging에서 실제로 조회 가능한지 확인하고, Office `pos-bridge` 소비 전 기본 상태를 기록한다.

## 2. 확인된 성공 항목

### 2.1 `v_office_qsc_dashboard`

단일 linked query로 조회 성공.

샘플 결과 특성:

- row가 실제로 반환됨
- `restaurant_id`와 `store_id`가 함께 노출됨
- 현재 샘플 row는 모두 `store_status = 'no_data'`
- `latest_check_date`는 `null`
- `total_checks`, `submitted_checks`, `pending_checks` 등은 `0`

즉, wrapper view 자체는 정상 동작하고, 아직 QC/QSC source 데이터가 없는 매장도 안정적으로 표현된다.

### 2.2 `v_office_qsc_issue_queue`

단일 linked query로 조회 성공.

결과:

- 빈 배열 반환

즉, view는 존재하고 조회 가능하지만 현재 조건에 맞는 issue row는 없었다.

### 2.3 `v_office_qsc_store_latest`

단일 linked query로 조회 성공.

샘플 결과 특성:

- row가 실제로 반환됨
- `GLOBOS Test Restaurant` 기준 `check_date = 2026-04-09`
- `total_checks = 1`
- `submitted_checks = 1`
- `pass_checks = 1`
- `store_status = 'good'`

즉, store latest wrapper도 Office 매장 현황용 snapshot을 정상적으로 제공한다.

### 2.4 `v_quality_monitoring`

두 가지를 확인했다.

1. `count(*)` 조회 성공
   - `monitoring_rows = 1`
2. explicit column drill-down 조회 성공

샘플 결과 특성:

- `category = 'Validation QC'`
- `result = 'pass'`
- `submission_status = 'submitted'`
- `photo_status = 'not_required'`
- `sv_review_status = 'not_required'`
- `followup_status = 'none'`

즉, Office drill-down이 기대하는 raw monitoring 표면도 실제 row를 반환한다.

## 3. 확인된 실패/제약

추가 query를 짧은 간격으로 반복하면 linked temp role 인증이 불안정해질 수 있었다.

반복된 에러:

```text
FATAL: (ECIRCUITBREAKER) too many authentication failures, new connections are temporarily blocked
```

그리고 최종적으로 CLI는 아래 힌트를 반환했다.

```text
Connect to your database by setting the env var: SUPABASE_DB_PASSWORD
```

## 4. 해석

현재 staging linked 환경은 다음 패턴으로 이해하는 게 맞다.

1. 단일 순차 query는 종종 성공한다
2. 짧은 간격의 추가 query는 temp role auth circuit breaker를 유발할 수 있다
3. 따라서 Office smoke는 linked 병렬 조회가 아니라 매우 보수적인 순차 조회 또는 direct DB URL 경로가 필요하다

## 5. 다음 권장 액션

1. `SUPABASE_DB_PASSWORD` 확보
2. 가능하면 `SUPABASE_DB_URL`로 direct query 경로 준비
3. 그 후 아래 조회를 다시 순차 실행
   - `select * from public.v_office_qsc_store_latest limit 3`
   - `select count(*) from public.v_quality_monitoring`
   - `select * from public.v_quality_monitoring where ... limit 3`

## 6. 결론

Office wrapper layer는 최소한 `v_office_qsc_dashboard`와 `v_office_qsc_issue_queue` 기준으로는 staging에서 조회가 가능하다는 점을 확인했다.  
남은 것은 wrapper 전체 기능 문제가 아니라, 현재 linked temp-role 인증 안정성 제약을 우회해 추가 smoke를 끝내는 일이다.
