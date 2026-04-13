---
title: "Phase 2 Step 2 — Migration SQL References"
version: "1.0"
date: "2026-04-12"
status: "static analysis complete"
---

# Phase 2 Step 2 — Supabase Migration References

> Static analysis of every `restaurants`/`restaurant_id`/`Restaurant`/`restaurant` reference in migration SQL files.

## Summary

- Total migration files with references: 46
- Total direct references (table/column names): 566
- Total incidental mentions (comments, strings): 28

## References by File

### 20260402000000_initial_schema.sql

- Line 9: `CREATE TABLE IF NOT EXISTS restaurants (` — Classification: DIRECT_REFERENCE
- Line 33: `restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 46: `restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 53: `UNIQUE (restaurant_id, table_number)` — Classification: DIRECT_REFERENCE
- Line 61: `restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 73: `restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 90: `restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 108: `restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 127: `restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 147: `restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 159: `restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 172: `restaurant_id     UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 205: `FROM restaurants r` — Classification: DIRECT_REFERENCE
- Line 211: `mi.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 219: `JOIN restaurants r ON r.id = mi.restaurant_id` — Classification: DIRECT_REFERENCE
- Line 229: `SELECT restaurant_id FROM users WHERE auth_id = auth.uid()` — Classification: DIRECT_REFERENCE
- Line 253: `ALTER TABLE restaurants    ENABLE ROW LEVEL SECURITY;` — Classification: DIRECT_REFERENCE
- Line 265: `-- restaurants: super_admin 전체, 나머지 본인 레스토랑만` — Classification: INCIDENTAL_MENTION
- Line 266: `CREATE POLICY restaurants_policy ON restaurants` — Classification: DIRECT_REFERENCE
- Line 271: `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE
- Line 275: `USING (restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE
- Line 278: `USING (restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE
- Line 281: `USING (restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE
- Line 284: `USING (restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE
- Line 287: `USING (restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE
- Line 290: `USING (restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE
- Line 293: `USING (restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE
- Line 296: `USING (restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE
- Line 299: `USING (restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE
- Line 309: `CREATE INDEX IF NOT EXISTS idx_users_restaurant ON users(restaurant_id);` — Classification: DIRECT_REFERENCE
- Line 310: `CREATE INDEX IF NOT EXISTS idx_tables_restaurant ON tables(restaurant_id);` — Classification: DIRECT_REFERENCE
- Line 311: `CREATE INDEX IF NOT EXISTS idx_menu_items_restaurant ON menu_items(restaurant_id);` — Classification: DIRECT_REFERENCE
- Line 313: `CREATE INDEX IF NOT EXISTS idx_orders_restaurant ON orders(restaurant_id);` — Classification: DIRECT_REFERENCE
- Line 315: `CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(restaurant_id, status);` — Classification: DIRECT_REFERENCE
- Line 317: `CREATE INDEX IF NOT EXISTS idx_payments_restaurant ON payments(restaurant_id);` — Classification: DIRECT_REFERENCE
- Line 320: `CREATE INDEX IF NOT EXISTS idx_external_sales_restaurant ON external_sales(restaurant_id, completed_at);` — Classification: DIRECT_REFERENCE
- Line 338: `WHERE id = p_table_id AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 345: `INSERT INTO orders (restaurant_id, table_id, status, created_by)` — Classification: DIRECT_REFERENCE
- Line 350: `(order_id, menu_item_id, quantity, unit_price, restaurant_id, item_type)` — Classification: DIRECT_REFERENCE
- Line 381: `FROM tables WHERE id = p_table_id AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 390: `FROM restaurants WHERE id = p_restaurant_id;` — Classification: DIRECT_REFERENCE
- Line 400: `INSERT INTO orders (restaurant_id, table_id, status, created_by, guest_count)` — Classification: DIRECT_REFERENCE
- Line 405: `(order_id, restaurant_id, item_type, label, unit_price, quantity, status)` — Classification: DIRECT_REFERENCE
- Line 412: `(order_id, menu_item_id, quantity, unit_price, restaurant_id, item_type)` — Classification: DIRECT_REFERENCE
- Line 441: `WHERE id = p_order_id AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 450: `(order_id, menu_item_id, quantity, unit_price, restaurant_id, item_type)` — Classification: DIRECT_REFERENCE
- Line 484: `(order_id, restaurant_id, amount, method, processed_by, is_revenue)` — Classification: DIRECT_REFERENCE
- Line 505: `COMMENT ON TABLE restaurants    IS 'F&B 레스토랑 테넌트';` — Classification: DIRECT_REFERENCE

### 20260402000001_seed_data.sql

- Line 1: `-- Only seed if no restaurants exist` — Classification: INCIDENTAL_MENTION
- Line 4: `IF NOT EXISTS (SELECT 1 FROM restaurants LIMIT 1) THEN` — Classification: DIRECT_REFERENCE
- Line 6: `-- Insert test restaurant` — Classification: INCIDENTAL_MENTION
- Line 7: `INSERT INTO restaurants (id, name, address, slug, operation_mode, is_active)` — Classification: DIRECT_REFERENCE
- Line 10: `'GLOBOS Test Restaurant',` — Classification: DIRECT_REFERENCE
- Line 18: `INSERT INTO tables (restaurant_id, table_number, seat_count, status)` — Classification: DIRECT_REFERENCE
- Line 27: `INSERT INTO menu_categories (id, restaurant_id, name, sort_order)` — Classification: DIRECT_REFERENCE
- Line 34: `INSERT INTO menu_items (restaurant_id, category_id, name, price, is_available)` — Classification: DIRECT_REFERENCE

### 20260402000002_pilot_data.sql

- Line 5: `-- R1: aaaaaaaa-0000-0000-0000-000000000001 (GLOBOS Test Restaurant)` — Classification: INCIDENTAL_MENTION
- Line 11: `WHERE restaurant_id = 'aaaaaaaa-0000-0000-0000-000000000001'` — Classification: DIRECT_REFERENCE
- Line 17: `INSERT INTO orders (id, restaurant_id, table_id, status, sales_channel, created_by)` — Classification: DIRECT_REFERENCE
- Line 20: `(SELECT auth_id FROM users WHERE role='waiter' AND restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' LIMIT 1)` — Classification: DIRECT_REFERENCE
- Line 21: `FROM tables t WHERE t.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND t.table_number='T01'` — Classification: DIRECT_REFERENCE
- Line 24: `INSERT INTO order_items (order_id, restaurant_id, menu_item_id, unit_price, quantity, status, item_type)` — Classification: DIRECT_REFERENCE
- Line 26: `FROM menu_items mi WHERE mi.name='불고기밥' AND mi.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' ON CONFLICT DO NO...` — Classification: DIRECT_REFERENCE
- Line 28: `INSERT INTO order_items (order_id, restaurant_id, menu_item_id, unit_price, quantity, status, item_type)` — Classification: DIRECT_REFERENCE
- Line 30: `FROM menu_items mi WHERE mi.name='김치찌개' AND mi.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' ON CONFLICT DO NO...` — Classification: DIRECT_REFERENCE
- Line 32: `INSERT INTO order_items (order_id, restaurant_id, menu_item_id, unit_price, quantity, status, item_type)` — Classification: DIRECT_REFERENCE
- Line 34: `FROM menu_items mi WHERE mi.name='막걸리' AND mi.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' ON CONFLICT DO NOT...` — Classification: DIRECT_REFERENCE
- Line 37: `INSERT INTO orders (id, restaurant_id, table_id, status, sales_channel, created_by)` — Classification: DIRECT_REFERENCE
- Line 40: `(SELECT auth_id FROM users WHERE role='waiter' AND restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' LIMIT 1)` — Classification: DIRECT_REFERENCE
- Line 41: `FROM tables t WHERE t.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND t.table_number='T03'` — Classification: DIRECT_REFERENCE
- Line 44: `INSERT INTO order_items (order_id, restaurant_id, menu_item_id, unit_price, quantity, status, item_type)` — Classification: DIRECT_REFERENCE
- Line 46: `FROM menu_items mi WHERE mi.name='떡볶이' AND mi.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' ON CONFLICT DO NOT...` — Classification: DIRECT_REFERENCE
- Line 48: `INSERT INTO order_items (order_id, restaurant_id, menu_item_id, unit_price, quantity, status, item_type)` — Classification: DIRECT_REFERENCE
- Line 50: `FROM menu_items mi WHERE mi.name='보리차' AND mi.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' ON CONFLICT DO NOT...` — Classification: DIRECT_REFERENCE
- Line 55: `INSERT INTO orders (id, restaurant_id, table_id, status, sales_channel, created_by)` — Classification: DIRECT_REFERENCE
- Line 58: `(SELECT auth_id FROM users WHERE role='waiter' AND restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' LIMIT 1)` — Classification: DIRECT_REFERENCE
- Line 59: `FROM tables t WHERE t.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND t.table_number='T02'` — Classification: DIRECT_REFERENCE
- Line 62: `INSERT INTO order_items (order_id, restaurant_id, menu_item_id, unit_price, quantity, status, item_type)` — Classification: DIRECT_REFERENCE
- Line 64: `FROM menu_items mi WHERE mi.name='비빔밥' AND mi.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' ON CONFLICT DO NOT...` — Classification: DIRECT_REFERENCE
- Line 66: `INSERT INTO order_items (order_id, restaurant_id, menu_item_id, unit_price, quantity, status, item_type)` — Classification: DIRECT_REFERENCE
- Line 68: `FROM menu_items mi WHERE mi.name='식혜' AND mi.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' ON CONFLICT DO NOTH...` — Classification: DIRECT_REFERENCE
- Line 73: `INSERT INTO orders (id, restaurant_id, table_id, status, sales_channel, created_at, updated_at)` — Classification: DIRECT_REFERENCE
- Line 77: `FROM tables t WHERE t.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND t.table_number='T04'` — Classification: DIRECT_REFERENCE
- Line 80: `INSERT INTO order_items (order_id, restaurant_id, menu_item_id, unit_price, quantity, status, item_type)` — Classification: DIRECT_REFERENCE
- Line 82: `FROM menu_items mi WHERE mi.name='불고기밥' AND mi.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' ON CONFLICT DO NO...` — Classification: DIRECT_REFERENCE
- Line 84: `INSERT INTO payments (id, restaurant_id, order_id, amount, method, is_revenue, created_at)` — Classification: DIRECT_REFERENCE
- Line 89: `INSERT INTO orders (id, restaurant_id, table_id, status, sales_channel, created_at, updated_at)` — Classification: DIRECT_REFERENCE
- Line 93: `FROM tables t WHERE t.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND t.table_number='T05'` — Classification: DIRECT_REFERENCE
- Line 96: `INSERT INTO order_items (order_id, restaurant_id, menu_item_id, unit_price, quantity, status, item_type)` — Classification: DIRECT_REFERENCE
- Line 98: `FROM menu_items mi WHERE mi.name='비빔밥' AND mi.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' ON CONFLICT DO NOT...` — Classification: DIRECT_REFERENCE
- Line 100: `INSERT INTO payments (id, restaurant_id, order_id, amount, method, is_revenue, created_at)` — Classification: DIRECT_REFERENCE
- Line 106: `INSERT INTO orders (id, restaurant_id, table_id, status, sales_channel, created_at)` — Classification: DIRECT_REFERENCE
- Line 109: `FROM tables t WHERE t.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND t.table_number='T06'` — Classification: DIRECT_REFERENCE
- Line 112: `INSERT INTO payments (id, restaurant_id, order_id, amount, method, is_revenue, created_at)` — Classification: DIRECT_REFERENCE
- Line 120: `INSERT INTO attendance_logs (restaurant_id, user_id, type, logged_at)` — Classification: DIRECT_REFERENCE
- Line 122: `FROM users u WHERE u.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND u.role='waiter';` — Classification: DIRECT_REFERENCE
- Line 124: `INSERT INTO attendance_logs (restaurant_id, user_id, type, logged_at)` — Classification: DIRECT_REFERENCE
- Line 126: `FROM users u WHERE u.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND u.role='kitchen';` — Classification: DIRECT_REFERENCE
- Line 128: `INSERT INTO attendance_logs (restaurant_id, user_id, type, logged_at)` — Classification: DIRECT_REFERENCE
- Line 130: `FROM users u WHERE u.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND u.role='cashier';` — Classification: DIRECT_REFERENCE
- Line 132: `INSERT INTO attendance_logs (restaurant_id, user_id, type, logged_at)` — Classification: DIRECT_REFERENCE
- Line 134: `FROM users u WHERE u.restaurant_id='aaaaaaaa-0000-0000-0000-000000000001' AND u.role='waiter';` — Classification: DIRECT_REFERENCE
- Line 140: `restaurant_id, source_system, external_order_id,` — Classification: DIRECT_REFERENCE

### 20260402000003_fingerprint_attendance.sql

- Line 8: `restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 17: `ON fingerprint_templates (restaurant_id);` — Classification: DIRECT_REFERENCE
- Line 26: `USING (restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE

### 20260402000004_cancel_order_rpc.sql

- Line 14: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE

### 20260402000005_fix_cancel_order_rpc.sql

- Line 15: `WHERE id = p_order_id AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE

### 20260403000000_attendance_camera_payroll.sql

- Line 9: `restaurant_id  UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 30: `USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']));` — Classification: DIRECT_REFERENCE
- Line 37: `restaurant_id UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 59: `USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']));` — Classification: DIRECT_REFERENCE

### 20260403000001_qc_module.sql

- Line 4: `restaurant_id      UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 24: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 33: `restaurant_id      UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 55: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE

### 20260403000002_inventory_v2.sql

- Line 10: `restaurant_id  UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 25: `USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']))` — Classification: DIRECT_REFERENCE
- Line 26: `WITH CHECK (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']));` — Classification: DIRECT_REFERENCE
- Line 32: `restaurant_id    UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 50: `USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']))` — Classification: DIRECT_REFERENCE
- Line 51: `WITH CHECK (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']));` — Classification: DIRECT_REFERENCE
- Line 57: `restaurant_id           UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 75: `USING (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']))` — Classification: DIRECT_REFERENCE
- Line 76: `WITH CHECK (restaurant_id = get_user_restaurant_id() OR has_any_role(ARRAY['super_admin']));` — Classification: DIRECT_REFERENCE
- Line 100: `INSERT INTO payments (order_id, restaurant_id, amount, method, processed_by, is_revenue)` — Classification: DIRECT_REFERENCE
- Line 119: `WHERE mr.menu_item_id = v_item.menu_item_id AND mr.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 124: `WHERE id = v_recipe.ingredient_id AND restaurant_id = p_restaurant_id;` — Classification: DIRECT_REFERENCE
- Line 126: `(restaurant_id, ingredient_id, transaction_type, quantity_g, reference_type, reference_id, created_by)` — Classification: DIRECT_REFERENCE

### 20260403000003_permissions.sql

- Line 6: `restaurant_id   UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE UNIQUE,` — Classification: DIRECT_REFERENCE
- Line 20: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 24: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE

### 20260403000004_qc_global_templates.sql

- Line 5: `ALTER COLUMN restaurant_id DROP NOT NULL;` — Classification: DIRECT_REFERENCE
- Line 18: `(is_global = TRUE AND restaurant_id IS NULL) OR` — Classification: DIRECT_REFERENCE
- Line 19: `(is_global = FALSE AND restaurant_id IS NOT NULL)` — Classification: DIRECT_REFERENCE
- Line 33: `restaurant_id = get_user_restaurant_id() OR` — Classification: DIRECT_REFERENCE
- Line 41: `AND restaurant_id = get_user_restaurant_id())` — Classification: DIRECT_REFERENCE
- Line 48: `AND restaurant_id = get_user_restaurant_id())` — Classification: DIRECT_REFERENCE
- Line 55: `AND restaurant_id = get_user_restaurant_id())` — Classification: DIRECT_REFERENCE

### 20260405000000_office_shared_hierarchy.sql

- Line 5: `-- Modifies: restaurants (adds brand_id FK)` — Classification: INCIDENTAL_MENTION
- Line 73: `AND table_name = 'restaurants'` — Classification: DIRECT_REFERENCE
- Line 76: `ALTER TABLE restaurants ADD COLUMN brand_id UUID REFERENCES brands(id);` — Classification: DIRECT_REFERENCE
- Line 77: `CREATE INDEX idx_restaurants_brand_id ON restaurants(brand_id);` — Classification: DIRECT_REFERENCE
- Line 78: `RAISE NOTICE 'Added brand_id to restaurants';` — Classification: DIRECT_REFERENCE
- Line 80: `RAISE NOTICE 'brand_id already exists on restaurants';` — Classification: DIRECT_REFERENCE

### 20260405000001_office_brand_seed.sql

- Line 35: `-- Map existing restaurants to brands by name pattern` — Classification: INCIDENTAL_MENTION
- Line 39: `UPDATE restaurants` — Classification: DIRECT_REFERENCE
- Line 46: `UPDATE restaurants` — Classification: DIRECT_REFERENCE
- Line 53: `UPDATE restaurants` — Classification: DIRECT_REFERENCE
- Line 60: `-- Report unmapped restaurants (for manual review)` — Classification: INCIDENTAL_MENTION
- Line 65: `SELECT COUNT(*) INTO unmapped_count FROM restaurants WHERE brand_id IS NULL;` — Classification: DIRECT_REFERENCE
- Line 67: `RAISE NOTICE '% restaurants still unmapped (brand_id IS NULL). Manual mapping may be needed.', unmapped_count;` — Classification: DIRECT_REFERENCE
- Line 69: `RAISE NOTICE 'All restaurants successfully mapped to brands.';` — Classification: DIRECT_REFERENCE

### 20260405000003_office_connection_views.sql

- Line 24: `JOIN restaurants r ON r.id = p.restaurant_id` — Classification: DIRECT_REFERENCE
- Line 35: `al.restaurant_id AS store_id,` — Classification: DIRECT_REFERENCE
- Line 46: `JOIN restaurants r ON r.id = al.restaurant_id` — Classification: DIRECT_REFERENCE
- Line 48: `GROUP BY al.restaurant_id, r.brand_id, al.user_id, COALESCE(u.full_name, u.role), u.role,` — Classification: DIRECT_REFERENCE
- Line 58: `qc.restaurant_id AS store_id,` — Classification: DIRECT_REFERENCE
- Line 71: `JOIN restaurants r ON r.id = qc.restaurant_id;` — Classification: DIRECT_REFERENCE
- Line 80: `ii.restaurant_id AS store_id,` — Classification: DIRECT_REFERENCE
- Line 93: `JOIN restaurants r ON r.id = ii.restaurant_id;` — Classification: DIRECT_REFERENCE
- Line 109: `JOIN restaurants r2 ON r2.id = p.restaurant_id` — Classification: DIRECT_REFERENCE
- Line 117: `JOIN restaurants r2 ON r2.id = p.restaurant_id` — Classification: DIRECT_REFERENCE
- Line 123: `LEFT JOIN restaurants r ON r.brand_id = b.id` — Classification: DIRECT_REFERENCE
- Line 124: `LEFT JOIN users u ON u.restaurant_id = r.id` — Classification: DIRECT_REFERENCE

### 20260405000005_office_payroll_trigger.sql

- Line 6: `restaurant_id     UUID NOT NULL REFERENCES restaurants(id),` — Classification: DIRECT_REFERENCE
- Line 24: `ON office_payroll_reviews(restaurant_id);` — Classification: DIRECT_REFERENCE
- Line 85: `FROM restaurants` — Classification: DIRECT_REFERENCE
- Line 86: `WHERE id = NEW.restaurant_id;` — Classification: DIRECT_REFERENCE
- Line 90: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 98: `NEW.restaurant_id,` — Classification: DIRECT_REFERENCE

### 20260405000006_office_purchases.sql

- Line 5: `restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),` — Classification: DIRECT_REFERENCE

### 20260405000007_office_qc_followups.sql

- Line 6: `restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),` — Classification: DIRECT_REFERENCE

### 20260405000009_office_view_rls.sql

- Line 27: `from public.restaurants r;` — Classification: DIRECT_REFERENCE
- Line 33: `from public.restaurants r` — Classification: DIRECT_REFERENCE
- Line 75: `from public.restaurants r` — Classification: DIRECT_REFERENCE

### 20260405000011_deliberry_settlement.sql

- Line 21: `restaurant_id     UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 45: `UNIQUE (restaurant_id, source_system, period_label)` — Classification: DIRECT_REFERENCE
- Line 96: `OR restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 102: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 112: `OR restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 118: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 125: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 129: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 141: `AND (is_super_admin() OR ds.restaurant_id = get_user_restaurant_id())` — Classification: DIRECT_REFERENCE
- Line 151: `AND ds.restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 161: `COALESCE(pos.restaurant_id, del.restaurant_id) AS restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 174: `o.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 183: `GROUP BY o.restaurant_id, (p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date` — Classification: DIRECT_REFERENCE
- Line 187: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 193: `GROUP BY restaurant_id, (completed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date` — Classification: DIRECT_REFERENCE
- Line 195: `ON pos.restaurant_id = del.restaurant_id AND pos.sale_date = del.sale_date;` — Classification: DIRECT_REFERENCE
- Line 203: `ds.restaurant_id,` — Classification: DIRECT_REFERENCE

### 20260405000012_store_type_classification.sql

- Line 9: `--   1. restaurants.store_type 컬럼 추가` — Classification: INCIDENTAL_MENTION
- Line 22: `-- 1. restaurants.store_type 컬럼 추가` — Classification: INCIDENTAL_MENTION
- Line 29: `AND table_name = 'restaurants'` — Classification: DIRECT_REFERENCE
- Line 32: `ALTER TABLE restaurants` — Classification: DIRECT_REFERENCE
- Line 34: `ALTER TABLE restaurants` — Classification: DIRECT_REFERENCE
- Line 37: `RAISE NOTICE 'Added store_type to restaurants';` — Classification: DIRECT_REFERENCE
- Line 39: `RAISE NOTICE 'store_type already exists on restaurants';` — Classification: DIRECT_REFERENCE
- Line 43: `COMMENT ON COLUMN restaurants.store_type IS` — Classification: DIRECT_REFERENCE
- Line 48: `ON restaurants(store_type);` — Classification: DIRECT_REFERENCE
- Line 50: `ON restaurants(brand_id, store_type);` — Classification: DIRECT_REFERENCE
- Line 68: `JOIN restaurants r ON r.id = p.restaurant_id` — Classification: DIRECT_REFERENCE
- Line 77: `al.restaurant_id AS store_id,` — Classification: DIRECT_REFERENCE
- Line 88: `JOIN restaurants r ON r.id = al.restaurant_id` — Classification: DIRECT_REFERENCE
- Line 91: `GROUP BY al.restaurant_id, r.brand_id, al.user_id, COALESCE(u.full_name, u.role), u.role,` — Classification: DIRECT_REFERENCE
- Line 98: `qc.restaurant_id AS store_id,` — Classification: DIRECT_REFERENCE
- Line 111: `JOIN restaurants r ON r.id = qc.restaurant_id` — Classification: DIRECT_REFERENCE
- Line 118: `ii.restaurant_id AS store_id,` — Classification: DIRECT_REFERENCE
- Line 131: `JOIN restaurants r ON r.id = ii.restaurant_id` — Classification: DIRECT_REFERENCE
- Line 145: `JOIN restaurants r2 ON r2.id = p.restaurant_id` — Classification: DIRECT_REFERENCE
- Line 154: `JOIN restaurants r2 ON r2.id = p.restaurant_id` — Classification: DIRECT_REFERENCE
- Line 161: `LEFT JOIN restaurants r ON r.brand_id = b.id AND r.store_type = 'direct'` — Classification: DIRECT_REFERENCE
- Line 162: `LEFT JOIN users u ON u.restaurant_id = r.id` — Classification: DIRECT_REFERENCE
- Line 194: `FROM public.restaurants r` — Classification: DIRECT_REFERENCE
- Line 201: `FROM public.restaurants r` — Classification: DIRECT_REFERENCE
- Line 209: `FROM public.restaurants r` — Classification: DIRECT_REFERENCE
- Line 232: `JOIN restaurants r ON r.id = p.restaurant_id` — Classification: DIRECT_REFERENCE
- Line 248: `WHERE u.restaurant_id = r.id AND u.is_active = TRUE) AS active_staff,` — Classification: DIRECT_REFERENCE
- Line 251: `WHERE p.restaurant_id = r.id AND p.is_revenue = TRUE` — Classification: DIRECT_REFERENCE
- Line 255: `WHERE o.restaurant_id = r.id` — Classification: DIRECT_REFERENCE
- Line 257: `FROM restaurants r` — Classification: DIRECT_REFERENCE
- Line 286: `-- ALTER TABLE restaurants DROP CONSTRAINT IF EXISTS restaurants_store_type_check;` — Classification: INCIDENTAL_MENTION
- Line 287: `-- ALTER TABLE restaurants DROP COLUMN IF EXISTS store_type;` — Classification: INCIDENTAL_MENTION

### 20260406000000_deliberry_store_type_integration.sql

- Line 35: `FROM restaurants r` — Classification: DIRECT_REFERENCE
- Line 50: `mi.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 59: `JOIN restaurants r ON r.id = mi.restaurant_id` — Classification: DIRECT_REFERENCE

### 20260408000000_security_hardening.sql

- Line 16: `-- POS admin/super_admin can see their restaurant's purchases` — Classification: INCIDENTAL_MENTION
- Line 21: `restaurant_id = ANY(office_get_accessible_store_ids())` — Classification: DIRECT_REFERENCE
- Line 23: `-- POS admin/super_admin: own restaurant` — Classification: INCIDENTAL_MENTION
- Line 28: `AND (u.role = 'super_admin' OR u.restaurant_id = office_purchases.restaurant_id)` — Classification: DIRECT_REFERENCE
- Line 36: `restaurant_id = ANY(office_get_accessible_store_ids())` — Classification: DIRECT_REFERENCE
- Line 48: `restaurant_id = ANY(office_get_accessible_store_ids())` — Classification: DIRECT_REFERENCE
- Line 57: `restaurant_id = ANY(office_get_accessible_store_ids())` — Classification: DIRECT_REFERENCE
- Line 70: `restaurant_id = ANY(office_get_accessible_store_ids())` — Classification: DIRECT_REFERENCE
- Line 76: `AND (u.role = 'super_admin' OR u.restaurant_id = office_qc_followups.restaurant_id)` — Classification: DIRECT_REFERENCE
- Line 83: `restaurant_id = ANY(office_get_accessible_store_ids())` — Classification: DIRECT_REFERENCE
- Line 94: `restaurant_id = ANY(office_get_accessible_store_ids())` — Classification: DIRECT_REFERENCE
- Line 103: `restaurant_id = ANY(office_get_accessible_store_ids())` — Classification: DIRECT_REFERENCE
- Line 148: `-- attendance-photos: users can only access their restaurant's folder` — Classification: INCIDENTAL_MENTION
- Line 149: `-- Pattern: attendance-photos/{restaurant_id}/...` — Classification: INCIDENTAL_MENTION
- Line 158: `-- POS users: match restaurant_id in path` — Classification: INCIDENTAL_MENTION
- Line 162: `AND (storage.foldername(name))[1] = u.restaurant_id::text` — Classification: DIRECT_REFERENCE
- Line 177: `AND (storage.foldername(name))[1] = u.restaurant_id::text` — Classification: DIRECT_REFERENCE
- Line 197: `AND (storage.foldername(name))[1] = u.restaurant_id::text` — Classification: DIRECT_REFERENCE
- Line 211: `AND (storage.foldername(name))[1] = u.restaurant_id::text` — Classification: DIRECT_REFERENCE

### 20260408000001_harness_audit_fixes.sql

- Line 41: `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())` — Classification: DIRECT_REFERENCE
- Line 42: `WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE
- Line 48: `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())` — Classification: DIRECT_REFERENCE
- Line 49: `WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE
- Line 55: `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())` — Classification: DIRECT_REFERENCE
- Line 56: `WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE
- Line 62: `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())` — Classification: DIRECT_REFERENCE
- Line 63: `WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE
- Line 69: `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())` — Classification: DIRECT_REFERENCE
- Line 70: `WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE
- Line 76: `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())` — Classification: DIRECT_REFERENCE
- Line 77: `WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE
- Line 83: `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())` — Classification: DIRECT_REFERENCE
- Line 84: `WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE
- Line 90: `USING (is_super_admin() OR restaurant_id = get_user_restaurant_id())` — Classification: DIRECT_REFERENCE
- Line 91: `WITH CHECK (is_super_admin() OR restaurant_id = get_user_restaurant_id());` — Classification: DIRECT_REFERENCE
- Line 102: `restaurant_id = ANY(office_get_accessible_store_ids())` — Classification: DIRECT_REFERENCE
- Line 104: `-- POS admin/super_admin: own restaurant or all` — Classification: INCIDENTAL_MENTION
- Line 109: `AND (u.role = 'super_admin' OR u.restaurant_id = office_payroll_reviews.restaurant_id)` — Classification: DIRECT_REFERENCE
- Line 117: `-- external_sales_read (from 20260405000011) already has is_super_admin() OR restaurant_id pattern` — Classification: INCIDENTAL_MENTION

### 20260408000003_delivery_settlement_confirm_rpc.sql

- Line 31: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 39: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 61: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE

### 20260408000004_order_item_status_rpc.sql

- Line 30: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 38: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 78: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE

### 20260409000000_dine_in_sales_contract_closure.sql

- Line 39: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 51: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 76: `AND m.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 83: `INSERT INTO orders (restaurant_id, table_id, status, created_by)` — Classification: DIRECT_REFERENCE
- Line 93: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 107: `AND m.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 124: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 162: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 170: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 183: `FROM restaurants` — Classification: DIRECT_REFERENCE
- Line 212: `AND m.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 220: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 231: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 255: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 269: `AND m.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 287: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 322: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 334: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 359: `AND m.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 373: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 387: `AND m.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 404: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 441: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 453: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 485: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 524: `AND mr.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 531: `AND restaurant_id = p_restaurant_id;` — Classification: DIRECT_REFERENCE
- Line 534: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 561: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 594: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 602: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 633: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE

### 20260409000001_inventory_ingredient_catalog_contracts.sql

- Line 18: `ON public.inventory_items (restaurant_id, lower(btrim(name)));` — Classification: DIRECT_REFERENCE
- Line 24: `restaurant_id UUID,` — Classification: DIRECT_REFERENCE
- Line 49: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 56: `ii.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 70: `WHERE ii.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 107: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 134: `WHERE ii.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 141: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 169: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 226: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 255: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 326: `WHERE ii.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 377: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 387: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE

### 20260409000002_inventory_recipe_bom_contracts.sql

- Line 25: `restaurant_id UUID,` — Classification: DIRECT_REFERENCE
- Line 49: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 57: `AND mi.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 65: `mr.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 76: `AND mi.restaurant_id = mr.restaurant_id` — Classification: DIRECT_REFERENCE
- Line 79: `AND ii.restaurant_id = mr.restaurant_id` — Classification: DIRECT_REFERENCE
- Line 80: `WHERE mr.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 94: `restaurant_id UUID,` — Classification: DIRECT_REFERENCE
- Line 125: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 145: `AND restaurant_id = p_restaurant_id;` — Classification: DIRECT_REFERENCE
- Line 155: `AND restaurant_id = p_restaurant_id;` — Classification: DIRECT_REFERENCE
- Line 170: `WHERE restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 195: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 208: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 231: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 244: `v_recipe.restaurant_id,` — Classification: DIRECT_REFERENCE

