# QSC v2 기존 QC 확장 계획

## 1. 목적

기존 POS QC v1 흐름을 보존하면서, 새로 설계한 QSC(품질·서비스·청결) 관리 화면과 업무 흐름을 POS와 Office 시스템에 반영한다.

이 문서는 구현 전에 기준을 고정하기 위한 계획 문서다. 새 QSC는 기존 QC를 대체하지 않는다. 기존 `qc_templates`, `qc_checks`, `qc_followups`, `qc-photos`, `v_quality_monitoring`, QC RPC를 기반으로 확장한다.

## 2. 결론

QSC v2는 다음 구조로 추진한다.

```text
POS Flutter
  - 직원 점검 입력
  - 사진 촬영
  - SV 확인/평가
  - 매장 단위 실행

POS Supabase
  - 기존 QC 원천 데이터
  - QSC v2 확장 필드/보조 테이블
  - 사진 Storage
  - Office 연동용 view/RPC

Office pos-bridge
  - Office 사용자 권한 확인
  - POS QSC view read-only 조회
  - brand/store scope 필터링

Office Flutter
  - 본사 품질점검 관제
  - 증거 리뷰
  - 이상 매장 확인
  - issue/follow-up 관리
  - 리포트/대시보드
```

## 3. 기존 기준

### 3.1 POS 기준

POS는 현장 실행 시스템이다.

- 매장 직원이 점검을 입력한다.
- 사진 증거를 업로드한다.
- 매장 관리자 또는 SV가 확인한다.
- 원천 점검 기록은 POS DB에 남는다.

현재 POS QC v1은 다음을 제공한다.

| 영역 | 기존 구현 |
|---|---|
| 점검 항목 | `qc_templates` |
| 점검 기록 | `qc_checks` |
| 사진 증거 | `qc-photos`, `evidence_photo_url` |
| 후속조치 | `qc_followups` |
| 분석 | `get_qc_analytics` |
| Office 조회 | `v_quality_monitoring` |
| Flutter 서비스 | `QcService` |
| 관리자 UI | Admin QC tab |

### 3.2 Office 기준

Office는 본사 관제·통제 시스템이다.

- Office는 현장 점검 입력의 원천 소유자가 아니다.
- Office는 POS에서 올라온 품질 상태를 조회한다.
- Office는 증거 리뷰, 이상 건 확인, follow-up, 리포트를 담당한다.
- Office와 POS는 별도 Supabase 프로젝트다.
- Office는 POS DB에 직접 write하지 않는다.

현재 Office 연동 흐름은 다음 기준을 따른다.

```text
Office Flutter
  -> Office Supabase Edge Function pos-bridge
  -> POS Supabase service role read
  -> v_quality_monitoring
```

Office 자체 control record는 다음 계열을 사용한다.

- `office_qc_issues`
- `office_qc_followups`
- `office_qc_followup_events`
- `ops.quality_checks_view`

## 4. 새 QSC 설계 반영 범위

첨부 설계 기준으로 다음 범위는 모두 반영 대상이다.

### 4.1 PC 관리자

| 화면 | 반영 방향 |
|---|---|
| 대시보드 | 전체 QSC 현황, 미완료, 위험 매장, 사진 등록, 관리자 미방문 요약 |
| 매장 현황 | 매장별 완료율, 사진 등록률, SV 방문, 미등록 항목, 상태 분포 |
| QSC 항목 | Q/S/C 분류, 항목별 양호/주의/위험, 항목 추가·수정·삭제 |
| QSC 점검 | 주간/일간 매트릭스, 사진 썸네일, 담당자, 미등록 표시 |
| 리포트 | 기간별 점수, 항목별 평균, 담당자별 점검, 개선 필요 TOP |
| 알림 | 사진 등록, 미등록, SV 등록, 지연, 개선 알림 |
| 설정 | 촬영 기준 시간, 허용 범위, 점검 기준 |
| 계정관리 | 담당자, 매장, 브랜드, 역할 매핑 |
| 권한관리 | 직원/관리자/SV/마스터 역할별 접근 권한 |

