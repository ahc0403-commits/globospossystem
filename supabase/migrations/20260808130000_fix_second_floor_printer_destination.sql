BEGIN;

-- The 2F route was saved with a missing IPv4 octet (`192.168.253`). The
-- adjacent store printers use 192.168.1.251 through 192.168.1.254.
UPDATE public.printer_destinations
SET ip = '192.168.1.253',
    updated_at = now()
WHERE lower(name) = '2f'
  AND purpose = 'floor'
  AND upper(floor_label) = '2F'
  AND ip = '192.168.253';

ALTER TABLE public.printer_destinations
  DROP CONSTRAINT IF EXISTS printer_destinations_ipv4_valid;

ALTER TABLE public.printer_destinations
  ADD CONSTRAINT printer_destinations_ipv4_valid CHECK (
    CASE
      WHEN ip ~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' THEN
        split_part(ip, '.', 1)::int BETWEEN 0 AND 255
        AND split_part(ip, '.', 2)::int BETWEEN 0 AND 255
        AND split_part(ip, '.', 3)::int BETWEEN 0 AND 255
        AND split_part(ip, '.', 4)::int BETWEEN 0 AND 255
      ELSE false
    END
  );

COMMIT;