### 20260409000003_inventory_recipe_bom_contracts_fix.sql

- Line 14: `restaurant_id UUID,` — Classification: DIRECT_REFERENCE
- Line 45: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 65: `AND mi.restaurant_id = p_restaurant_id;` — Classification: DIRECT_REFERENCE
- Line 75: `AND ii.restaurant_id = p_restaurant_id;` — Classification: DIRECT_REFERENCE
- Line 88: `WHERE mr.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 113: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 126: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 149: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 162: `v_recipe.restaurant_id,` — Classification: DIRECT_REFERENCE

### 20260409000004_inventory_physical_count_contracts.sql

- Line 45: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 65: `ON ipc.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 68: `WHERE ii.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 111: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 131: `AND ii.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 144: `WHERE ipc.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 150: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 182: `AND ii.restaurant_id = p_restaurant_id;` — Classification: DIRECT_REFERENCE
- Line 185: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 216: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE

### 20260409000005_inventory_physical_count_contracts_fix.sql

- Line 44: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 64: `AND ii.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 77: `WHERE ipc.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 83: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 115: `AND ii.restaurant_id = p_restaurant_id;` — Classification: DIRECT_REFERENCE
- Line 118: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 149: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE

### 20260409000006_inventory_transaction_visibility_contracts.sql

- Line 6: `-- - restaurant-scoped date-range filtering` — Classification: INCIDENTAL_MENTION
- Line 20: `restaurant_id UUID,` — Classification: DIRECT_REFERENCE
- Line 46: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 61: `it.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 74: `AND ii.restaurant_id = it.restaurant_id` — Classification: DIRECT_REFERENCE
- Line 75: `WHERE it.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE

### 20260409000007_attendance_event_capture_contracts.sql

- Line 37: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 47: `WHERE u.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 62: `restaurant_id UUID,` — Classification: DIRECT_REFERENCE
- Line 87: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 103: `AND u.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 112: `al.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 124: `AND u.restaurant_id = al.restaurant_id` — Classification: DIRECT_REFERENCE
- Line 125: `WHERE al.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 142: `restaurant_id UUID,` — Classification: DIRECT_REFERENCE
- Line 169: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 185: `AND u.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 193: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 217: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 229: `v_log.restaurant_id,` — Classification: DIRECT_REFERENCE

