# QSC v2 Office Read Model Contract

## 1. 목적

이 문서는 POS QSC v2 데이터를 Office 시스템이 어떻게 읽어야 하는지에 대한 read-only 계약을 고정한다.

핵심 원칙:

- POS는 현장 실행 source system이다.
- Office는 관제/control system이다.
- Office 앱 코드는 이 문서 기준으로 POS read model을 소비하되, POS source table을 직접 business logic 용도로 재조합하지 않는다.
- 기존 Office coupling을 깨지 않기 위해 `restaurants` 물리 테이블과 `restaurant_id` 물리 FK는 유지한다.

## 2. 비범위

- Office Supabase schema 변경
- Office Flutter 화면 구현
- POS source write contract 재정의

## 3. 권위 있는 POS read entrypoints

Office가 QSC를 읽을 때 사용하는 POS 쪽 entrypoint는 아래로 제한한다.

| 레이어 | 객체 | 목적 |
|---|---|---|
| raw monitoring | `v_quality_monitoring` | item-level 증거/상태 원본 조회 |
| store summary | `v_qsc_dashboard_summary` | 최신일 기준 KPI 카드 / 문제 매장 집계 |
| daily store rollup | `v_qsc_store_status` | 매장 현황 표 / 분포 / 기간 비교 |
| daily item rollup | `v_qsc_item_status` | 항목/카테고리 분석 / weak point 확인 |
| office wrapper | `v_office_qsc_dashboard` | Office 대시보드용 얇은 호환 view |
| office wrapper | `v_office_qsc_store_latest` | Office 매장 현황 최신 snapshot |
| office wrapper | `v_office_qsc_issue_queue` | Office follow-up/이슈 큐 |

## 4. naming contract

### 4.1 physical invariants

- physical source table은 `restaurants` 유지
- physical FK는 `restaurant_id` 유지
- Office hard coupling인 `restaurants.id/name/address/is_active`는 유지

### 4.2 read model aliases

Office 화면과 bridge에서는 `store_id` 표현을 써도 되지만, POS read model은 아래 규칙을 따른다.

- `store_id`는 POS `restaurant_id`와 동일 값이다.
- Office wrapper view는 가능하면 `restaurant_id`와 `store_id`를 동시에 노출한다.
- 기존 `v_quality_monitoring`는 역사적 계약을 존중해 `store_id`를 유지한다.

## 5. object responsibilities

### 5.1 `v_quality_monitoring`

가장 세밀한 item-level snapshot이다.

이 view는 아래 경우에만 Office에서 직접 읽는다.

- 증거 사진/메모 drill-down
- 특정 점검 row 확인
- follow-up 생성 전 원본 사실 확인

Office는 이 view를 대시보드 KPI 계산의 1차 source로 삼지 않는다. KPI는 summary/rollup view를 우선 사용한다.

### 5.2 `v_qsc_dashboard_summary`

최신 점검일 기준 매장 단위 요약이다.

주요 용도:

- 전체 매장 수
- 완료/미완료/위험 매장 count
- 사진 누락/미확인 SV count
- 점검 완료율/평균 점수

### 5.3 `v_qsc_store_status`

일자별 매장 상태 롤업이다.

주요 용도:

- 매장 현황 표
- 상태 분포 차트
- 기간/브랜드 비교
- 문제 매장 필터링

### 5.4 `v_qsc_item_status`

일자별 항목 상태 롤업이다.

주요 용도:

- 항목별 양호율
- 항목별 사진 누락
- SV pending 항목 분석
- 개선 필요 항목 TOP 분석

## 6. Office wrapper contract

Office는 bridge/service 레이어에서 아래 wrapper view를 우선 소비한다.

### 6.1 `v_office_qsc_dashboard`

`v_qsc_dashboard_summary`를 그대로 얇게 감싼 view다.

필수 컬럼:

```text
restaurant_id
store_id
brand_id
store_name
latest_check_date
total_checks
submitted_checks
pending_checks
overdue_checks
failed_checks
missing_photo_checks
pending_sv_reviews
open_followups
average_score
completion_rate
store_status
```

`store_status` 규칙:

- `risk`: overdue/fail/open follow-up 존재
- `caution`: pending/missing photo/pending SV 존재
- `good`: 위 조건 없음
- `no_data`: 최신 점검일 없음

### 6.2 `v_office_qsc_store_latest`

매장별 최신일 snapshot view다.

필수 컬럼:

```text
restaurant_id
store_id
brand_id
store_name
check_date
total_checks
submitted_checks
pending_checks
overdue_checks
pass_checks
fail_checks
na_checks
missing_photo_checks
partial_photo_checks
pending_sv_reviews
active_followups
average_score
average_sv_score
completion_rate
store_status
```

### 6.3 `v_office_qsc_issue_queue`

Office follow-up/이슈 큐용 문제 row 모음이다.

필수 컬럼:

```text
check_id
restaurant_id
store_id
brand_id
store_name
category
qsc_domain
criteria_text
check_date
result
photo_status
submission_status
sv_review_status
followup_status
severity
evidence_photo_url
note
checked_by
created_at
submitted_at
score
grade
```

`severity` 규칙:

- `critical`: overdue 또는 fail + missing photo
- `high`: overdue 또는 fail 또는 rejected SV
- `medium`: pending SV 또는 partial/missing photo
- `low`: pending submission 또는 open/in_progress follow-up

## 7. Office bridge query rules

Office bridge는 아래 규칙을 따른다.

1. 기본 목록/카드는 wrapper view 또는 summary view 우선
2. 증거 drill-down이 필요할 때만 `v_quality_monitoring` item-level row 조회
3. `select *` 대신 명시 컬럼 선택
4. 브랜드/매장 scope 필터는 Office 권한 기준으로 bridge에서 강제
5. POS source table 직접 join을 Office 앱에서 하지 않는다

## 8. backward compatibility

### 8.1 guaranteed

- `v_quality_monitoring` 기존 앞쪽 컬럼 의미 유지
- `restaurants` direct select 계약 유지
- QSC v2 필드는 append-only 또는 wrapper view 추가로 제공

### 8.2 not guaranteed

- Office가 POS source table 내부 구현 세부를 직접 의존하는 것
- `qc_checks`, `qc_templates` 원본 테이블을 Office 앱이 직접 집계하는 것

## 9. rollout recommendation

1. POS에서 `v_quality_monitoring` + `v_qsc_*` 배포
2. POS에서 `v_office_qsc_*` wrapper view 배포
3. Office bridge는 wrapper view 우선 소비
4. 기존 Office 품질 화면은 필요 시 점진적으로 wrapper view로 전환

## 10. decision note

이 계약은 Office 앱 코드를 바로 바꾸자는 문서가 아니다.  
먼저 POS read-model의 안정된 표면을 고정해서, Office가 QSC v2를 읽을 때 source/control 경계가 흔들리지 않게 하는 게 목적이다.
