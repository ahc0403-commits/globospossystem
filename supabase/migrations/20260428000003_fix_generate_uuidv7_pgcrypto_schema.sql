BEGIN;

CREATE OR REPLACE FUNCTION public.generate_uuidv7()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  ts_ms   bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  rand_b  bytea  := extensions.gen_random_bytes(10);
  g1      text;
  g2      text;
  g3      text;
  vbyte   int;
  g4      text;
  g5      text;
BEGIN
  g1 := lpad(to_hex((ts_ms >> 16) & x'ffffffff'::bigint), 8, '0');
  g2 := lpad(to_hex(ts_ms & x'ffff'::bigint), 4, '0');
  g3 := '7' || substr(encode(rand_b, 'hex'), 1, 3);
  vbyte := (get_byte(rand_b, 2) & x'3f'::int) | x'80'::int;
  g4 := lpad(to_hex(vbyte), 2, '0') || substr(encode(rand_b, 'hex'), 7, 2);
  g5 := substr(encode(rand_b, 'hex'), 9, 12);
  RETURN g1 || '-' || g2 || '-' || g3 || '-' || g4 || '-' || g5;
END;
$$;

COMMIT;
