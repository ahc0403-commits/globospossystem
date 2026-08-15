BEGIN;

-- production-gate: self-verifying
-- Source: 분식클럽_메뉴_전체정리(한베영).xlsx, sheet "Menu 메뉴".
-- Only the KDS override is changed; customer names, price, image, route,
-- availability, and category data remain untouched.
CREATE TEMP TABLE paperless_menu_seed (
  name_ko text PRIMARY KEY,
  paperless_name_vi text NOT NULL
) ON COMMIT DROP;

INSERT INTO paperless_menu_seed(name_ko, paperless_name_vi) VALUES
  ('오리지널 김밥', 'Kimbap Truyền Thống'),
  ('치즈김밥', 'Kimbap Phô Mai'),
  ('참치김밥', 'Kimbap Cá Ngừ'),
  ('소시지김밥', 'Kimbap Xúc Xích'),
  ('게맛살튀김김밥', 'Kimbap Thanh Cua Chiên Giòn'),
  ('돈까스김밥', 'Kimbap Donkatsu'),
  ('계란말이김밥', 'Kimbap Trứng Cuộn'),
  ('제육쌈 김밥', 'Kimbap Thịt Heo Cay'),
  ('불고기쌈 김밥', 'Kimbap Bulgogi'),
  ('계란라면', 'Mì Ramen Trứng'),
  ('치즈라면', 'Mì Ramen Phô Mai'),
  ('해물잔치라면', 'Mì Janchi Hải Sản'),
  ('떡만두라면', 'Mì Ramen Bánh Gạo & Mandu'),
  ('해물라면', 'Mì Ramen Hải Sản'),
  ('짜계치', 'Jjagyechi'),
  ('불닭계란볶음면', 'Mì Buldak'),
  ('군만두', 'Mandu Chiên'),
  ('찐만두', 'Mandu Hấp'),
  ('만두국', 'Canh Mandu'),
  ('떡만두국', 'Canh Bánh Gạo & Mandu'),
  ('비빔냉면', 'Mì Lạnh Trộn'),
  ('잡채', 'Japchae'),
  ('오뎅 유부우동', 'Udon Đậu Hũ Chả Cá'),
  ('해물 유부우동', 'Udon Đậu Hũ Hải Sản'),
  ('김치 유부우동', 'Udon Đậu Hũ Kimchi'),
  ('참치김치볶음밥', 'Cơm Chiên Cá Ngừ Kimchi'),
  ('햄김치볶음밥', 'Cơm Chiên Kimchi Ham'),
  ('치킨마요 덮밥', 'Cơm Gà Sốt Mayo'),
  ('돌솥 불고기 비빔밥', 'Cơm Trộn Bulgogi'),
  ('돌솥 제육 비빔밥', 'Cơm Trộn Thịt Heo Cay'),
  ('쌀밥', 'Cơm Trắng'),
  ('돈까스', 'Donkatsu'),
  ('오뎅탕', 'Canh Chả Cá'),
  ('소고기 미역국', 'Canh Rong Biển Thịt Bò'),
  ('참치 김치찌개', 'Canh Kimchi Cá Ngừ'),
  ('돼지고기 김치찌개', 'Canh Kimchi Thịt Heo'),
  ('해물 김치찌개', 'Canh Kimchi Hải Sản'),
  ('뚝배기 불고기', 'Bulgogi Nồi Đất Nung'),
  ('오리지널 떡볶이', 'Tteokbokki Truyền Thống'),
  ('로제 떡볶이', 'Tteokbokki Sốt Rosé'),
  ('크림 떡볶이', 'Tteokbokki Sốt Kem'),
  ('치즈떡볶이', 'Tteokbokki Phô Mai'),
  ('라볶이', 'Rabokki'),
  ('어묵튀김', 'Chả Cá Chiên'),
  ('오징어튀김', 'Mực Chiên'),
  ('맛살 튀김', 'Thanh Cua Chiên'),
  ('김말이', 'Cuộn Rong Biển Chiên'),
  ('새우튀김', 'Tôm Chiên'),
  ('소시지꼬치', 'Xúc Xích Xiên Que'),
  ('핫도그', 'Hot Dog Kiểu Hàn'),
  ('떡강정(떡꼬치)', 'Xiên Bánh Gạo Sốt Cay Ngọt'),
  ('치즈떡강정', 'Xiên Bánh Gạo Phô Mai'),
  ('소시지떡강정', 'Xiên Bánh Gạo Xúc Xích'),
  ('감자튀김', 'Khoai Tây Chiên'),
  ('치즈 감자튀김', 'Khoai Tây Chiên Phô Mai'),
  ('야채계란말이', 'Trứng Cuộn Rau Củ'),
  ('치즈계란말이', 'Trứng Cuộn Phô Mai'),
  ('소시지계란말이', 'Trứng Cuộn Xúc Xích'),
  ('순살 후라이드 치킨', 'Gà Rán Truyền Thống'),
  ('순살 양념 치킨', 'Gà Sốt Yangnyeom'),
  ('순살 간장치킨', 'Gà Sốt Tương'),
  ('어니언크림 순살치킨', 'Gà Sốt Kem Hành'),
  ('치즈파우더 순살치킨', 'Gà Rắc Bột Phô Mai'),
  ('치즈 핫 순살치킨', 'Gà Sốt Phô Mai Cay'),
  ('콜라', 'Coca-Cola'),
  ('제로콜라', 'Coca-Cola Zero'),
  ('스프라이트', 'Sprite'),
  ('환타오렌지', 'Fanta Cam'),
  ('스팅 딸기맛', 'Sting Dâu'),
  ('물', 'Nước Suối'),
  ('물티슈', 'Khăn Ướt');