### 4.2 모바일 직원

직원 모바일은 현장 실행 중심이다.

- 오늘 업무
- QSC 점검 입력
- 사진 촬영
- 항목별 결과 입력
- 재고 입력
- 발주 확인
- 알림 확인

모바일 직원 화면은 PC 관리 화면을 축소하지 않는다. 한 화면에 하나의 주요 행동만 둔다.

### 4.3 모바일 SV

SV 모바일은 담당 매장 확인과 평가 중심이다.

- SV 대시보드
- 담당 매장 점검 수행률
- 미진행 매장 확인
- 방문 점검 시작
- 직원 입력 결과 확인
- 사진 증거 확인
- 점수/평가 입력
- 점검 완료 처리

### 4.4 모바일 관리자

모바일 관리자는 전체 기능 복제가 아니라 quick review 중심으로 둔다.

- 문제 매장 리스트
- 매장 상세 요약
- 항목 상세 확인
- 점검 결과 확인
- 긴급 알림 확인

Office 문서 기준상 모바일은 Office의 주 운영면이 아니다. Office 모바일은 빠른 확인과 조치만 지원한다.

## 5. 데이터 모델 확장 원칙

### 5.1 지켜야 할 것

1. POS의 `restaurants` 물리 테이블은 유지한다.
2. POS 기존 `restaurant_id` FK 컬럼은 깨지 않는다.
3. 기존 QC RPC 계약은 호환 유지한다.
4. 기존 Office `pos-bridge` read-only 원칙을 유지한다.
5. Office 로컬 `restaurant_id` 컬럼은 Office DB 내부 convention으로 유지할 수 있다.
6. 새 write path는 SECURITY DEFINER RPC 또는 검증된 서버 경계에서 처리한다.

### 5.2 즉시 만들지 말아야 할 것

다음 방식은 피한다.

- `qsc_*` 신규 테이블 세트로 기존 QC를 우회하는 구조
- Office DB에 POS 점검 원천 데이터를 복제하는 구조
- Office에서 POS QSC 데이터를 직접 write하는 구조
- PC 화면을 그대로 모바일에 축소하는 구조
- 모바일 앱을 별도 제품처럼 분리하는 구조

## 6. Gap 분석

기존 QC v1에 없는 QSC v2 기능은 다음과 같다.

| 기능 | 기존 상태 | 확장 방향 |
|---|---|---|
| 점검 일정 | 미설계 | 점검 계획/기준 시간 추가 |
| 미등록 상태 | 부분 계산 가능 | 명시적 status 또는 view 계산 |
| 사진 여러 장 | 단일 URL 중심 | 사진 보조 테이블 검토 |
| 사진 등록률 | 부족 | uploaded/required count 계산 |
| SV 확인 | 부족 | review 상태/기록 추가 |
| SV 점수/평가 | 없음 | score/grade/review note 추가 |
| 관리자 방문 여부 | 없음 | visit/review metadata 추가 |
| 개선 조치 | 기존 followup 있음 | QSC 개선 상태로 확장 |
| 알림 | 미설계 | notification/read model 추가 |
| 기간 리포트 | 일부 analytics | 브랜드/매장/항목/담당자 집계 확장 |
| 권한 세분화 | 일부 extra permission | QSC 역할별 권한 매트릭스 정리 |

## 7. 권장 데이터 확장안

최종 DDL은 별도 설계/리뷰 후 확정한다. 현재 단계에서는 확장 방향만 고정한다.

### 7.1 `qc_templates` 확장 후보

기존 QSC 항목 관리의 기준 테이블이다.

추가 후보:

- `qsc_domain` — `quality`, `service`, `cleanliness`
- `requires_photo`
- `required_photo_count`
- `default_frequency`
- `is_sv_required`
- `weight`
- `risk_threshold`

### 7.2 `qc_checks` 확장 후보

현장 점검 원천 기록이다.

추가 후보:

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
- `improvement_required`
- `improvement_status`

### 7.3 `qc_check_photos` 신규 후보