### 20260409000008_qc_contract_closure.sql

- Line 24: `restaurant_id UUID,` — Classification: DIRECT_REFERENCE
- Line 62: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 70: `qt.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 88: `OR qt.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 145: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 151: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 177: `'restaurant_id', v_created.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 245: `AND v_existing.restaurant_id <> v_actor.restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 328: `'restaurant_id', v_updated.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 377: `AND v_existing.restaurant_id <> v_actor.restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 394: `'restaurant_id', v_updated.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 410: `restaurant_id UUID,` — Classification: DIRECT_REFERENCE
- Line 446: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 461: `qc.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 476: `WHERE qc.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 522: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 549: `OR qt.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 564: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 583: `restaurant_id = EXCLUDED.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 597: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 623: `restaurant_id UUID,` — Classification: DIRECT_REFERENCE
- Line 653: `FROM public.restaurants r` — Classification: DIRECT_REFERENCE
- Line 658: `ar.id AS restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 661: `AND (qt.is_global = TRUE OR qt.restaurant_id = ar.id)` — Classification: DIRECT_REFERENCE
- Line 666: `AND (qt.is_global = TRUE OR qt.restaurant_id = ar.id)` — Classification: DIRECT_REFERENCE
- Line 671: `qc.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 678: `GROUP BY qc.restaurant_id` — Classification: DIRECT_REFERENCE
- Line 681: `ar.id AS restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 695: `ON tc.restaurant_id = ar.id` — Classification: DIRECT_REFERENCE
- Line 697: `ON ch.restaurant_id = ar.id` — Classification: DIRECT_REFERENCE

