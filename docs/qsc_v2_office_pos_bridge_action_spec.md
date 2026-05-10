# QSC v2 Office POS Bridge Action Spec

## 1. 목적

이 문서는 Office `pos-bridge`가 QSC v2 read-model을 노출할 때 필요한 action contract를 정의한다.

## 1.1 Ownership decision

`pos-bridge`는 Office repo 소유 구현체다.

- 구현 위치: `~/Documents/restaurant_office_app`의 Office Supabase Edge Function 또는 Office backend bridge layer
- POS repo 책임: QSC read-model view와 action contract 제공
- POS repo 비책임: `supabase/functions/pos-bridge` 중복 구현

따라서 POS repo는 `qsc_dashboard`, `qsc_store_latest`, `qsc_issue_queue`,
`qsc_check_detail`, `qsc_item_status` action 계약과 아래 view contract를
유지한다. Office repo는 이 계약을 소비하는 bridge implementation, Office
권한 scope 강제, request validation, error normalization을 소유한다.

범위:

- Office -> POS read-only bridge action
- request/response shape
- 어떤 POS view를 action별 source로 쓸지 고정

비범위:

- Office Flutter 화면 구현
- Office DB 저장 로직
- POS write mutation

## 2. 공통 규칙

1. 모든 action은 read-only다.
2. source table 직접 join 금지. 지정된 view만 사용한다.
3. `select *` 금지. 명시 컬럼만 사용한다.
4. `brand_id` / `store_id` scope는 Office 권한 기준으로 bridge가 강제한다.
5. `store_id`는 POS `restaurant_id`와 같은 값이다.

## 3. action 목록

### 3.1 `qsc_dashboard`

목적:

- Office 품질 대시보드 KPI 카드
- 최신 문제 매장 요약

source:

- `public.v_office_qsc_dashboard`

request:

```json
{
  "action": "qsc_dashboard",
  "brand_id": "optional-brand-uuid",
  "store_ids": ["optional-store-uuid"],
  "limit": 100
}
```

response row:

```json
{
  "restaurant_id": "uuid",
  "store_id": "uuid",
  "brand_id": "uuid",
  "store_name": "A매장 강남점",
  "latest_check_date": "2026-05-07",
  "total_checks": 120,
  "submitted_checks": 110,
  "pending_checks": 6,
  "overdue_checks": 4,
  "failed_checks": 8,
  "missing_photo_checks": 5,
  "pending_sv_reviews": 3,
  "open_followups": 2,
  "average_score": 88.7,
  "completion_rate": 91.7,
  "store_status": "caution"
}
```

### 3.2 `qsc_store_latest`

목적:

- Office 매장 현황 표
- 문제 매장 리스트

source:

- `public.v_office_qsc_store_latest`

request:

```json
{
  "action": "qsc_store_latest",
  "brand_id": "optional-brand-uuid",
  "store_ids": ["optional-store-uuid"],
  "store_status": ["risk", "caution"],
  "sort_by": "completion_rate",
  "sort_dir": "asc",
  "limit": 100,
  "offset": 0
}
```

### 3.3 `qsc_issue_queue`

목적:

- Office 이슈 큐
- follow-up 생성 전 원본 사실 확인 리스트

source:

- `public.v_office_qsc_issue_queue`

request:

```json
{
  "action": "qsc_issue_queue",
  "brand_id": "optional-brand-uuid",
  "store_ids": ["optional-store-uuid"],
  "severity": ["critical", "high", "medium"],
  "qsc_domain": ["quality", "service", "cleanliness"],
  "submission_status": ["pending", "overdue"],
  "sv_review_status": ["pending", "rejected"],
  "photo_status": ["missing", "partial"],
  "check_date_from": "2026-05-01",
  "check_date_to": "2026-05-07",
  "limit": 100,
  "offset": 0
}
```

### 3.4 `qsc_check_detail`

목적:

- 특정 check row drill-down
- 증거 사진/메모/상태 확인

source:

- `public.v_quality_monitoring`

request:

```json
{
  "action": "qsc_check_detail",
  "check_id": "uuid"
}
```

response row should include:

```json
{
  "check_id": "uuid",
  "store_id": "uuid",
  "brand_id": "uuid",
  "store_name": "A매장 강남점",
  "category": "청결",
  "criteria_text": "주방 바닥 청결 상태",
  "check_date": "2026-05-07",
  "result": "fail",
  "evidence_photo_url": "https://...",
  "note": "바닥 청소 미흡",
  "checked_by": "uuid",
  "created_at": "2026-05-07T09:30:00Z",
  "qsc_domain": "cleanliness",
  "requires_photo": true,
  "required_photo_count": 2,
  "photo_uploaded_count": 1,
  "photo_status": "partial",
  "submission_status": "submitted",
  "submitted_at": "2026-05-07T09:31:00Z",
  "score": 72.5,
  "grade": "risk",
  "sv_review_status": "pending",
  "sv_reviewed_by": null,
  "sv_reviewed_at": null,
  "sv_score": null,
  "improvement_required": true,
  "followup_status": "open",
  "followup_id": "uuid",
  "visit_session_id": "uuid"
}
```

### 3.5 `qsc_item_status`

목적:

- 항목별 weak-point 분석
- 도메인/카테고리 기준 통계

source:

- `public.v_qsc_item_status`

request:

```json
{
  "action": "qsc_item_status",
  "brand_id": "optional-brand-uuid",
  "store_ids": ["optional-store-uuid"],
  "check_date_from": "2026-05-01",
  "check_date_to": "2026-05-07",
  "qsc_domain": ["cleanliness"],
  "limit": 200,
  "offset": 0
}
```

## 4. error contract

bridge는 최소 아래 에러를 구분한다.

- `POS_BRIDGE_SCOPE_REQUIRED`
- `POS_BRIDGE_SCOPE_FORBIDDEN`
- `POS_BRIDGE_ACTION_UNSUPPORTED`
- `POS_BRIDGE_CHECK_ID_REQUIRED`
- `POS_BRIDGE_QUERY_FAILED`

## 5. rollout guidance

1. `qsc_dashboard`
2. `qsc_store_latest`
3. `qsc_issue_queue`
4. `qsc_check_detail`
5. `qsc_item_status`

이 순서로 열면 Office 대시보드/현황/이슈 큐부터 먼저 붙일 수 있다.
