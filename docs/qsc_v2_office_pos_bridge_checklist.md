# QSC v2 Office POS Bridge Checklist

## 1. 목적

이 문서는 Office `pos-bridge`가 POS QSC v2 read model을 안전하게 소비하기 위한 구현 체크리스트다.

## 1.1 Ownership

`pos-bridge` 구현은 Office repo 소유다.

- Office repo: `~/Documents/restaurant_office_app`
- Office 책임: bridge implementation, Office 권한 scope 강제, action dispatch, error normalization
- POS repo 책임: QSC wrapper/read-model view와 action contract 유지
- POS repo 비책임: `supabase/functions/pos-bridge` 중복 구현

POS 쪽 계약은 [qsc_v2_office_pos_bridge_action_spec.md](/Users/andreahn/globos_pos_system/docs/qsc_v2_office_pos_bridge_action_spec.md)를 따른다.

대상:

- Office bridge/edge function 작성자
- Office backend/service 작성자
- POS 쪽 read-model 계약 검토자

## 2. 선행조건

- POS에 `v_quality_monitoring`, `v_qsc_dashboard_summary`, `v_qsc_store_status`, `v_qsc_item_status`가 배포되어 있어야 한다.
- Office wrapper view를 쓸 경우 `v_office_qsc_dashboard`, `v_office_qsc_store_latest`, `v_office_qsc_issue_queue`가 배포되어 있어야 한다.
- `restaurants` 물리 테이블과 `restaurant_id` 물리 FK는 유지되어야 한다.

## 3. bridge 원칙

1. Office는 POS source table을 직접 join하지 않는다.
2. bridge는 wrapper view 또는 summary view를 우선 읽는다.
3. `select *`를 사용하지 않는다.
4. brand/store scope는 Office 권한 기준으로 bridge에서 강제한다.
5. item-level evidence drill-down만 `v_quality_monitoring`를 직접 읽는다.

## 4. 화면별 추천 query source

| Office 기능 | 추천 source |
|---|---|
| 품질 대시보드 KPI | `v_office_qsc_dashboard` |
| 문제 매장 리스트 | `v_office_qsc_store_latest` |
| 매장 현황 표 | `v_office_qsc_store_latest` |
| 개선 필요 큐 | `v_office_qsc_issue_queue` |
| 증거 사진/메모 drill-down | `v_quality_monitoring` |
| 항목별 weak point 분석 | `v_qsc_item_status` |

## 5. 명시 컬럼 목록

### 5.1 dashboard

```sql
select
  restaurant_id,
  store_id,
  brand_id,
  store_name,
  latest_check_date,
  total_checks,
  submitted_checks,
  pending_checks,
  overdue_checks,
  failed_checks,
  missing_photo_checks,
  pending_sv_reviews,
  open_followups,
  average_score,
  completion_rate,
  store_status
from public.v_office_qsc_dashboard
```

### 5.2 store latest

```sql
select
  restaurant_id,
  store_id,
  brand_id,
  store_name,
  check_date,
  total_checks,
  submitted_checks,
  pending_checks,
  overdue_checks,
  pass_checks,
  fail_checks,
  na_checks,
  missing_photo_checks,
  partial_photo_checks,
  pending_sv_reviews,
  active_followups,
  average_score,
  average_sv_score,
  completion_rate,
  store_status
from public.v_office_qsc_store_latest
```

### 5.3 issue queue

```sql
select
  check_id,
  restaurant_id,
  store_id,
  brand_id,
  store_name,
  category,
  qsc_domain,
  criteria_text,
  check_date,
  result,
  photo_status,
  submission_status,
  sv_review_status,
  followup_status,
  severity,
  evidence_photo_url,
  note,
  checked_by,
  created_at,
  submitted_at,
  score,
  grade
from public.v_office_qsc_issue_queue
```

### 5.4 evidence drill-down

```sql
select
  check_id,
  store_id,
  brand_id,
  store_name,
  category,
  criteria_text,
  check_date,
  result,
  evidence_photo_url,
  note,
  checked_by,
  created_at,
  qsc_domain,
  requires_photo,
  required_photo_count,
  photo_uploaded_count,
  photo_status,
  submission_status,
  submitted_at,
  score,
  grade,
  sv_review_status,
  sv_reviewed_by,
  sv_reviewed_at,
  sv_score,
  improvement_required,
  followup_status,
  followup_id,
  visit_session_id
from public.v_quality_monitoring
where check_id = :check_id
```

## 6. filter contract

bridge는 아래 필터를 우선 지원한다.

- `brand_id`
- `store_id` or `restaurant_id`
- `check_date`
- `store_status`
- `qsc_domain`
- `severity`
- `submission_status`
- `sv_review_status`
- `photo_status`

## 7. pagination/sorting guidance

- 대시보드 KPI는 pagination 불필요
- 문제 매장 리스트는 `store_status`, `completion_rate`, `average_score` 기준 정렬 권장
- issue queue는 `severity`, `check_date desc`, `store_name` 정렬 권장
- evidence drill-down은 pagination 불필요

## 8. safe rollout checklist

- [ ] `restaurants.id/name/address/is_active` 직접 select가 계속 동작한다
- [ ] `v_quality_monitoring`의 기존 앞쪽 컬럼 순서와 의미가 유지된다
- [ ] Office bridge query에 `select *`가 없다
- [ ] bridge가 summary view와 raw monitoring view를 혼용하지 않는다
- [ ] brand/store scope가 bridge 레벨에서 강제된다
- [ ] issue queue는 `severity`와 `photo_status`를 그대로 전달한다
- [ ] Office에서 POS source table 직접 join이 없다

## 9. escalation note

Office에서 POS table을 직접 읽어야 한다는 요구가 나오면, 먼저 wrapper view 또는 summary view로 해결 가능한지 재검토해야 한다.  
이 경계를 무너뜨리면 source/control 분리가 다시 흔들린다.
