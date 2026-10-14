SET fixture.super_admin='true';
SET request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
CREATE TEMP TABLE policy_fixture(id uuid);
INSERT INTO policy_fixture SELECT (approve_invoice_mapping_policy('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','fixture-policy-v1',
 '{"category_units":{"21000000-0000-0000-0000-000000000001":"Phần","21000000-0000-0000-0000-000000000002":"Suất"},"menu_units":{},"combo_unit":"Bộ"}','Synthetic authenticated policy approval')->>'id')::uuid;
SELECT fixture_assert((approve_invoice_mapping_policy('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','fixture-policy-v1',
 '{"category_units":{"21000000-0000-0000-0000-000000000001":"Phần","21000000-0000-0000-0000-000000000002":"Suất"},"menu_units":{},"combo_unit":"Bộ"}','Synthetic authenticated policy approval')->>'id')::uuid=(SELECT id FROM policy_fixture),'same policy retry retains actual ID');
SET fixture.super_admin='false';
DO $$BEGIN
 BEGIN PERFORM approve_invoice_mapping_policy('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','illegal','{}','illegal');
 RAISE EXCEPTION 'UNAUTHORIZED_POLICY_ACCEPTED'; EXCEPTION WHEN others THEN IF SQLERRM<>'INVOICE_PROFILE_FORBIDDEN' THEN RAISE; END IF; END;
END $$;
-- One INSERT statement has 205 never-sold menus; the transition trigger splits
-- them into three set-based batches rather than making 205 approval calls.
INSERT INTO menu_items(id,restaurant_id,category_id,name_vi,name,vat_rate)
SELECT md5('new-invoice-menu-'||n)::uuid,'20000000-0000-0000-0000-000000000001','21000000-0000-0000-0000-000000000001','Món mới '||n,'New menu '||n,8 FROM generate_series(1,205)n;
SELECT pg_stat_force_next_flush();
SELECT fixture_assert((SELECT calls=3 FROM pg_stat_user_functions WHERE schemaname='pos_invoice_private' AND funcname='apply_policy_batch'),'205 registrations execute exactly three policy batches');
SELECT fixture_assert((SELECT count(*)=205 FROM menu_invoice_profiles WHERE policy_id=(SELECT id FROM policy_fixture)),'every never-sold menu gets a real policy profile');
SELECT fixture_assert((SELECT bool_and(invoice_name_vi=name_vi AND invoice_unit_name='Phần') FROM menu_items WHERE name LIKE 'New menu %'),'menu display synchronized atomically');
SELECT fixture_assert((SELECT bool_and(approved_by='00000000-0000-0000-0000-000000000001'::uuid AND recorded_by=auth.uid() AND effective_to IS NULL AND source_reference LIKE '%policy:%') FROM menu_invoice_profiles WHERE policy_id=(SELECT id FROM policy_fixture)),'real policy provenance, actor and indefinite validity');
DO $$DECLARE before_count integer; before_id uuid; BEGIN
 SELECT count(*) INTO before_count FROM menu_invoice_profiles;
 UPDATE menu_items SET name=name WHERE name LIKE 'New menu %';
 PERFORM fixture_assert((SELECT count(*)=before_count FROM menu_invoice_profiles),'unrelated updates add no approvals');
 SELECT id INTO before_id FROM menu_invoice_profiles WHERE menu_item_id=md5('new-invoice-menu-1')::uuid AND effective_to IS NULL;
 UPDATE menu_items SET name_vi='Món mới đã sửa' WHERE id=md5('new-invoice-menu-1')::uuid;
 PERFORM fixture_assert((SELECT invoice_name_vi='Món mới đã sửa' AND id<>before_id FROM menu_invoice_profiles WHERE menu_item_id=md5('new-invoice-menu-1')::uuid AND effective_to IS NULL),'name edit versions actual mapping');
 PERFORM fixture_assert((SELECT effective_to IS NOT NULL FROM menu_invoice_profiles WHERE id=before_id),'earlier period closed without overwriting name');
 UPDATE menu_items SET is_combo=true WHERE id=md5('new-invoice-menu-2')::uuid;
 PERFORM fixture_assert((SELECT invoice_unit_name='Bộ' FROM menu_items WHERE id=md5('new-invoice-menu-2')::uuid),'combo policy unit distinct from food');
 UPDATE menu_items SET category_id='21000000-0000-0000-0000-000000000002' WHERE id=md5('new-invoice-menu-3')::uuid;
 PERFORM fixture_assert((SELECT invoice_unit_name='Suất' FROM menu_items WHERE id=md5('new-invoice-menu-3')::uuid),'drink unit distinct from food');
 BEGIN INSERT INTO menu_items(id,restaurant_id,category_id,name_vi,name,vat_rate) VALUES(md5('unmapped-category')::uuid,'20000000-0000-0000-0000-000000000001',NULL,'Unknown','Unknown',8);
 RAISE EXCEPTION 'UNKNOWN_UNIT_ACCEPTED'; EXCEPTION WHEN others THEN IF SQLERRM<>'INVOICE_POLICY_MENU_INFORMATION_REQUIRED' THEN RAISE; END IF; END;
 PERFORM fixture_assert(NOT EXISTS(SELECT 1 FROM menu_items WHERE id=md5('unmapped-category')::uuid),'missing rule rolls back menu insertion');
