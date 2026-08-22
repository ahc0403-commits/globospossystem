BEGIN;

-- production-gate: self-verifying
-- Complete the customer/cashier English catalogue for the two BunsikClub
-- stores. Korean names, Vietnamese names, prices, availability, images,
-- kitchen labels, and category routing are intentionally left untouched.
CREATE TEMP TABLE bunsik_menu_english_seed (
  name_ko text PRIMARY KEY,
  name_en text NOT NULL
) ON COMMIT DROP;

INSERT INTO bunsik_menu_english_seed(name_ko, name_en) VALUES
  ('오리지널 김밥', 'Original Kimbap'),
  ('치즈김밥', 'Cheese Kimbap'),
  ('참치김밥', 'Tuna Kimbap'),
  ('소시지김밥', 'Sausage Kimbap'),
  ('게맛살튀김김밥', 'Crispy Crab Stick Kimbap'),
  ('돈까스김밥', 'Donkatsu Kimbap'),
  ('계란말이김밥', 'Rolled Omelet Kimbap'),
  ('제육쌈 김밥 [쌈야채 제공]', 'Spicy Pork Kimbap (Wrap Vegetables Included)'),
  ('불고기쌈 김밥 [쌈야채 제공]', 'Bulgogi Kimbap (Wrap Vegetables Included)'),
  ('계란라면', 'Egg Ramen'),
  ('치즈라면', 'Cheese Ramen'),
  ('해물잔치라면 (안매움)', 'Seafood Janchi Ramen (Not Spicy)'),
  ('떡만두라면', 'Rice Cake and Mandu Ramen'),
  ('해물라면', 'Seafood Ramen'),
  ('짜계치 [짜장 계란후라이 치즈]', 'Jjagyechi (Black Bean Noodles, Fried Egg and Cheese)'),
  ('불닭계란볶음면', 'Buldak Egg Stir-Fried Noodles'),
  ('군만두', 'Fried Mandu'),
  ('찐만두', 'Steamed Mandu'),
  ('만두국', 'Mandu Soup'),
  ('떡만두국', 'Rice Cake and Mandu Soup'),
  ('비빔냉면', 'Bibim Naengmyeon'),
  ('물냉면', 'Mul Naengmyeon'),
  ('잡채', 'Japchae'),
  ('오뎅 유부우동', 'Fish Cake and Tofu Udon'),
  ('해물 유부우동', 'Seafood and Tofu Udon'),
  ('김치 유부우동', 'Kimchi and Tofu Udon'),
  ('참치김치볶음밥', 'Tuna Kimchi Fried Rice'),
  ('햄김치볶음밥', 'Ham Kimchi Fried Rice'),
  ('치킨마요 덮밥', 'Chicken Mayo Rice Bowl'),
  ('돌솥 불고기 비빔밥', 'Stone Pot Bulgogi Bibimbap'),
  ('돌솥 제육 비빔밥', 'Stone Pot Spicy Pork Bibimbap'),
  ('밥', 'Steamed Rice'),
  ('쌀밥', 'Steamed Rice'),
  ('돈까스', 'Donkatsu (Breaded Pork Cutlet)'),
  ('오뎅탕 (쌀밥포함)', 'Fish Cake Soup (Rice Included)'),
  ('소고기 미역국 (쌀밥포함)', 'Beef Seaweed Soup (Rice Included)'),
  ('참치 김치찌개 (쌀밥포함)', 'Tuna Kimchi Stew (Rice Included)'),
  ('돼지고기 김치찌개 (쌀밥포함)', 'Pork Kimchi Stew (Rice Included)'),
  ('해물 김치찌개 (쌀밥포함)', 'Seafood Kimchi Stew (Rice Included)'),
  ('뚝배기 불고기 (쌀밥포함)', 'Earthen Pot Bulgogi (Rice Included)'),
  ('오리지널 떡볶이', 'Original Tteokbokki'),
  ('로제 떡볶이', 'Rose Tteokbokki'),
  ('크림 떡볶이', 'Cream Tteokbokki'),
  ('치즈떡볶이', 'Cheese Tteokbokki'),
  ('치즈떡붂이', 'Cheese Tteokbokki'),
  ('라볶이(떡볶이+라면+계란)', 'Rabokki (Tteokbokki, Ramen and Egg)'),
  ('라붂이(떡붂이+라면+계란)', 'Rabokki (Tteokbokki, Ramen and Egg)'),
  ('어묵튀김 (2개)', 'Fried Fish Cake (2 Pieces)'),
  ('오징어튀김 (2개)', 'Fried Squid (2 Pieces)'),
  ('맛살 튀김 (2개)', 'Fried Crab Sticks (2 Pieces)'),
  ('김말이 (2개)', 'Kimmari (2 Pieces)'),
  ('새우튀김 (2개)', 'Fried Shrimp (2 Pieces)'),
  ('소시지꼬치(2개)', 'Sausage Skewers (2 Pieces)'),
  ('핫도그 (1개)', 'Korean Hot Dog (1 Piece)'),
  ('떡강정(떡꼬치)', 'Sweet and Spicy Rice Cake Skewer'),
  ('치즈떡강정', 'Cheese Rice Cake Skewer'),
  ('소시지떡강정 (소떡소떡)', 'Sausage and Rice Cake Skewer (Sotteok Sotteok)'),
  ('감자튀김', 'French Fries'),
  ('치즈 감자튀김', 'Cheese Fries'),
  ('야채계란말이', 'Vegetable Rolled Omelet'),
  ('치즈계란말이', 'Cheese Rolled Omelet'),
  ('소시지계란말이', 'Sausage Rolled Omelet'),
  ('순살 후라이드 치킨', 'Original Boneless Fried Chicken'),
  ('순살 양념 치킨', 'Yangnyeom Boneless Chicken'),
  ('순살 간장치킨', 'Soy Garlic Boneless Chicken'),
  ('어니언크림 순살치킨', 'Onion Cream Boneless Chicken'),
  ('치즈파우더 순살치킨', 'Cheese Powder Boneless Chicken'),
  ('치즈 핫 순살치킨', 'Spicy Cheese Boneless Chicken'),
  ('콜라', 'Coca-Cola'),
  ('코카코라 제로', 'Coca-Cola Zero'),
  ('스프라이트', 'Sprite'),
  ('환다 오렌지', 'Fanta Orange'),
  ('스팅 딸기', 'Strawberry Sting'),
  ('생수', 'Dasani Water'),
  ('계란후라이 (1개)', 'Fried Egg (1 Piece)'),
  ('라면사리', 'Extra Ramen Noodles'),
  ('모짜렐라치즈 (20g)', 'Mozzarella Cheese (20g)'),
  ('삶은계란 (1개)', 'Boiled Egg (1 Piece)'),
  ('야채쌈 (5장)', 'Wrap Vegetables (5 Leaves)'),
  ('어묵추가 (20g)', 'Extra Fish Cake (20g)'),
  ('음료', 'Drink'),
  ('체다치즈 (1장)', 'Cheddar Cheese (1 Slice)'),
  ('핫팟어묵 (3알)', 'Hotpot Fish Cake (3 Pieces)'),
  ('해물(새우,오징어,조개)', 'Seafood (Shrimp, Squid and Clams)'),
  ('(Combo1)오리지널떡볶이 + 참치김밥 + 음료1', '(Combo 1) Original Tteokbokki + Tuna Kimbap + 1 Drink'),
  ('(Combo2)계란라면 + 치즈김밥 + 음료1', '(Combo 2) Egg Ramen + Cheese Kimbap + 1 Drink'),
  ('(Combo3)로제떡볶이 + 게맛살튀김김밥 + 해물라면+ 야채계란말이 + 음료2개', '(Combo 3) Rose Tteokbokki + Crispy Crab Stick Kimbap + Seafood Ramen + Vegetable Rolled Omelet + 2 Drinks'),
  ('(Combo4)뚝배기불고기 + 참치김치찌개 + 찐만두+ 야채계란말이 + 음료2개', '(Combo 4) Earthen Pot Bulgogi + Tuna Kimchi Stew + Steamed Mandu + Vegetable Rolled Omelet + 2 Drinks'),
  ('(Combo5)돈까스 + 비빔냉면 + 제육쌈김밥 + 야채계란말이+ 음료2개', '(Combo 5) Donkatsu + Bibim Naengmyeon + Spicy Pork Kimbap + Vegetable Rolled Omelet + 2 Drinks'),
  ('(Combo6)순살 양념치킨 + 불고기쌈김밥 + 참치김치찌개+ 치즈감자튀김 + 음료2개', '(Combo 6) Yangnyeom Boneless Chicken + Bulgogi Kimbap + Tuna Kimchi Stew + Cheese Fries + 2 Drinks');