### 20260409000009_bundle_a_security_closure.sql

- Line 12: `-- users: read remains restaurant-scoped, direct authenticated writes removed` — Classification: INCIDENTAL_MENTION
- Line 20: `OR restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 88: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 96: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 152: `'restaurant_id', v_updated.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 199: `SET restaurant_id = p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 212: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 223: `-- restaurants: writes limited to admin/super_admin or super_admin only` — Classification: INCIDENTAL_MENTION
- Line 225: `DROP POLICY IF EXISTS restaurants_policy ON public.restaurants;` — Classification: DIRECT_REFERENCE
- Line 227: `CREATE POLICY restaurants_select_policy ON public.restaurants` — Classification: DIRECT_REFERENCE
- Line 234: `CREATE POLICY restaurants_super_admin_insert_policy ON public.restaurants` — Classification: DIRECT_REFERENCE
- Line 240: `CREATE POLICY restaurants_admin_update_policy ON public.restaurants` — Classification: DIRECT_REFERENCE
- Line 268: `OR restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 276: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 286: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 293: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 303: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 312: `OR restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 320: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 330: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 337: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 347: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 356: `OR restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 364: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 374: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 381: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 391: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE

### 20260409000010_bundle_b1_admin_mutation_rpcs.sql

- Line 2: `-- Bundle B-1: admin mutation RPC boundaries for restaurants/tables/menu` — Classification: INCIDENTAL_MENTION
- Line 11: `-- Helper: active admin/super_admin actor for target restaurant` — Classification: INCIDENTAL_MENTION
- Line 35: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 47: `DROP POLICY IF EXISTS restaurants_super_admin_insert_policy ON public.restaurants;` — Classification: DIRECT_REFERENCE
- Line 48: `DROP POLICY IF EXISTS restaurants_admin_update_policy ON public.restaurants;` — Classification: DIRECT_REFERENCE
- Line 63: `-- restaurants` — Classification: INCIDENTAL_MENTION
- Line 73: `) RETURNS public.restaurants AS $$` — Classification: DIRECT_REFERENCE
- Line 76: `v_created public.restaurants%ROWTYPE;` — Classification: DIRECT_REFERENCE
- Line 97: `INSERT INTO public.restaurants (` — Classification: DIRECT_REFERENCE
- Line 125: `'restaurants',` — Classification: DIRECT_REFERENCE
- Line 128: `'restaurant_id', v_created.id,` — Classification: DIRECT_REFERENCE
- Line 157: `) RETURNS public.restaurants AS $$` — Classification: DIRECT_REFERENCE
- Line 160: `v_existing public.restaurants%ROWTYPE;` — Classification: DIRECT_REFERENCE
- Line 161: `v_updated public.restaurants%ROWTYPE;` — Classification: DIRECT_REFERENCE
- Line 184: `FROM public.restaurants` — Classification: DIRECT_REFERENCE
- Line 236: `UPDATE public.restaurants` — Classification: DIRECT_REFERENCE
- Line 252: `'restaurants',` — Classification: DIRECT_REFERENCE
- Line 255: `'restaurant_id', v_updated.id,` — Classification: DIRECT_REFERENCE
- Line 271: `) RETURNS public.restaurants AS $$` — Classification: DIRECT_REFERENCE
- Line 273: `v_existing public.restaurants%ROWTYPE;` — Classification: DIRECT_REFERENCE
- Line 274: `v_updated public.restaurants%ROWTYPE;` — Classification: DIRECT_REFERENCE
- Line 282: `FROM public.restaurants` — Classification: DIRECT_REFERENCE
- Line 292: `UPDATE public.restaurants` — Classification: DIRECT_REFERENCE
- Line 301: `'restaurants',` — Classification: DIRECT_REFERENCE
- Line 304: `'restaurant_id', v_updated.id,` — Classification: DIRECT_REFERENCE
- Line 323: `) RETURNS public.restaurants AS $$` — Classification: DIRECT_REFERENCE
- Line 325: `v_existing public.restaurants%ROWTYPE;` — Classification: DIRECT_REFERENCE
- Line 326: `v_updated public.restaurants%ROWTYPE;` — Classification: DIRECT_REFERENCE
- Line 348: `FROM public.restaurants` — Classification: DIRECT_REFERENCE
- Line 382: `UPDATE public.restaurants` — Classification: DIRECT_REFERENCE
- Line 395: `'restaurants',` — Classification: DIRECT_REFERENCE
- Line 398: `'restaurant_id', v_updated.id,` — Classification: DIRECT_REFERENCE
- Line 430: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 454: `'restaurant_id', v_created.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 497: `PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);` — Classification: DIRECT_REFERENCE
- Line 540: `'restaurant_id', v_updated.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 574: `PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);` — Classification: DIRECT_REFERENCE
- Line 586: `'restaurant_id', v_existing.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 619: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 641: `'restaurant_id', v_created.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 684: `PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);` — Classification: DIRECT_REFERENCE
- Line 726: `'restaurant_id', v_updated.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 760: `PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);` — Classification: DIRECT_REFERENCE
- Line 772: `'restaurant_id', v_existing.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 813: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 819: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 851: `'restaurant_id', v_created.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 903: `PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);` — Classification: DIRECT_REFERENCE
- Line 909: `AND restaurant_id = v_existing.restaurant_id` — Classification: DIRECT_REFERENCE
- Line 986: `'restaurant_id', v_updated.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 1020: `PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);` — Classification: DIRECT_REFERENCE
- Line 1032: `'restaurant_id', v_existing.restaurant_id,` — Classification: DIRECT_REFERENCE

