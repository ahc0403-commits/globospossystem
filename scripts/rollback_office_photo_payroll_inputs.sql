-- Metadata-only rollback for the new read contract; no workforce/pay data writes.
drop function if exists public.office_photo_payroll_inputs(uuid,uuid,date,date);
