SET fixture.super_admin='true';
SET request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
DO $$DECLARE batch jsonb; a jsonb; b jsonb; BEGIN
 batch:=jsonb_build_array(jsonb_build_object('approval_type','item_type','item_type','wet_tissue_charge','invoice_name_vi','Khăn ướt','unit_name','Cái','mapping_version','fixture-wet-v1','source_reference','synthetic fixture approval','effective_from','2026-10-08T00:00:00+07:00','effective_to','2026-10-09T00:00:00+07:00'));
 a:=approve_invoice_mapping_batch('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',batch);
 b:=approve_invoice_mapping_batch('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',batch);
 PERFORM fixture_assert(a=b AND jsonb_array_length(a->'profiles')=1,'bulk retry returns identical real profile ID');
 PERFORM fixture_assert((SELECT count(*)=1 FROM item_type_invoice_profiles),'finite wet-tissue profile is not duplicated');
 BEGIN PERFORM approve_invoice_mapping_batch('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001',jsonb_build_array(jsonb_build_object('approval_type','menu_item','menu_item_id',md5('fixture-menu-1'),'invoice_name_vi','wrong store','unit_name','Phần','mapping_version','bad','source_reference','fixture','effective_from','2026-10-08T00:00:00+07:00')));
 RAISE EXCEPTION 'WRONG_STORE_ACCEPTED'; EXCEPTION WHEN others THEN IF SQLERRM<>'INVOICE_PROFILE_BATCH_INVALID' THEN RAISE; END IF; END;
 BEGIN PERFORM approve_invoice_mapping_batch('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',jsonb_set(batch,'{0,invoice_name_vi}','"overlapping version"'));
 RAISE EXCEPTION 'OVERLAP_ACCEPTED'; EXCEPTION WHEN others THEN IF SQLERRM<>'INVOICE_PROFILE_HISTORY_OVERLAP' THEN RAISE; END IF; END;
END $$;
-- Repair a stale already-v2 unissued snapshot from actual sold lines.
INSERT INTO orders VALUES('32000000-0000-0000-0000-000000000001','completed','dine_in');
INSERT INTO payments(order_id,restaurant_id,created_at,amount_portion,amount,method,is_revenue) VALUES('32000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','2026-10-08 12:00+07',12960,12960,'BANKTRANSFER',true);
INSERT INTO order_items(id,order_id,menu_item_id,display_name,quantity,unit_price,total_amount_ex_tax,vat_rate,vat_amount,paying_amount_inc_tax,created_at,status,item_type)
VALUES('42000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000001',md5('fixture-menu-2')::uuid,'Food',1,10000,10000,8,800,10800,'2026-10-08 12:00+07','served','menu_item'),
('42000000-0000-0000-0000-000000000002','32000000-0000-0000-0000-000000000001',NULL,'Wet tissue',1,2000,2000,8,160,2160,'2026-10-08 12:00+07','served','wet_tissue_charge');
INSERT INTO meinvoice_jobs(id,order_id,source_system,created_at,tax_entity_id,payment_method_snapshot,line_items_snapshot,payment_summary,snapshot_version)
VALUES('62000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000001','restaurant_pos',now(),'10000000-0000-0000-0000-000000000001','QR','[{"display_name":"Stale v2"}]','[]',2);
DO $$DECLARE a jsonb; b jsonb; line jsonb; BEGIN
 PERFORM fixture_assert((SELECT line_items @> '[{"display_name":"Stale v2"}]' FROM pos_restaurant_receipt_rows_v2('2026-10-08',ARRAY['32000000-0000-0000-0000-000000000001'::uuid])),'ordinary historical read preserves v2 snapshot');
 a:=revalidate_meinvoice_export_snapshots('2026-10-08','10000000-0000-0000-0000-000000000001',ARRAY['32000000-0000-0000-0000-000000000001'::uuid]);
 PERFORM fixture_assert(a->>'updated_count'='1','explicit revalidation replaces stale v2 from source');
 SELECT line_items_snapshot->1 INTO line FROM meinvoice_jobs WHERE id='62000000-0000-0000-0000-000000000001';
 PERFORM fixture_assert(line->>'invoice_approval_type'='item_type' AND line->>'menu_item_id' IS NULL AND line->>'invoice_name_vi'='Khăn ướt' AND line->>'misa_unit_name'='Cái' AND line->>'invoice_profile_id' IS NOT NULL,'wet tissue uses real scoped type approval, no fake menu');
 b:=revalidate_meinvoice_export_snapshots('2026-10-08','10000000-0000-0000-0000-000000000001',ARRAY['32000000-0000-0000-0000-000000000001'::uuid]);
 PERFORM fixture_assert(b->>'updated_count'='0' AND b->>'unchanged_count'='1' AND (SELECT snapshot_version=3 AND payment_summary='[]'::jsonb FROM meinvoice_jobs WHERE id='62000000-0000-0000-0000-000000000001'),'revalidation idempotent with original payment summary array');
 PERFORM fixture_assert((SELECT line_items_snapshot @> '[{"display_name":"Stale v2"}]' FROM meinvoice_job_snapshot_versions WHERE job_id='62000000-0000-0000-0000-000000000001' AND snapshot_version=2),'previous version archived');
 PERFORM fixture_assert((SELECT NOT invoice_snapshot_is_valid(line_items,'2026-10-09 12:00+07') FROM pos_restaurant_receipt_rows_fresh('2026-10-08',ARRAY['32000000-0000-0000-0000-000000000001'::uuid])),'finite mapping cannot be applied on following day');
