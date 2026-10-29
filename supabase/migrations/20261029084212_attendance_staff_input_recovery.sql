-- Repair only the staff projection boundary. All other financial sources keep
-- invoker security/RLS; the private view (including bank data) stays private.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';
CREATE FUNCTION public.get_financial_payroll_staff_rows(p_store_ids uuid[])
RETURNS TABLE(id uuid,store_id uuid,employee_number text,full_name text,employment_role text,
 employment_start_date date,photo_policy boolean,pay_policies jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
BEGIN
 IF auth.uid() IS NULL OR coalesce(cardinality(p_store_ids),0)=0
 OR EXISTS(SELECT 1 FROM unnest(p_store_ids) requested(id)
 WHERE requested.id IS NULL OR (NOT coalesce(public.is_super_admin(),false) AND NOT EXISTS(SELECT 1 FROM public.user_accessible_stores(auth.uid()) allowed(id) WHERE allowed.id=requested.id)))
 THEN RAISE EXCEPTION 'FINANCIAL_INPUT_FORBIDDEN'; END IF;
 RETURN QUERY WITH allowed AS MATERIALIZED(
 SELECT DISTINCT requested.id FROM unnest(p_store_ids) requested(id)
 WHERE public.workforce_can_manage_store(requested.id))
 SELECT s.id,s.store_id,s.employee_number,s.full_name,s.employment_role,
 s.employment_start_date,s.photo_policy,s.pay_policies
 FROM public.v_financial_payroll_staff s JOIN allowed a ON a.id=s.store_id WHERE s.is_active;
END $$;
REVOKE ALL ON FUNCTION public.get_financial_payroll_staff_rows(uuid[]) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_financial_payroll_staff_rows(uuid[]) TO authenticated;
DO $readers$
DECLARE signature text; definition text; needle text := 'FROM public.v_financial_payroll_staff WHERE store_id = ANY($1)';
BEGIN
 FOREACH signature IN ARRAY ARRAY[
 'public.get_financial_input_page(text,uuid[],timestamptz,timestamptz,date,date,jsonb,text,integer)',
 'public.get_employee_financial_input_page(text,uuid,uuid[],timestamptz,timestamptz,date,date,jsonb,text,integer)'] LOOP
  SELECT pg_get_functiondef(signature::regprocedure) INTO definition;
  IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'ATTENDANCE_STAFF_INPUT_REPAIR_DRIFT'; END IF;
  -- is_active filtering is done inside the explicitly scoped helper.
  definition:=replace(definition,needle||' AND is_active = true','FROM public.get_financial_payroll_staff_rows($1) WHERE store_id = ANY($1)');
  IF strpos(definition,needle)>0 THEN RAISE EXCEPTION 'ATTENDANCE_STAFF_INPUT_REPAIR_DRIFT'; END IF;
  EXECUTE definition;
 END LOOP;
END $readers$;
DO $manual$
DECLARE d text; needle text := $old$'admin', 'store_admin', 'brand_admin', 'super_admin'$old$;
BEGIN
 SELECT pg_get_functiondef('public.admin_record_employee_attendance(uuid,uuid,text,timestamptz,text,text)'::regprocedure) INTO d;
 IF strpos(d,needle)=0 THEN RAISE EXCEPTION 'ATTENDANCE_MANUAL_ROLE_REPAIR_DRIFT'; END IF;
 d:=replace(d,needle,needle||', ''photo_objet_master''');
 d:=replace(d,'  PERFORM public.verify_discount_manager_pin_or_raise(', $guard$  IF v_actor.role='photo_objet_master' AND NOT public.workforce_can_manage_store(p_store_id) THEN
    RAISE EXCEPTION 'ATTENDANCE_MANUAL_ENTRY_FORBIDDEN';
  END IF;
  PERFORM public.verify_discount_manager_pin_or_raise($guard$);
 IF strpos(d,'AND NOT public.workforce_can_manage_store(p_store_id)')=0 THEN RAISE EXCEPTION 'ATTENDANCE_MANUAL_ROLE_REPAIR_DRIFT'; END IF;
 EXECUTE d;
END $manual$;
DO $$ BEGIN
 IF has_table_privilege('authenticated','public.v_financial_payroll_staff','SELECT')
 OR has_function_privilege('anon','public.get_financial_payroll_staff_rows(uuid[])','EXECUTE')
 OR EXISTS(SELECT 1 FROM pg_proc WHERE oid IN(
 'public.get_financial_input_page(text,uuid[],timestamptz,timestamptz,date,date,jsonb,text,integer)'::regprocedure,
 'public.get_employee_financial_input_page(text,uuid,uuid[],timestamptz,timestamptz,date,date,jsonb,text,integer)'::regprocedure) AND prosecdef)
 THEN RAISE EXCEPTION 'ATTENDANCE_STAFF_INPUT_PERMISSIONS_INVALID'; END IF;
END $$;
COMMIT;
