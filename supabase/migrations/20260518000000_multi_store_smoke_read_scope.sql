BEGIN;

DROP POLICY IF EXISTS restaurants_select_policy ON public.restaurants;

CREATE POLICY restaurants_select_policy ON public.restaurants
  FOR SELECT TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = restaurants.id
    )
  );

DROP POLICY IF EXISTS tables_select_policy ON public.tables;

CREATE POLICY tables_select_policy ON public.tables
  FOR SELECT TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = tables.restaurant_id
    )
  );

DROP POLICY IF EXISTS menu_categories_select_policy ON public.menu_categories;

CREATE POLICY menu_categories_select_policy ON public.menu_categories
  FOR SELECT TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = menu_categories.restaurant_id
    )
  );

DROP POLICY IF EXISTS menu_items_select_policy ON public.menu_items;

CREATE POLICY menu_items_select_policy ON public.menu_items
  FOR SELECT TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = menu_items.restaurant_id
    )
  );

DROP POLICY IF EXISTS brands_scoped_read ON public.brands;

CREATE POLICY brands_scoped_read ON public.brands
  FOR SELECT TO authenticated
  USING (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.auth_id = auth.uid()
        AND u.role IN ('admin', 'super_admin')
    )
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_brands(auth.uid()) b(brand_id)
      WHERE b.brand_id = brands.id
    )
  );

COMMIT;
