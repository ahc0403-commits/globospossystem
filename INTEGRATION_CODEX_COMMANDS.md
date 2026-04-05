# POS ↔ Office 연동 — POS 측 코덱스 명령어
# Claude Code에서 순차 실행할 명령어 목록
# 생성일: 2026-04-05
# 관련 문서: Governance/OFFICE_INTEGRATION.md, Governance/SCHEMA.md

---

## ═══ PHASE 0: 공유 기반 구축 ═══

---

### POS-CMD-01: companies + brands 테이블 생성 + restaurants.brand_id FK — ✅ SQL 생성 완료
```
마이그레이션 파일 이미 생성됨: supabase/migrations/20260405000000_office_shared_hierarchy.sql
적용: supabase db push 또는 supabase migration up
1. companies 테이블 생성:
   - id UUID PRIMARY KEY DEFAULT gen_random_uuid()
   - name TEXT NOT NULL
   - created_at TIMESTAMPTZ NOT NULL DEFAULT now()

2. brands 테이블 생성:
   - id UUID PRIMARY KEY DEFAULT gen_random_uuid()
   - company_id UUID REFERENCES companies(id)
   - code TEXT UNIQUE NOT NULL
   - name TEXT NOT NULL
   - logo_url TEXT
   - created_at TIMESTAMPTZ NOT NULL DEFAULT now()

3. restaurants 테이블에 brand_id 추가:
   ALTER TABLE restaurants ADD COLUMN brand_id UUID REFERENCES brands(id);

4. RLS 정책:
   - companies: 인증된 사용자만 SELECT 가능
   - brands: 인증된 사용자만 SELECT 가능
   - brand_id가 nullable이므로 기존 restaurants RLS에 영향 없음 확인

5. 인덱스:
   - CREATE INDEX idx_restaurants_brand_id ON restaurants(brand_id);
   - CREATE INDEX idx_brands_company_id ON brands(company_id);

규칙:
- 기존 restaurants RLS 정책은 절대 수정하지 마
- brand_id는 nullable로 추가 (기존 데이터 호환)
- gen_random_uuid() 사용 (uuid_generate_v4() 아님)
- 파일 상단에 주석: "-- Office integration Phase 0: Shared hierarchy tables"
```

---

### POS-CMD-02: 초기 브랜드 데이터 + 레스토랑 매핑
```
프로젝트 /Users/andreahn/globos_pos_system 에서 작업해줘.

supabase/migrations/ 폴더에 새 마이그레이션 파일 생성:
파일명: 20260405000001_office_brand_seed.sql

내용:
1. GLOBOSVN 회사 생성:
   INSERT INTO companies (name) VALUES ('GLOBOSVN Co., Ltd.');

2. 3개 브랜드 생성 (company_id는 위에서 생성한 회사의 id):
   - code: 'modern_k', name: 'Modern K Brunch & Bakery'
   - code: 'k_noodle', name: 'K-Noodle'
   - code: 'k_shabu', name: 'K-Shabu'

3. 기존 restaurants 레코드의 brand_id를 적절한 브랜드에 매핑:
   - restaurants 테이블의 기존 데이터를 조회해서, name 기반으로 매핑
   - 매핑이 불확실한 경우 NULL로 유지 (수동 매핑 대비)

규칙:
- INSERT 시 ON CONFLICT DO NOTHING 사용 (멱등성)
- 회사 id를 변수로 잡아서 사용 (WITH cte 패턴)
- 파일 상단 주석: "-- Office integration Phase 0: Brand seed data"
```

---

### POS-CMD-03: payroll_records 상태값 마이그레이션
```
프로젝트 /Users/andreahn/globos_pos_system 에서 작업해줘.

supabase/migrations/ 폴더에 새 마이그레이션 파일 생성:
파일명: 20260405000002_office_payroll_status_migration.sql

내용:
1. payroll_records 기존 CHECK 제약 제거:
   ALTER TABLE payroll_records DROP CONSTRAINT IF EXISTS payroll_records_status_check;

2. 기존 'confirmed' → 'store_submitted'로 데이터 업데이트:
   UPDATE payroll_records SET status = 'store_submitted' WHERE status = 'confirmed';

3. 새 CHECK 제약 추가:
   ALTER TABLE payroll_records ADD CONSTRAINT payroll_records_status_check
   CHECK (status IN ('draft', 'store_submitted', 'office_confirmed', 'paid'));

규칙:
- 이것은 breaking change. 기존 POS 코드에서 'confirmed' 참조하는 곳을 반드시 함께 수정해야 함
- 파일 상단 주석: "-- Office integration Phase 0: Payroll status migration (BREAKING)"
- 마이그레이션 실행 전 payroll_records에 status='confirmed'인 행이 몇 건인지 확인하는 SELECT문 포함
```

