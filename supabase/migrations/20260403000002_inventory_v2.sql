ALTER TABLE inventory_items
  ADD COLUMN IF NOT EXISTS unit           TEXT DEFAULT 'g' CHECK (unit IN ('g','ml','ea')),
  ADD COLUMN IF NOT EXISTS current_stock  DECIMAL(12,3) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS reorder_point  DECIMAL(12,3),
  ADD COLUMN IF NOT EXISTS cost_per_unit  DECIMAL(12,2),
  ADD COLUMN IF NOT EXISTS supplier_name  TEXT;

CREATE TABLE IF NOT EXISTS menu_recipes (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id  UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  menu_item_id   UUID NOT NULL REFERENCES menu_items(id) ON DELETE CASCADE,
  ingredient_id  UUID NOT NULL REFERENCES inventory_items(id) ON DELETE CASCADE,
  quantity_g     DECIMAL(10,3) NOT NULL CHECK (quantity_g > 0),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (menu_item_id, ingredient_id)
);
ALTER TABLE menu_recipes ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'menu_recipes' AND policyname = 'restaurant_isolation'
  ) THEN
    CREATE POLICY "restaurant_isolation" ON menu_recipes
      USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']))
      WITH CHECK (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']));
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS inventory_transactions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id    UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  ingredient_id    UUID NOT NULL REFERENCES inventory_items(id) ON DELETE CASCADE,
  transaction_type TEXT NOT NULL CHECK (transaction_type IN ('deduct','restock','adjust','waste')),
  quantity_g       DECIMAL(12,3) NOT NULL,
  reference_type   TEXT,
  reference_id     UUID,
  note             TEXT,
  created_by       UUID REFERENCES auth.users(id),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE inventory_transactions ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'inventory_transactions' AND policyname = 'restaurant_isolation'
  ) THEN
    CREATE POLICY "restaurant_isolation" ON inventory_transactions
      USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']))
      WITH CHECK (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']));
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS inventory_physical_counts (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id           UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  ingredient_id           UUID NOT NULL REFERENCES inventory_items(id) ON DELETE CASCADE,
  count_date              DATE NOT NULL,
  actual_quantity_g       DECIMAL(12,3) NOT NULL,
  theoretical_quantity_g  DECIMAL(12,3),
  variance_g              DECIMAL(12,3),
  counted_by              UUID REFERENCES auth.users(id),
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (ingredient_id, count_date)
);
ALTER TABLE inventory_physical_counts ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'inventory_physical_counts' AND policyname = 'restaurant_isolation'
  ) THEN
    CREATE POLICY "restaurant_isolation" ON inventory_physical_counts
      USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']))
      WITH CHECK (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']));
  END IF;
END $$;

CREATE OR REPLACE FUNCTION process_payment(
  p_order_id      UUID,
  p_restaurant_id UUID,
  p_amount        DECIMAL(12,2),
  p_method        TEXT
) RETURNS payments AS $$
DECLARE
  v_payment    payments;
  v_table_id   UUID;
  v_is_revenue BOOLEAN;
  v_item       RECORD;
  v_recipe     RECORD;
  v_deduct_qty DECIMAL(12,3);
BEGIN
  IF EXISTS (SELECT 1 FROM payments WHERE order_id = p_order_id) THEN
    RAISE EXCEPTION 'PAYMENT_ALREADY_EXISTS';
  END IF;

  v_is_revenue := (p_method != 'service');

  INSERT INTO payments (order_id, restaurant_id, amount, method, processed_by, is_revenue)
  VALUES (p_order_id, p_restaurant_id, p_amount, p_method, auth.uid(), v_is_revenue)
  RETURNING * INTO v_payment;

  UPDATE orders SET status = 'completed', updated_at = now()
  WHERE id = p_order_id RETURNING table_id INTO v_table_id;

  IF v_table_id IS NOT NULL THEN
    UPDATE tables SET status = 'available', updated_at = now() WHERE id = v_table_id;
  END IF;

  FOR v_item IN
    SELECT oi.id AS order_item_id, oi.menu_item_id, oi.quantity AS ordered_qty
    FROM order_items oi
    WHERE oi.order_id = p_order_id AND oi.menu_item_id IS NOT NULL
  LOOP
    FOR v_recipe IN
      SELECT mr.ingredient_id, mr.quantity_g
      FROM menu_recipes mr
      WHERE mr.menu_item_id = v_item.menu_item_id AND mr.restaurant_id = p_restaurant_id
    LOOP
      v_deduct_qty := v_item.ordered_qty * v_recipe.quantity_g;
      UPDATE inventory_items
      SET current_stock = current_stock - v_deduct_qty, updated_at = now()
      WHERE id = v_recipe.ingredient_id AND restaurant_id = p_restaurant_id;
      INSERT INTO inventory_transactions
        (restaurant_id, ingredient_id, transaction_type, quantity_g, reference_type, reference_id, created_by)
      VALUES
        (p_restaurant_id, v_recipe.ingredient_id, 'deduct', -v_deduct_qty, 'order_item', v_item.order_item_id, auth.uid());
    END LOOP;
  END LOOP;

  RETURN v_payment;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