기존 `qc_checks.evidence_photo_url` 하나로 다중 사진, 촬영자, SV 사진, 시간 기준 검증을 표현하기 어렵다면 보조 테이블을 둔다.

주요 후보 컬럼:

- `id`
- `restaurant_id`
- `check_id`
- `template_id`
- `photo_url`
- `photo_type` — `staff`, `sv`, `reference`
- `uploaded_by`
- `uploaded_at`
- `taken_at`
- `recognized_status`
- `metadata`

Storage path는 기존 `qc-photos` bucket을 유지하되, `{restaurant_id}/checks/{date}/{check_id}/...` 형태로 정리한다.

### 7.4 `qc_visit_reviews` 신규 후보

SV 방문 확인과 평가를 점검 입력과 분리해야 하면 별도 테이블을 둔다.

주요 후보 컬럼:

- `id`
- `restaurant_id`
- `check_date`
- `reviewed_by`
- `reviewed_at`
- `visit_status`
- `score`
- `grade`
- `review_note`
- `next_action_required`

단순 1차 구현에서는 `qc_checks` 확장 컬럼으로 시작하고, SV 리뷰가 check 묶음 단위로 커지면 테이블을 분리한다.

### 7.5 `qc_notification_events` 신규 후보

일정/미등록/지연/개선 알림은 기존 QC v1에 없다. 알림은 계산 view만으로 충분한지, 이벤트 테이블이 필요한지 검토한다.

주요 후보 컬럼:

- `id`
- `restaurant_id`
- `event_type`
- `source_check_id`
- `source_followup_id`
- `severity`
- `message`
- `created_at`
- `read_at`
- `resolved_at`

## 8. Office 연동 계획

### 8.1 POS view 확장

Office가 QSC v2를 읽을 수 있도록 `v_quality_monitoring` 또는 새 호환 view를 확장한다.

권장 view:

- `v_quality_monitoring` 기존 호환 유지
- `v_qsc_store_status` 신규 후보
- `v_qsc_dashboard_summary` 신규 후보
- `v_qsc_item_status` 신규 후보
- `v_qsc_improvement_status` 신규 후보

기존 Office가 `v_quality_monitoring`에 의존하므로, 기존 컬럼 의미를 깨지 않고 필요한 컬럼만 추가한다.

### 8.2 pos-bridge 확장

Office Edge Function `pos-bridge`는 다음 action을 확장할 수 있다.

- `quality_monitoring` 기존 유지
- `qsc_store_status`
- `qsc_dashboard_summary`
- `qsc_item_status`
- `qsc_improvement_status`

Office 사용자의 brand/store scope 검증은 현재 `resolveAccessScope` 원칙을 따른다.

### 8.3 Office control record

Office에서 발생하는 리뷰/후속조치 상태는 Office DB의 control record로 관리한다.

```text
POS qc_checks
  -> Office office_qc_issues
  -> Office office_qc_followups
  -> Office office_qc_followup_events
```

POS 원천 데이터와 Office control record는 서로 매핑 가능해야 한다. source check id, restaurant id, brand id, check date를 보존한다.

## 9. Flutter 구현 전략

### 9.1 공통화

다음은 공통으로 둔다.

- QSC 모델
- QSC repository/service
- 상태 계산
- 권한 체크
- 사진 업로드 서비스
- 날짜/기간 필터
- status badge
- score/grade 계산
- notification summary 계산

### 9.2 화면 분기

다음만 역할/화면폭에 따라 다르게 둔다.

| 역할/화면 | UX |
|---|---|
| PC 관리자 | 표, 차트, 필터, 대량 관리 |
| 모바일 직원 | 오늘 업무, 사진 촬영, 단계형 점검 |
| 모바일 SV | 담당 매장, 방문 점검, 평가 |
| 모바일 관리자 | 문제 매장, 알림, 요약 확인 |
| Office Web | 본사 관제, 증거 리뷰, follow-up |
| Office Mobile | quick review, 알림, 간단 조치 |

## 10. 구현 단계

