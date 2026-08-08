\set ON_ERROR_STOP on

DO $verify$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.printer_destinations'::regclass
      AND conname = 'printer_destinations_ipv4_valid'
      AND convalidated
  ) THEN
    RAISE EXCEPTION 'PRINTER_DESTINATION_IPV4_CONSTRAINT_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.printer_destinations
    WHERE ip = '192.168.253'
  ) THEN
    RAISE EXCEPTION 'SECOND_FLOOR_PRINTER_IP_NOT_REPAIRED';
  END IF;
END;
$verify$;