### 20260409000011_admin_mutation_audit_trace_read.sql

- Line 6: `-- - restaurants, tables, menu_categories, menu_items only` — Classification: INCIDENTAL_MENTION
- Line 44: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 64: `ARRAY['restaurants', 'tables', 'menu_categories', 'menu_items']` — Classification: DIRECT_REFERENCE
- Line 67: `NULLIF(al.details ->> 'restaurant_id', '')::UUID = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 69: `al.entity_type = 'restaurants'` — Classification: DIRECT_REFERENCE

### 20260409000012_pos_native_auth_rewrite.sql

- Line 74: `OR restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 84: `AND (is_super_admin() OR restaurant_id = get_user_restaurant_id())` — Classification: DIRECT_REFERENCE
- Line 88: `AND (is_super_admin() OR restaurant_id = get_user_restaurant_id())` — Classification: DIRECT_REFERENCE

### 20260409000013_drop_office_remote_residue.sql

- Line 40: `DROP POLICY IF EXISTS office_read_restaurants ON restaurants;` — Classification: DIRECT_REFERENCE

### 20260409000014_order_lifecycle_completion.sql

- Line 20: `--   - Tenant scoping via restaurant_id` — Classification: INCIDENTAL_MENTION
- Line 67: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 76: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 118: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 165: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 179: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 225: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 270: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 279: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 302: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 341: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 390: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 403: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 437: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 478: `AND mr.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 485: `AND restaurant_id = p_restaurant_id;` — Classification: DIRECT_REFERENCE
- Line 488: `restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 515: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 558: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 566: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 611: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE

