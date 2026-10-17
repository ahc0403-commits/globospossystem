# QSC v2 SQL Readiness Notes

## 1. 목적

이 문서는 QSC v2 draft migration을 실제 적용 전 관점에서 다시 점검한 메모다.  
초안 단계에서 바로 잡아야 하는 계약/순서 이슈를 기록한다.

## 2. 확인한 핵심 이슈

### 2.1 `qc_checks` uniqueness 범위

기존 `qc_checks`는 아래 uniqueness를 가진다.

```text
UNIQUE (template_id, check_date)
```

이 구조는 `is_global = true` 템플릿이 여러 매장에서 같은 날짜에 동시에 사용될 때 충돌한다.

문제점:

- 매장 A가 글로벌 템플릿 X를 2026-05-07에 저장
- 매장 B가 같은 글로벌 템플릿 X를 2026-05-07에 저장
- 기존 uniqueness에서는 두 번째 저장이 첫 번째 row를 덮어쓸 수 있다

대응:

- [20260507000007_qsc_v2_check_scope_uniqueness.sql](/Users/andreahn/globos_pos_system/supabase/migrations/20260507000007_qsc_v2_check_scope_uniqueness.sql) 추가
- uniqueness를 `(restaurant_id, template_id, check_date)`로 확장
- `upsert_qc_check` draft도 같은 key를 기준으로 conflict 처리하도록 수정

### 2.2 `upsert_qc_check` 기존 row 조회 범위

초안 상태에서는 `v_existing` 조회가 `template_id + check_date`만 보던 부분이 있었다.

이 경우도 글로벌 템플릿 시 store 경계를 넘나드는 잘못된 이전 row를 읽을 수 있다.

대응:

- `restaurant_id = p_store_id` 조건 추가

### 2.3 template RPC 확장 불완전

`qc_templates`에는 QSC v2 필드로 `weight`, `sort_group`을 추가했지만,  
초안의 `create_qc_template` / `update_qc_template`는 이 필드를 실제로 받지 않거나 patch하지 못했다.

대응:

- `create_qc_template`에 `p_weight`, `p_sort_group` 추가
- `update_qc_template` patch 허용 목록에 `weight`, `sort_group` 추가
- audit log에도 두 필드 포함

## 3. 적용 순서 조정 권장

초기 분할안보다 실제 적용 순서는 아래가 더 안전하다.

1. `20260507000007_qsc_v2_check_scope_uniqueness.sql`
2. `20260507000000_qsc_v2_core_additive_columns.sql`
3. `20260507000001_qsc_v2_check_photos.sql`
4. `20260507000002_qsc_v2_monitoring_views.sql`
5. `20260507000003_qsc_v2_rpc_extensions.sql`
6. `20260507000004_qsc_v2_get_qc_checks_extension.sql`
7. `20260507000005_qsc_v2_template_rpc_extension.sql`
8. `20260507000006_qsc_v2_office_read_model_views.sql`

이유:

- uniqueness를 먼저 넓혀야 Wave 4 upsert conflict key가 유효해진다
- Office wrapper view는 raw monitoring/QSC summary view 이후에만 안전하다

## 4. 아직 남은 점검 포인트

### 4.1 historical compatibility

`qc_checks` uniqueness를 넓히는 것은 현재보다 permissive하다.  
기존 데이터 충돌 가능성은 낮지만, 배포 전에는 아래 확인이 필요하다.

```sql
select template_id, check_date, count(*)
from public.qc_checks
group by template_id, check_date
having count(*) > 1;
```

이 결과는 현재 uniqueness 때문에 원칙적으로 0건이어야 한다.

### 4.2 RPC overload compatibility

`upsert_qc_check` 이름은 유지하되 trailing default params를 붙이는 방식이므로,  
기존 Flutter/Supabase RPC 호출이 omitted optional args를 문제없이 처리하는지 실제 staging에서 확인이 필요하다.

### 4.3 Office wrapper consumer discipline

wrapper view를 만들었다고 해서 Office가 source table이나 raw view를 직접 join하면 안 된다.  
Office bridge는 [qsc_v2_office_pos_bridge_checklist.md](/Users/andreahn/globos_pos_system/docs/qsc_v2_office_pos_bridge_checklist.md)를 따라야 한다.

## 5. 결론

현재 QSC v2 draft는 “구조상 가능한 초안”에서 “실제 적용을 준비하는 초안” 단계로 한 번 올라왔다.  
특히 글로벌 템플릿과 다매장 운영을 생각하면 store-scoped uniqueness 조정은 선택이 아니라 필수에 가깝다.
