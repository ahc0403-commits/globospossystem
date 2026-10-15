CREATE ROLE authenticated NOLOGIN;
CREATE ROLE anon NOLOGIN;
CREATE SCHEMA storage;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
CREATE FUNCTION storage.foldername(text) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT (string_to_array($1, '/'))[1:array_length(string_to_array($1, '/'),1)-1]
$$;
CREATE TABLE storage.objects(bucket_id text NOT NULL, name text NOT NULL);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
GRANT USAGE ON SCHEMA storage, auth, public TO authenticated, anon;
GRANT INSERT ON storage.objects TO authenticated, anon;
CREATE FUNCTION public.can_create_inventory_purchase_order(uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT auth.uid() = '00000000-0000-0000-0000-000000000002'::uuid
    AND $1 = '00000000-0000-0000-0000-000000000101'::uuid
$$;
CREATE FUNCTION public.can_verify_inventory_receipt(uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER AS $$ SELECT false $$;
CREATE POLICY inventory_receipt_statement_objects_write
ON storage.objects FOR INSERT TO authenticated WITH CHECK (
  bucket_id = 'inventory-receipt-statements'
  AND (public.can_create_inventory_purchase_order(
    NULLIF((storage.foldername(name))[1], '')::uuid)
    OR public.can_verify_inventory_receipt(
    NULLIF((storage.foldername(name))[1], '')::uuid))
);
CREATE POLICY attendance_fixture ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id = 'attendance-photos'
  AND auth.uid() = '00000000-0000-0000-0000-000000000001'::uuid
  AND (storage.foldername(name))[1] = '00000000-0000-0000-0000-000000000101');
-- Reproduce the production rename/revoke and new, stricter public wrapper.
ALTER FUNCTION public.can_create_inventory_purchase_order(uuid)
  RENAME TO procurement_pre_inbox_can_create_order;
REVOKE ALL ON FUNCTION public.procurement_pre_inbox_can_create_order(uuid)
  FROM PUBLIC, anon, authenticated;
CREATE FUNCTION public.can_create_inventory_purchase_order(uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT public.procurement_pre_inbox_can_create_order($1)
    AND current_setting('fixture.receiver_assigned', true) = 'true'
$$;
REVOKE ALL ON FUNCTION public.can_create_inventory_purchase_order(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_create_inventory_purchase_order(uuid) TO authenticated;
SET ROLE authenticated;
SET request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
DO $$
BEGIN
  BEGIN
    INSERT INTO storage.objects VALUES ('attendance-photos',
      '00000000-0000-0000-0000-000000000101/employee/before.jpg');
    RAISE EXCEPTION 'Expected production failure before repair';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM NOT LIKE '%procurement_pre_inbox_can_create_order%' THEN RAISE; END IF;
  END;
END $$;
RESET ROLE;
