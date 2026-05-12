# QSC v2 DB Contract Draft

## 1. 목적

이 문서는 QSC v2 구현을 위한 POS DB 계약 초안이다.

범위:

- 기존 QC v1 스키마를 깨지 않는 additive 확장
- POS source record와 Office control read contract의 분리
- 다음 단계 마이그레이션 분할 기준 제시

비범위:

- 실제 SQL migration 작성
- Flutter 화면 구현
- Office repo 코드 수정

## 2. 현재 기준

현재 QSC 관련 핵심 source contract는 POS DB의 다음 객체다.

| 객체 | 역할 |
|---|---|
| `qc_templates` | 점검 항목 기준표 |
| `qc_checks` | 점검 결과 원천 기록 |
| `qc_followups` | 현장 후속조치 |
| `qc-photos` | 사진 저장 bucket |
| `get_qc_templates` | 항목 조회 |
| `create_qc_template` / `update_qc_template` / `deactivate_qc_template` | 항목 관리 |
| `get_qc_checks` / `upsert_qc_check` | 점검 read/write |
| `create_qc_followup` / `update_qc_followup_status` / `get_qc_followups` | follow-up |
| `get_qc_analytics` | 통계 |
| `v_quality_monitoring` | Office read-only monitoring view |

현재 `v_quality_monitoring`는 다음 컬럼만 제공한다.

```text
check_id
store_id
brand_id
store_name
category
criteria_text
check_date
result
evidence_photo_url
note
checked_by
created_at
```

이 상태로는 새 QSC 설계의 다음 요구사항을 직접 표현할 수 없다.

- Q/S/C 분류
- 사진 등록률
- 제출 상태
- SV 확인/평가
- 미등록/지연
- 점수/등급
- 관리자 방문 여부
- 개선 필요 여부

## 3. 권위 있는 경계

### 3.1 POS source record

POS는 현장 실행 시스템이며, 아래가 source of truth다.

- 점검 항목
- 점검 결과
- 사진 증거
- SV 확인 결과
- 매장 단위 점검 상태

### 3.2 Office control record

Office는 control tower이며, 아래는 Office control record다.

- `office_qc_issues`
- `office_qc_followups`
- `office_qc_followup_events`
- `ops.quality_checks_view`

Office는 POS source record를 수정하지 않는다. Office는 POS source를 read-only로 보고, 리뷰/이슈/후속조치를 자기 DB에 기록한다.

### 3.3 Historical residue rule

POS repo 안에 과거 Office 관련 migration 흔적이 있더라도, 현재 2-DB 구조 기준의 권위 있는 Office contract는 `restaurant_office_app` repo와 Office Supabase에 있다.

따라서 QSC v2 구현에서:

- POS DB 안에 Office control record를 새로 확장하지 않는다.
- POS는 source record와 Office read view만 소유한다.
- Office control workflow는 Office DB에서 확장한다.

## 4. 설계 원칙

1. `restaurants` 물리 테이블 유지.
2. `restaurant_id` 물리 FK 유지.
3. 기존 QC RPC 이름과 핵심 입력 계약 유지.
4. 새 필드는 additive로 추가.
5. write path는 RPC 또는 서버 검증 경계로만 연다.
6. Office 연동은 `v_quality_monitoring` 호환을 깨지 않는다.
7. 상태 계산은 가능한 한 POS DB에서 고정한다.

## 5. 결과 상태 체계 초안

기존 `qc_checks.result`는 `pass/fail/na`다. 이 계약은 유지한다.

새 UI용 상태는 별도 read model 또는 보조 컬럼으로 표현한다.

### 5.1 Source result

| 필드 | 값 |
|---|---|
| `qc_checks.result` | `pass`, `fail`, `na` |

### 5.2 UI presentation status

| 개념 | 값 | source 기준 |
|---|---|---|
| 점검 제출 상태 | `pending`, `submitted`, `overdue` | 일정 + 제출 시각 |
| 사진 상태 | `missing`, `partial`, `complete`, `not_required` | required vs uploaded count |
| SV 확인 상태 | `not_required`, `pending`, `reviewed`, `rejected` | SV review fields |
| 개선 상태 | `none`, `open`, `in_progress`, `resolved` | follow-up / improvement 상태 |
| 표시 등급 | `good`, `caution`, `risk` | 점수/실패/미완료 기준 계산 |

권장 방향:

- `pass/fail/na`는 DB source result로 유지
- `good/caution/risk`는 UI/리포트용 계산 결과로 추가

## 6. 테이블 확장 초안

### 6.1 `qc_templates`

현재 역할:

- 점검 항목 정의

추가 컬럼 초안:

| 컬럼 | 타입 | null | 기본값 | 목적 |
|---|---|---|---|---|
| `qsc_domain` | text | no | none | `quality/service/cleanliness` |
| `requires_photo` | boolean | no | `true` | 사진 필수 여부 |
| `required_photo_count` | integer | no | `1` | 최소 사진 개수 |
| `weight` | numeric(5,2) | no | `1` | 점수 가중치 |
| `sort_group` | text | yes | null | 모바일/PC 그룹핑 |
| `is_sv_required` | boolean | no | `false` | SV review 필요 여부 |

Wave 1 staged exception: `qsc_domain` may remain nullable until category-to-domain mapping is confirmed and historical rows are safely backfilled. After that mapping is fixed, the target contract is non-null with the check constraint below.

제약 초안:

- `qsc_domain in ('quality','service','cleanliness')`
- `required_photo_count >= 0`
- `weight > 0`

비고:

- 기존 `category`는 유지한다.
- `category`는 세부 카테고리, `qsc_domain`은 상위 Q/S/C 축으로 분리한다.

### 6.2 `qc_checks`

현재 역할:

- 한 항목에 대한 날짜별 점검 결과 원천 기록

추가 컬럼 초안:

| 컬럼 | 타입 | null | 기본값 | 목적 |
|---|---|---|---|---|
| `scheduled_at` | timestamptz | yes | null | 예정 시각 |
| `due_at` | timestamptz | yes | null | 마감 시각 |
| `submitted_at` | timestamptz | yes | null | 제출 시각 |
| `submission_status` | text | no | `'submitted'` | `pending/submitted/overdue` |
| `photo_required_count` | integer | no | `0` | 기준 고정 |
| `photo_uploaded_count` | integer | no | `0` | 현재 업로드 수 |
| `score` | numeric(5,2) | yes | null | source 점수 |
| `grade` | text | yes | null | 계산 등급 |
| `sv_review_status` | text | no | `'not_required'` | SV review 상태 |
| `sv_reviewed_by` | uuid | yes | null | SV reviewer |
| `sv_reviewed_at` | timestamptz | yes | null | SV review 시각 |
| `sv_score` | numeric(5,2) | yes | null | SV score |
| `sv_note` | text | yes | null | SV note |
| `visit_session_id` | uuid | yes | null | visit grouping key |

제약 초안:

- `submission_status in ('pending','submitted','overdue')`
- `photo_required_count >= 0`
- `photo_uploaded_count >= 0`
- `sv_review_status in ('not_required','pending','reviewed','rejected')`
- `grade in ('good','caution','risk')` or null

비고:

- `created_at`는 row 생성 시각이고, `submitted_at`는 업무 제출 시각이다.
- 기존 `evidence_photo_url`는 호환용으로 유지한다.
- 새 다중 사진 모델 도입 전까지 대표 사진 URL로 계속 쓸 수 있다.

### 6.3 `qc_check_photos` 신규 초안

도입 목적:

- 다중 사진
- 촬영자 구분
- 촬영 시각 추적
- 대표 사진과 썸네일 계산

컬럼 초안:

| 컬럼 | 타입 | null | 기본값 | 목적 |
|---|---|---|---|---|
| `id` | uuid | no | `gen_random_uuid()` | PK |
| `restaurant_id` | uuid | no | none | tenant scope |
| `check_id` | uuid | no | none | `qc_checks.id` FK |
| `template_id` | uuid | no | none | 조회 편의 |
| `photo_url` | text | no | none | signed/public path |
| `storage_path` | text | no | none | storage object path |
| `photo_role` | text | no | `'staff'` | `staff/sv/reference` |
| `uploaded_by` | uuid | yes | null | actor |
| `uploaded_at` | timestamptz | no | `now()` | 업로드 시각 |
| `taken_at` | timestamptz | yes | null | 촬영 시각 |
| `is_primary` | boolean | no | `false` | 대표 사진 |
| `caption` | text | yes | null | 설명 |

제약 초안:

- `photo_role in ('staff','sv','reference')`
- `unique(check_id, storage_path)`

도입 판단:

- 첨부 설계 수준을 맞추려면 사실상 필요하다.
- 단일 `evidence_photo_url`만으로 사진 등록률, SV 확인 사진, 다중 썸네일 구성이 어렵다.

### 6.4 `qc_visit_reviews` 신규 초안

도입 목적:

- SV 방문 단위를 check row와 분리
- 하루/매장 기준 review 묶음 관리
- 모바일 SV 완료 흐름 표현

컬럼 초안:

| 컬럼 | 타입 | null | 기본값 | 목적 |
|---|---|---|---|---|
| `id` | uuid | no | `gen_random_uuid()` | PK |
| `restaurant_id` | uuid | no | none | tenant scope |
| `review_date` | date | no | none | 방문 기준일 |
| `reviewed_by` | uuid | no | none | SV actor |
| `reviewed_at` | timestamptz | no | `now()` | 완료 시각 |
| `status` | text | no | `'reviewed'` | 상태 |
| `score` | numeric(5,2) | yes | null | 묶음 점수 |
| `grade` | text | yes | null | 묶음 등급 |
| `note` | text | yes | null | 종합 의견 |

제약 초안:

- `status in ('reviewed','rejected')`

도입 판단:

- SV review가 항목별로 끝나면 `qc_checks` 컬럼만으로 시작 가능하다.
- 매장 단위 방문 완료 개념이 필요하면 분리하는 편이 낫다.

초안 결론:

- Phase 1에서는 optional.
- 우선 `qc_checks`에 review 컬럼을 추가하고, 묶음 review 요구가 확정되면 Phase 2에서 테이블 추가.

### 6.5 `qc_notification_events` 신규 초안

도입 목적:

- 읽음 상태 저장
- 반복 알림 dedupe
- 지연/미방문/미등록 이벤트 추적

컬럼 초안:

| 컬럼 | 타입 | null | 기본값 | 목적 |
|---|---|---|---|---|
| `id` | uuid | no | `gen_random_uuid()` | PK |
| `restaurant_id` | uuid | no | none | tenant scope |
| `event_type` | text | no | none | 이벤트 종류 |
| `source_check_id` | uuid | yes | null | check linkage |
| `source_followup_id` | uuid | yes | null | follow-up linkage |
| `severity` | text | no | `'info'` | `info/warn/critical` |
| `message` | text | no | none | 표시 메시지 |
| `created_at` | timestamptz | no | `now()` | 생성 시각 |
| `read_at` | timestamptz | yes | null | 읽음 |
| `resolved_at` | timestamptz | yes | null | 해소 |

제약 초안:

- `event_type in ('check_due','check_overdue','photo_missing','sv_pending','improvement_open')`
- `severity in ('info','warn','critical')`

초안 결론:

- Phase 1에서는 계산 view 우선.
- 읽음/해결 상태가 필요해지면 테이블 추가.

## 7. View Contract 초안

### 7.1 `v_quality_monitoring`

원칙:

- 기존 Office 계약 유지
- 기존 컬럼 의미 유지
- 컬럼 추가만 허용

기존 유지 컬럼:

```text
check_id
store_id
brand_id
store_name
category
criteria_text
check_date
result
evidence_photo_url
note
checked_by
created_at
```

추가 컬럼 초안:

```text
qsc_domain
requires_photo
required_photo_count
photo_uploaded_count
photo_status
submission_status
submitted_at
score
grade
sv_review_status
sv_reviewed_by
sv_reviewed_at
sv_score
improvement_required
followup_status
followup_id
visit_session_id
```

파생 규칙 초안:

- `photo_status`
  - `not_required`
  - `missing`
  - `partial`
  - `complete`
- `improvement_required`
  - `result = 'fail'`
  - or `sv_review_status = 'rejected'`
  - or `grade = 'risk'`

### 7.2 신규 summary view 초안

#### `v_qsc_dashboard_summary`

용도:

- 관리자 대시보드 KPI

권장 컬럼:

```text
brand_id
store_id
store_name
period_start
period_end
total_items
submitted_items
pending_items
overdue_items
photo_required_total
photo_uploaded_total
photo_completion_rate
sv_pending_count
sv_reviewed_count
risk_count
caution_count
good_count
open_followup_count
average_score
```

#### `v_qsc_store_status`

용도:

- 매장 현황 표

권장 컬럼:

