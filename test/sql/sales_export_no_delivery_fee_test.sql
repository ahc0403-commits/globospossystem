SET fixture.super_admin='true';
SET request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
DO $$DECLARE o uuid;lines jsonb;a jsonb;b jsonb;BEGIN
 SELECT order_id INTO o FROM no_delivery_fee_scope;
 SELECT line_items INTO lines FROM public.pos_restaurant_receipt_rows_fresh('2026-10-12',ARRAY[o]);
 PERFORM fixture_assert(jsonb_array_length(lines)=1 AND (lines->0->>'quantity')::numeric=2
  AND lines->0->>'invoice_name_vi'='Japchae (Miến Xào)' AND lines->0->>'misa_unit_name'='Phần'
  AND lines->0->>'invoice_effective_to' IS NULL,'delivery fee disappears while sold menu quantity and perpetual metadata remain');
 PERFORM fixture_assert(public.invoice_snapshot_is_valid(lines,'2026-10-12 12:00+07')
  AND public.invoice_snapshot_is_valid(lines,'2026-10-13 12:00+07'),'permanent profile is valid on sale day and next day');
 a:=public.revalidate_meinvoice_export_snapshots('2026-10-12','10000000-0000-0000-0000-000000000001',ARRAY[o]);
 b:=public.revalidate_meinvoice_export_snapshots('2026-10-12','10000000-0000-0000-0000-000000000001',ARRAY[o]);
 PERFORM fixture_assert(a->>'updated_count'='1' AND b->>'unchanged_count'='1' AND b->>'updated_count'='0','source rebuild and retry are idempotent');
 PERFORM fixture_assert((SELECT snapshot_version=3 AND jsonb_array_length(line_items_snapshot)=1 FROM public.meinvoice_jobs WHERE order_id=o),'regeneration stores only sold menu rows');
 PERFORM fixture_assert((SELECT v.line_items_snapshot=s.old_lines FROM public.meinvoice_job_snapshot_versions v
  JOIN public.meinvoice_jobs j ON j.id=v.job_id JOIN no_delivery_fee_scope s ON s.order_id=j.order_id WHERE v.snapshot_version=2),'previous snapshot preserved');
 PERFORM fixture_assert((SELECT count(*)=2 AND sum(total_amount_ex_tax+vat_amount)=10800 FROM public.order_items WHERE order_id=o),'original sale and zero placeholder rows are untouched');
 PERFORM fixture_assert(EXISTS(SELECT 1 FROM jsonb_array_elements(public.get_pos_daily_sales_summary('2026-10-12')->'entities') e
  WHERE e->>'tax_entity_id'='10000000-0000-0000-0000-000000000001' AND e->>'source_item_count'='1' AND e->>'export_line_count'='1'),'summary and exported line counts exclude the same fee');
END $$;
