-- Metadata-only rollback for the new read contract; no workforce/pay data writes.
drop view if exists public.v_office_employee_daily_allowances;
drop function if exists public.office_photo_payroll_inputs(uuid,uuid,date,date);