END $$;
SET fixture.super_admin='true';
DO $$BEGIN
 BEGIN PERFORM approve_invoice_mapping_policy('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','invalid-unit',
 '{"category_units":{"21000000-0000-0000-0000-000000000001":null},"menu_units":{},"combo_unit":"Bộ"}','Invalid fixture');
 RAISE EXCEPTION 'NON_STRING_POLICY_ACCEPTED'; EXCEPTION WHEN others THEN IF SQLERRM<>'INVOICE_POLICY_RULES_INVALID' THEN RAISE; END IF; END;
END $$;
DO $$DECLARE page jsonb; second jsonb; a jsonb; b jsonb; ids uuid[]; BEGIN
 page:=get_invoice_mapping_catalog('10000000-0000-0000-0000-000000000001');
 PERFORM fixture_assert(jsonb_array_length(page->'rows')=100 AND (page->>'total_count')::integer>205,'catalog covers all master menus with bounded page');
 second:=get_invoice_mapping_catalog('10000000-0000-0000-0000-000000000001',(page->'rows'->99->>'id')::uuid);
 PERFORM fixture_assert((second->>'total_count')::integer=(page->>'total_count')::integer AND jsonb_array_length(second->'rows')=100,'stable catalog pagination beyond 100');
 ids:=ARRAY[md5('new-invoice-menu-10')::uuid];
 a:=apply_invoice_mapping_policy_batch('20000000-0000-0000-0000-000000000001',ids);
 b:=apply_invoice_mapping_policy_batch('20000000-0000-0000-0000-000000000001',ids);
 PERFORM fixture_assert(a=b AND a->>'unchanged_count'='1','automatic mapping retry creates no new version');
 UPDATE menu_items SET invoice_name_vi=NULL,invoice_unit_name=NULL WHERE id=ids[1];
 a:=apply_invoice_mapping_policy_batch('20000000-0000-0000-0000-000000000001',ids);
 PERFORM fixture_assert(a->>'unchanged_count'='1' AND (SELECT invoice_name_vi=name_vi AND invoice_unit_name='Phần' FROM menu_items WHERE id=ids[1]),'display mismatch repaired from actual profile without duplicate approval');
 BEGIN PERFORM apply_invoice_mapping_policy_batch('20000000-0000-0000-0000-000000000002',ids);
 RAISE EXCEPTION 'CROSS_STORE_ACCEPTED'; EXCEPTION WHEN others THEN IF SQLERRM NOT IN('INVOICE_POLICY_REQUIRED','INVOICE_PROFILE_SCOPE_INVALID') THEN RAISE; END IF; END;
 BEGIN PERFORM apply_invoice_mapping_policy_batch('20000000-0000-0000-0000-000000000001',ARRAY(SELECT md5('new-invoice-menu-'||n)::uuid FROM generate_series(1,101)n));
 RAISE EXCEPTION 'OVERSIZED_RPC_ACCEPTED'; EXCEPTION WHEN others THEN IF SQLERRM<>'INVOICE_PROFILE_BATCH_INVALID' THEN RAISE; END IF; END;