END $$;
UPDATE meinvoice_jobs SET dispatch_attempts=1 WHERE id='62000000-0000-0000-0000-000000000001';
SELECT fixture_assert(revalidate_meinvoice_export_snapshots('2026-10-08','10000000-0000-0000-0000-000000000001',ARRAY['32000000-0000-0000-0000-000000000001'::uuid])->>'protected_count'='1','attempted job is protected');
SELECT fixture_assert((SELECT count(*)=2 AND sum(reported_receipt_count)=569 FROM sales_external_reporting_protections WHERE business_date='2026-10-11'),'provided completed 569 receipts protected without fabricated invoice IDs');
SELECT fixture_assert((get_pos_daily_sales_export_page('2026-10-11','a6bda671-4179-5a29-a798-76357b42b497','photo_objet_moers')->>'externally_reported')::boolean,'manual completed day protected even when POS jobs pending');
SELECT fixture_assert(EXISTS(SELECT 1 FROM jsonb_array_elements(get_pos_daily_sales_summary('2026-10-08')->'entities') e WHERE e ?& ARRAY['source_item_count','export_line_count','mapping_revision']),'summary distinguishes receipts and item rows with approval revision');
SELECT fixture_assert(NOT invoice_snapshot_is_valid('[{"quantity":"NaN"}]','2026-10-08 12:00+07'),'missing/NaN financial fields do not pass SQL validation');
INSERT INTO meinvoice_jobs(id,order_id,source_system,source_snapshot,created_at,tax_entity_id,payment_method_snapshot,line_items_snapshot,payment_summary,snapshot_version)
VALUES('62000000-0000-0000-0000-000000000099',NULL,'photo_objet_moers','{"sale_date":"2026-10-11T12:00:00+07:00"}',now(),'a6bda671-4179-5a29-a798-76357b42b497','TM','[{"quantity":1}]','{}',2);
SELECT fixture_assert(sales_job_is_externally_reported('a6bda671-4179-5a29-a798-76357b42b497','photo_objet_moers',NULL,'{"sale_date":"2026-10-11T12:00:00+07:00"}'),'completion proof protects a pending Photo job by actual sale day');
DO $$BEGIN
 BEGIN UPDATE meinvoice_jobs SET line_items_snapshot='[{"quantity":2}]' WHERE id='62000000-0000-0000-0000-000000000099';RAISE EXCEPTION 'MANUAL_COMPLETED_MUTATION_ACCEPTED';
 EXCEPTION WHEN others THEN IF SQLERRM<>'MEINVOICE_EXTERNALLY_REPORTED_IMMUTABLE' THEN RAISE; END IF; END;
END $$;
SET request.jwt.claim.role='service_role';
SELECT fixture_assert(NOT EXISTS(SELECT 1 FROM claim_meinvoice_jobs('72000000-0000-0000-0000-000000000099',50,'a6bda671-4179-5a29-a798-76357b42b497') WHERE id='62000000-0000-0000-0000-000000000099'),'claim cannot reissue externally reported pending jobs');
SET request.jwt.claim.role='authenticated';
-- Same-day, same-time cursor ordering remains equivalent after predicate pushdown.
SELECT fixture_assert((SELECT jsonb_agg(order_id ORDER BY sold_at,order_id) FROM pos_daily_receipt_scope_page('2026-10-09','10000000-0000-0000-0000-000000000001',NULL,NULL,100))=
 (SELECT jsonb_agg(order_id ORDER BY sold_at,order_id) FROM(SELECT * FROM pos_daily_receipt_scope('2026-10-09') WHERE tax_entity_id='10000000-0000-0000-0000-000000000001' ORDER BY sold_at,order_id LIMIT 100)s),'pushed-down restaurant page preserves historical scope and stable order');
SELECT fixture_assert(jsonb_array_length(approve_menu_invoice_profile_v3(md5('fixture-menu-3')::uuid,'Current approved name','Phần',now()-interval '1 second',NULL,'fixture-menu-current-v3','synthetic menu editor')->'profiles')=1,'single editor approval uses same versioned batch contract');
SELECT fixture_assert((SELECT invoice_name_vi='Current approved name' AND invoice_unit_name='Phần' AND vat_rate=8 FROM menu_items WHERE id=md5('fixture-menu-3')::uuid),'current approval refreshes menu description/unit without changing VAT');
DO $$DECLARE before text; after text; BEGIN
 before:=pos_sales_export_source_revision('2026-10-08','10000000-0000-0000-0000-000000000001');
 UPDATE order_items SET quantity=2 WHERE id='42000000-0000-0000-0000-000000000001';
 after:=pos_sales_export_source_revision('2026-10-08','10000000-0000-0000-0000-000000000001');
 PERFORM fixture_assert(before<>after,'same-gross quantity edit changes source fingerprint');
 UPDATE order_items SET quantity=1 WHERE id='42000000-0000-0000-0000-000000000001';
 PERFORM fixture_assert(before=pos_sales_export_source_revision('2026-10-08','10000000-0000-0000-0000-000000000001'),'unchanged source fingerprint is stable');
 PERFORM fixture_assert(get_pos_daily_sales_export_page('2026-10-08','10000000-0000-0000-0000-000000000001','restaurant_pos')->>'source_revision'=before,'page and source checksum share statement snapshot');
END $$;
