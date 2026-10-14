-- Local fixture dependencies omitted by the historical procurement harness.
CREATE TABLE public.pos_live_events(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,restaurant_id uuid,domain text,source_table text,event_type text,occurred_at timestamptz DEFAULT now());
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS full_name text;
CREATE TABLE IF NOT EXISTS auth.users(id uuid PRIMARY KEY);
INSERT INTO auth.users(id) SELECT auth_id FROM public.users WHERE auth_id IS NOT NULL ON CONFLICT DO NOTHING;

ALTER TABLE public.user_store_access ADD COLUMN source_type text NOT NULL DEFAULT 'direct';
CREATE UNIQUE INDEX IF NOT EXISTS fixture_store_access_key ON public.user_store_access(user_id,store_id,source_type);

CREATE FUNCTION public.admin_get_store_workforce_readiness(uuid) RETURNS jsonb LANGUAGE sql AS $$ SELECT '{}'::jsonb $$;
CREATE FUNCTION public.require_workforce_manager(uuid) RETURNS public.users LANGUAGE sql AS $$ SELECT u FROM public.users u WHERE u.auth_id=auth.uid() LIMIT 1 $$;
ALTER TABLE public.brands ADD COLUMN management_model text,ADD COLUMN brand_manager_slots integer;
CREATE TABLE public.store_employees(store_id uuid,is_active boolean);

INSERT INTO public.tax_entity(id) SELECT DISTINCT tax_entity_id FROM public.restaurants WHERE tax_entity_id IS NOT NULL ON CONFLICT DO NOTHING;
