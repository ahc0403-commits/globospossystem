\set ON_ERROR_STOP on
BEGIN;
SELECT set_config('request.jwt.claim.sub',test_uuid(101)::text,true);
DO $$DECLARE line uuid; BEGIN
 line:=test_line(990001,2,2,1,1);
 BEGIN
  PERFORM kds_record_station_progress_v3(line,'base','floor_served',1,gen_random_uuid());
  RAISE EXCEPTION 'EXPECTED_PARTIAL_REJECTION';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='EMERGENCY_QUANTITY_CHAIN_VIOLATION',SQLERRM; END;
 RAISE NOTICE 'BASELINE_REPRODUCED: ready single unit rejected while another unit is cooking';
END$$;
ROLLBACK;
