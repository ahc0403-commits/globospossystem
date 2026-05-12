# QSC v2 Flutter Write Integration Plan

## 1. 목적

이 문서는 QSC v2 DB/RPC 초안을 현재 POS Flutter 클라이언트에 어떻게 연결할지 정리하는 구현 기준서다.

범위:

- `QcService` 확장 방향
- `qc_provider.dart` write flow 변경 방향
- 직원 모바일 / 관리자 PC / SV 모바일 write payload 기준
- 기존 QC v1 화면을 깨지 않는 점진적 확장 순서

비범위:

- 실제 Flutter 코드 수정
- 실제 SQL migration 적용
- Office repo 구현

관련 문서:

- [qsc_v2_existing_qc_extension_plan.md](/Users/andreahn/globos_pos_system/docs/qsc_v2_existing_qc_extension_plan.md)
- [qsc_v2_phase0_gap_matrix.md](/Users/andreahn/globos_pos_system/docs/qsc_v2_phase0_gap_matrix.md)
- [qsc_v2_db_contract_draft.md](/Users/andreahn/globos_pos_system/docs/qsc_v2_db_contract_draft.md)
- [qsc_v2_migration_split_plan.md](/Users/andreahn/globos_pos_system/docs/qsc_v2_migration_split_plan.md)
- [20260507000003_qsc_v2_rpc_extensions.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260507000003_qsc_v2_rpc_extensions.sql)

---

## 2. 현재 Flutter write 흐름

현재 POS Flutter의 핵심 write 흐름은 아래와 같다.

### 2.1 직원 점검 입력

현재 위치:

- [qc_check_screen.dart](/Users/andreahn/globos_pos_system/lib/features/qc/qc_check_screen.dart)
- [qc_provider.dart](/Users/andreahn/globos_pos_system/lib/features/qc/qc_provider.dart)
- [qc_service.dart](/Users/andreahn/globos_pos_system/lib/core/services/qc_service.dart)

현재 실행 순서:

```text
사용자 입력
-> ImagePicker로 단일 사진 선택
-> uploadQcPhoto()
-> signed URL 획득
-> upsertCheck()
-> upsert_qc_check RPC
-> qc_checks.evidence_photo_url 저장
```

### 2.2 관리자 QC 화면

현재 위치:

- [qc_tab.dart](/Users/andreahn/globos_pos_system/lib/features/admin/tabs/qc_tab.dart)

현재 범위:

- 템플릿 관리
- 주간 점검 현황 조회
- follow-up 관리

현재는 QSC v2의 다음 쓰기 기능이 없다.

- 다중 사진
- 제출 상태 제어
- SV 확인/평가
- 방문 세션
- 사진 개수 기반 검증

---

## 3. 유지해야 하는 클라이언트 불변조건

1. 기존 `QcService.upsertCheck()`를 호출하는 화면은 당장 깨지면 안 된다.
2. 기존 `QcCheckNotifier.submitCheck()`는 최소 수정으로 유지하는 것이 좋다.
3. 기존 단일 `evidence_photo_url` consumer는 대표 사진 URL이 계속 들어와야 한다.
4. 기존 admin QC tab은 read 중심이므로, write 모델 변경보다 read 확장 이후에 점진적으로 손댄다.

---

## 4. 권장 클라이언트 구조 변화

### 4.1 `QcService` 확장 원칙

현재 `QcService`는 QC v1의 thin RPC wrapper다. QSC v2에서는 다음 세 레벨로 나누는 것이 좋다.

```text
Level 1  legacy-compatible methods
- fetchTemplates
- fetchChecks
- upsertCheck

Level 2  QSC v2 write helpers
- upsertCheckV2
- upsertCheckPhoto
- submitVisitReview

Level 3  read-model helpers
- fetchQscDashboardSummary
- fetchQscStoreStatus
- fetchQscItemStatus
```

권장 이유:

- 기존 화면은 `upsertCheck`를 그대로 쓸 수 있다.
- 새 화면은 `upsertCheckV2`부터 사용하면 된다.
- read model helper를 분리하면 admin/mobile SV 화면이 `fetchChecks()`를 억지로 재활용하지 않아도 된다.

### 4.2 `QcCheckNotifier` 확장 원칙

현재 notifier는 “단일 사진 + 단일 결과 저장”에 맞춰져 있다.

QSC v2에서는 역할별로 notifier를 분리하는 편이 안전하다.

권장 구조:

```text
QcCheckNotifier          기존 직원 점검 호환
QscTaskNotifier          오늘 업무 / 제출 상태 / 미완료
QscVisitReviewNotifier   SV 확인/평가
QscAdminStatusNotifier   관리자 현황/필터/요약
```

