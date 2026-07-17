# 법인-브랜드-매장 운영 계약

## 기준 계층

운영 데이터는 `tax_entity -> tax_entity_brands -> brands -> restaurants` 순서로
구분한다. 법인은 세금·소유·Office 연동 기준이고, 브랜드는 영업 및 매출 분석
기준이다. 같은 법인을 여러 브랜드에 연결할 수 있고, 같은 브랜드를 여러 법인에 연결할
수도 있다.

`restaurants`는 계속 물리 매장 테이블이다. 기존 `id`, `name`, `address`,
`is_active`와 기존 매장 행은 유지한다.

## 내부·외부 회사

`tax_entity.owner_type`만 내부·외부의 원본이다.

- `internal`: `restaurants.store_type`은 `direct`로 파생되며 Office 연동 대상이다.
- `external`: `restaurants.store_type`은 `external`로 파생되며 Office 연동 및
  `v_office_eligible_stores` 조회 대상에서 제외된다.

`store_type` RPC 인자는 기존 클라이언트 호환을 위해 남아 있지만 저장값을
결정하지 않는다. 법인의 소유유형을 변경하면 소속 매장의 호환값도 동기화된다.

POS 운영 DB에는 Office의 `ops.stores`, `core.account_status`, Office helper RPC가
없어도 된다. 이 객체가 모두 있는 환경에서만 Office bridge를 실행하고, 없으면 POS
매장/법인 변경은 정상 완료한 뒤 Office 연결을 보류한다. `v_office_eligible_stores`는
내부 법인 매장만 제공하므로 외부 법인은 Office 후보에 포함되지 않는다.

## 매장 등록 순서

1. `admin_upsert_tax_entity_v2`로 법인을 등록한다.
2. `admin_set_tax_entity_brand_link_v2`로 법인과 브랜드를 연결한다.
3. `admin_create_restaurant_v2`로 법인과 브랜드를 모두 지정해 매장을 만든다.
4. 법인 또는 브랜드를 변경할 때는 `admin_update_restaurant_v2`를 사용한다.

사용 중인 법인-브랜드 연결은 해제할 수 없다. 기존 v1 매장 RPC는 유지되지만,
법인을 변경하거나 한 브랜드에 연결된 법인이 여러 개인 경우 v2를 사용한다.

## AKJ / PHOTO OBJET 안전 백필

AKJ의 세금 프로필은 고정 ID
`a6bda671-4179-5a29-a798-76357b42b497`로 준비한다. 실제 세금번호가 확정되지
않은 상태에서는 `PENDING_AKJ_TAX_PROFILE`이라는 명시적 비재정 표식과
`pending_tax_profile` 상태를 사용한다. 이 값은 실제 세금번호가 아니다.

PHOTO OBJET 브랜드 ID `77000000-0000-0000-0000-000000000001`에 속하면서 기존
공용 개발 placeholder 법인을 사용하던 매장만 AKJ pending 프로필로 이동한다.
이미 다른 법인에 속한 PHOTO OBJET 매장은 변경하지 않는다. 따라서 이후 외부
회사가 PHOTO OBJET을 운영하면 별도 `tax_entity`를 만들고 같은 브랜드를 여러
법인에 연결해 독립적으로 집계할 수 있다.

이동 전 매장별 법인과 브랜드 추천값은
`hierarchy_20260711090000_photo_backup`에 한 번만 캡처한다. 기존
`store_tax_entity_history` 행도 별도 캡처하고, placeholder 기간은 닫은 뒤 AKJ
기간을 새 행으로 추가한다. 이력 사유에는 migration actor와 source/destination을
기록하며 재실행 시 같은 기간을 중복 추가하지 않는다. 최초 스냅샷이 완료되면
`hierarchy_20260711090000_backup_state`에 완료 시각을 기록한다. 이후 forward SQL을
재실행해도 매핑, 객체 정의, 기존 이력 백업은 다시 캡처하지 않으므로 migration이
생성한 이력이 rollback 원본에 섞이지 않는다.

AKJ의 정식 법인명과 실제 베트남 세금번호를 검증한 뒤 다음 순서로 활성화한다.

1. `admin_upsert_tax_entity_v2`로 실제 법인명과 세금번호를 입력하고 상태를
   `ready`로 변경한다.
2. meInvoice 비밀값과 비밀이 아닌 설정을 등록한다.
3. 공급사 확인 후 `integration_status=active`로 전환한다.

DB 트리거는 `pending_tax_profile` 법인의 meInvoice 설정을 `active`로 변경하지
못하게 한다. 따라서 실제 세금번호를 입력하기 전에는 발행할 수 없다.

## 운영 검증

배포 스크립트는 Supabase project ref `ynriuoomotxuwhuxxmhj`와 Vercel POS
project/org ID를 코드에 고정한다. `SUPABASE_DB_URL`, project-ref override,
Vercel-project override, mismatch bypass가 있으면 비밀값을 출력하지 않고 즉시
중단한다. 계층 migration을 지정하면 preflight와 forward verification을 자동으로
실행한다.

```bash
scripts/deploy_pos_production.sh \
  --migration supabase/migrations/20260711090000_legal_entity_brand_store_hierarchy.sql
```

각 SQL은 linked POS production에 독립 실행할 수 있다. verification은 읽기 전용이고
rollback과 분리되어 있다.

```bash
supabase db query --linked \
  -f scripts/preflight_legal_entity_brand_store_hierarchy.sql -o table
supabase db query --linked \
  -f scripts/verify_legal_entity_brand_store_hierarchy.sql -o table
```

rollback은 파괴적 작업이다. 캡처가 없거나 PHOTO OBJET 매핑/이력이 이후 변경된
경우 실패한다. 승인 후에만 별도로 실행하고, 성공 후 migration history를
`reverted`로 repair한다. rollback SQL은 복원 후 원래 매장-법인-브랜드 매핑과
이력 전체가 최초 스냅샷과 정확히 같은지, migration 생성 이력이 남지 않았는지
검증한 뒤에만 백업 테이블을 제거한다.

```bash
supabase db query --linked \
  -f scripts/rollback_legal_entity_brand_store_hierarchy.sql -o table
supabase migration repair 20260711090000 --status reverted --yes
```

수동 조회 예시는 다음과 같다.

```sql
select tax_entity_id, brand_id from public.tax_entity_brands;
select * from public.v_office_eligible_stores;
select id, tax_code, name, owner_type, onboarding_status
from public.tax_entity
order by name;
```