---

### POS-CMD-04: POS Flutter 모델 업데이트 (brand_id 추가) — ✅ 완료
```
이 명령은 이미 직접 실행 완료됨 (2026-04-05).
변경된 파일: lib/features/super_admin/super_admin_provider.dart

완료된 작업:
1. SuperRestaurant 클래스에 brandId, brandName, brandCode 필드 추가
2. fromJson에서 brands 조인 데이터 파싱 추가
3. loadAllRestaurants 쿼리를 select('*, brands(name, code)')로 변경
4. addRestaurant/updateRestaurant에 brandId 파라미터 추가
5. SuperAdminState에 brands 목록, selectedBrandId, filteredRestaurants getter 추가
6. loadBrands(), setBrandFilter() 메서드 추가
7. payroll 'confirmed' 상태는 Dart 코드에서 미참조 확인 (DB 제약만 변경 필요)
```

---

### POS-CMD-05: POS super_admin 화면에 브랜드 필터 추가
```
프로젝트 /Users/andreahn/globos_pos_system 에서 작업해줘.

lib/features/super_admin/ 폴더에서 다음 작업:

1. super_provider.dart (또는 해당 provider):
   - brands 목록을 로드하는 provider 추가
   - 선택된 brand_id로 레스토랑 목록을 필터링하는 기능 추가

2. super_dashboard.dart (또는 해당 대시보드 화면):
   - 상단에 브랜드 드롭다운 필터 추가
   - '전체' 옵션 포함 (기본값)
   - 브랜드 선택 시 해당 브랜드의 레스토랑만 표시

3. super_reports_screen.dart (또는 해당 리포트 화면):
   - 브랜드별 매출 비교 차트 추가 (fl_chart 기반)
   - 기존 레스토랑별 리포트에 브랜드 그룹화 옵션

규칙:
- 기존 super_admin 기능이 깨지지 않아야 함
- brand_id가 NULL인 레스토랑도 '미분류'로 표시
- Riverpod 패턴 준수 (기존 코드 컨벤션 따라)
- UI는 기존 테마와 일관성 유지
```

---

## ═══ PHASE 1: 연결 뷰 생성 ═══

---

### POS-CMD-06: Office 연결 뷰 5개 생성
```
프로젝트 /Users/andreahn/globos_pos_system 에서 작업해줘.

supabase/migrations/ 폴더에 새 마이그레이션 파일 생성:
파일명: 20260405000003_office_connection_views.sql

다음 5개 뷰를 생성해줘 (SQL은 Governance/OFFICE_INTEGRATION.md에서 복사):

1. v_store_daily_sales:
   - payments + restaurants + brands 조인
   - 매장별, 일자별 매출 집계
   - is_revenue 기준 매출/서비스 분리

2. v_store_attendance_summary:
   - attendance_logs + users + restaurants 조인
   - 직원별, 일자별 첫 출근/마지막 퇴근

3. v_quality_monitoring:
   - qc_checks + qc_templates + restaurants 조인
   - 점검 결과 + 증빙 사진 URL

4. v_inventory_status:
   - inventory_items + restaurants 조인
   - 현재 재고 + 발주점 비교 + needs_reorder 계산

5. v_brand_kpi:
   - brands + restaurants + users + payments 조인
   - 브랜드별 매장 수, 직원 수, MTD 매출

RLS 정책:
- 모든 뷰에 인증 사용자 SELECT 허용
- super_admin은 전체, admin은 자기 restaurant_id 기반 (기존 RLS 상속)

규칙:
- 뷰는 CREATE OR REPLACE VIEW 사용
- 모든 타임존 변환은 'Asia/Ho_Chi_Minh' 사용
- 금액은 is_revenue = TRUE 필터 필수
- 파일 상단 주석: "-- Office integration Phase 1: Connection views for Office System"
```