DO $$
BEGIN
  IF (SELECT count(*) FROM paperless_menu_seed) <> 71
     OR EXISTS (
       SELECT 1 FROM paperless_menu_seed
       WHERE btrim(name_ko) = '' OR btrim(paperless_name_vi) = ''
     ) THEN
    RAISE EXCEPTION 'BUNSIK_PAPERLESS_SEED_SOURCE_INVALID';
  END IF;
END;
$$;

-- Production currently carries quantity suffixes, service notes, and a small
-- number of legacy Korean typos that are intentionally absent from the source
-- workbook. Keep those aliases local to this one-time data migration.
CREATE TEMP TABLE paperless_menu_alias (
  menu_name_ko text PRIMARY KEY,
  seed_name_ko text NOT NULL REFERENCES paperless_menu_seed(name_ko)
) ON COMMIT DROP;

INSERT INTO paperless_menu_alias(menu_name_ko, seed_name_ko) VALUES
  ('김말이 (2개)', '김말이'),
  ('라볶이(떡볶이+라면+계란)', '라볶이'),
  ('라붂이(떡붂이+라면+계란)', '라볶이'),
  ('맛살 튀김 (2개)', '맛살 튀김'),
  ('생수', '물'),
  ('밥', '쌀밥'),
  ('불고기쌈 김밥 [쌈야채 제공]', '불고기쌈 김밥'),
  ('새우튀김 (2개)', '새우튀김'),
  ('소시지꼬치(2개)', '소시지꼬치'),
  ('소시지떡강정 (소떡소떡)', '소시지떡강정'),
  ('스팅 딸기', '스팅 딸기맛'),
  ('어묵튀김 (2개)', '어묵튀김'),
  ('오징어튀김 (2개)', '오징어튀김'),
  ('코카코라 제로', '제로콜라'),
  ('제육쌈 김밥 [쌈야채 제공]', '제육쌈 김밥'),
  ('짜계치 [짜장 계란후라이 치즈]', '짜계치'),
  ('핫도그 (1개)', '핫도그'),
  ('해물잔치라면 (안매움)', '해물잔치라면'),
  ('환다 오렌지', '환타오렌지'),
  ('치즈떡붂이', '치즈떡볶이');

DO $$
BEGIN
  IF (
    SELECT count(*)
    FROM public.restaurants
    WHERE upper(btrim(short_code)) IN ('BT', 'SP')
      AND is_active = true
  ) <> 2
     OR NOT EXISTS (
       SELECT 1 FROM public.restaurants
       WHERE upper(btrim(short_code)) = 'BT' AND is_active = true
     )
     OR NOT EXISTS (
       SELECT 1 FROM public.restaurants
       WHERE upper(btrim(short_code)) = 'SP' AND is_active = true
     ) THEN
    RAISE EXCEPTION 'BUNSIK_PAPERLESS_TARGET_STORE_CARDINALITY_INVALID';
  END IF;
END;
$$;

