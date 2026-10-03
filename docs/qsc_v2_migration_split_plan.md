# QSC v2 Migration Split Plan

## 1. 목적

이 문서는 QSC v2 DB 계약 초안을 실제 migration 작업 단위로 나누기 위한 분할 계획이다.

목표:

- 기존 QC v1 계약을 깨지 않는다.
- Office read contract 호환을 유지한다.
- 위험도가 높은 변경을 작은 묶음으로 분리한다.
- 각 단계마다 검증 포인트를 명확히 둔다.

관련 문서:

- [qsc_v2_existing_qc_extension_plan.md](/Users/andreahn/globos_pos_system/docs/qsc_v2_existing_qc_extension_plan.md)
- [qsc_v2_phase0_gap_matrix.md](/Users/andreahn/globos_pos_system/docs/qsc_v2_phase0_gap_matrix.md)
- [qsc_v2_db_contract_draft.md](/Users/andreahn/globos_pos_system/docs/qsc_v2_db_contract_draft.md)

## 2. 분할 원칙

1. 기존 `qc_templates`, `qc_checks`, `qc_followups`, `v_quality_monitoring`, QC RPC는 즉시 삭제하거나 rename하지 않는다.
2. additive column과 신규 table을 먼저 넣고, read model을 확장한 뒤 Flutter write path를 붙인다.
3. Office가 읽는 `v_quality_monitoring`는 기존 컬럼 의미를 유지하고 컬럼만 추가한다.
4. storage path 변경은 DB migration과 분리한다.
5. 신규 write RPC는 기존 `upsert_qc_check`와 역할이 겹치면 nullable 확장부터 검토한다.

## 3. 권장 실행 순서

```text
Wave 1  schema additive
Wave 2  photo model
Wave 3  read model views
Wave 4  RPC contract extension
Wave 5  due/alert read model
Wave 6  optional visit review model
```

## 4. Wave 1 — Core Additive Columns

### 목표

기존 QC 스키마에 QSC v2 표현력의 핵심 컬럼을 추가한다.

### migration 범위

권장 파일명 예시:

`20260507xxxxxx_qsc_v2_core_additive_columns.sql`

### 변경 대상

#### `qc_templates`

추가:

- `qsc_domain`
- `requires_photo`
- `required_photo_count`
- `weight`
- `sort_group`
- `is_sv_required`

제약:

- `qsc_domain` CHECK
- `required_photo_count >= 0`
- `weight > 0`

#### `qc_checks`

추가:

- `scheduled_at`
- `due_at`
- `submitted_at`
- `submission_status`
- `photo_required_count`
- `photo_uploaded_count`
- `score`
- `grade`
- `sv_review_status`
- `sv_reviewed_by`
- `sv_reviewed_at`
- `sv_score`
- `sv_note`
- `visit_session_id`

제약:

- `submission_status` CHECK
- `photo_*_count >= 0`
- `sv_review_status` CHECK
- `grade` CHECK or null

### 의도적으로 하지 않는 것

- 기존 `result` enum/text 변경
- 기존 `evidence_photo_url` 제거
- 기존 RPC 시그니처 변경

### 검증 포인트

1. 기존 `get_qc_templates`, `get_qc_checks`, `get_qc_analytics` 호출이 깨지지 않아야 한다.
2. 기존 admin QC tab이 migration 후에도 읽혀야 한다.
3. null/default 덕분에 historical row가 모두 유효해야 한다.

## 5. Wave 2 — Photo Model Introduction

### 목표

다중 사진 모델을 추가한다.

### migration 범위

권장 파일명 예시:

`20260507xxxxxx_qsc_v2_check_photos.sql`

### 변경 대상

신규 테이블:

- `qc_check_photos`

필수 인덱스:

- `(check_id, uploaded_at desc)`
- `(restaurant_id, check_id)`
- `(template_id, uploaded_at desc)`
- unique `(check_id, storage_path)`

RLS 방향:

- `restaurant_id = get_user_store_id()` fallback 또는 current multi-access helper 기반
- super_admin 허용

### 의도적으로 하지 않는 것

- 기존 storage bucket rename
- 기존 `evidence_photo_url` 역마이그레이션
- image metadata extraction 자동화

### 검증 포인트

1. 신규 테이블만 추가되고 기존 점검 입력은 계속 가능해야 한다.
2. storage policy와 경로 규칙이 기존 bucket과 충돌하지 않아야 한다.
3. `photo_uploaded_count`를 나중 RPC 또는 trigger 없이도 초기에는 수동/앱 갱신 가능하게 열어둔다.

## 6. Wave 3 — Monitoring View Expansion

### 목표

Office와 관리자 화면이 읽을 QSC v2 read model을 만든다.

### migration 범위

권장 파일명 예시:

`20260507xxxxxx_qsc_v2_monitoring_views.sql`

### 변경 대상

#### `v_quality_monitoring`

기존 컬럼 유지 + 추가:

- `qsc_domain`
- `requires_photo`
- `required_photo_count`
- `photo_uploaded_count`
- `photo_status`
- `submission_status`
- `submitted_at`
- `score`
- `grade`
- `sv_review_status`
- `sv_reviewed_by`
- `sv_reviewed_at`
- `sv_score`
- `improvement_required`
- `followup_status`
- `followup_id`
- `visit_session_id`

#### 신규 view

- `v_qsc_dashboard_summary`
- `v_qsc_store_status`
- `v_qsc_item_status`

### 의도적으로 하지 않는 것

- Office repo 수정
- `pos-bridge` 수정
- notification event table 추가

### 검증 포인트

1. 기존 Office `quality_monitoring` read가 깨지지 않아야 한다.
2. 기존 `select * from v_quality_monitoring` 기반 consumer가 추가 컬럼을 무시해도 안전해야 한다.
3. summary view는 direct store only 기준을 계속 지켜야 한다.

