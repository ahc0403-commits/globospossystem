-- 250: master_admin role support for Office DB
-- master_admin manages multiple POS restaurants via office_user_profiles scope
-- master_admin_restaurants stores cross-DB references (no FK to POS tables)

-- Junction: master_admin <-> POS restaurants (restaurant_id is cross-DB, no FK)
CREATE TABLE IF NOT EXISTS public.master_admin_restaurants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_auth_id UUID NOT NULL,
  restaurant_id UUID NOT NULL,
  granted_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_auth_id, restaurant_id)
);
CREATE INDEX IF NOT EXISTS idx_mar_user ON public.master_admin_restaurants(user_auth_id);
CREATE INDEX IF NOT EXISTS idx_mar_restaurant ON public.master_admin_restaurants(restaurant_id);
-- Helper: check if current user is master_admin (via office_user_profiles)
CREATE OR REPLACE FUNCTION public.is_master_admin()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS(
    SELECT 1 FROM public.office_user_profiles
    WHERE auth_id = auth.uid()
      AND account_level = 'master_admin'
  );
$$;
-- Helper: get restaurant IDs assigned to current master_admin
CREATE OR REPLACE FUNCTION public.get_master_admin_restaurant_ids()
RETURNS UUID[] LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT ARRAY(
    SELECT restaurant_id FROM public.master_admin_restaurants
    WHERE user_auth_id = auth.uid()
  );
$$;
-- RLS
ALTER TABLE public.master_admin_restaurants ENABLE ROW LEVEL SECURITY;
CREATE POLICY "platform_admin_all" ON public.master_admin_restaurants
  FOR ALL TO authenticated
  USING (
    EXISTS(
      SELECT 1 FROM public.office_user_profiles
      WHERE auth_id = auth.uid()
        AND account_level IN ('super_admin', 'platform_admin', 'office_admin')
    )
  );
CREATE POLICY "master_admin_own" ON public.master_admin_restaurants
  FOR SELECT TO authenticated
  USING (user_auth_id = auth.uid());
