# QSC v2 RPC Smoke Note (2026-05-07)

## 1. 왜 DB linked query만으로는 충분하지 않은가

QSC v2의 핵심 RPC는 아래처럼 `auth.uid()`와 POS 사용자 권한을 전제로 동작한다.

- `upsert_qc_check`
- `upsert_qc_check_photo`
- `submit_qc_visit_review`
- `get_qc_templates`
- `get_qc_checks`

즉, Supabase CLI의 linked DB query로 함수 존재/시그니처 확인은 가능하지만,  
그 호출이 실제 POS 앱과 동일한 인증 컨텍스트에서 성공하는지까지는 보장하지 못한다.

## 2. 이번 단계에서 확인한 것

- 함수가 staging DB에 배포되었는지: 확인 완료
- Office wrapper/read-model이 row를 반환하는지: 확인 완료

## 3. 아직 남은 것

아래는 앱 인증 컨텍스트에서 확인해야 한다.

1. legacy `upsert_qc_check` 7-param path
2. extended `upsert_qc_check` trailing param path
3. `get_qc_templates` 응답 shape
4. `get_qc_checks` 응답 shape
5. `submit_qc_visit_review` write behavior

## 4. 권장 검증 경로

### 경로 A: Flutter 앱 smoke

- 직원 점검 입력
- 멀티사진 업로드
- 관리자 템플릿 수정
- SV review

### 경로 B: authenticated PostgREST / RPC smoke

- 실제 POS 사용자 JWT
- role/extra_permissions가 설정된 사용자
- staging 환경에서 request/response 로깅

## 5. 결론

지금은 DB deploy와 Office read smoke까지 끝난 상태다.  
다음 “진짜” 남은 검증은 schema가 아니라 authenticated app/RPC behavior다.
