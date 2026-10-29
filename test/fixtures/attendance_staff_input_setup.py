"""Exact production function bodies on synthetic stores; no production staff data."""
from pathlib import Path
import re, sys
root=Path(sys.argv[1]); migrations=root/'supabase/migrations'
def function(file,name):
 s=(migrations/file).read_text(); m=re.search(r'CREATE (?:OR REPLACE )?FUNCTION public\.'+name+r'\(',s,re.I); assert m,name
 tag=re.search(r'\bAS\s+(\$[^$]*\$)',s[m.start():],re.I).group(1)
 start=s.index(tag,m.start()); end=s.index(tag+';',start+len(tag))+len(tag)+1
 return s[m.start():end]
print('''
DO $$ BEGIN IF current_database()<>'payroll_test' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF; END $$;
CREATE SCHEMA extensions;
CREATE EXTENSION pgcrypto WITH SCHEMA extensions;
CREATE TABLE brands(id uuid PRIMARY KEY,management_model text);
CREATE TABLE restaurants(id uuid PRIMARY KEY,brand_id uuid REFERENCES brands,name text,is_active boolean DEFAULT true);
ALTER TABLE store_employees ADD COLUMN employment_start_date date, ADD COLUMN bank_account_number text;
ALTER TABLE attendance_logs ADD COLUMN recorded_by_user_id uuid;
ALTER TABLE attendance_logs ALTER COLUMN id SET DEFAULT gen_random_uuid();
CREATE TABLE audit_logs(actor_id uuid,action text,entity_type text,entity_id uuid,details jsonb);
CREATE TABLE restaurant_settings(restaurant_id uuid PRIMARY KEY,settings_json jsonb);
CREATE TABLE office_photo_pay_policies(store_id uuid,effective_from date,monthly_salary numeric,standard_monthly_minutes integer,overtime_multiplier numeric);
CREATE TABLE fixture_store_access(actor uuid,store_id uuid);
CREATE OR REPLACE FUNCTION public.user_accessible_stores(p_actor uuid) RETURNS TABLE(store_id uuid) LANGUAGE sql STABLE SECURITY DEFINER AS $$ SELECT store_id FROM fixture_store_access WHERE actor=p_actor $$;
INSERT INTO brands VALUES('77000000-0000-0000-0000-000000000001','brand_centralized'),('77000000-0000-0000-0000-000000000002','store_managed');
INSERT INTO restaurants SELECT ('10000000-0000-0000-0000-'||lpad(g::text,12,'0'))::uuid,CASE WHEN g>2 THEN '77000000-0000-0000-0000-000000000001'::uuid ELSE '77000000-0000-0000-0000-000000000002'::uuid END,CASE g WHEN 1 THEN 'Bunsik fixture' WHEN 2 THEN 'JeonGabok fixture' ELSE 'Photo fixture '||g END,true FROM generate_series(1,7)g;
INSERT INTO users VALUES('20000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000003',true,'super_admin','Super fixture'),('20000000-0000-0000-0000-000000000004','20000000-0000-0000-0000-000000000004',true,'store_admin','JeonGabok manager fixture'),('20000000-0000-0000-0000-000000000006','20000000-0000-0000-0000-000000000005',true,'photo_objet_master','Photo manager fixture');
INSERT INTO fixture_store_access VALUES('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001'),('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001'),('20000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000002');
INSERT INTO fixture_store_access SELECT '20000000-0000-0000-0000-000000000005',id FROM restaurants WHERE name LIKE 'Photo%';
DELETE FROM store_employees;
INSERT INTO store_employees(id,store_id,full_name,employee_number,employment_role,is_active,employment_start_date,bank_account_number) SELECT gen_random_uuid(),id,'Employee fixture','E'||row_number() OVER(ORDER BY id),'part_timer',true,'2026-01-01','PRIVATE BANK FIXTURE' FROM restaurants;
INSERT INTO office_photo_pay_policies SELECT id,'2026-01-01',5000000,12480,1.5 FROM restaurants WHERE name LIKE 'Photo%';
INSERT INTO restaurant_settings SELECT id,jsonb_build_object('discount_manager_pin_hash',extensions.crypt('2468',extensions.gen_salt('bf'))) FROM restaurants;
''')
print(function('20260717170000_workforce_fixed_accounts.sql','workforce_can_manage_store').replace('p_store_id uuid','store_id uuid').replace('p_store_id','$1'))
print(function('20261011020000_employee_scoped_payroll.sql','get_employee_financial_input_page'))
print('REVOKE ALL ON FUNCTION public.get_employee_financial_input_page(text,uuid,uuid[],timestamptz,timestamptz,date,date,jsonb,text,integer) FROM PUBLIC,anon; GRANT EXECUTE ON FUNCTION public.get_employee_financial_input_page(text,uuid,uuid[],timestamptz,timestamptz,date,date,jsonb,text,integer) TO authenticated;')
print(function('20260706010000_discount_staff_meal_v1_schema.sql','verify_discount_manager_pin_or_raise'))
print((migrations/'20260819133000_manual_attendance_duplicate_type_scope.sql').read_text())
s=(migrations/'20261023100000_photo_office_operations.sql').read_text(); a=s.index('create view public.v_financial_payroll_staff');b=s.index('create function public.office_photo_payroll_batch',a);print(s[a:b])
