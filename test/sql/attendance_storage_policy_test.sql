SET ROLE authenticated;
SET request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
INSERT INTO storage.objects VALUES ('attendance-photos',
  '00000000-0000-0000-0000-000000000101/employee/after.jpg');
DO $$
BEGIN
  BEGIN
    INSERT INTO storage.objects VALUES ('attendance-photos',
      '00000000-0000-0000-0000-000000000102/employee/wrong-store.jpg');
    RAISE EXCEPTION 'Cross-store upload unexpectedly allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    INSERT INTO storage.objects VALUES ('inventory-receipt-statements',
      '00000000-0000-0000-0000-000000000101/employee/not-orderer.pdf');
    RAISE EXCEPTION 'Attendance user gained procurement access';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SET request.jwt.claim.sub = '00000000-0000-0000-0000-000000000002';
SET fixture.receiver_assigned = 'false';
DO $$
BEGIN
  BEGIN
    INSERT INTO storage.objects VALUES ('inventory-receipt-statements',
      '00000000-0000-0000-0000-000000000101/orderer/unassigned.pdf');
    RAISE EXCEPTION 'Private predecessor bypassed current approval rules';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SET fixture.receiver_assigned = 'true';
INSERT INTO storage.objects VALUES ('inventory-receipt-statements',
  '00000000-0000-0000-0000-000000000101/orderer/assigned.pdf');
RESET ROLE;
SET ROLE anon;
DO $$
BEGIN
  BEGIN
    INSERT INTO storage.objects VALUES ('attendance-photos',
      '00000000-0000-0000-0000-000000000101/anonymous.jpg');
    RAISE EXCEPTION 'Anonymous upload unexpectedly allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
DO $$
BEGIN
  IF (SELECT count(*) FROM storage.objects) <> 2 THEN
    RAISE EXCEPTION 'Unexpected upload count after policy repair';
  END IF;
END $$;
