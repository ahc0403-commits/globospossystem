-- Repair the shared Storage policy left bound to the renamed private helper.
-- Attendance roles, store scope, and procurement approval rules stay unchanged.
BEGIN;

DROP POLICY inventory_receipt_statement_objects_write ON storage.objects;
CREATE POLICY inventory_receipt_statement_objects_write
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'inventory-receipt-statements'
  AND (
    public.can_create_inventory_purchase_order(
      NULLIF((storage.foldername(name))[1], '')::uuid
    )
    OR public.can_verify_inventory_receipt(
      NULLIF((storage.foldername(name))[1], '')::uuid
    )
  )
);

COMMIT;
