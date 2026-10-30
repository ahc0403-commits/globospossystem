-- Network-report fixture only. Other financial fixtures define their own stores.
DO $$ BEGIN
  IF current_database() <> 'payroll_test' THEN RAISE EXCEPTION 'TEST_DATABASE_REQUIRED'; END IF;
END $$;
CREATE TABLE public.restaurants (
  id uuid PRIMARY KEY, name text NOT NULL,
  is_active boolean NOT NULL DEFAULT true, tax_entity_id uuid
);
INSERT INTO public.restaurants(id,name)
SELECT ('10000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid,
       'Fixture store ' || i FROM generate_series(1,500) i;
ALTER TABLE public.restaurants ENABLE ROW LEVEL SECURITY;
CREATE POLICY restaurants_read ON public.restaurants FOR SELECT TO authenticated
  USING (public.fixture_can_read(id));
GRANT SELECT ON public.restaurants TO authenticated;