```text
store_id
brand_id
store_name
period_start
period_end
completion_rate
photo_completion_rate
sv_review_rate
open_followup_count
risk_count
caution_count
good_count
last_submitted_at
last_sv_reviewed_at
status_bucket
```

#### `v_qsc_item_status`

용도:

- QSC 항목 화면과 리포트

권장 컬럼:

```text
template_id
qsc_domain
category
criteria_text
store_count
pass_count
fail_count
na_count
good_count
caution_count
risk_count
photo_missing_count
average_score
```

#### `v_qsc_due_status`

용도:

- 미등록/지연/사진 부족 알림

권장 컬럼:

```text
store_id
template_id
check_id
due_at
submission_status
photo_status
sv_review_status
age_minutes
severity
```

## 8. RPC Contract 초안

### 8.1 기존 RPC 유지

그대로 유지:

- `get_qc_templates`
- `create_qc_template`
- `update_qc_template`
- `deactivate_qc_template`
- `get_qc_checks`
- `upsert_qc_check`
- `create_qc_followup`
- `update_qc_followup_status`
- `get_qc_followups`
- `get_qc_analytics`

### 8.2 기존 RPC 확장 포인트

#### `upsert_qc_check`

확장 후보 입력:

```text
p_submitted_at
p_submission_status
p_photo_required_count
p_photo_uploaded_count
p_score
p_grade
p_sv_review_status
p_sv_reviewed_by
p_sv_reviewed_at
p_sv_score
p_sv_note
```

원칙:

- 기존 호출자는 깨지지 않도록 nullable/default 처리
- 모바일 직원과 SV 플로우는 같은 RPC를 공유할지, review 전용 RPC를 분리할지 별도 결정

### 8.3 신규 RPC 후보

#### `upsert_qc_check_photo(...)`

용도:

- 다중 사진 등록
- 대표 사진 지정
- `photo_uploaded_count` 갱신

#### `submit_qc_visit_review(...)`

용도:

- SV review 상태 반영
- 점수/의견 저장
- 필요 시 `qc_visit_reviews` 생성

#### `get_qsc_dashboard_summary(...)`

용도:

- 관리자 대시보드 요약

#### `get_qsc_store_status(...)`

용도:

- 매장 현황 표

#### `get_qsc_due_status(...)`

용도:

- 미등록/지연/미확인 상태 조회

초안 결론:

- Phase 1에서는 read-heavy summary RPC보다 view를 우선 고려한다.
- write는 RPC로 간다.

## 9. Storage Contract 초안

현재 상태:

- `qc-photos` bucket 사용
- scoped policy 존재

권장 경로:

```text
{restaurant_id}/checks/{check_date}/{check_id}/{photo_id}.jpg
{restaurant_id}/templates/{template_id}/reference/{photo_id}.jpg
```

이전 경로 호환:

- 기존 `storeId/checks/date/templateId.jpg` 경로는 읽기 호환 유지 가능
- 신규 업로드부터 새 경로를 쓰는 migration-less 전략 가능

원칙:

- signed URL은 계속 application layer에서 생성
- DB에는 `storage_path`와 대표 `photo_url`을 함께 둘 수 있음

## 10. 권장 Phase 1 범위

### 포함

1. `qc_templates` additive columns
2. `qc_checks` additive columns
3. `qc_check_photos` 신규 테이블
4. `v_quality_monitoring` 컬럼 확장
5. `v_qsc_dashboard_summary`
6. `v_qsc_store_status`

### 제외

1. `qc_visit_reviews`
2. `qc_notification_events`
3. Office-side table 변경
4. deep escalation workflow

## 11. 열어둬야 하는 결정

1. `grade`를 DB에 저장할지, view에서만 계산할지
2. `sv_score`와 `score`를 분리할지 단일화할지
3. `submission_status`를 row에 저장할지 동적 계산할지
4. `qc_followups`와 Office `office_qc_followups`의 자동 연결 시점
5. `qsc_domain` enum vs text

권장 방향:

- 초기에는 text + CHECK
- 나중에 enum 전환 가능

## 12. 다음 작업 입력

이 문서를 기준으로 다음 단계에서 해야 할 일:

1. migration 분할안 작성
2. view 컬럼 목록 확정
3. `qc_check_photos` 도입 여부 최종 확정
4. `upsert_qc_check` 확장안 확정
5. POS Flutter 화면별 필요한 read/write 목록 작성