---

## ═══ PHASE 2: 급여 연동 RPC ═══

---

### POS-CMD-07: office_confirm_payroll RPC 생성
```
프로젝트 /Users/andreahn/globos_pos_system 에서 작업해줘.

supabase/migrations/ 폴더에 새 마이그레이션 파일 생성:
파일명: 20260405000004_office_payroll_rpc.sql

내용:
1. office_confirm_payroll(p_payroll_id UUID) RPC:
   - payroll_records에서 해당 id의 status를 'office_confirmed'로 변경
   - WHERE 조건: status = 'store_submitted' (다른 상태에서는 변경 불가)
   - SECURITY DEFINER로 생성

2. office_return_payroll(p_payroll_id UUID) RPC:
   - payroll_records에서 해당 id의 status를 'draft'로 되돌림
   - WHERE 조건: status = 'store_submitted'
   - Office에서 반려 시 POS 측 상태 리셋

규칙:
- 두 RPC 모두 SECURITY DEFINER
- 상태 전환 제약 필수 (잘못된 상태에서 호출 시 에러)
- 감사 로그 생성 포함 (audit_logs 테이블에 기록)
- 파일 상단 주석: "-- Office integration Phase 2: Payroll bidirectional RPC"
```

---

### POS-CMD-08: POS payroll 제출 시 자동 트리거
```
프로젝트 /Users/andreahn/globos_pos_system 에서 작업해줘.

supabase/migrations/ 폴더에 새 마이그레이션 파일 생성:
파일명: 20260405000005_office_payroll_trigger.sql

내용:
1. office_payroll_reviews 테이블 생성 (Office 소유이지만 같은 DB):
   - id UUID PRIMARY KEY DEFAULT gen_random_uuid()
   - source_payroll_id UUID REFERENCES payroll_records(id) NOT NULL
   - restaurant_id UUID REFERENCES restaurants(id) NOT NULL
   - brand_id UUID REFERENCES brands(id)
   - period_start DATE NOT NULL
   - period_end DATE NOT NULL
   - status TEXT DEFAULT 'pending_review'
     CHECK (status IN ('pending_review','in_review','confirmed','rejected','returned'))
   - reviewed_by UUID REFERENCES auth.users(id)
   - confirmed_by UUID REFERENCES auth.users(id)
   - review_notes TEXT
   - created_at TIMESTAMPTZ NOT NULL DEFAULT now()
   - updated_at TIMESTAMPTZ NOT NULL DEFAULT now()

2. 트리거 함수: on_payroll_store_submitted()
   - payroll_records.status가 'store_submitted'로 변경되면 실행
   - office_payroll_reviews에 새 레코드 자동 생성
   - brand_id는 restaurants 테이블에서 조회해서 채움

3. 트리거:
   CREATE TRIGGER trg_payroll_store_submitted
   AFTER UPDATE OF status ON payroll_records
   FOR EACH ROW
   WHEN (NEW.status = 'store_submitted' AND OLD.status = 'draft')
   EXECUTE FUNCTION on_payroll_store_submitted();

규칙:
- office_payroll_reviews 테이블은 office_* 접두사 규칙에 따름
- 중복 생성 방지: source_payroll_id + period 기준 UNIQUE
- RLS: office_payroll_reviews는 인증 사용자 SELECT + 특정 역할 UPDATE
- 파일 상단 주석: "-- Office integration Phase 2: Payroll auto-review creation trigger"
```

---

### POS-CMD-09: POS super_admin → Office 리다이렉트 링크 (Phase 3)
```
프로젝트 /Users/andreahn/globos_pos_system 에서 작업해줘.

lib/features/super_admin/super_dashboard.dart 에서:

1. 대시보드에 "Office System으로 이동" 버튼/링크 추가
   - Office System URL로 이동 (url_launcher 사용)
   - 아이콘: Icons.business 또는 Icons.dashboard_customize

2. 리포트 화면에 "상세 리포트는 Office에서 확인" 안내 추가
   - Office KPI 대시보드 URL 링크

규칙:
- 기존 super_admin 기능은 모두 유지
- Office URL은 환경변수 또는 config에서 관리
- Phase 3에서만 실행 (Phase 2 안정화 후)
```
