INSERT INTO restaurants(id,name) VALUES
 ('20000000-0000-4000-8000-000000000001','Paperless'),
 ('20000000-0000-4000-8000-000000000002','Other tenant'),
 ('20000000-0000-4000-8000-000000000003','Bulk fixture');
INSERT INTO users(id,auth_id,role) VALUES
 ('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','super_admin'),
 ('10000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002','store_admin'),
 ('10000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000003','cashier');
INSERT INTO fixture_store_access VALUES
 ('10000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000001'),
 ('10000000-0000-4000-8000-000000000003','20000000-0000-4000-8000-000000000001');
CREATE TABLE setup_inputs AS SELECT
 '[{"table_number":"101","seat_count":4,"floor_label":"1F"}]'::jsonb AS tables,
 '[{"name":"Cashier Receipt","physical_name":"Cashier","purpose":"receipt","physical_slot":"cashier","connection":"usb","usb_printer_name":"XP-80C","ip":"","port":9100}]'::jsonb AS receipt;
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',false);
DO $$ BEGIN
 PERFORM setup_assert((SELECT NOT (admin_validate_store_opening_config_v2('20000000-0000-4000-8000-000000000001',tables,receipt,'paperless')->>'valid')::boolean FROM setup_inputs),'admin cannot silently change owner-only operation mode');
 BEGIN
  PERFORM admin_get_store_opening_readiness('20000000-0000-4000-8000-000000000002');
  RAISE EXCEPTION 'tenant boundary failed';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'ADMIN_MUTATION_FORBIDDEN' THEN RAISE; END IF; END;
END $$;
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000003',false);
DO $$ BEGIN
 BEGIN
  PERFORM admin_apply_store_opening_config_v2('20000000-0000-4000-8000-000000000001','[]','[]','paperless');
  RAISE EXCEPTION 'cashier authorization failed';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'ADMIN_MUTATION_FORBIDDEN' THEN RAISE; END IF; END;
END $$;
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',false);
SELECT setup_assert((admin_validate_store_opening_config_v2('20000000-0000-4000-8000-000000000001',tables,receipt,'paperless')->>'valid')::boolean,'paperless validates one USB receipt and no LAN IP') FROM setup_inputs;
SELECT admin_apply_store_opening_config_v2('20000000-0000-4000-8000-000000000001',tables,receipt,'paperless') FROM setup_inputs;
SELECT setup_assert((SELECT count(*)=1 FROM printer_destinations WHERE restaurant_id='20000000-0000-4000-8000-000000000001'),'paperless creates exactly one route');
SELECT setup_assert((SELECT count(*)=1 FROM printer_endpoints WHERE is_active AND endpoint_type='usb' AND device_name='XP-80C'),'USB name saved');
SELECT setup_assert(NOT EXISTS(SELECT 1 FROM printer_endpoints WHERE is_active AND endpoint_type<>'usb'),'compatibility loopback is not an active network endpoint');
SELECT setup_assert(get_store_fulfillment_mode('20000000-0000-4000-8000-000000000001')='paperless','mode applied through existing owner contract');
SELECT setup_assert((SELECT count(*)=1 FROM emergency_fulfillment_sessions WHERE status='active'),'paperless KDS session created');
CREATE TABLE setup_before AS SELECT id,updated_at FROM printer_destinations;
SELECT admin_apply_store_opening_config_v2('20000000-0000-4000-8000-000000000001',tables,receipt,'paperless') FROM setup_inputs;
SELECT setup_assert((SELECT bool_and(d.updated_at=b.updated_at) FROM printer_destinations d JOIN setup_before b USING(id)),'identical apply retains IDs and test timestamps');
SELECT setup_assert((SELECT count(*)=1 FROM fulfillment_mode_changes),'identical apply does not duplicate mode change');
INSERT INTO print_jobs(restaurant_id,destination_id,copy_type,payload,status)
 SELECT restaurant_id,id,'receipt','{"printed_reason":"test_print"}','done' FROM printer_destinations;