### 20260409000015_admin_operational_visibility.sql

- Line 49: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 70: `'restaurants', 'tables', 'menu_categories', 'menu_items',` — Classification: DIRECT_REFERENCE
- Line 75: `NULLIF(al.details ->> 'restaurant_id', '')::UUID = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 77: `al.entity_type = 'restaurants'` — Classification: DIRECT_REFERENCE
- Line 156: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 173: `WHERE restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 181: `WHERE o.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 193: `WHERE restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 203: `WHERE restaurant_id = p_restaurant_id;` — Classification: DIRECT_REFERENCE

### 20260409000016_cashier_waiter_field_usability.sql

- Line 44: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 60: `WHERE restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 70: `WHERE restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 81: `WHERE restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE

### 20260410000000_daily_closing_snapshot.sql

- Line 24: `restaurant_id   UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 48: `CONSTRAINT unique_daily_closing UNIQUE (restaurant_id, closing_date)` — Classification: DIRECT_REFERENCE
- Line 52: `ON daily_closings(restaurant_id, closing_date DESC);` — Classification: DIRECT_REFERENCE
- Line 99: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 110: `WHERE restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 124: `WHERE restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 132: `WHERE o.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 145: `WHERE restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 155: `WHERE restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 161: `restaurant_id, closing_date, closed_by,` — Classification: DIRECT_REFERENCE
- Line 180: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 252: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 276: `WHERE dc.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE

