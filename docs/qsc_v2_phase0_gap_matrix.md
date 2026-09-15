# QSC v2 Phase 0 Gap Matrix

## 1. 목적

이 문서는 QSC v2 구현 전 `현재 QC v1 계약`과 `새 QSC 설계 요구사항`의 차이를 고정하기 위한 Phase 0 산출물이다.

사용 목적:

- DB additive migration 범위 결정
- POS Flutter 화면 재구성 범위 결정
- Office 품질점검 연동 확장 범위 결정
- 기존 호환 계약을 깨지 않는 선 결정

관련 계획 문서:

- [qsc_v2_existing_qc_extension_plan.md](/Users/andreahn/globos_pos_system/docs/qsc_v2_existing_qc_extension_plan.md)

## 2. 현재 계약 인벤토리

### 2.1 POS DB / RPC

현재 확인된 핵심 계약:

| 구분 | 현재 계약 | 비고 |
|---|---|---|
| 기준 항목 | `qc_templates` | 매장별 + global template 공존 |
| 점검 기록 | `qc_checks` | `pass/fail/na`, 단일 `evidence_photo_url` |
| 후속조치 | `qc_followups` | failed check 기준 open/in_progress/resolved |
| 사진 저장 | `qc-photos` bucket | 경로는 store/date/template 중심 |
| 관리자 요약 | `get_qc_superadmin_summary` | 주간 요약 |
| 점검 조회 | `get_qc_checks` | 날짜 범위 조회 |
| 점검 저장 | `upsert_qc_check` | 기존 write anchor |
| 후속조치 생성 | `create_qc_followup` | failed check only |
| 후속조치 변경 | `update_qc_followup_status` | 상태 변경 |
| 분석 | `get_qc_analytics` | total/pass/fail/na/coverage/open_followups |
| Office read view | `v_quality_monitoring` | POS -> Office read model |

### 2.2 POS Flutter

현재 확인된 클라이언트 계약:

| 구분 | 현재 구현 | 비고 |
|---|---|---|
| 서비스 | `QcService` | template/check/followup/analytics/upload |
| 점검 입력 | `lib/features/qc/qc_check_screen.dart` | 오늘 점검 중심 |
| 관리자 화면 | `lib/features/admin/tabs/qc_tab.dart` | 항목 관리, 점검 이력, 후속조치 |
| 권한 | role + `extra_permissions` (`qc_check`) | 직원/관리자 분기 기반 |

### 2.3 Office

현재 확인된 Office 계약:

| 구분 | 현재 계약 | 비고 |
|---|---|---|
| POS read path | `pos-bridge` | read-only, service role 기반 |
| POS 품질 read | `v_quality_monitoring` | brand/store scope 필터링 |
| Office quality read | `ops.quality_checks_view` | Office-side queue |
| Office follow-up | `office_qc_followups` | Office control record |
| Office issue queue | `office_qc_issues` | POS source와 매핑되는 Office record |
| Office repo | `QualityRepository` | Office + POS read model 병행 |

## 3. 새 QSC 요구사항 매핑

### 3.1 PC 관리자

| 요구사항 | 현재 지원 | Gap | 권장 처리 |
|---|---|---|---|
| 대시보드 KPI | 부분 지원 | 미완료, 위험, 미방문, 사진 등록 KPI 부족 | 신규 summary view 또는 `v_quality_monitoring` 확장 |
| 매장 현황 표 | 부분 지원 | 매장별 상태 분포/사진 등록률/SV 방문 필요 | store status view 추가 |
| Q/S/C 항목 분류 | 없음 | `category`만으로 부족 | `qsc_domain` 추가 |
| QSC 점검 주간 매트릭스 | 부분 지원 | 주차/요일 매트릭스 없음 | read model 추가 |
| 사진 등록 현황 | 없음 | 단일 URL만 존재 | photo count 또는 photo table 필요 |
| 관리자 방문 여부 | 없음 | 방문/확인 메타데이터 없음 | review/visit field 추가 |
| 리포트 | 부분 지원 | 항목별 평균/담당자별/기간별 집계 부족 | analytics view 확장 |
| 알림 | 없음 | 미등록/지연/미방문 알림 없음 | notification read model 또는 event table |
| 설정 | 없음 | 기준 시간/허용 범위 정책 없음 | settings table 또는 restaurant settings 확장 |
| 계정/권한 | 부분 지원 | SV/관리자/QSC 역할 매트릭스 부족 | UI + permission contract 정리 |