SELECT setup_assert((admin_get_store_opening_readiness('20000000-0000-4000-8000-000000000001')->>'ready')::boolean,'one receipt test completes paperless readiness');
SELECT setup_assert(jsonb_array_length(admin_get_store_opening_readiness('20000000-0000-4000-8000-000000000001')->'tests')=1,'paperless readiness requires one test');
-- Endpoint-only change must invalidate the old successful test.
SELECT admin_apply_store_opening_config_v2('20000000-0000-4000-8000-000000000001',tables,jsonb_set(receipt,'{0,usb_printer_name}','"XP-80C (Copy 1)"'),'paperless') FROM setup_inputs;
SELECT setup_assert(NOT (admin_get_store_opening_readiness('20000000-0000-4000-8000-000000000001')->>'ready')::boolean,'USB name change invalidates old tests');
DO $$ DECLARE v_before int; BEGIN
 SELECT count(*) INTO v_before FROM tables;
 BEGIN
  PERFORM admin_apply_store_opening_config_v2('20000000-0000-4000-8000-000000000001',
   '[{"table_number":"invalid-write","seat_count":4,"floor_label":"1F"}]',
   '[{"name":"Bad","physical_slot":"cashier","purpose":"receipt","connection":"usb","usb_printer_name":""}]','paperless');
  RAISE EXCEPTION 'invalid USB accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'STORE_SETUP_CONFIG_INVALID' THEN RAISE; END IF; END;
 PERFORM setup_assert((SELECT count(*)=v_before FROM tables),'invalid USB blocks every write atomically');
END $$;
UPDATE tables SET status='occupied' WHERE table_number='101';
DO $$ BEGIN
 BEGIN
  PERFORM admin_apply_store_opening_config_v2('20000000-0000-4000-8000-000000000001',
   '[{"table_number":"101","seat_count":5,"floor_label":"1F"}]',
   (SELECT receipt FROM setup_inputs),'paperless');
  RAISE EXCEPTION 'occupied table changed';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'STORE_SETUP_CONFIG_INVALID' THEN RAISE; END IF; END;
 PERFORM setup_assert((SELECT seat_count=4 FROM tables WHERE table_number='101'),'occupied table preserved');
END $$;
UPDATE tables SET status='available';
INSERT INTO emergency_fulfillment_items(session_id,ordered_quantity,floor_served_quantity)
 SELECT id,2,1 FROM emergency_fulfillment_sessions WHERE status='active';
ALTER TABLE setup_inputs ADD COLUMN physical jsonb;
UPDATE setup_inputs SET physical = receipt || jsonb_build_array(
 receipt->0 || jsonb_build_object('name','G via Cashier','purpose','floor','floor_label','1F'),
 jsonb_build_object('name','Kitchen','physical_slot','kitchen','purpose','kitchen','connection','wired','ip','192.168.1.11','port',9100),
 jsonb_build_object('name','1F','physical_slot','floor2','purpose','floor','floor_label','2F','connection','wired','ip','192.168.1.12','port',9100),
 jsonb_build_object('name','2F','physical_slot','floor3','purpose','floor','floor_label','3F','connection','wireless','ip','192.168.1.13','port',9100));
SELECT setup_assert(NOT (admin_validate_store_opening_config_v2('20000000-0000-4000-8000-000000000001',tables,physical,'paperless')->>'valid')::boolean,'paperless rejects operational print routes') FROM setup_inputs;
SELECT setup_assert(NOT (admin_validate_store_opening_config_v2('20000000-0000-4000-8000-000000000001',tables,receipt,'pos_print')->>'valid')::boolean,'physical operation still requires kitchen route') FROM setup_inputs;
SELECT admin_apply_store_opening_config_v2('20000000-0000-4000-8000-000000000001',tables,physical,'pos_print') FROM setup_inputs;
SELECT setup_assert((SELECT count(*)=5 AND count(DISTINCT physical_printer_id)=4 FROM printer_destinations WHERE is_active),'physical setup has four printers and five routes');
SELECT setup_assert((SELECT count(DISTINCT physical_printer_id)=1 FROM printer_destinations WHERE purpose='receipt' OR floor_label='1F'),'cashier and G share one physical USB printer');
SELECT setup_assert((SELECT count(*)=1 FROM emergency_fulfillment_sessions WHERE status='active'),'switch to printing preserves draining paperless orders');
INSERT INTO print_jobs(restaurant_id,destination_id,copy_type,payload,status)
 SELECT restaurant_id,id,purpose,'{"printed_reason":"test_print"}','done' FROM printer_destinations;
