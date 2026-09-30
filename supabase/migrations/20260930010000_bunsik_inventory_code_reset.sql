-- Workbook SHA256: 02b3a2db9ab27b9ca5bf4691cd237d19987cbdc0e73c1c31a23e6fc876411d20
-- All 10 worksheets. Preserve workbook codes (DR and GO included).
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';
-- Prevent master and sample changes between snapshot, reset, and verification.
LOCK TABLE public.inventory_products, public.inventory_items, public.inventory_supplier_items,
 public.inventory_purchase_orders, public.inventory_receipts IN SHARE ROW EXCLUSIVE MODE;
-- Known source identities, counts, and test-store guard. No mutations.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.restaurants WHERE id='8bc9eef5-dcd5-46b1-b931-23f77132322c' AND brand_id='a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878') OR
     NOT EXISTS (SELECT 1 FROM public.restaurants WHERE id='3a268807-771f-4fd4-84fe-e1b0b00de40a' AND brand_id='a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878' AND lower(name) LIKE '%sample%') THEN
    RAISE EXCEPTION 'BUNSIK_STORE_SCOPE_CHANGED';
  END IF;
  IF (SELECT count(*) FROM public.inventory_products WHERE restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c')<>104 OR
     (SELECT count(*) FROM public.inventory_products WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a')<>104 THEN
    RAISE EXCEPTION 'BUNSIK_SOURCE_COUNTS_CHANGED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.procurement_quote_lines q JOIN public.inventory_supplier_items s ON s.id=q.supplier_item_id JOIN public.inventory_products p ON p.id=s.product_id WHERE p.restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a') OR
     EXISTS(SELECT 1 FROM public.inventory_purchase_request_lines l JOIN public.inventory_products p ON p.id=l.product_id WHERE p.restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a') THEN
    RAISE EXCEPTION 'BUNSIK_SAMPLE_UNEXPECTED_PROCUREMENT_DEPENDENCY';
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS inventory_migration_backup;
REVOKE ALL ON SCHEMA inventory_migration_backup FROM PUBLIC, anon, authenticated;
CREATE TABLE inventory_migration_backup.bunsik_20260930 (
  table_name text PRIMARY KEY, rows jsonb NOT NULL
);
CREATE TEMP TABLE bunsik_code_map(product_id uuid,old_code text,new_code text PRIMARY KEY,name text,stock_unit text,base_unit text,base_factor numeric,supplier_name text) ON COMMIT DROP;
INSERT INTO bunsik_code_map VALUES
  ('825886cc-90d8-46b9-9be8-4acd625a3017'::uuid,'3615','WR001','[AA]Tôm tẩm bột (300g) (튀김옷 새우)','팩(Gói)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('9d641448-a994-450a-816c-7cae5c845969'::uuid,'8089','WR002','[Dairymond] Phô Mai Lát (1Kg) (슬라이스 치즈)','개(Cái)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('6c67135b-5b08-406c-8ad2-e79080dc4232'::uuid,'7390','WR003','[Ottogi] Mù tạt mật ong (오뚜기 허니머스타드)','개(Cái)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('30a92d78-6268-479f-b43b-d588e54e6f57'::uuid,'7315','WR004','[오뚜기]북경짜장VN(135g)','BOX','ea',1,'Woori Fresh Food - 우리푸드'),
  ('e5e9c7df-3903-4327-948e-e44cb7f4304a'::uuid,'9016','WR005','Bánh gạo cắt lát (떡국떡)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('21d986c0-cab1-4b6f-96e3-da424e0cae7d'::uuid,'1063','WR006','Bắp cải trắng (양배추)','Kg','ea',1,'Woori Fresh Food - 우리푸드'),
  ('71122a61-24a7-40e2-a222-f8629046cf26'::uuid,'9120','WR007','Bột chiên giòn (튀김가루)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('c9ee4ac0-bc34-4d86-a995-40eff9d6ff49'::uuid,'9011','WR008','Bột nêm vị bò (소고기 다시다)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('abe33a14-387b-4521-81b9-91f4dab7cf62'::uuid,'9397','WR009','Bột ngọt Ajinomoto (아지노모토 미원)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('723191b9-5b79-4e5c-8938-24b4081b36f7'::uuid,'8332','WR010','Bột rong biển[농우]김가루(1Kg)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('90ee110d-eb17-4fec-ba9a-f137466c7253'::uuid,'7382','WR011','Bột tiêu (후춧가루)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('c57fea4f-4a31-4c94-82f4-9cb5b0313218'::uuid,'8644','WR012','Cá ngừ ngâm dầu (참치캔)','개(Cái)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('1cd683cc-4f9f-4d3a-9e67-9a5e544fa2cf'::uuid,'1020','WR013','Cà rốt (당근)','Kg','ea',1,'Woori Fresh Food - 우리푸드'),
  ('4cc07b20-8c39-46ab-bc43-cec9b1b15c94'::uuid,'2159','WR014','Cá viên (어묵볼)','Kg','ea',1,'Woori Fresh Food - 우리푸드'),
  ('f7c9e5c3-5c02-480e-8105-3a9d83a101b4'::uuid,'8661','WR015','Chả Cá HQ (한국 어묵)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('f7ca0c65-eaa9-468a-a7ce-537d9d46d47c'::uuid,'8478','WR016','Củ cải vàng Kimbab (김밥용 단무지)','Thùng (통)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('8e555436-5306-41c8-92dd-56e0fe3589b5'::uuid,'8247','WR017','Dầu ăn (식용유)','Thùng (통)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('c2a806c3-50a6-4bdb-9b0f-60954b5e6325'::uuid,'7180','WR018','Đậu đỏ nguyên hạt (3Kg) (통팥)','Thùng (통)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('e1515839-f0fa-4f8b-b5b7-f221ea133709'::uuid,'8173','WR019','Dầu hào Gấu trúc (PET) (팬더 굴소스)','Thùng (통)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('c2e22abe-9d51-4b72-bf95-6504843d93af'::uuid,'7514','WR020','Đậu hũ chiên (đông) (냉동 튀긴두부/유부)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('8aecc78f-5104-43bb-8ba7-f7e6ed7fa198'::uuid,'1022','WR021','Đậu hũ HQ (hộp/500g) (한국 두부)','개(Cái)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('b7a6d859-aacf-42a5-a049-16616440892b'::uuid,'9418','WR022','Dầu mè Nongwoo 3L ([농우]참기름)','병(Bình)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('5c812ddd-e9f7-4192-a13d-65bc10fb02af'::uuid,'1068','WR023','Dưa leo (Thái) (오이)','Kg','ea',1,'Woori Fresh Food - 우리푸드'),
  ('e5656b02-386d-417b-aed5-c683900ada25'::uuid,'8049','WR024','Đường Biên Hòa (설탕)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('1dc35170-6f4c-4e1c-96af-e6b7c01859a9'::uuid,'9622','WR025','GẠO (쌀)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('db181b1b-9cfc-4620-913d-463f33fc4c4f'::uuid,'8035','WR026','Giấm Hwanman (1.8L) (환만 식초)','병(Chai)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('0aaf28c7-c547-461f-b3e9-eeaccbdb407e'::uuid,'9565','WR027','Giấy bếp Pulppy (주방용 키친타월)','팩(Gói)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('7bd457a6-df05-47bf-bc1f-998f499f9ced'::uuid,'7531','WR028','Ham cơm cuộn (김밥용 햄)','개(Cái)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('2de4877b-c841-4e8b-819b-d28ffd767997'::uuid,'1021','WR029','Hành ba rô (대파/리크)','Kg','ea',1,'Woori Fresh Food - 우리푸드'),
  ('6d1b30fd-9745-460f-a2ba-aec8a4deba05'::uuid,'1077','WR030','Hành lá (쪽파)','Kg','ea',1,'Woori Fresh Food - 우리푸드'),
  ('68ea8db4-3c8a-476f-8b25-275f2d8cac83'::uuid,'1944','WR031','Hành tây lột vỏ (깐 양파)','Kg','ea',1,'Woori Fresh Food - 우리푸드'),
  ('3aec6b20-d8e6-4931-b6f9-f14430501782'::uuid,'8224','WR032','Khoai tây chiên (cắt thường) (감자튀김)','Kg','ea',1,'Woori Fresh Food - 우리푸드'),
  ('5fdd7a4b-f543-4278-9063-bd3be7162f76'::uuid,'4540','WR033','Kim chi cải thảo TQ (배추김치)','BOX','ea',1,'Woori Fresh Food - 우리푸드'),
  ('5e8bb61d-dd16-4b7b-af60-41e5033e79f8'::uuid,'8234','WR034','Lá Kim Làm Gimbap (김밥용 김)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('cc2b6aa1-6037-47f6-9bd2-312853c7c387'::uuid,'7365','WR035','Maiyonnaise (마요네즈)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('96a41fdd-2a24-4c6c-b37f-a6b6fc2e5cfc'::uuid,'7176','WR036','Mandu nhân thịt (고기만두)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('fd04d744-c4a0-4a7a-b004-8a140fe1cfdd'::uuid,'8141','WR037','Màng bọc thực phẩm (식품용 랩)','개(Cái)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('61e7f1af-877c-4303-8718-98a0ad9d7cdb'::uuid,'1373','WR038','Mè rang (볶은 참깨)','Kg','ea',1,'Woori Fresh Food - 우리푸드'),
  ('f71d84a0-fa70-4ed2-8e51-3febc117aa5a'::uuid,'8483','WR039','Mì lạnh ([미식가]냉면(2Kg))','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('0deda905-1ecb-420d-aa65-943d825a3993'::uuid,'9668','WR040','Miến khoai lang ngon (900g) (고구마 당면)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('fbf2ed81-5c39-4f2c-bc2c-1b4677a2e526'::uuid,'3107','WR041','Mực nguyên con làm sạch (450g팩) (손질 통오징어)','팩(Gói)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('2bdfd9f6-b0fd-439d-b69a-a92f4bdcb341'::uuid,'8613','WR042','Muối hột Hàn quốc (한국 굵은소금)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('33c5ab18-d0c5-41fc-a44a-2d7decbd0914'::uuid,'9242','WR043','Muối Matsogeum (맛소금)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('3621e83b-fce7-4aad-bbb2-d5649c852ba7'::uuid,'7004','WR044','muối mịn (고운 소금)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('1d9282a4-6757-43d1-91c7-c109bc6233a3'::uuid,'7319','WR045','My không gia vị (사리면)','BOX','ea',1,'Woori Fresh Food - 우리푸드'),
  ('7d638683-ad2b-4615-8623-b6469bb602fc'::uuid,'7535','WR046','Mỳ Udong Tươi (생우동면)','BOX','ea',1,'Woori Fresh Food - 우리푸드'),
  ('4e2f26cb-1271-4e16-8d49-021f043010cc'::uuid,'1092','WR047','Nấm kim châm (팽이버섯)','팩(Gói)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('f4134797-24c9-4899-ac50-3e7c9d2dbe5b'::uuid,'3517','WR048','Nghêu nhỏ (작은 바지락)','Kg','ea',1,'Woori Fresh Food - 우리푸드'),
  ('fe6fbd47-a144-4d5a-99e5-83fcee2fc61c'::uuid,'8984','WR049','Ngưu bàng (우엉)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('0df7bd66-6c80-4e2a-9a5e-f280bc625206'::uuid,'8281','WR050','Nước cốt cá cơm (멸치액젓)','병(Bình)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('5f5930d6-e2d4-4057-828c-b5d7fe8b87bf'::uuid,'9033','WR051','Nước dùng mỳ lạnh (냉면육수)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('def02298-af9c-46f9-93da-fb0be8e82066'::uuid,'9095','WR052','Nước đường (물엿)','Thùng (통)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('1796b2df-df1a-4508-b2c6-813e679017c2'::uuid,'9144','WR053','Nước mắm cá ngừ (참치 액젓)','병(Bình)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('6725c0e1-fd18-42a1-b198-f6d113deb731'::uuid,'9608','WR054','Nước Rửa Chén (주방세제)','Thùng (통)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('392e46a4-9493-4cae-a82f-13572c909800'::uuid,'1859','WR055','Ớt bột cay (고춧가루 매운맛)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('9b610551-42c3-4fde-9488-714025946dbb'::uuid,'1851','WR056','Ớt bột mịn (고춧가루 고운것)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('b12d9341-0324-4515-9c2f-9d4fa99a2f37'::uuid,'1096','WR057','Ớt sừng đỏ (홍고추)','Kg','ea',1,'Woori Fresh Food - 우리푸드'),
  ('4e94faeb-63ba-462d-af97-4ee7db2aa9d6'::uuid,'1081','WR058','Ớt sừng xanh (청고추/풋고추)','Kg','ea',1,'Woori Fresh Food - 우리푸드'),
  ('b0559893-8eaa-4499-a074-0067d3a441fc'::uuid,'9446','WR059','Phô mai bào Mozzarella (모짜렐라 치즈)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('2976f2ec-dc53-4f05-8717-b6bf462c8010'::uuid,'1053','WR060','Rau bó xôi (시금치)','Kg','ea',1,'Woori Fresh Food - 우리푸드'),
  ('04a263b0-aab8-41fe-8dc5-ad0800200787'::uuid,'7218','WR061','Rong biển khô (마른 미역)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('4fb43db1-8e28-4466-97fd-e39007507108'::uuid,'7147','WR062','Rượu nấu ăn (요리술/미림)','병(Bình)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('37ccea5a-0d22-4802-b6a7-d1e95a28a6d5'::uuid,'7121','WR063','sốt mì udon (우동 소스)','병(Bình)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('818ff8d6-301c-480c-8907-b40c053fce57'::uuid,'7122','WR064','Sốt tartar (타르타르 소스)','병(Bình)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('16a4c9e5-ef0f-4669-a6c7-1cd7890a1bf5'::uuid,'7386','WR065','Sốt Teriyaki 2.25Kg ([오뚜기]데리야끼소스)','병(Chai)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('1fab2940-0345-40b2-a6b3-63e6196582fb'::uuid,'8200','WR066','Sữa Tươi không đường (무가당 우유)','개(Cái)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('76fc09b4-166c-466f-856a-b7074d1375c2'::uuid,'1056','WR067','Tần ô (쑥갓)','Kg','ea',1,'Woori Fresh Food - 우리푸드'),
  ('5c37a9a2-63e8-4a7e-96d3-4d9c37520a73'::uuid,'7533','WR068','Thanh cua (게맛살/크래미)','팩(Gói)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('906aa7ea-6935-4e0c-86df-77b4a05a31d8'::uuid,'1018','WR069','Tỏi xay (다진 마늘)','Kg','ea',1,'Woori Fresh Food - 우리푸드'),
  ('cbf44146-af1d-4772-aa1e-f6c6e393ecc1'::uuid,'3100','WR070','Tôm (새우)','Kg','ea',1,'Woori Fresh Food - 우리푸드'),
  ('1809c7da-a948-43ef-8596-544b1f808715'::uuid,'9006','WR071','Trứng gà (계란)','판(Vỉ)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('e3f96fcc-1174-4b3f-91c1-8b56acdbb076'::uuid,'7362','WR072','Tương cà (토마토 케첩)','Bịch (봉)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('f0da40c1-2c10-4a3e-b9f8-139978d81e0a'::uuid,'9090','WR073','Tương Mongo [몽고]진간장(마산)(13L)','Thùng (통)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('c99e92f9-909f-4e44-aae7-b98568473125'::uuid,'8100','WR074','Tương ớt (고추장)','Thùng (통)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('596a3c0d-8620-4925-911f-5cfe6744dbc9'::uuid,'9406','WR075','Tương ớt Cholimex (2.1L) (칠리소스)','병(Bình)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('ca9e7ce0-a209-482b-842a-8c743758e425'::uuid,'9153','WR076','Tương trộn SSAMJANG (쌈장)','Thùng (통)','ea',1,'Woori Fresh Food - 우리푸드'),
  ('24fda656-2e9b-48f8-99d2-ce277d6443c4'::uuid,'1048','WR077','Xà lách (nhà kính) (상추)','Kg','ea',1,'Woori Fresh Food - 우리푸드'),
  ('b4417c59-7377-4dba-910f-d2549717edaf'::uuid,'10001','OT001','Bột chiên giòn 500g (튀김가루)','Box','ea',1,'오뚜기 Otoki'),
  ('c1fdb601-1e46-4304-80b6-f2132e6a60ba'::uuid,'10005','OT002','Bột Phô Mai Otoki 100g (오뚜기 치즈 분말)','Box','ea',1,'오뚜기 Otoki'),
  ('2a670aa2-d411-4703-9b59-83c45b5827cd'::uuid,'10009','OT003','Bột Súp Mì Jin Han 300g (진한 분말스프)','Box','ea',1,'오뚜기 Otoki'),
  ('6da2126f-fa08-4156-9dcc-ac5d5ad05095'::uuid,'10006','OT004','O''Chef Xốt gà rán kiểu Hàn vị Cay 2Kg (오쉐프 한국식 매운맛)','Box','ea',1,'오뚜기 Otoki'),
  ('35a78516-fae6-42b3-814a-ba559d9abcd6'::uuid,'10007','OT005','O''Chef Xốt gà rán kiểu Hàn vị Truyền thống 2Kg (오쉐프 한국식 오리지날)','Box','ea',1,'오뚜기 Otoki'),
  ('21ba1b85-8a43-4c0f-88fc-92a3dcb4ff3b'::uuid,'10008','OT006','O''Chef Xốt hương vị gà cay 2Kg (오쉐프 불닭맛소스)','Box','ea',1,'오뚜기 Otoki'),
  ('bb82167c-c23c-46fc-a675-b4cd2357ef7e'::uuid,'10010','OT007','Sốt Cốc Lết Chiên Bột PET 2.1Kg (돈까스 소스)','Box','ea',1,'오뚜기 Otoki'),
  ('3b9ea6f3-d902-4b9a-b289-61c1f46af8ca'::uuid,'10002','OT008','Xốt gà nước trong 1Kg (간장치킨 소스)','Box','ea',1,'오뚜기 Otoki'),
  ('072befa6-985b-49d8-82ac-e7ef4b392c34'::uuid,'10004','OT009','Xốt Gia Vị Hành Tây 1Kg (어니언드레싱 파우치)','Box','ea',1,'오뚜기 Otoki'),
  ('a61b66d2-8e80-4b71-8cb6-2c80676c7d8d'::uuid,'10003','OT010','Xốt Phô Mai 1Kg (치즈드레싱 파우치)','Box','ea',1,'오뚜기 Otoki'),
  ('fdccf444-5207-4013-a8d4-3bea3d1a2da5'::uuid,'40005','YK001','Bột gia vị Tokbokki 1Kg (떡볶이파우더)','Bịch (봉)','ea',1,'YK'),
  ('59b9eeee-a365-40af-b261-e169993ff77a'::uuid,'40002','YK002','Kim mari tự làm 1Kg (수제김말이)','Bịch (봉)','ea',1,'YK'),
  ('c2dfd1bc-94d6-42d0-9cc5-60af37887f69'::uuid,'40003','YK003','Nước dùng mì lạnh 1Kg (냉면육수)','Bịch (봉)','ea',1,'YK'),
  ('f6fdb928-2fb0-4e00-935d-eca0d7d9d1d8'::uuid,'40001','YK004','Sốt kim chi 1Kg (김치소스)','Bịch (봉)','ea',1,'YK'),
  ('bb4597c7-5366-4cb9-8713-05d29861929f'::uuid,'40004','YK005','Sốt mì lạnh trộn 1Kg (비빔냉면소스)','Bịch (봉)','ea',1,'YK'),
  ('a5be85b7-81da-4152-9b30-34517ac7fc4e'::uuid,'40006','YK006','Sốt tương ớt trộn cơm 1Kg (비빔고추장)','Bịch (봉)','ea',1,'YK'),
  ('3bf0cd70-1403-4241-aee3-00a640569ea6'::uuid,'30002','SP001','Hotdog phô mai xúc xích kiểu Hàn Quốc 500g/6 cái (한국식 치즈 핫도그)','Bịch (봉)','ea',1,'Shopee'),
  ('8e364ce6-0631-4ee5-a6b8-dd3005369c97'::uuid,'30004','SP002','Kem nấu tiệt trùng Cooking Emborg (20% FAT) (요리용 생크림)','팩(Gói)','ea',1,'Shopee'),
  ('4aed28be-254b-43ed-b378-f6a42cdc097f'::uuid,'30003','SP003','Lá kinh giới nghiền 500g (들깻잎 분말)','Bịch (봉)','ea',1,'Shopee'),
  ('a21160ca-8d93-4f7c-a7e1-10e58d866942'::uuid,'30001','SP004','Xúc xích Standard Con Heo Vàng 500g (스탠다드 소시지)','Bịch (봉)','ea',1,'Shopee'),
  ('bd2c2130-8518-4cfb-866d-e40f3642a571'::uuid,'10012','PL001','Xốt ướp Bulgogi bò 10Kg (소고기 불고기 양념)','Box','ea',1,'Phúc Lộc Korea'),
  ('7431b993-1257-4215-8a4c-144aba6dd4b8'::uuid,'10011','PL002','Xốt ướp Bulgogi cay 10Kg (매운 불고기 양념)','Box','ea',1,'Phúc Lộc Korea'),
  ('fa75b211-b768-4f93-9060-432332d28be8'::uuid,'20002','MB001','KNUCKLE - Thịt bò nướng (500g) (소고기 설도 구이용)','개(Cái)','ea',1,'미트박스 Meatbox'),
  ('a2c6cc05-b491-4154-bba6-3d5591d3187f'::uuid,'20001','MB002','MÁ ĐÙI GÀ RÚT XƯƠNG (500g) (닭다리살 정육)','개(Cái)','ea',1,'미트박스 Meatbox'),
  ('6f705c53-6bca-4efc-8099-71d0dd36e110'::uuid,'20003','MB003','NẠC VAI (500g) (돼지 앞다리살)','개(Cái)','ea',1,'미트박스 Meatbox'),
  ('fb7813f8-d511-4fe6-973e-040c3f300da0'::uuid,'20004','MB004','WANG DONKKASEU (miếng) (왕돈까스)','장(Miếng)','ea',1,'미트박스 Meatbox'),
  ('d9422063-357d-41c2-8b8f-bff4c1e4ab1f'::uuid,'50001','NK001','Bánh gạo Tokbokki (떡볶이밀떡)','Kg','ea',1,'나경떡집 - NaKyung TteokJip'),
  (NULL::uuid,NULL,'DR001','Nước suối Dasani (500ml)','Chai','ea',1,'Đại lý Trinh Dũng'),
  (NULL::uuid,NULL,'DR002','Coca (330ml)','Lon','ea',1,'Đại lý Trinh Dũng'),
  (NULL::uuid,NULL,'DR003','Coca Zero (330ml)','Lon','ea',1,'Đại lý Trinh Dũng'),
  (NULL::uuid,NULL,'DR004','Sprite (330ml)','Lon','ea',1,'Đại lý Trinh Dũng'),
  (NULL::uuid,NULL,'DR005','Fanta (330ml)','Lon','ea',1,'Đại lý Trinh Dũng'),
  (NULL::uuid,NULL,'DR006','Sting (330ml)','Lon','ea',1,'Đại lý Trinh Dũng'),
  (NULL::uuid,NULL,'GO001','Bao xốp loại nhỏ','Kg','g',1000,'PACKAGING'),
  (NULL::uuid,NULL,'GO002','Bao xốp loại lớn','Kg','g',1000,'PACKAGING'),
  (NULL::uuid,NULL,'GO003','Đũa muỗng','Bộ','ea',1,'PACKAGING'),
  (NULL::uuid,NULL,'GO004','Hộp chữ nhật (750ml)','Cái','ea',1,'PACKAGING'),
  (NULL::uuid,NULL,'GO005','Hộp đựng sốt','Cái','ea',1,'PACKAGING'),
  (NULL::uuid,NULL,'GO006','Hộp tròn (500ml)','Cái','ea',1,'PACKAGING'),
  (NULL::uuid,NULL,'GO007','Khăn lạnh có logo','Cái','ea',1,'PACKAGING'),
  (NULL::uuid,NULL,'GO008','Khăn lạnh không logo','Cái','ea',1,'PACKAGING'),
  (NULL::uuid,NULL,'GO009','Nắp hộp chữ nhật (750ml)','Cái','ea',1,'PACKAGING'),
  (NULL::uuid,NULL,'GO010','Nắp hộp tròn (500ml)','Cái','ea',1,'PACKAGING'),
  (NULL::uuid,NULL,'GO011','Ống hút','Cái','ea',1,'PACKAGING'),
  (NULL::uuid,NULL,'GO012','Tăm','Cái','ea',1,'PACKAGING'),
  (NULL::uuid,NULL,'GO013','Túi giấy (đựng xúc xích,…)','Cái','ea',1,'PACKAGING');
DO $$ BEGIN
  IF (SELECT count(*) FROM bunsik_code_map m JOIN public.inventory_products p ON p.id=m.product_id AND p.product_code=m.old_code AND p.restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c' AND p.is_active AND p.inventory_item_id IS NOT NULL AND lower(btrim(p.name))=lower(btrim(m.name)))<>104 THEN
    RAISE EXCEPTION 'BUNSIK_WORKBOOK_MAPPING_CHANGED';
  END IF;
END $$;
CREATE TEMP TABLE bunsik_sample_orders AS SELECT id FROM public.inventory_purchase_orders WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
CREATE TEMP TABLE bunsik_sample_receipts AS SELECT id FROM public.inventory_receipts WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_supplier_returns',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_supplier_returns t WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_receipt_issues',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_receipt_issues t WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_receipt_change_history',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_receipt_change_history t WHERE receipt_id IN (SELECT id FROM bunsik_sample_receipts);
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_receipt_submission_attempts',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_receipt_submission_attempts t WHERE receipt_id IN (SELECT id FROM bunsik_sample_receipts);
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_receipt_confirmation_attempts',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_receipt_confirmation_attempts t WHERE purchase_order_id IN (SELECT id FROM bunsik_sample_orders);
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_receipt_lines',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_receipt_lines t WHERE receipt_id IN (SELECT id FROM bunsik_sample_receipts);
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_receipts',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_receipts t WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_purchase_order_lines',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_purchase_order_lines t WHERE purchase_order_id IN (SELECT id FROM bunsik_sample_orders);
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_purchase_approval_events',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_purchase_approval_events t WHERE purchase_order_id IN (SELECT id FROM bunsik_sample_orders);
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_purchase_documents',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_purchase_documents t WHERE purchase_order_id IN (SELECT id FROM bunsik_sample_orders);
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_purchase_orders',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_purchase_orders t WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_stock_audit_lines',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_stock_audit_lines t WHERE session_id IN(SELECT id FROM public.inventory_stock_audit_sessions WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a');
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_stock_audit_sessions',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_stock_audit_sessions t WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_recommendation_lines',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_recommendation_lines t WHERE run_id IN(SELECT id FROM public.inventory_recommendation_runs WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a');
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_recommendation_runs',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_recommendation_runs t WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_daily_consumption',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_daily_consumption t WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_supplier_item_price_history',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_supplier_item_price_history t WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_supplier_items',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_supplier_items t WHERE product_id IN(SELECT id FROM public.inventory_products WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a');
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'menu_recipes',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.menu_recipes t WHERE ingredient_id IN(SELECT id FROM public.inventory_items WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a');
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_physical_counts',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_physical_counts t WHERE ingredient_id IN(SELECT id FROM public.inventory_items WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a');
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_transactions',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_transactions t WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_products',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_products t WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'inventory_items',coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM public.inventory_items t WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'binh_products',jsonb_agg(to_jsonb(p)) FROM public.inventory_products p WHERE restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c';
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'binh_items',jsonb_agg(to_jsonb(i)) FROM public.inventory_items i WHERE restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c';
UPDATE public.inventory_products p SET product_code=m.new_code,updated_at=now()
 FROM bunsik_code_map m WHERE p.id=m.product_id;
-- Source contains no prices. Register the 19 items for stocktake, but disable
-- purchase ordering until price/unit terms have been entered by the operator.
INSERT INTO public.inventory_suppliers(brand_id,supplier_name,supplier_type,status,memo)
 SELECT DISTINCT 'a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878'::uuid,m.supplier_name,
 CASE WHEN m.new_code LIKE 'GO%' THEN 'packaging' ELSE 'beverage' END,'active',
 'Bunsik Inventory Items - Dung.xlsx; DR / GO. Price terms pending.'
 FROM bunsik_code_map m WHERE m.product_id IS NULL AND NOT EXISTS(
 SELECT 1 FROM public.inventory_suppliers s WHERE s.brand_id='a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878' AND s.supplier_name=m.supplier_name);
CREATE TEMP TABLE bunsik_new_items ON COMMIT DROP AS SELECT new_code,gen_random_uuid() item_id,gen_random_uuid() product_id FROM bunsik_code_map WHERE product_id IS NULL;
INSERT INTO public.inventory_items(id,restaurant_id,name,quantity,unit,current_stock,reorder_point,cost_per_unit,supplier_name,is_active)
 SELECT n.item_id,'8bc9eef5-dcd5-46b1-b931-23f77132322c',m.name,0,m.base_unit,0,0,0,m.supplier_name,true FROM bunsik_new_items n JOIN bunsik_code_map m USING(new_code);
INSERT INTO public.inventory_products(id,restaurant_id,brand_id,inventory_item_id,product_code,name,category,stock_unit,base_unit,base_unit_factor,is_orderable,is_active)
 SELECT n.product_id,'8bc9eef5-dcd5-46b1-b931-23f77132322c','a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878',n.item_id,m.new_code,m.name,
 CASE WHEN m.new_code LIKE 'GO%' THEN 'PACKAGING' ELSE 'DRINKS' END,m.stock_unit,m.base_unit,m.base_factor,false,true FROM bunsik_new_items n JOIN bunsik_code_map m USING(new_code);
INSERT INTO public.inventory_supplier_items(supplier_id,product_id,supplier_sku,order_unit,order_unit_quantity_base,min_order_quantity,unit_price,tax_rate,is_preferred,is_active)
 SELECT s.id,n.product_id,m.new_code,m.stock_unit,m.base_factor,1,0,0,true,false FROM bunsik_new_items n JOIN bunsik_code_map m USING(new_code) JOIN public.inventory_suppliers s ON s.brand_id='a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878' AND s.supplier_name=m.supplier_name;
DELETE FROM public.inventory_supplier_returns WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
DELETE FROM public.inventory_receipt_issues WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
DELETE FROM public.inventory_receipt_change_history WHERE receipt_id IN (SELECT id FROM bunsik_sample_receipts);
DELETE FROM public.inventory_receipt_submission_attempts WHERE receipt_id IN (SELECT id FROM bunsik_sample_receipts);
DELETE FROM public.inventory_receipt_confirmation_attempts WHERE purchase_order_id IN (SELECT id FROM bunsik_sample_orders);
DELETE FROM public.inventory_receipt_lines WHERE receipt_id IN (SELECT id FROM bunsik_sample_receipts);
DELETE FROM public.inventory_receipts WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
DELETE FROM public.inventory_purchase_order_lines WHERE purchase_order_id IN (SELECT id FROM bunsik_sample_orders);
DELETE FROM public.inventory_purchase_approval_events WHERE purchase_order_id IN (SELECT id FROM bunsik_sample_orders);
DELETE FROM public.inventory_purchase_documents WHERE purchase_order_id IN (SELECT id FROM bunsik_sample_orders);
DELETE FROM public.inventory_purchase_orders WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
DELETE FROM public.inventory_stock_audit_lines WHERE session_id IN(SELECT id FROM public.inventory_stock_audit_sessions WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a');
DELETE FROM public.inventory_stock_audit_sessions WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
DELETE FROM public.inventory_recommendation_lines WHERE run_id IN(SELECT id FROM public.inventory_recommendation_runs WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a');
DELETE FROM public.inventory_recommendation_runs WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
DELETE FROM public.inventory_daily_consumption WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
DELETE FROM public.inventory_supplier_item_price_history WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
DELETE FROM public.inventory_supplier_items WHERE product_id IN(SELECT id FROM public.inventory_products WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a');
DELETE FROM public.menu_recipes WHERE ingredient_id IN(SELECT id FROM public.inventory_items WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a');
DELETE FROM public.inventory_physical_counts WHERE ingredient_id IN(SELECT id FROM public.inventory_items WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a');
DELETE FROM public.inventory_transactions WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
DELETE FROM public.inventory_products WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
DELETE FROM public.inventory_items WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
CREATE TEMP TABLE bunsik_clone ON COMMIT DROP AS
 SELECT id source_product_id,inventory_item_id source_item_id,gen_random_uuid() product_id,gen_random_uuid() item_id
 FROM public.inventory_products WHERE restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c';
INSERT INTO public.inventory_items(id,restaurant_id,name,quantity,unit,created_at,updated_at,current_stock,reorder_point,cost_per_unit,supplier_name,is_active)
 SELECT c.item_id,'3a268807-771f-4fd4-84fe-e1b0b00de40a',i.name,i.quantity,i.unit,now(),now(),i.current_stock,i.reorder_point,i.cost_per_unit,i.supplier_name,i.is_active FROM bunsik_clone c JOIN public.inventory_items i ON i.id=c.source_item_id;
INSERT INTO public.inventory_products(id,restaurant_id,brand_id,inventory_item_id,product_code,name,category,stock_unit,base_unit,base_unit_factor,image_url,storage_type,shelf_life_days,is_orderable,is_active)
 SELECT c.product_id,'3a268807-771f-4fd4-84fe-e1b0b00de40a',p.brand_id,c.item_id,p.product_code,p.name,p.category,p.stock_unit,p.base_unit,p.base_unit_factor,p.image_url,p.storage_type,p.shelf_life_days,p.is_orderable,p.is_active FROM bunsik_clone c JOIN public.inventory_products p ON p.id=c.source_product_id;
INSERT INTO public.inventory_supplier_items(supplier_id,product_id,supplier_sku,order_unit,order_unit_quantity_base,min_order_quantity,unit_price,tax_rate,lead_time_days,is_preferred,is_active)
 SELECT s.supplier_id,c.product_id,s.supplier_sku,s.order_unit,s.order_unit_quantity_base,s.min_order_quantity,s.unit_price,s.tax_rate,s.lead_time_days,s.is_preferred,s.is_active FROM bunsik_clone c JOIN public.inventory_supplier_items s ON s.product_id=c.source_product_id;
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'clone_ids',jsonb_agg(to_jsonb(c)) FROM bunsik_clone c;
INSERT INTO inventory_migration_backup.bunsik_20260930 SELECT 'new_binh_ids',jsonb_agg(to_jsonb(n)) FROM bunsik_new_items n;
DO $$ BEGIN
 IF (SELECT count(*) FROM public.inventory_products WHERE restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c')<>123 OR (SELECT count(*) FROM public.inventory_products WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a')<>123 THEN RAISE EXCEPTION 'BUNSIK_FINAL_COUNT_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM public.inventory_products b FULL JOIN public.inventory_products s ON s.restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a' AND s.product_code=b.product_code WHERE b.restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c' AND (s.id IS NULL OR (to_jsonb(b)-ARRAY['id','restaurant_id','inventory_item_id','created_at','updated_at']) IS DISTINCT FROM (to_jsonb(s)-ARRAY['id','restaurant_id','inventory_item_id','created_at','updated_at']))) THEN RAISE EXCEPTION 'BUNSIK_CLONE_PRODUCT_MISMATCH'; END IF;
 IF EXISTS(SELECT 1 FROM public.inventory_products b JOIN public.inventory_products s ON s.restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a' AND s.product_code=b.product_code JOIN public.inventory_items bi ON bi.id=b.inventory_item_id JOIN public.inventory_items si ON si.id=s.inventory_item_id WHERE b.restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c' AND (to_jsonb(bi)-ARRAY['id','restaurant_id','created_at','updated_at']) IS DISTINCT FROM (to_jsonb(si)-ARRAY['id','restaurant_id','created_at','updated_at'])) THEN RAISE EXCEPTION 'BUNSIK_CLONE_STOCK_MISMATCH'; END IF;
 IF EXISTS(SELECT 1 FROM public.inventory_products b JOIN public.inventory_products s ON s.restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a' AND s.product_code=b.product_code WHERE b.restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c' AND (SELECT coalesce(jsonb_agg(to_jsonb(x)-ARRAY['id','product_id','created_at','updated_at'] ORDER BY supplier_id,order_unit),'[]') FROM public.inventory_supplier_items x WHERE x.product_id=b.id) IS DISTINCT FROM (SELECT coalesce(jsonb_agg(to_jsonb(x)-ARRAY['id','product_id','created_at','updated_at'] ORDER BY supplier_id,order_unit),'[]') FROM public.inventory_supplier_items x WHERE x.product_id=s.id)) THEN RAISE EXCEPTION 'BUNSIK_CLONE_SUPPLIER_MISMATCH'; END IF;
 IF EXISTS(SELECT 1 FROM inventory_migration_backup.bunsik_20260930 z CROSS JOIN LATERAL jsonb_populate_recordset(NULL::public.inventory_items,z.rows) old JOIN public.inventory_items i ON i.id=old.id WHERE z.table_name='binh_items' AND to_jsonb(old) IS DISTINCT FROM to_jsonb(i)) THEN RAISE EXCEPTION 'BUNSIK_ORIGINAL_STOCK_CHANGED'; END IF;
 IF EXISTS(SELECT 1 FROM public.inventory_products WHERE restaurant_id IN ('8bc9eef5-dcd5-46b1-b931-23f77132322c','3a268807-771f-4fd4-84fe-e1b0b00de40a') AND product_code !~ '^(WR|OT|YK|SP|PL|MB|NK|DR|GO)[0-9]{3}$') THEN RAISE EXCEPTION 'BUNSIK_FINAL_CODE_INVALID'; END IF;
END $$;
COMMIT;
