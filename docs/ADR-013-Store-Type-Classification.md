# ADR-013 — Store Type Classification: 직영(direct) vs 외부(external)

## 상태
**승인됨** — 2026-04-05

## 컨텍스트
- 직영매장과 외부매장의 데이터 거버넌스가 다름
- 외부매장 데이터는 Office에 일절 노출하지 않음 (매출/근태/QC/재고 전부)
- POS super_admin만 외부매장 데이터 접근 가능
- 외부매장도 Deliberry 배달앱에서 주문을 받음
- 향후 50개 이상 대규모 확장 예상

## 결정
`restaurants` 테이블에 `store_type` 컬럼 추가 (별도 테이블 아님)

## 변경 사항
1. `restaurants.store_type TEXT CHECK ('direct','external')` 컬럼 + 인덱스 2개
2. 연결 뷰 5개 재생성: `WHERE r.store_type = 'direct'` 필터 추가
3. `office_get_accessible_store_ids()` 함수 수정: external 제외
4. 외부매장 전용 뷰 2개 신규: `v_external_store_sales`, `v_external_store_overview`

## 데이터 흐름
- 직영(direct) → Office 연결 뷰 → Office 시스템 (기존과 동일)
- 외부(external) → 외부매장 전용 뷰 → POS super_admin만 접근
- Deliberry → 직영+외부 모두 접근 (필터 없음)

## 마이그레이션
`supabase/migrations/20260405000012_store_type_classification.sql`

## 관련 문서
- ADR-012: Office Integration Shared Supabase
- Governance/OFFICE_INTEGRATION.md