CREATE TEMP TABLE bunsik_category_english_seed (
  name_ko text PRIMARY KEY,
  name_en text NOT NULL
) ON COMMIT DROP;

INSERT INTO bunsik_category_english_seed(name_ko, name_en) VALUES
  ('김밥', 'Kimbap'),
  ('라면', 'Ramen'),
  ('치킨', 'Fried Chicken'),
  ('떡볶이', 'Tteokbokki'),
  ('튀김', 'Fried Snacks'),
  ('밥', 'Rice Dishes'),
  ('면', 'Noodles'),
  ('탕', 'Soups'),
  ('돈까스', 'Donkatsu'),
  ('만두', 'Mandu'),
  ('계란말이', 'Rolled Omelets'),
  ('간식', 'Snacks'),
  ('음료', 'Drinks'),
  ('주류', 'Alcohol'),
  ('추가', 'Add-ons'),
  ('콤보', 'Combos');

DO $$
BEGIN
  IF (SELECT count(*) FROM bunsik_menu_english_seed) <> 90
     OR (SELECT count(*) FROM bunsik_category_english_seed) <> 16
     OR EXISTS (
       SELECT 1 FROM bunsik_menu_english_seed
       WHERE btrim(name_ko) = '' OR btrim(name_en) = ''
     )
     OR EXISTS (
       SELECT 1 FROM bunsik_category_english_seed
       WHERE btrim(name_ko) = '' OR btrim(name_en) = ''
     ) THEN
    RAISE EXCEPTION 'BUNSIK_ENGLISH_SEED_INVALID';
  END IF;

  IF (SELECT count(*) FROM public.restaurants
      WHERE id IN (
        '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid,
        '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
      ) AND is_active = true) <> 2 THEN
    RAISE EXCEPTION 'BUNSIK_ENGLISH_TARGET_STORES_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.menu_items menu
    LEFT JOIN bunsik_menu_english_seed seed
      ON seed.name_ko = regexp_replace(
        btrim(COALESCE(NULLIF(menu.name_ko, ''), menu.name)),
        '\s+', ' ', 'g'
      )
    WHERE menu.restaurant_id IN (
      '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid,
      '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
    )
      AND seed.name_ko IS NULL
  ) THEN
    RAISE EXCEPTION 'BUNSIK_ENGLISH_MENU_COVERAGE_INCOMPLETE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.menu_categories category
    LEFT JOIN bunsik_category_english_seed seed
      ON seed.name_ko = btrim(COALESCE(NULLIF(category.name_ko, ''), category.name))
    WHERE category.restaurant_id IN (
      '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid,
      '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
    )
      AND seed.name_ko IS NULL
  ) THEN
    RAISE EXCEPTION 'BUNSIK_ENGLISH_CATEGORY_COVERAGE_INCOMPLETE';
  END IF;
