-- Service-only evidence metadata for Office's scoped, batched source recheck.
-- One row per referenced object; the Office bridge applies its store scope and
-- validates terminal state, the current document version, size and MIME type.
create view public.v_office_inventory_evidence_objects
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
join storage.objects o on o.bucket_id = 'inventory-receipt-statements' and o.name = r.statement_storage_path;
revoke all on public.v_office_inventory_evidence_objects from public, anon, authenticated;
grant select on public.v_office_inventory_evidence_objects to service_role;