## 7. Wave 4 — RPC Contract Extension

### 목표

QSC v2 입력값을 server-owned write path로 수용한다.

### migration 범위

권장 파일명 예시:

`20260507xxxxxx_qsc_v2_rpc_extensions.sql`

### 변경 대상

우선 확장 후보:

- `upsert_qc_check`
- 필요 시 신규 `upsert_qc_check_photo`
- 필요 시 신규 `submit_qc_visit_review`

### 권장 방식

#### `upsert_qc_check`

nullable/default param 추가:

- `p_submitted_at`
- `p_submission_status`
- `p_photo_required_count`
- `p_photo_uploaded_count`
- `p_score`
- `p_grade`
- `p_sv_review_status`
- `p_sv_reviewed_by`
- `p_sv_reviewed_at`
- `p_sv_score`
- `p_sv_note`

#### `upsert_qc_check_photo`

신규 RPC가 더 깔끔한 경우:

- photo row insert
- primary flag 조정
- optional `qc_checks.evidence_photo_url` 대표값 동기화

### 의도적으로 하지 않는 것

- 기존 RPC 이름 변경
- 기존 파라미터 삭제
- Office 전용 RPC 추가

### 검증 포인트

1. 기존 `QcService.upsertCheck()` 호출이 그대로 성공해야 한다.
2. 새 파라미터를 넣지 않은 old client도 동작해야 한다.
3. audit log가 기존 패턴을 유지해야 한다.

## 8. Wave 5 — Due Status And Alert Read Models

### 목표

미등록, 지연, 사진 부족, SV 미확인을 계산하는 read model을 만든다.

### migration 범위

권장 파일명 예시:

`20260507xxxxxx_qsc_v2_due_status_views.sql`

### 변경 대상

신규 view:

- `v_qsc_due_status`

선택적 신규 table:

- `qc_notification_events`는 이 wave에서는 보류

### 권장 계산 규칙

- `pending`: due 전, submitted_at 없음
- `overdue`: due 경과, submitted_at 없음
- `photo_missing`: requires_photo true and uploaded_count = 0
- `photo_partial`: uploaded_count < required_count
- `sv_pending`: is_sv_required true and `sv_review_status = 'pending'`

### 의도적으로 하지 않는 것

- push/alarm delivery logic
- 읽음 상태 저장

### 검증 포인트

1. 계산 view만으로 관리자 알림 리스트를 렌더링할 수 있어야 한다.
2. 실제 persisted 알림이 없어도 1차 운영이 가능해야 한다.

## 9. Wave 6 — Optional Visit Review Model

### 목표

SV review가 item row 수준으로 부족할 때 묶음 review 모델을 추가한다.

### migration 범위

권장 파일명 예시:

`20260507xxxxxx_qsc_v2_visit_reviews.sql`

### 변경 대상

신규 테이블:

- `qc_visit_reviews`

신규 view 선택:

- `v_qsc_sv_review_status`

### 이 wave를 뒤로 미루는 이유

1. 현재 요구사항은 `qc_checks` 확장만으로도 일부 대응 가능하다.
2. SV review가 항목 단위인지 방문 단위인지 최종 결정이 아직 없다.
3. 조기 도입하면 Flutter write flow가 불필요하게 복잡해질 수 있다.

## 10. 권장 실제 구현 묶음

### Batch A

- Wave 1
- Wave 3

이유:

- 컬럼 추가 후 바로 read model을 만들면 Flutter와 Office 모두 새로운 상태를 읽을 수 있다.

### Batch B

- Wave 2
- Wave 4

이유:

- 사진 구조와 write 확장을 함께 넣어야 모바일 직원/SV 플로우를 붙이기 쉽다.

### Batch C

- Wave 5
- optional Wave 6

이유:

- 알림과 SV 묶음 review는 운영 데이터가 조금 보여야 설계가 덜 흔들린다.

## 11. 마이그레이션별 리스크

| wave | 주요 리스크 | 대응 |
|---|---|---|
| 1 | 기존 row default 누락 | `NOT NULL + DEFAULT` 조합으로 추가 |
| 2 | 사진 모델 중복 source | 대표 사진 유지 규칙 명확화 |
| 3 | Office read break | 기존 `v_quality_monitoring` 컬럼 유지 |
| 4 | old client break | nullable param, backward compatible rpc |
| 5 | 알림 과잉 계산 | persisted event 없이 view 우선 |
| 6 | review 모델 과설계 | optional wave로 분리 |

## 12. 각 wave 완료 기준

### Wave 1 완료 기준

- migration apply 성공
- 기존 QC 탭 read 정상
- 기존 RPC smoke pass

### Wave 2 완료 기준

- `qc_check_photos` insert/select 가능
- storage path 규칙 정리 완료
- 기존 대표 사진 계약 유지

### Wave 3 완료 기준

- `v_quality_monitoring` 확장 컬럼 조회 가능
- `v_qsc_dashboard_summary`, `v_qsc_store_status`, `v_qsc_item_status` 조회 가능
- Office read compatibility 확인

### Wave 4 완료 기준

- old `upsert_qc_check` call pass
- new extended call pass
- optional photo/review rpc pass

### Wave 5 완료 기준

- `v_qsc_due_status`에서 pending/overdue/photo/sv 상태 조회 가능

### Wave 6 완료 기준

- SV review를 check 묶음 단위로 저장/조회 가능

## 13. 다음 작업

이 문서 다음 단계는 실제 SQL 초안이다.

순서:

1. Wave 1 SQL 초안 작성
2. Wave 3 view SQL 초안 작성
3. `QcService` 확장 포인트 정의
4. Office `pos-bridge` 추가 action 설계