END;
$$;

UPDATE public.menu_items menu
SET name_en = seed.name_en,
    updated_at = now()
FROM bunsik_menu_english_seed seed
WHERE menu.restaurant_id IN (
    '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid,
    '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
  )
  AND seed.name_ko = regexp_replace(
    btrim(COALESCE(NULLIF(menu.name_ko, ''), menu.name)),
    '\s+', ' ', 'g'
  )
  AND menu.name_en IS DISTINCT FROM seed.name_en;

UPDATE public.menu_categories category
SET name_en = seed.name_en
FROM bunsik_category_english_seed seed
WHERE category.restaurant_id IN (
    '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid,
    '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
  )
  AND seed.name_ko = btrim(COALESCE(NULLIF(category.name_ko, ''), category.name))
  AND category.name_en IS DISTINCT FROM seed.name_en;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.menu_items menu
    JOIN bunsik_menu_english_seed seed
      ON seed.name_ko = regexp_replace(
        btrim(COALESCE(NULLIF(menu.name_ko, ''), menu.name)),
        '\s+', ' ', 'g'
      )
    WHERE menu.restaurant_id IN (
      '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid,
      '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
    )
      AND menu.name_en IS DISTINCT FROM seed.name_en
  ) OR EXISTS (
    SELECT 1
    FROM public.menu_categories category
    JOIN bunsik_category_english_seed seed
      ON seed.name_ko = btrim(COALESCE(NULLIF(category.name_ko, ''), category.name))
    WHERE category.restaurant_id IN (
      '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid,
      '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
    )
      AND category.name_en IS DISTINCT FROM seed.name_en
  ) THEN
    RAISE EXCEPTION 'BUNSIK_ENGLISH_POSTCONDITION_FAILED';
  END IF;
END;
$$;

COMMIT;
