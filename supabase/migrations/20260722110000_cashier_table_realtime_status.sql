-- Cashier/waiter table and payment surfaces subscribe to these operational
-- tables. Without publication membership, a channel can report SUBSCRIBED
-- while never receiving the Postgres changes, leaving the UI stale until a
-- manual refresh.

DO $migration$
DECLARE
  v_table_name text;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication
    WHERE pubname = 'supabase_realtime'
  ) THEN
    RAISE NOTICE 'supabase_realtime publication is not available; skipping';
    RETURN;
  END IF;

  FOREACH v_table_name IN ARRAY ARRAY[
    'tables',
    'orders',
    'order_items',
    'payments'
  ]
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = v_table_name
    ) THEN
      EXECUTE format(
        'ALTER PUBLICATION supabase_realtime ADD TABLE public.%I',
        v_table_name
      );
    END IF;
  END LOOP;
END
$migration$;