### 20260410000001_inventory_restock_waste_rpc.sql

- Line 38: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 52: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 66: `AND restaurant_id = p_restaurant_id;` — Classification: DIRECT_REFERENCE
- Line 70: `restaurant_id, ingredient_id, transaction_type,` — Classification: DIRECT_REFERENCE
- Line 85: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 122: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 136: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 150: `AND restaurant_id = p_restaurant_id;` — Classification: DIRECT_REFERENCE
- Line 154: `restaurant_id, ingredient_id, transaction_type,` — Classification: DIRECT_REFERENCE
- Line 169: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE

### 20260410000002_qc_followup_and_analytics.sql

- Line 5: `--   - qc_followups table (POS-native, restaurant-scoped)` — Classification: INCIDENTAL_MENTION
- Line 8: `--   - get_qc_followups: read followups for restaurant` — Classification: INCIDENTAL_MENTION
- Line 18: `restaurant_id    UUID NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,` — Classification: DIRECT_REFERENCE
- Line 44: `restaurant_id = get_user_restaurant_id()` — Classification: DIRECT_REFERENCE
- Line 71: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 78: `AND restaurant_id = p_restaurant_id;` — Classification: DIRECT_REFERENCE
- Line 96: `restaurant_id, source_check_id, status,` — Classification: DIRECT_REFERENCE
- Line 112: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 145: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 156: `AND restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 185: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 203: `restaurant_id     UUID,` — Classification: DIRECT_REFERENCE
- Line 230: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 237: `f.restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 253: `WHERE f.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 303: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 329: `AND (qt.is_global = TRUE OR qt.restaurant_id = p_restaurant_id)` — Classification: DIRECT_REFERENCE
- Line 334: `AND (qt.is_global = TRUE OR qt.restaurant_id = p_restaurant_id)) = 0` — Classification: DIRECT_REFERENCE
- Line 340: `AND (qt.is_global = TRUE OR qt.restaurant_id = p_restaurant_id))` — Classification: DIRECT_REFERENCE
- Line 346: `WHERE f.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 350: `WHERE qc.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE

### 20260410000003_inventory_low_stock_visibility.sql

- Line 55: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 66: `WHERE restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 80: `WHERE restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 88: `WHERE o.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 101: `WHERE restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 111: `WHERE restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 119: `WHERE restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 126: `restaurant_id, closing_date, closed_by,` — Classification: DIRECT_REFERENCE
- Line 145: `'restaurant_id', p_restaurant_id,` — Classification: DIRECT_REFERENCE
- Line 218: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 243: `WHERE dc.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 288: `AND v_actor.restaurant_id <> p_restaurant_id THEN` — Classification: DIRECT_REFERENCE
- Line 305: `WHERE restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 313: `WHERE o.restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 325: `WHERE restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE
- Line 335: `WHERE restaurant_id = p_restaurant_id;` — Classification: DIRECT_REFERENCE
- Line 341: `WHERE restaurant_id = p_restaurant_id` — Classification: DIRECT_REFERENCE