END $$;
SELECT fixture_assert((SELECT bool_and(effective_from<=statement_timestamp()+interval '1 day' AND effective_to IS NULL) FROM menu_invoice_profiles WHERE policy_id=(SELECT id FROM policy_fixture) AND effective_to IS NULL),'NULL validity remains valid tomorrow');
-- Real source resolution, rather than invented profile metadata in a fixture.
INSERT INTO orders VALUES(md5('invoice-first-sale')::uuid,'completed','dine_in');
INSERT INTO payments(order_id,restaurant_id,created_at,amount_portion,amount,method,is_revenue) VALUES(md5('invoice-first-sale')::uuid,'20000000-0000-0000-0000-000000000001',clock_timestamp(),108,108,'BANKTRANSFER',true);
INSERT INTO order_items(id,order_id,menu_item_id,display_name,quantity,unit_price,total_amount_ex_tax,vat_rate,vat_amount,paying_amount_inc_tax,created_at,status,item_type)
VALUES(md5('invoice-first-item')::uuid,md5('invoice-first-sale')::uuid,md5('new-invoice-menu-10')::uuid,'First sale',1,100,100,8,8,108,clock_timestamp(),'served','menu_item');
DO $$DECLARE line jsonb; BEGIN
 SELECT line_items->0 INTO line FROM pos_restaurant_receipt_rows_fresh((clock_timestamp() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,ARRAY[md5('invoice-first-sale')::uuid]);
 PERFORM fixture_assert(line->>'invoice_profile_id' IS NOT NULL AND (SELECT policy_id=(SELECT id FROM policy_fixture) FROM menu_invoice_profiles WHERE id=(line->>'invoice_profile_id')::uuid),'first sale resolves the real automatically created profile');
 PERFORM fixture_assert(NOT EXISTS(SELECT 1 FROM unnest(ARRAY['invoice_name_vi','misa_unit_name','invoice_profile_id','invoice_approval_type','invoice_mapping_version','invoice_effective_from','invoice_store_id','invoice_source_reference']) field WHERE nullif(line->>field,'') IS NULL),'all eight fields reach first sale');
END $$;
INSERT INTO meinvoice_jobs(id,order_id,source_system,created_at,tax_entity_id,payment_method_snapshot,line_items_snapshot,payment_summary,snapshot_version)
VALUES(md5('invoice-first-job')::uuid,md5('invoice-first-sale')::uuid,'restaurant_pos',clock_timestamp(),'10000000-0000-0000-0000-000000000001','CK','[{"order_item_id":"missing-mapping"}]','[]',2);
SELECT fixture_assert((SELECT status='pending_manual_config' AND manual_action_type='invoice_mapping_required' FROM meinvoice_jobs WHERE id=md5('invoice-first-job')::uuid),'missing mapping is async review without blocking source payment');
SELECT fixture_assert(revalidate_meinvoice_export_snapshots((clock_timestamp() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,'10000000-0000-0000-0000-000000000001',ARRAY[md5('invoice-first-sale')::uuid])->>'updated_count'='1','real approval revalidates unissued job');
SELECT fixture_assert((SELECT status='pending' AND manual_action_type IS NULL FROM meinvoice_jobs WHERE id=md5('invoice-first-job')::uuid),'completed metadata releases mapping review');
DO $$DECLARE result jsonb; BEGIN
 result:=to_jsonb(admin_create_menu_item_with_invoice('20000000-0000-0000-0000-000000000001','21000000-0000-0000-0000-000000000001','Single unit','Một cái','Single unit',NULL,100,0,true,NULL,'Cái'));
 PERFORM fixture_assert(result->>'invoice_unit_name'='Cái' AND EXISTS(SELECT 1 FROM menu_invoice_profiles WHERE menu_item_id=(result->>'id')::uuid AND effective_to IS NULL),'explicit actual unit is mapped in one registration transaction');
END $$;
DO $$DECLARE menu_id uuid; BEGIN
 menu_id:=md5('new-invoice-menu-20')::uuid;
 PERFORM approve_menu_invoice_profile_v3(menu_id,'Một cái thực tế','Cái',clock_timestamp(),NULL,'manual-unit-fixture','Synthetic actual unit approval');
 UPDATE menu_items SET name_vi='Tên sửa lần một' WHERE id=menu_id;
 UPDATE menu_items SET name_vi='Tên sửa lần hai' WHERE id=menu_id;
 PERFORM fixture_assert((SELECT invoice_unit_name='Cái' FROM menu_items WHERE id=menu_id),'individual manual units survive multiple automatic name versions');
 INSERT INTO meinvoice_jobs(id,order_id,source_system,created_at,tax_entity_id,line_items_snapshot,status,manual_action_type)
 VALUES(md5('malformed-invoice-job')::uuid,md5('invoice-first-sale')::uuid,'restaurant_pos',clock_timestamp(),'10000000-0000-0000-0000-000000000001','{}','pending_manual_config','invoice_mapping_required');
 PERFORM fixture_assert((SELECT status='pending_manual_config' FROM meinvoice_jobs WHERE id=md5('malformed-invoice-job')::uuid),'malformed snapshot does not throw from mapping review trigger');
END $$;
-- Test both deployed additive and repository replacement import histories.
DO $$DECLARE result jsonb; payload jsonb; categories jsonb; items jsonb; BEGIN
 SELECT jsonb_agg(jsonb_build_object('source_row',n,'category_name','Food','category_sort_order',0,'name','Imported '||n,'name_vi','Món nhập '||n,'invoice_sale_unit','Phần','description',NULL,'price',100,'is_available',true,'is_visible_public',false,'sort_order',n,'beverage_sugar_tax_class','not_applicable','sugar_g_per_100ml',NULL,'tax_basis_note',NULL)) INTO payload FROM generate_series(1,150)n;
 result:=admin_import_menu_items('20000000-0000-0000-0000-000000000001',payload);
 PERFORM fixture_assert((SELECT count(*)=150 AND bool_and(invoice_name_vi=name_vi AND invoice_unit_name='Phần') FROM menu_items WHERE name LIKE 'Imported %'),'all imported never-sold menus mapped with provided Vietnamese names');
 SELECT jsonb_agg(jsonb_build_object('store_id',restaurant_id,'category_id',id,'name_ko',name,'name_vi',name_vi,'name_en',name,'sort_order',sort_order)) INTO categories FROM menu_categories WHERE restaurant_id='20000000-0000-0000-0000-000000000001' AND is_active;
 SELECT jsonb_agg(jsonb_build_object('store_id',restaurant_id,'category_id',category_id,'item_id',id,'name_ko',name,'name_vi',name_vi||' sửa','name_en',name,'price',price,'is_available',true,'is_visible_public',false,'sort_order',sort_order)) INTO items FROM menu_items WHERE name LIKE 'Imported %';
 result:=admin_update_menu_workbook_i18n('20000000-0000-0000-0000-000000000001',categories,items);
 PERFORM fixture_assert((SELECT count(*)=150 AND bool_and(invoice_name_vi=name_vi AND invoice_name_vi LIKE '% sửa') FROM menu_items WHERE name LIKE 'Imported %'),'round-trip updates all real profiles in bounded batches');
END $$;
SELECT pg_stat_force_next_flush();
SELECT funcname,calls,total_time FROM pg_stat_user_functions WHERE schemaname='pos_invoice_private' ORDER BY funcname;
SELECT 'FULL_MENU_INVOICE_MAPPING_SQL=PASS';