### Phase 0. 기준 확정

목표: 기존 QC와 새 QSC 설계의 매핑을 확정한다.

작업:

1. 기존 `qc_templates`, `qc_checks`, `qc_followups`, `v_quality_monitoring` 컬럼 inventory 작성.
2. 첨부 QSC 화면별 데이터 요구사항 작성.
3. 기존으로 가능한 항목과 확장 필요한 항목을 구분.
4. Office 품질점검 화면이 읽어야 하는 최종 view 계약 정의.

완료 기준:

- QSC v2 데이터 계약 초안 확정
- Office read contract 초안 확정
- 모바일/웹 화면별 MVP 범위 확정

### Phase 1. POS DB additive 확장

목표: 기존 QC v1을 깨지 않고 QSC v2 표현력을 추가한다.

작업:

1. 필요한 컬럼을 additive migration으로 추가.
2. 다중 사진이 필요하면 `qc_check_photos` 추가.
3. SV 확인이 묶음 단위로 필요하면 `qc_visit_reviews` 추가.
4. 일정/알림 read model 또는 event table 추가.
5. RLS/RPC 권한 검증을 `user_accessible_stores()` 기준으로 설계.

완료 기준:

- 기존 QC 테스트 통과
- 기존 RPC 호환 유지
- 새 view/RPC smoke query 가능

### Phase 2. POS Flutter QSC 실행 화면

목표: 매장 직원과 SV가 새 QSC 흐름으로 점검을 수행한다.

작업:

1. 직원 오늘 업무 화면.
2. QSC 항목 선택/진행 화면.
3. 사진 촬영/업로드 화면.
4. 항목별 결과 입력.
5. 제출 완료 상태.
6. SV 담당 매장 목록.
7. SV 방문 점검/평가/완료 화면.

완료 기준:

- 직원이 모바일에서 QSC 점검을 제출할 수 있음
- SV가 제출 내용을 확인하고 평가할 수 있음
- 사진 등록/미등록 상태가 정확히 계산됨

### Phase 3. POS PC 관리자 화면

목표: 첨부 PC 화면 수준의 관리자 관제 기능을 제공한다.

작업:

1. QSC 대시보드.
2. 매장 현황.
3. QSC 항목 관리.
4. QSC 점검 매트릭스.
5. 리포트.
6. 알림.
7. 설정.
8. 계정/권한 관리의 QSC 권한 반영.

완료 기준:

- 매장별 상태/미등록/사진/SV 방문 현황 확인 가능
- 항목별 Q/S/C 결과 분포 확인 가능
- 기간 리포트 확인 가능

### Phase 4. Office 품질점검 연동 확장

목표: Office 품질점검에 QSC v2 데이터가 들어오도록 한다.

작업:

1. POS view 확장 또는 신규 view 추가.
2. Office `pos-bridge` action 추가.
3. Office `QualityRepository` read model 확장.
4. Office Quality page에 QSC 현황 반영.
5. `office_qc_issues`/`office_qc_followups`와 POS source check 매핑.
6. Office report/dashboard에 QSC 요약 반영.

완료 기준:

- Office에서 POS QSC 현황 조회 가능
- Office에서 이상 건/미등록/개선 필요 항목 확인 가능
- Office follow-up이 source check와 연결됨

### Phase 5. 알림/리포트/운영 고도화

목표: 운영 자동화와 리포트 품질을 높인다.

작업:

1. 사진 미등록 알림.
2. 점검 지연 알림.
3. SV 미확인 알림.
4. 개선 미완료 알림.
5. 월간/분기/연간 리포트.
6. 엑셀 다운로드.
7. KPI 카드와 TOP 리스트.

완료 기준:

- 운영자가 지연/미등록/개선 필요 상태를 놓치지 않음
- Office와 POS 리포트의 숫자가 같은 기준으로 계산됨

## 11. 권한 기준

QSC 권한은 기존 POS 권한 모델과 ADR-014의 store access 원칙을 따른다.

