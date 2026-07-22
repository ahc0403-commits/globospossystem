DO $verification$
DECLARE
  v_missing_tables text[];
BEGIN
  SELECT array_agg(expected.table_name ORDER BY expected.table_name)
  INTO v_missing_tables
  FROM unnest(ARRAY['tables', 'orders', 'order_items', 'payments'])
    AS expected(table_name)
  WHERE NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables published
    WHERE published.pubname = 'supabase_realtime'
      AND published.schemaname = 'public'
      AND published.tablename = expected.table_name
  );

  IF coalesce(array_length(v_missing_tables, 1), 0) > 0 THEN
    RAISE EXCEPTION
      'CASHIER_TABLE_REALTIME_PUBLICATION_INCOMPLETE: %',
      array_to_string(v_missing_tables, ', ');
  END IF;
END
$verification$;

SELECT tablename
FROM pg_publication_tables
WHERE pubname = 'supabase_realtime'
  AND schemaname = 'public'
  AND tablename IN ('tables', 'orders', 'order_items', 'payments')
ORDER BY tablename;