SELECT setup_assert((admin_get_store_opening_readiness('20000000-0000-4000-8000-000000000001')->>'ready')::boolean,'physical operation requires successful active routes');
SELECT admin_apply_store_opening_config_v2('20000000-0000-4000-8000-000000000001',tables,receipt,'paperless') FROM setup_inputs;
SELECT setup_assert((SELECT count(*)=5 FROM printer_destinations WHERE is_active),'switch to paperless preserves unspecified route records');
SELECT setup_assert(jsonb_array_length(admin_get_store_opening_readiness('20000000-0000-4000-8000-000000000001')->'tests')=1,'preserved kitchen and floor routes do not block paperless readiness');
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',false);
SELECT setup_assert((admin_validate_store_opening_config_v2('20000000-0000-4000-8000-000000000001',tables,receipt,'paperless')->>'valid')::boolean,'store admin can configure current operation mode') FROM setup_inputs;
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',false);
DO $$ DECLARE ids uuid[]; request_id uuid := gen_random_uuid(); first_jobs jsonb; again_jobs jsonb; count_before int; BEGIN
 SELECT array_agg(id ORDER BY id) INTO ids FROM printer_destinations WHERE restaurant_id='20000000-0000-4000-8000-000000000001' AND is_active;
 first_jobs := admin_enqueue_store_opening_tests('20000000-0000-4000-8000-000000000001',ids,request_id);
 again_jobs := admin_enqueue_store_opening_tests('20000000-0000-4000-8000-000000000001',ids,request_id);
 PERFORM setup_assert(jsonb_array_length(first_jobs)=5 AND first_jobs=again_jobs,'batch test enqueue is idempotent and returns every job ID');
 SELECT count(*) INTO count_before FROM print_jobs;
 BEGIN
  PERFORM admin_enqueue_store_opening_tests('20000000-0000-4000-8000-000000000001',ids || gen_random_uuid(),gen_random_uuid());
  RAISE EXCEPTION 'invalid batch destination accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'STORE_SETUP_DESTINATION_NOT_APPLIED' THEN RAISE; END IF; END;
 PERFORM setup_assert((SELECT count(*)=count_before FROM print_jobs),'invalid destination rolls back entire batch enqueue');
END $$;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SELECT pg_stat_statements_reset();
\timing on
SELECT admin_apply_store_opening_config_v2('20000000-0000-4000-8000-000000000003',
 (SELECT jsonb_agg(jsonb_build_object('table_number',n::text,'seat_count',4,'floor_label','1F')) FROM generate_series(1,500) n),
 (SELECT receipt FROM setup_inputs),'paperless');
\timing off
SELECT setup_assert((SELECT count(*)=500 FROM tables WHERE restaurant_id='20000000-0000-4000-8000-000000000003'),'500 tables applied in a batch');
SELECT calls,rows,left(query,180) AS statement FROM pg_stat_statements WHERE calls>30 ORDER BY calls DESC;
SELECT setup_assert(NOT EXISTS(SELECT 1 FROM pg_stat_statements WHERE calls>30 AND query NOT LIKE '%current_setting%' AND query NOT LIKE 'SELECT 1 FROM ONLY %'),'application SQL statements do not grow per table (indexed FK checks excluded)');
SELECT calls,rows,round(total_exec_time::numeric,2) AS total_ms,left(query,110) AS statement FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 6;
SELECT 'STORE_OPENING_PRINTER_MODES=PASS';
