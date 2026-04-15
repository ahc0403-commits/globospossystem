-- Priority 2 Office security remediation (2026-04-08 audit)
-- Covers: HIGH-4, HIGH-5, HIGH-6

alter view public.v_photo_objet_daily_summary
  set (security_invoker = true);
revoke usage on schema system from anon;
grant usage on schema system to authenticated;
drop policy if exists "po_attendance_upload" on storage.objects;
drop policy if exists "po_attendance_read" on storage.objects;
create policy "po_attendance_upload" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'po-attendance'
    and (
      public.is_photo_objet_master()
      or (
        public.get_photo_objet_store_id() is not null
        and split_part(name, '/', 1) = public.get_photo_objet_store_id()::text
      )
    )
  );
create policy "po_attendance_read" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'po-attendance'
    and (
      public.is_photo_objet_master()
      or (
        public.get_photo_objet_store_id() is not null
        and split_part(name, '/', 1) = public.get_photo_objet_store_id()::text
      )
    )
  );
