# QSC v2 Staging Runbook

## 1. 목적

이 문서는 QSC v2 draft migration을 staging에 적용하기 전/중/후에 따라야 하는 실행 순서를 고정한다.

목표:

- 기존 QC v1 계약이 깨지지 않는지 확인
- 글로벌 템플릿 + 다매장 시 store-scoped uniqueness가 의도대로 동작하는지 확인
- Office read-model wrapper view가 안전하게 조회되는지 확인

## 2. 실행 원칙

1. **STAGING only**로 먼저 검증한다.
2. apply 중 실패하면 그 지점에서 즉시 중단한다.
3. staging에서 in-place patching은 하지 않는다.
4. Office 앱 코드는 이 단계에서 수정하지 않는다.
5. `restaurants` / `restaurant_id` 물리 계약은 바꾸지 않는다.

## 3. 적용 대상 migration 순서

QSC v2 draft 기준 권장 순서는 아래다.

1. [20260507000007_qsc_v2_check_scope_uniqueness.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260507000007_qsc_v2_check_scope_uniqueness.sql)
2. [20260507000000_qsc_v2_core_additive_columns.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260507000000_qsc_v2_core_additive_columns.sql)
3. [20260507000001_qsc_v2_check_photos.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260507000001_qsc_v2_check_photos.sql)
4. [20260507000002_qsc_v2_monitoring_views.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260507000002_qsc_v2_monitoring_views.sql)
5. [20260507000003_qsc_v2_rpc_extensions.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260507000003_qsc_v2_rpc_extensions.sql)
6. [20260507000004_qsc_v2_get_qc_checks_extension.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260507000004_qsc_v2_get_qc_checks_extension.sql)
7. [20260507000005_qsc_v2_template_rpc_extension.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260507000005_qsc_v2_template_rpc_extension.sql)
8. [20260507000006_qsc_v2_office_read_model_views.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260507000006_qsc_v2_office_read_model_views.sql)

## 4. preflight

### 4.1 backup

staging 기준 fresh dump 또는 dashboard backup을 먼저 확보한다.

예시:

```bash
supabase db dump --linked -f /tmp/qsc_v2_staging_preflight_dump.sql
```

### 4.2 linked project 확인

```bash
cat supabase/.temp/project-ref
cat supabase/.branches/_current_branch
```

현재 shell의 linked project ref와 branch 상태를 확인한다.  
이 ref가 진짜 staging인지 불명확하면 mutation apply를 시작하지 않는다.

### 4.3 preflight query

아래 smoke SQL을 먼저 실행해 현 상태를 잠근다.

```bash
supabase db query --linked -f /Users/andreahn/globos_pos_system/supabase/snippets/qsc_v2_staging_smoke_checks.sql -o json
```

## 5. apply 방식

초기 draft 검증 단계에서는 `db push`보다 migration file 단위 `db query --linked -f`가 더 안전하다.  
linked temp role이 불안정하면 `SUPABASE_DB_PASSWORD`를 준비해 direct `--db-url` 경로로 재시도한다.

예시:

```bash
supabase db query --linked -f /Users/andreahn/globos_pos_system/supabase/migrations/20260507000007_qsc_v2_check_scope_uniqueness.sql
supabase db query --linked -f /Users/andreahn/globos_pos_system/supabase/migrations/20260507000000_qsc_v2_core_additive_columns.sql
supabase db query --linked -f /Users/andreahn/globos_pos_system/supabase/migrations/20260507000001_qsc_v2_check_photos.sql
supabase db query --linked -f /Users/andreahn/globos_pos_system/supabase/migrations/20260507000002_qsc_v2_monitoring_views.sql
supabase db query --linked -f /Users/andreahn/globos_pos_system/supabase/migrations/20260507000003_qsc_v2_rpc_extensions.sql
supabase db query --linked -f /Users/andreahn/globos_pos_system/supabase/migrations/20260507000004_qsc_v2_get_qc_checks_extension.sql
supabase db query --linked -f /Users/andreahn/globos_pos_system/supabase/migrations/20260507000005_qsc_v2_template_rpc_extension.sql
supabase db query --linked -f /Users/andreahn/globos_pos_system/supabase/migrations/20260507000006_qsc_v2_office_read_model_views.sql
```

실패하면 즉시 중단하고 해당 error output을 저장한다.

## 6. post-apply smoke

같은 smoke SQL을 다시 실행한다.

```bash
supabase db query --linked -f /Users/andreahn/globos_pos_system/supabase/snippets/qsc_v2_staging_smoke_checks.sql -o json
```

추가 확인:

```bash
supabase db query "select * from public.v_office_qsc_dashboard limit 5" --linked -o json
supabase db query "select * from public.v_office_qsc_store_latest limit 5" --linked -o json
supabase db query "select * from public.v_office_qsc_issue_queue limit 5" --linked -o json
```

## 7. Flutter / RPC smoke

### 7.1 POS app smoke

staging 연결로 아래 흐름을 직접 확인한다.

1. 관리자 템플릿 생성/수정
2. 직원 점검 입력
3. 멀티사진 업로드
4. 관리자 QC 탭 주간/기간 조회
5. SV review

### 7.2 RPC compatibility smoke

기존 호출 경로와 새 호출 경로 둘 다 확인한다.

- `upsert_qc_check` legacy 7-param path
- `upsert_qc_check` extended trailing param path
- `get_qc_templates`
- `get_qc_checks`

## 8. Office bridge smoke

Office repo 코드는 아직 안 바꾸더라도, bridge 개발자가 아래를 수동 query로 확인해야 한다.

1. `v_office_qsc_dashboard` select
2. `v_office_qsc_store_latest` select
3. `v_office_qsc_issue_queue` select
4. `v_quality_monitoring` item drill-down select

명시 컬럼 목록은 [qsc_v2_office_pos_bridge_checklist.md](/Users/andreahn/globos_pos_system/docs/qsc_v2_office_pos_bridge_checklist.md)를 따른다.

## 9. GO / NO-GO 기준

### GO

- 모든 migration apply 성공
- smoke SQL PASS
- POS Flutter 핵심 흐름 PASS
- wrapper view select PASS
- 기존 `restaurants` direct select 계약 유지

### NO-GO

- uniqueness migration 실패
- `upsert_qc_check` overload 호출 실패
- `v_quality_monitoring` legacy 컬럼 의미 변경
- Office wrapper view select 실패
- 기존 QC v1 화면/저장 경로 회귀

## 10. 산출물

staging run 후 아래를 남긴다.

- exact apply command log
- failing statement 또는 success log
- post-apply smoke output
- POS manual smoke 결과
- Office wrapper query 결과
