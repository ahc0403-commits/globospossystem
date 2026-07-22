-- Force all physical printer menu labels to use the Vietnamese menu field.
-- The source translations are the user-approved multilingual workbook
-- menu_multilingual_20260722.xlsx (99 stable menu item IDs).

CREATE TEMP TABLE vietnamese_print_menu_source (
  item_id uuid PRIMARY KEY,
  store_id uuid NOT NULL,
  name_vi text NOT NULL
);

INSERT INTO vietnamese_print_menu_source (item_id, store_id, name_vi)
VALUES
  ('88d94d10-7a42-469c-9d84-b198660e8895', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Kimbap truyền thống'),
  ('9438209e-3d5b-476e-8a1f-81bb2bbfab22', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Kimbap phô mai'),
  ('a89eddd8-8992-4b3e-bbc5-e88ac2d94beb', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Kimbap cá ngừ'),
  ('c1f9e44b-31c1-40f5-a9d7-6aade6d6df62', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Kimbap xúc xích'),
  ('9cfc91d8-187c-4e01-bc25-5053da5b273c', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Kimbap thịt heo cay cuốn rau'),
  ('6cedb7be-3812-4a0e-90a8-dd9002acaff6', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Kimbap bò bulgogi'),
  ('7a0559bf-b301-422d-abd1-d767d96607f9', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Kimbap tôm chiên giòn'),
  ('c93cb0a3-084b-42f9-8c70-658055fe8e8d', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Kimbap donkatsu'),
  ('b171cb47-20ad-497a-bd7e-768dc19eae5a', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Kimbap trứng cuộn'),
  ('10e22c74-2599-4711-8dae-e53551d8bfec', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Kimbap đậu hũ chiên'),
  ('095e786b-a1b7-467e-be0d-91e5321bebe2', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Kimbap khổng lồ'),
  ('e9249f46-eb5f-4b49-86bf-2b96886a36f7', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Mì ramen trứng'),
  ('261e27ad-221d-436d-907d-ced19442a38a', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Mì ramen phô mai'),
  ('51cdfda3-3f55-4100-9d37-c4e71e780076', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Mì ramen bánh gạo và mandu'),
  ('66988d96-6cd3-4c82-917b-f7b7a1746544', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Mì ramen hải sản'),
  ('be3bd7cc-fad0-4bb2-839a-9a583a274197', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Mì tương đen với trứng ốp la và phô mai'),
  ('3b6db611-3372-4b14-ad96-c79e9419b614', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Mì nước dùng xương bò với hành lá và tỏi'),
  ('429b4200-d450-4213-ac89-e0b9a42a1e31', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Mì janchi nước dùng cá cơm kiểu Veteran'),
  ('8984716d-d4fe-40f9-838b-cddfbdb1fcfe', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Mì gà cay Samyang phủ trứng cuộn'),
  ('c33d8e86-c740-4aec-b1e0-fe805921ea44', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Mì gà siêu cay Samyang'),
  ('7b52bdb1-4a4e-4063-b1eb-7cb619ca6954', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Canh bánh xếp Hàn Quốc (Mandu)'),
  ('0864bf3b-08c1-4802-81d2-c6cb577db55b', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Canh bánh gạo và bánh xếp Mandu'),
  ('dd82519c-f530-4116-b6da-aba02101742c', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Bánh xếp Mandu chiên giòn'),
  ('e78f8305-9b35-4176-88e5-05e9d148bb3b', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Bánh xếp Mandu hấp'),
  ('054183e8-4859-473d-94da-5a80a1c0dbe3', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Mì lạnh nước dùng'),
  ('4790e3f0-4392-4b39-8f2b-36f36e5a4f73', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Mì lạnh trộn cay'),
  ('87903180-98aa-49ef-94c1-c6a07dc399d1', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Miến xào Japchae'),
  ('1a1006c5-b2b2-46a3-94d1-0f3834bc38ae', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Mì dai trộn cay Jjolmyeon'),
  ('8ba2083f-7349-4127-a25c-1145ab3809fe', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Udon hải sản và đậu hũ chiên'),
  ('6ccd2c8c-d32d-46f4-b1e8-f32c05ba93c3', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Udon chả cá và đậu hũ chiên'),
  ('cbb959e3-91a0-4eec-8247-efc7ed99d190', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Udon kimchi và đậu hũ chiên'),
  ('3be4f38c-ef01-4cd7-bf85-8c0bcbba00cc', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Cơm trộn bulgogi với bơ và trứng'),
  ('5aebdd01-77b1-4680-9dc8-90594d13ae6c', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Cơm chiên kimchi cá ngừ'),
  ('5cec8a38-dbbb-4b39-8be9-f7b24e9e60cc', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Cơm chiên kimchi thịt xông khói'),
  ('43a1eb25-ac4c-46ee-bcae-2cb428db302a', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Cơm trộn thố đá truyền thống'),
  ('1df63b35-82b6-491f-8e6a-ef2a3f4f3b99', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Cơm trộn thố đá bò bulgogi'),
  ('63a465cc-d20a-40e1-8155-3476723aa0bf', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Cơm trộn thố đá thịt heo cay'),
  ('26d51179-9583-41c6-93c4-85d585bb7397', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Cơm thịt heo xào cay'),
  ('b6a7cac4-0883-4c47-bcff-5a6b75c52d81', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Cơm bò bulgogi'),
  ('6edf3964-958a-4081-8d7c-53bf3d204bd4', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Cơm gà sốt mayonnaise'),
  ('f1678503-e41e-4691-92cd-39dd8dbf5ab3', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Thịt heo chiên xù Donkatsu'),
  ('84e6760a-a0ee-453f-ab62-35bb0303d644', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Donkatsu nhân phô mai'),
  ('74537966-2da3-435b-9b75-cb7b8e1e2bf1', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Canh rong biển'),
  ('a1ac3e1d-f79d-437d-bf43-bc36f22dd67c', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Canh kimchi thịt heo'),
  ('bbedf516-bca6-4a8f-b95a-e6a17830d8e9', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Canh kimchi hải sản'),
  ('b69f317f-85f6-4646-bf7f-c0273f04aa6b', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Canh chả cá Hàn Quốc'),
  ('3b04c86d-819c-4b79-ac73-5fede52ccc54', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Tteokbokki truyền thống'),
  ('af4c3502-ab29-4c60-b723-b4192512040e', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Tteokbokki sốt rosé'),
  ('da8b0919-37b4-4b13-b235-4fa10cd66098', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Tteokbokki sốt kem'),
  ('a65d6220-7b44-4956-80ec-58e6fb8a840e', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Tteokbokki sốt mala'),
  ('4a3c66e9-9030-4c15-91d1-1ae945d10470', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Tteokbokki sốt tương đen'),
  ('b7447f36-f897-436a-8816-0accf1057f2b', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Thêm hải sản'),
  ('6229a22e-671a-46b0-bfa7-01c130e09a33', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Thêm phô mai cheddar'),
  ('8a0cb733-20f2-456a-bd1d-508dc19fb1e1', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Thêm phô mai mozzarella'),
  ('941ff260-bef1-42d8-85e1-4b547158b85e', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Thêm mì ramen'),
  ('14382ab9-ab82-4770-b563-9d39f954b2fe', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Thêm mì dai Jjolmyeon'),
  ('25f76588-9dd2-4a47-bbf8-adb87ec33f62', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Thêm chả cá'),
  ('1d311a45-2eff-4f48-8315-dc91a1dc516a', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Chả cá chiên'),
  ('0edffb4d-69ba-4e91-aa47-ab6e2a0d6458', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Trứng luộc'),
  ('ddb4de6d-ce60-4a05-9280-7a3e813e83cc', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Trứng ốp la'),
  ('79d312d3-38d3-4471-be30-df0167c4927f', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Xiên chả cá lẩu'),
  ('fbf259e6-970e-4de6-9012-229d8a6e3b1a', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Tôm chiên giòn'),
  ('d3bc693a-c71c-43d8-86a9-1e3e9a0dd56e', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Mực chiên giòn'),
  ('872451e3-44ff-40c4-8860-83dfd8fe79a0', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Miến cuộn rong biển chiên giòn'),
  ('b7dba2ff-dd59-4288-bce8-2c8f845d9757', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Rau củ chiên giòn'),
  ('2df52791-0d70-4ae2-bb9a-b6edeba82a0e', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Dồi huyết Hàn Quốc (Sundae)'),
  ('4145fa2c-ae96-4ff9-b05a-b09a0e73c267', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Bánh hot dog mini kiểu Hàn Quốc'),
  ('1a56e598-e671-41ec-90f0-d090159575ad', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Xiên xúc xích và bánh gạo Sotteok'),
  ('f3728392-28c1-4628-9c26-64b2352a9f7a', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Xiên xúc xích'),
  ('ee8115b9-ca4d-42b1-8234-7c19489106d9', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Xiên bánh gạo sốt cay ngọt'),
  ('fc9d0e45-86bb-443a-baa2-487a49c63a73', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Dồi huyết Sundae mini chiên giòn'),
  ('ee06a0ba-224b-4b3b-89a9-064787deacd6', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Khoai tây chiên'),
  ('3c626b70-5896-49ac-b4de-9949017602c1', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Trứng cuộn rau củ'),
  ('d52e9851-d46b-4810-9a3e-283bd1ad08a4', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Trứng cuộn phô mai'),
  ('af10eeb2-c134-4097-9b30-5ba600ee393d', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Trứng cuộn xúc xích'),
  ('6c5cce63-7813-4672-9398-96e3df557f2a', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Gà rán nguyên vị'),
  ('5e0f393a-5991-4de4-9007-2bd9f6335ef9', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Gà rán sốt cay ngọt'),
  ('c5a12a5e-a0c8-471c-9022-314e3c0b27ea', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Gà rán sốt xì dầu tỏi'),
  ('8e5e45c9-3a3e-4ecc-86d3-f781ee891419', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Gà rán sốt kem hành tây'),
  ('c94ae9d4-4cc6-4733-a945-240014c8d22a', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Gà rán phủ bột phô mai Ppuringkle'),
  ('35073b4d-35d0-42a0-afab-ebe4c1f55d89', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Gà rán siêu cay'),
  ('e540288b-9ffd-4588-ade3-a9caff135eaa', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Combo ăn vặt cho 1 người'),
  ('efd63a5f-d763-44ff-a963-008a39a1b016', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Combo đặc biệt Hàn Quốc'),
  ('363c2a5b-cc8c-4f41-a924-ffdcc81e74e0', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Combo ramen và kimbap'),
  ('6430a874-f80d-4a58-ba47-3618a96c7e58', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Combo ăn vặt cho 2 người'),
  ('3c81832e-2eab-4547-95eb-0a7aad2d206f', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Combo tiệc gà rán'),
  ('4c5be6f9-ed4b-448e-af39-81da9aa4fc1c', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Combo đồ ăn đường phố'),
  ('7338787b-637d-444d-bad5-809acfe40d90', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Combo cơm và canh'),
  ('861caf23-d790-4254-bb1e-853ea6cde9e4', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Combo tiệc Bunsik Club'),
  ('45fa52a2-157e-4d79-ba8e-6235602485d1', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Combo mâm cơm Hàn Quốc'),
  ('fd4b76b5-00ca-462f-82a2-7c71231e72be', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Combo thử thách siêu cay'),
  ('b2aebb30-36b2-40ec-b1f0-07e1498ff752', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Trà đá'),
  ('5fb7dcd2-853b-4e0f-903b-ac551163a253', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Nước ngũ cốc rang Misugaru'),
  ('858e8f17-b69f-48f8-a17c-ba2c929dfc69', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Nước uống vị sữa chua Coolpis'),
  ('865408f0-26fb-4bf5-9c77-58da7e0470ee', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Trà xanh mật ong'),
  ('ea411674-3cc2-4e3f-914f-1973bf484494', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Coca-Cola'),
  ('821f0b80-46dd-49f6-82d1-383142cc07bf', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Nước ngọt có ga vị chanh'),
  ('426d7dba-c50e-4bbe-82ac-35e066733cab', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Nước gạo Hàn Quốc Achim Haetsal'),
  ('40a0e119-f0d5-4e23-bf25-d64aaa214964', '8bc9eef5-dcd5-46b1-b931-23f77132322c', 'Nước gạo ngọt truyền thống Sikhye');

DO $translations$
DECLARE
  v_source_count integer;
  v_updated_count integer;
BEGIN
  SELECT count(*) INTO v_source_count
  FROM vietnamese_print_menu_source;

  IF v_source_count <> 99 THEN
    RAISE EXCEPTION 'VIETNAMESE_PRINT_TRANSLATION_SOURCE_COUNT_INVALID:%',
      v_source_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM vietnamese_print_menu_source
    WHERE NULLIF(btrim(name_vi), '') IS NULL
       OR name_vi ~ '[가-힣]'
  ) THEN
    RAISE EXCEPTION 'VIETNAMESE_PRINT_TRANSLATION_SOURCE_INVALID';
  END IF;

  -- Fresh/local databases do not contain the production restaurant. Keep the
  -- migration replayable there, while requiring an exact 99-row match in prod.
  IF EXISTS (
    SELECT 1
    FROM public.restaurants
    WHERE id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
  ) THEN
    UPDATE public.menu_items mi
    SET name_vi = btrim(source.name_vi),
        updated_at = now()
    FROM vietnamese_print_menu_source source
    WHERE mi.id = source.item_id
      AND mi.restaurant_id = source.store_id;

    GET DIAGNOSTICS v_updated_count = ROW_COUNT;
    IF v_updated_count <> v_source_count THEN
      RAISE EXCEPTION 'VIETNAMESE_PRINT_TRANSLATION_TARGET_MISMATCH:%/%',
        v_updated_count, v_source_count;
    END IF;
  END IF;
END;
$translations$;

CREATE OR REPLACE FUNCTION public.force_print_job_menu_labels_vi()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_items jsonb;
BEGIN
  IF NEW.order_id IS NULL
     OR jsonb_typeof(COALESCE(NEW.payload -> 'items', 'null'::jsonb)) <> 'array' THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      item.raw || jsonb_build_object(
        'label',
        CASE
          WHEN NULLIF(btrim(menu.name_vi), '') IS NOT NULL
               AND btrim(menu.name_vi) !~ '[가-힣]'
            THEN btrim(menu.name_vi)
          ELSE 'Món'
        END
      )
      ORDER BY item.ord
    ),
    '[]'::jsonb
  )
  INTO v_items
  FROM jsonb_array_elements(NEW.payload -> 'items')
    WITH ORDINALITY AS item(raw, ord)
  LEFT JOIN LATERAL (
    SELECT oi.menu_item_id
    FROM public.order_items oi
    WHERE oi.order_id = NEW.order_id
      AND oi.status <> 'cancelled'
      AND (
        (
          NULLIF(item.raw ->> 'item_id', '') IS NOT NULL
          AND oi.id::text = NULLIF(item.raw ->> 'item_id', '')
        )
        OR NULLIF(item.raw ->> 'item_id', '') IS NULL
      )
    ORDER BY oi.created_at, oi.id
    OFFSET CASE
      WHEN NULLIF(item.raw ->> 'item_id', '') IS NULL THEN item.ord - 1
      ELSE 0
    END
    LIMIT 1
  ) order_line ON true
  LEFT JOIN public.menu_items menu
    ON menu.id = COALESCE(
      CASE
        WHEN COALESCE(item.raw ->> 'menu_item_id', '') ~
             '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
          THEN (item.raw ->> 'menu_item_id')::uuid
        ELSE NULL
      END,
      order_line.menu_item_id
    )
   AND menu.restaurant_id = NEW.restaurant_id;

  NEW.payload := jsonb_set(NEW.payload, '{items}', v_items, false);
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.force_print_job_menu_labels_vi()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS force_print_job_menu_labels_vi
  ON public.print_jobs;
CREATE TRIGGER force_print_job_menu_labels_vi
BEFORE INSERT OR UPDATE OF payload ON public.print_jobs
FOR EACH ROW
EXECUTE FUNCTION public.force_print_job_menu_labels_vi();

-- Normalize jobs that have not printed yet so retrying them cannot emit Korean.
UPDATE public.print_jobs
SET payload = payload
WHERE order_id IS NOT NULL
  AND status IN ('pending', 'failed');

DROP TABLE vietnamese_print_menu_source;
