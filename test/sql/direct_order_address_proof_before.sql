\set ON_ERROR_STOP on
SELECT set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',false);
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}',false);
DO $$
DECLARE f jsonb; sid uuid; secret text; payload jsonb;
BEGIN
 IF current_database()<>'codex_direct_photo' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF;
 f:=photo_test.create_request();
 BEGIN
  INSERT INTO public.direct_order_request_addresses(request_id,restaurant_id,customer_name,customer_phone,
   formatted_address,detail_address,address_source,location_verified)
  VALUES((f->>'request_id')::uuid,(f->>'store_id')::uuid,'Fixture','0901234567','123 Test street','','manual',false);
  RAISE EXCEPTION 'EXPECTED_ADDRESS_CONSTRAINT_FAILURE';
 EXCEPTION WHEN check_violation THEN
  IF SQLERRM NOT LIKE '%direct_order_address_detail_valid%' THEN RAISE; END IF;
 END;
 RAISE NOTICE 'OPTIONAL_ADDRESS_BEFORE=REPRODUCED actual_table_constraint';
END $$;
