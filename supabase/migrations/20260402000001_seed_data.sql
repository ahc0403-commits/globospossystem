-- Only seed if no restaurants exist
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM restaurants LIMIT 1) THEN

    -- Insert test restaurant
    INSERT INTO restaurants (id, name, address, slug, operation_mode, is_active)
    VALUES (
      'aaaaaaaa-0000-0000-0000-000000000001',
      'GLOBOS Test Restaurant',
      '123 Test Street, Ho Chi Minh City',
      'globos-test',
      'standard',
      true
    );

    -- Insert tables (T01-T10)
    INSERT INTO tables (restaurant_id, table_number, seat_count, status)
    SELECT
      'aaaaaaaa-0000-0000-0000-000000000001',
      'T' || LPAD(n::text, 2, '0'),
      4,
      'available'
    FROM generate_series(1, 10) AS n;

    -- Insert menu categories
    INSERT INTO menu_categories (id, restaurant_id, name, sort_order)
    VALUES
      ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'Food', 1),
      ('bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001', 'Drinks', 2),
      ('bbbbbbbb-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000001', 'Desserts', 3);

    -- Insert menu items
    INSERT INTO menu_items (restaurant_id, category_id, name, price, is_available)
    VALUES
      ('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', 'Bulgogi Rice', 89000, true),
      ('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', 'Kimchi Jjigae', 79000, true),
      ('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', 'Bibimbap', 75000, true),
      ('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', 'Tteokbokki', 65000, true),
      ('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002', 'Korean Barley Tea', 25000, true),
      ('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002', 'Sikhye', 30000, true),
      ('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002', 'Makgeolli', 45000, true),
      ('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000003', 'Bingsu', 55000, true),
      ('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000003', 'Hotteok', 35000, true);

  END IF;
END $$;
