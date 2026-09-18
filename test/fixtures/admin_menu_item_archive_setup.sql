ALTER TABLE public.users
  ALTER COLUMN id SET DEFAULT gen_random_uuid();

CREATE TABLE public.user_store_access (
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  store_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  is_primary boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  source_type text NOT NULL,
  PRIMARY KEY (user_id, store_id)
);

ALTER TABLE public.menu_categories
  ADD COLUMN sort_order integer NOT NULL DEFAULT 0,
  ADD COLUMN is_active boolean NOT NULL DEFAULT true;

ALTER TABLE public.menu_items
  ADD COLUMN is_available boolean NOT NULL DEFAULT true,
  ADD COLUMN is_visible_public boolean NOT NULL DEFAULT true,
  ADD COLUMN sort_order integer NOT NULL DEFAULT 0,
  ADD COLUMN image_url text,
  ADD COLUMN image_storage_path text,
  ADD COLUMN is_combo boolean NOT NULL DEFAULT false,
  ADD COLUMN is_archived boolean NOT NULL DEFAULT false,
  ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(),
  ADD CONSTRAINT menu_items_category_id_fkey
    FOREIGN KEY (category_id)
    REFERENCES public.menu_categories(id)
    ON DELETE SET NULL;

CREATE TABLE public.menu_combo_components (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  combo_menu_item_id uuid NOT NULL REFERENCES public.menu_items(id) ON DELETE CASCADE,
  component_menu_item_id uuid NOT NULL REFERENCES public.menu_items(id) ON DELETE RESTRICT,
  quantity integer NOT NULL,
  sort_order integer NOT NULL DEFAULT 0,
  UNIQUE (combo_menu_item_id, component_menu_item_id)
);

ALTER TABLE public.audit_logs
  ALTER COLUMN id SET DEFAULT gen_random_uuid();

CREATE FUNCTION public.admin_delete_menu_category(
  p_category_id uuid
) RETURNS public.menu_categories
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_existing public.menu_categories%ROWTYPE;
BEGIN
  SELECT * INTO v_existing
  FROM public.menu_categories
  WHERE id = p_category_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;
  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);
  IF EXISTS (
    SELECT 1 FROM public.menu_items item
    WHERE item.category_id = v_existing.id
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_EMPTY';
  END IF;
  DELETE FROM public.menu_categories WHERE id = v_existing.id;
  RETURN v_existing;
END;
$$;