WITH normalized_menu AS (
  SELECT
    menu.id AS menu_id,
    restaurant.id AS restaurant_id,
    regexp_replace(
      regexp_replace(
        btrim(COALESCE(NULLIF(menu.name_ko, ''), menu.name)),
        '\s*\(쌀밥포함\)\s*$',
        '',
        'g'
      ),
      '\s+',
      ' ',
      'g'
    ) AS menu_key
  FROM public.menu_items menu
  JOIN public.restaurants restaurant ON restaurant.id = menu.restaurant_id
  WHERE upper(btrim(restaurant.short_code)) IN ('BT', 'SP')
    AND restaurant.is_active = true
), matched_menu AS (
  SELECT normalized.menu_id, normalized.restaurant_id, seed.paperless_name_vi
  FROM normalized_menu normalized
  LEFT JOIN paperless_menu_alias alias ON alias.menu_name_ko = normalized.menu_key
  JOIN paperless_menu_seed seed
    ON seed.name_ko = COALESCE(alias.seed_name_ko, normalized.menu_key)
)
UPDATE public.menu_items menu
SET paperless_name_vi = matched.paperless_name_vi,
    updated_at = now()
FROM matched_menu matched
WHERE menu.id = matched.menu_id
  AND menu.restaurant_id = matched.restaurant_id
  AND menu.paperless_name_vi IS DISTINCT FROM matched.paperless_name_vi;

DO $$
BEGIN
  IF EXISTS (
    WITH normalized_menu AS (
      SELECT
        menu.paperless_name_vi,
        regexp_replace(
          regexp_replace(
            btrim(COALESCE(NULLIF(menu.name_ko, ''), menu.name)),
            '\s*\(쌀밥포함\)\s*$',
            '',
            'g'
          ),
          '\s+',
          ' ',
          'g'
        ) AS menu_key
      FROM public.menu_items menu
      JOIN public.restaurants restaurant ON restaurant.id = menu.restaurant_id
      WHERE upper(btrim(restaurant.short_code)) IN ('BT', 'SP')
        AND restaurant.is_active = true
    )
    SELECT 1
    FROM normalized_menu normalized
    LEFT JOIN paperless_menu_alias alias ON alias.menu_name_ko = normalized.menu_key
    JOIN paperless_menu_seed seed
      ON seed.name_ko = COALESCE(alias.seed_name_ko, normalized.menu_key)
    WHERE normalized.paperless_name_vi IS DISTINCT FROM seed.paperless_name_vi
  ) THEN
    RAISE EXCEPTION 'BUNSIK_PAPERLESS_SEED_VERIFICATION_FAILED';
  END IF;

  -- Both current stores contain every workbook menu except 물티슈, which is
  -- not registered in either catalog. Fail before commit if any other source
  -- menu is absent from either store, while still supporting it if registered
  -- before this migration runs.
  IF EXISTS (
    WITH target_store AS (
      SELECT id
      FROM public.restaurants
      WHERE upper(btrim(short_code)) IN ('BT', 'SP')
        AND is_active = true
    ), normalized_menu AS (
      SELECT
        menu.restaurant_id,
        regexp_replace(
          regexp_replace(
            btrim(COALESCE(NULLIF(menu.name_ko, ''), menu.name)),
            '\s*\(쌀밥포함\)\s*$',
            '',
            'g'
          ),
          '\s+',
          ' ',
          'g'
        ) AS menu_key
      FROM public.menu_items menu
      JOIN target_store target ON target.id = menu.restaurant_id
    ), matched_menu AS (
      SELECT
        normalized.restaurant_id,
        COALESCE(alias.seed_name_ko, normalized.menu_key) AS seed_name_ko
      FROM normalized_menu normalized
      LEFT JOIN paperless_menu_alias alias ON alias.menu_name_ko = normalized.menu_key
    )
    SELECT 1
    FROM target_store target
    CROSS JOIN paperless_menu_seed seed
    WHERE seed.name_ko <> '물티슈'
      AND NOT EXISTS (
        SELECT 1
        FROM matched_menu matched
        WHERE matched.restaurant_id = target.id
          AND matched.seed_name_ko = seed.name_ko
      )
  ) THEN
    RAISE EXCEPTION 'BUNSIK_PAPERLESS_PER_STORE_COVERAGE_FAILED';
  END IF;
END;
$$;

COMMIT;
