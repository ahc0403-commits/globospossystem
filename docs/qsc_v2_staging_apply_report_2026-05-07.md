# QSC v2 Staging Apply Report (2026-05-07)

## 1. 실행 경계

- Environment: linked Supabase project `globospossystem` (`ynriuoomotxuwhuxxmhj`)
- Mode: staging-only sequential apply
- Rule: single query at a time, no parallel mutation

## 2. 배경

이전 preflight에서 linked temp role 인증이 병렬 query 시 불안정했고, Office wrapper view가 아직 없다는 점을 확인했다.  
이번 실행은 그 상태에서 QSC v2 draft migration을 순차적으로 적용하고 핵심 post-check를 남기기 위한 run이다.

## 3. 적용한 migration

순서:

1. `20260507000007_qsc_v2_check_scope_uniqueness.sql`
2. `20260507000000_qsc_v2_core_additive_columns.sql`
3. `20260507000001_qsc_v2_check_photos.sql`
4. `20260507000002_qsc_v2_monitoring_views.sql`
5. `20260507000003_qsc_v2_rpc_extensions.sql`
6. `20260507000004_qsc_v2_get_qc_checks_extension.sql`
7. `20260507000005_qsc_v2_template_rpc_extension.sql`
8. `20260507000006_qsc_v2_office_read_model_views.sql`

모든 apply command는 성공했다.

## 4. 핵심 post-check

### 4.1 `qc_checks` uniqueness

변경 전:

```text
UNIQUE (template_id, check_date)
```

변경 후 확인:

```text
qc_checks_restaurant_template_check_date_key
UNIQUE (restaurant_id, template_id, check_date)
```

### 4.2 core QSC v2 columns

원격에서 아래 `qc_checks` 컬럼 존재를 확인했다.

- `submission_status`
- `photo_required_count`
- `photo_uploaded_count`
- `grade`
- `sv_review_status`

### 4.3 normalized photo table

원격에서 아래 table 존재를 확인했다.

```text
public.qc_check_photos
```

### 4.4 summary / wrapper views

원격에서 아래 객체 존재를 확인했다.

- `v_qsc_dashboard_summary`
- `v_qsc_store_status`
- `v_qsc_item_status`
- `v_office_qsc_dashboard`
- `v_office_qsc_store_latest`
- `v_office_qsc_issue_queue`

### 4.5 RPC contract

원격에서 아래 함수 시그니처 존재를 확인했다.

- `upsert_qc_check(uuid, uuid, date, text, text, text, uuid, timestamptz, text, integer, integer, numeric, text, text, uuid, timestamptz, numeric, text, uuid)`
- `upsert_qc_check_photo(uuid, uuid, uuid, text, text, text, uuid, timestamptz, boolean, text, boolean)`
- `refresh_qc_check_photo_summary(uuid, boolean)`
- `submit_qc_visit_review(uuid, uuid[], text, numeric, text, uuid, timestamptz, uuid)`
- `get_qc_checks(uuid, date, date)`
- `get_qc_templates(uuid, text)`
- `create_qc_template(text, text, uuid, text, integer, boolean, text, boolean, integer, numeric, text, boolean)`
- `update_qc_template(uuid, jsonb)`

## 5. 관찰 사항

1. linked single-query 방식은 안정적으로 동작했다.
2. 병렬 linked query는 여전히 temp role auth circuit breaker를 유발할 수 있다.
3. 따라서 post-apply smoke와 follow-up query도 순차로 실행해야 한다.

## 6. 아직 남은 검증

이번 run은 DB object apply와 핵심 구조 확인까지다. 아래는 아직 남아 있다.

### 6.1 Flutter manual smoke

- 관리자 템플릿 생성/수정
- 직원 점검 입력
- 멀티사진 업로드
- 관리자 QC 탭 주간/기간 조회
- SV review

### 6.2 Office bridge smoke

- `v_office_qsc_dashboard` 실제 row 조회: PASS
- `v_office_qsc_store_latest` 실제 row 조회: PASS
- `v_office_qsc_issue_queue` 실제 row 조회: PASS (0 rows)
- `v_quality_monitoring` drill-down 조회: PASS

### 6.3 RPC behavior smoke

- legacy `upsert_qc_check` 7-param path
- extended `upsert_qc_check` trailing param path

주의:

이 RPC들은 `auth.uid()`와 POS 사용자/권한 컨텍스트를 전제로 동작한다.  
따라서 DB superuser linked query만으로는 앱 실사용 경로와 같은 의미의 smoke가 아니다.  
이 부분은 Flutter 앱 또는 authenticated PostgREST/RPC 경로에서 검증해야 한다.

## 7. 결론

QSC v2 draft DB layer는 linked staging 기준으로 순차 apply에 성공했다.  
즉, 구조상 초안 수준을 넘어 실제 staging object로 올라간 상태다.

다음 단계는 DB apply가 아니라 앱/bridge 소비 검증이다.