### 3.2 모바일 직원

| 요구사항 | 현재 지원 | Gap | 권장 처리 |
|---|---|---|---|
| 오늘 업무 | 없음 | 점검 대상/미완료 목록 없음 | task read model 추가 |
| 항목별 순차 입력 | 부분 지원 | 화면 흐름 단순화 필요 | mobile flow 재구성 |
| 사진 여러 장 | 없음 | 단일 증거 URL만 있음 | `qc_check_photos` 검토 |
| 제출 상태 | 부분 지원 | `created_at` 외 명시 상태 부족 | `submitted_at`, `submission_status` 추가 |
| 재고/발주 연계 표시 | 없음 | QSC 화면과 업무 hub 분리 필요 | 앱 수준 홈 화면 설계 |
| 알림 확인 | 없음 | 지연/미등록/공지 읽기 모델 없음 | notifications 설계 |

### 3.3 모바일 SV

| 요구사항 | 현재 지원 | Gap | 권장 처리 |
|---|---|---|---|
| 담당 매장 목록 | 부분 지원 가능 | dedicated SV read model 없음 | SV dashboard query 추가 |
| 미진행 매장 | 없음 | check completion by scope 없음 | store completion summary 필요 |
| 직원 입력 확인 | 부분 지원 | 검토 전용 flow 없음 | mobile SV review flow 추가 |
| 점수/평가 입력 | 없음 | score/grade/review fields 없음 | `qc_checks` 또는 review table 확장 |
| 방문 점검 완료 | 없음 | review 상태 없음 | `sv_review_status`, `sv_reviewed_at` 추가 |

### 3.4 Office 품질점검

| 요구사항 | 현재 지원 | Gap | 권장 처리 |
|---|---|---|---|
| POS QSC 상태 반영 | 부분 지원 | `v_quality_monitoring`가 QSC v2 필드를 다 안 줌 | view 확장 |
| 증거 리뷰 | 부분 지원 | 다중 사진/시간 기준 확인 부족 | photo read contract 확장 |
| 문제 매장 식별 | 부분 지원 | 위험/주의/미방문/미등록 구분 부족 | issue classification 확장 |
| follow-up 관리 | 지원 | QSC v2 상태와 연결 강화 필요 | source/control mapping 강화 |
| 리포트 연동 | 부분 지원 | dashboard/report widget 확장 필요 | Office repo + page 확장 |

## 4. 현재 계약으로 충분한 것

다음은 지금 구조를 유지해도 된다.

1. POS가 점검 원천 데이터를 소유한다.
2. Office는 POS를 read-only로 조회한다.
3. `qc_followups`는 POS 현장 후속조치의 기본 흐름으로 유지할 수 있다.
4. `restaurant_id` 물리 컬럼은 유지한다.
5. RPC write path는 계속 서버 소유로 간다.

## 5. 반드시 확장해야 하는 것

다음은 QSC v2 구현에 사실상 필수다.

1. `qsc_domain`
2. 사진 여러 장 또는 최소 `photo_required_count` / `photo_uploaded_count`
3. `submission_status`
4. SV review 상태와 평가 필드
5. 매장 단위 summary read model
6. 알림/미등록/지연 read model
7. Office에서 읽을 확장 품질 view

## 6. 데이터 모델 후보 우선순위

### 6.1 바로 additive 가능한 컬럼

우선 `qc_templates` / `qc_checks`에 붙여볼 수 있는 필드:

| 테이블 | 필드 후보 | 이유 |
|---|---|---|
| `qc_templates` | `qsc_domain` | Q/S/C 분류 필요 |
| `qc_templates` | `requires_photo` | 사진 필수 여부 |
| `qc_templates` | `required_photo_count` | 사진 등록률 계산 |
| `qc_templates` | `weight` | 점수 계산 준비 |
| `qc_checks` | `submitted_at` | 명시 제출 시각 |
| `qc_checks` | `submission_status` | 미등록/완료/지연 상태 |
| `qc_checks` | `photo_required_count` | 계산 고정 |
| `qc_checks` | `photo_uploaded_count` | 계산 고정 |
| `qc_checks` | `score` | 항목 또는 점검 점수 |
| `qc_checks` | `grade` | 등급 표시 |
| `qc_checks` | `sv_review_status` | SV 확인 여부 |
| `qc_checks` | `sv_reviewed_by` | 확인자 |
| `qc_checks` | `sv_reviewed_at` | 확인 시각 |
| `qc_checks` | `sv_score` | SV 점수 |
| `qc_checks` | `sv_note` | SV 의견 |

### 6.2 분리 테이블 검토가 필요한 것

| 테이블 후보 | 필요 조건 | 판단 기준 |
|---|---|---|
| `qc_check_photos` | 다중 사진, 촬영 메타데이터, staff/SV 구분 필요 | 단일 `evidence_photo_url`로 부족하면 도입 |
| `qc_visit_reviews` | SV 리뷰가 check 묶음 단위면 필요 | 하루/매장 단위 review를 모델링해야 하면 도입 |
| `qc_notification_events` | 알림 읽음/해결 상태를 저장해야 하면 필요 | 단순 계산 view로 부족할 때 도입 |

## 7. 뷰 / Read Model 후보

### 7.1 POS 쪽

권장 후보:

| view | 목적 |
|---|---|
| `v_quality_monitoring` 확장 | Office 호환 유지 |
| `v_qsc_dashboard_summary` | KPI 카드 |
| `v_qsc_store_status` | 매장 현황 |
| `v_qsc_item_status` | 항목별 분포 |
| `v_qsc_due_status` | 미등록/지연/사진 부족 |

### 7.2 Office 쪽

권장 사용 방식:

| Office surface | 소스 |
|---|---|
| Quality page summary | POS `v_quality_monitoring` / `v_qsc_dashboard_summary` |
| Quality table | POS monitoring + Office `ops.quality_checks_view` |
| Issue queue | `office_qc_issues` |
| Follow-up page | `office_qc_followups` |

## 8. 구현 순서 제안

### Step 1

DB 계약 초안 확정.

산출물:

- additive 컬럼 목록
- 신규 테이블 필요 여부 결정
- view 목록

### Step 2

POS read/write 경계 확정.

산출물:

- 수정할 RPC 목록
- 신규 RPC 필요 목록
- 기존 RPC 호환 기준

### Step 3

Flutter 화면 범위 고정.

산출물:

- 직원 모바일 화면 흐름
- SV 모바일 화면 흐름
- 관리자 PC 화면 우선순위

### Step 4

Office 연동 계약 고정.

산출물:

- `pos-bridge` 추가 action 목록
- Office `QualityRepository` 확장 포인트
- source/control record mapping 규칙

## 9. 현재 가장 큰 설계 리스크

1. `pass/fail/na`를 그대로 둘지, `good/caution/risk/na`로 확장할지 미정이다.
2. SV 확인을 `qc_checks` 컬럼으로 끝낼지, 별도 review record로 뺄지 미정이다.
3. 사진 여러 장 요구를 무시하면 첨부 화면 수준을 못 맞춘다.
4. Office와 POS가 서로 다른 수치를 보여줄 위험이 있다.
5. 모바일 관리자 범위를 크게 잡으면 Flutter 작업량이 급격히 늘어난다.

## 10. 다음 구현 입력값

다음 단계에서 바로 결정해야 할 것:

1. 결과 상태 체계
2. 점수/등급 계산식
3. 사진 모델 단일/다중
4. SV 리뷰 단위
5. MVP에서 모바일 관리자 포함 여부
6. Office follow-up 자동 생성 여부