완전 분리 전까지는 1차로 아래만 해도 된다.

- `QcCheckNotifier.submitCheck()` 유지
- `submitCheckV2()` 추가
- `submitVisitReview()` 추가

---

## 5. 서비스 메서드 설계 기준

### 5.1 유지: `upsertCheck()`

현재 시그니처:

```dart
Future<void> upsertCheck({
  required String storeId,
  required String templateId,
  required String checkDate,
  required String result,
  String? evidencePhotoUrl,
  String? note,
  String? checkedBy,
})
```

처리 방침:

- 이 메서드는 유지한다.
- 내부 RPC 호출은 확장된 `upsert_qc_check`를 그대로 사용해도 된다.
- 새 trailing params는 보내지 않는다.

효과:

- 기존 직원 입력 화면은 변경 없이 유지 가능
- migration 적용 후에도 QC v1 동작 보존

### 5.2 추가: `upsertCheckV2()`

권장 시그니처:

```dart
Future<void> upsertCheckV2({
  required String storeId,
  required String templateId,
  required String checkDate,
  required String result,
  String? evidencePhotoUrl,
  String? note,
  String? checkedBy,
  DateTime? submittedAt,
  String? submissionStatus,
  int? photoRequiredCount,
  int? photoUploadedCount,
  double? score,
  String? grade,
  String? svReviewStatus,
  String? svReviewedBy,
  DateTime? svReviewedAt,
  double? svScore,
  String? svNote,
  String? visitSessionId,
})
```

용도:

- 모바일 직원 제출
- 관리자 수정 저장
- SV 리뷰 전 상태 저장

주의:

- `result`는 계속 `pass/fail/na`
- `grade`는 `good/caution/risk`
- `submissionStatus`는 `pending/submitted/overdue`

### 5.3 추가: `upsertCheckPhoto()`

권장 시그니처:

```dart
Future<Map<String, dynamic>> upsertCheckPhoto({
  required String storeId,
  required String checkId,
  required String templateId,
  required File file,
  required String photoRole,
  bool isPrimary = false,
  DateTime? takenAt,
  String? caption,
  bool syncLegacyPhoto = true,
})
```

내부 처리:

```text
1. storage path 생성
2. qc-photos bucket 업로드
3. signed URL 생성
4. upsert_qc_check_photo RPC 호출
5. RPC가 qc_checks.photo_uploaded_count / evidence_photo_url 동기화
```

`photoRole` 기준:

- `staff`
- `sv`
- `reference`

### 5.4 추가: `submitVisitReview()`

권장 시그니처:

```dart
Future<void> submitVisitReview({
  required String storeId,
  required List<String> checkIds,
  required String svReviewStatus,
  double? svScore,
  String? svNote,
  String? visitSessionId,
  DateTime? reviewedAt,
  String? reviewedBy,
})
```

용도:

- 모바일 SV 점검 완료
- 관리자 방문 리뷰

---

## 6. 화면별 payload 기준

### 6.1 직원 모바일

1차 구현 기준:

```text
오늘 업무 로드
-> 항목 선택
-> 결과 pass/fail/na
-> 사진 1장 이상 첨부 가능
-> note 입력
-> submitted 상태로 저장
```

권장 payload:

```text
result
note
submitted_at
submission_status = submitted
photo_required_count
photo_uploaded_count
```

직원 화면에서는 아직 `score`, `grade`, `sv_*`를 직접 편집하지 않는다.

### 6.2 관리자 PC

1차 구현 기준:

```text
템플릿 관리
점검 현황 조회
미완료/위험 필터
follow-up 생성/변경
```

관리자 화면에서 바로 write가 필요한 경우:

- 템플릿 `qsc_domain`
- `requires_photo`
- `required_photo_count`
- `weight`
- `is_sv_required`

즉, 관리자 PC는 먼저 `qc_templates` 편집 payload가 늘어나야 한다.

### 6.3 모바일 SV

1차 구현 기준:

```text
담당 매장 선택
미확인 점검 목록 조회
사진 확인
평가/점수 입력
reviewed 또는 rejected 처리
```

권장 payload:

```text
sv_review_status
sv_reviewed_by
sv_reviewed_at
sv_score
sv_note
visit_session_id
```

점검 결과 `result` 자체는 직원 source를 유지하고, SV는 검토 상태를 덧붙인다.

### 6.4 모바일 관리자

모바일 관리자는 1차에서 write보다 read가 우선이다.

필요 시 가능한 write:

- follow-up 상태 변경
- 리뷰 note 추가

하지만 우선순위는 낮다.

---

## 7. `QcCheckNotifier.submitCheck()` 전환 전략

현재:

```text
uploadQcPhoto()
-> evidencePhotoUrl 1개 생성
-> upsertCheck()
```

권장 2단계 전환:

### Step A

기존 흐름 유지

```text
uploadQcPhoto()
-> 대표 signed URL 생성
-> upsertCheck()
```

장점:

- 지금 화면 거의 안 건드림
- migration 적용 후에도 바로 동작 가능

한계:

- `qc_check_photos`는 비어 있게 됨
- photo count는 실제 다중 사진 모델과 분리됨

### Step B

QSC v2 저장 흐름 적용

```text
upsertCheckV2() 먼저 호출해서 check row 확보
-> upsertCheckPhoto() 1회 이상 호출
-> 필요 시 마지막에 upsertCheckV2() 또는 refresh 로드
```

권장 최종 흐름:

```text
1. upsertCheckV2(submission_status=pending or submitted)
2. photo 여러 장 업로드 + upsertCheckPhoto
3. 마지막 상태 갱신
```

실행 관점에서는 Step A에서 Step B로 천천히 옮기는 게 안전하다.

---

## 8. 템플릿 관리 화면 변경 기준

현재 `_TemplateManagementTab`는 아래만 관리한다.

- `category`
- `criteria_text`
- `criteria_photo_url`
- `sort_order`

QSC v2에서는 입력 필드를 추가해야 한다.

추가 후보:

- `qsc_domain`
- `requires_photo`
- `required_photo_count`
- `weight`
- `sort_group`
- `is_sv_required`

권장 순서:

1. `qsc_domain`
2. `requires_photo`
3. `required_photo_count`
4. `is_sv_required`
5. `weight`
6. `sort_group`

이 순서가 좋은 이유:

- 화면 복잡도를 한 번에 늘리지 않는다.
- 관리자에게 필요한 운영 설정부터 붙일 수 있다.

---

## 9. 에러 계약 추가 기준

현재 provider는 QC v1 에러 코드를 문자열 매칭으로 처리한다.

QSC v2에서 추가될 에러 코드 후보:

```text
QC_CHECK_SUBMISSION_STATUS_INVALID
QC_CHECK_PHOTO_REQUIRED_COUNT_INVALID
QC_CHECK_PHOTO_UPLOADED_COUNT_INVALID
QC_CHECK_GRADE_INVALID
QC_CHECK_SV_REVIEW_STATUS_INVALID
QC_CHECK_SV_ACTOR_INVALID
QC_CHECK_PHOTO_WRITE_FORBIDDEN
QC_CHECK_PHOTO_ROLE_INVALID
QC_CHECK_PHOTO_CHECK_NOT_FOUND
QC_VISIT_REVIEW_FORBIDDEN
QC_VISIT_REVIEW_CHECKS_REQUIRED
QC_VISIT_REVIEW_STATUS_INVALID
QC_VISIT_REVIEW_CHECK_NOT_FOUND
```

따라서 `QcCheckNotifier`와 향후 SV notifier는 QC v2 에러 매핑을 추가해야 한다.

---

## 10. 구현 우선순위

### Phase A — 호환 유지

1. `QcService.upsertCheck()` 유지
2. DB migration 적용
3. 기존 화면 정상 동작 확인

### Phase B — 직원 QSC 입력

1. `upsertCheckV2()` 추가
2. `upsertCheckPhoto()` 추가
3. 직원 모바일에서 제출 상태 + 사진 count 사용

### Phase C — 관리자 설정/현황

1. 템플릿 편집 payload 확장
2. `v_qsc_*` 기반 read helper 추가
3. 관리자 화면 교체

### Phase D — 모바일 SV

1. `submitVisitReview()` 추가 연결
2. 미확인 점검 목록
3. 점수/평가/반려 흐름

---

## 11. 지금 바로 코드로 옮길 때의 최소 변경안

가장 보수적인 실제 적용 순서는 아래다.

1. `QcService`에 새 메서드만 추가
2. 기존 `submitCheck()`는 그대로 유지
3. 새 `submitCheckV2()`를 별도 추가
4. 새 QSC 화면만 `submitCheckV2()` 사용
5. 기존 QC 화면는 추후 교체

이렇게 하면 현재 운영 흐름을 깨지 않고, 새 설계 화면을 병행 개발할 수 있다.

---

## 12. 결론

현재 Flutter 구조는 완전히 갈아엎을 필요가 없다.

정확한 방향은:

```text
기존 QC v1 write flow 유지
+ QSC v2 service method 추가
+ notifier 분화
+ 새 화면은 새 payload 사용
+ 기존 화면은 점진적 교체
```

즉, QSC v2는 “서비스와 payload를 먼저 확장하고, 화면은 역할별로 순차 교체”하는 방식이 가장 안전하다.