| 역할 | 권장 권한 |
|---|---|
| 직원 | 자기 매장 점검 입력, 사진 업로드 |
| 매장 관리자 | 자기 매장 항목 관리, 점검 확인, 개선 조치 |
| SV | 담당 매장 확인/평가, 방문 점검 |
| brand_admin | 브랜드 하위 매장 조회/관리 |
| super_admin | 전체 조회/관리 |
| Office quality user | Office 품질 리뷰, issue/follow-up 관리 |
| Office master/admin | 범위 내 매장 관제, 리포트 확인 |

모든 write path는 명시적 `store_id` 또는 `restaurant_id`를 받아 서버에서 접근 가능 매장인지 검증한다.

## 12. 리스크와 대응

| 리스크 | 대응 |
|---|---|
| 기존 QC v1 회귀 | additive migration, 기존 RPC 호환 유지 |
| Office와 POS 숫자 불일치 | POS view를 계산 기준으로 고정 |
| 사진 데이터 복잡도 증가 | `qc_check_photos`로 정규화 |
| 모바일 화면 과다 분리 | 공통 state/repository 유지, layout만 분기 |
| Office가 source data를 수정하는 구조로 변질 | Office는 POS read-only, control record만 Office DB에 저장 |
| `restaurant_id`/`store_id` 혼용 | POS 물리 컬럼은 유지, view/API에서 alias 관리 |
| 알림 과다 생성 | event table 도입 전 read model 계산으로 먼저 검증 |

## 13. 구현 전 확인 필요 사항

- QSC 항목 결과값을 기존 `pass/fail/na`로 유지할지, `good/caution/risk/na`로 확장할지 결정한다.
- 점수/등급 산정 기준을 확정한다.
- SV 확인이 항목 단위인지, 점검 묶음 단위인지 결정한다.
- 사진 필수 개수와 기준 시간 정책을 확정한다.
- 모바일 관리자 화면을 1차 MVP에 포함할지 결정한다.
- Office에서 QSC follow-up 생성이 자동인지 수동인지 결정한다.
- 기존 `qc_followups`와 Office `office_qc_followups`의 책임 경계를 최종 확정한다.

## 14. MVP 권장 범위

1차 MVP는 다음으로 제한한다.

1. 기존 QC 항목 관리 개선.
2. 모바일 직원 점검 입력/사진 촬영.
3. 모바일 SV 확인/평가.
4. PC 관리자 매장 현황/QSC 점검/리포트 기본.
5. Office 품질점검에 POS QSC 현황 반영.
6. 미등록/지연/개선 필요 상태 표시.

1차 MVP에서 제외하거나 후순위로 둔다.

- 고급 자동 점수 보정
- 복잡한 escalation engine
- 모든 PC 화면의 완전한 엑셀/인쇄 기능
- Office 모바일의 전체 관리자 기능
- 별도 QSC 앱 분리

## 15. 참조 문서

- `/Users/andreahn/globos_pos_system/CLAUDE.md`
- `/Users/andreahn/globos_pos_system/docs/ADR-014-Brand-Store-Multi-Access-Model.md`
- `/Users/andreahn/Documents/restaurant-ops-vault/00_HOME/POS_OPERATING_FUNCTION_PHASE_PLAN.md`
- `/Users/andreahn/Documents/restaurant-ops-vault/00_HOME/SYSTEM_MAP.md`
- `/Users/andreahn/Documents/restaurant-ops-vault/00_HOME/SOURCE_VS_CONTROL_MODEL.md`
- `/Users/andreahn/Documents/restaurant-ops-vault/02_DOMAIN/QUALITY.md`
- `/Users/andreahn/Documents/restaurant-ops-vault/05_WORKFLOWS/QUALITY_CHECK_FLOW.md`
- `/Users/andreahn/Documents/restaurant-ops-vault/10_UX_UI/WEB_VS_MOBILE_SCOPE.md`
- `/Users/andreahn/Documents/restaurant_office_app/CLAUDE.md`
- `/Users/andreahn/Documents/restaurant_office_app/docs/office/quality_followups_phase_2_0_schema_gateway.md`
