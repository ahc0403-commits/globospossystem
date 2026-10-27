-- Policy-3 procurement exports are the canonical supplier PO evidence.
-- Include their Storage registry rows in the existing service-only batch view.
create or replace view public.v_office_inventory_evidence_objects
with (security_invoker = true) as
select d.restaurant_id, d.purchase_order_id, 'inventory-purchase-documents'::text as bucket_id,
       o.name as object_name, o.metadata->>'mimetype' as mime_type,
       o.metadata->>'size' as byte_size
from public.inventory_purchase_documents d
join storage.objects o on o.bucket_id = 'inventory-purchase-documents' and o.name = d.storage_path
union all
select r.restaurant_id, r.purchase_order_id, 'inventory-receipt-statements'::text,
       o.name, o.metadata->>'mimetype', o.metadata->>'size'
from public.inventory_receipts r
join storage.objects o on o.bucket_id = 'inventory-receipt-statements' and o.name = r.statement_storage_path
union all
select e.restaurant_id, e.record_id, 'inventory-purchase-documents'::text,
       o.name, o.metadata->>'mimetype', o.metadata->>'size'
from public.procurement_document_exports e
join storage.objects o on o.bucket_id = 'inventory-purchase-documents' and o.name = e.storage_path
where e.kind = 'po';
