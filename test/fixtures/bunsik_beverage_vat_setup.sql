INSERT INTO public.restaurants(id) VALUES
 ('8bc9eef5-dcd5-46b1-b931-23f77132322c'),('3a268807-771f-4fd4-84fe-e1b0b00de40a');
-- Exact identities verified by a read-only production query on 2026-09-29.
INSERT INTO public.menu_items(restaurant_id,id,name_en,vat_category,price) VALUES
 ('8bc9eef5-dcd5-46b1-b931-23f77132322c','53249604-fd2e-40f5-a776-3e1bc5f32153','Coca-Cola','food',18000),
 ('8bc9eef5-dcd5-46b1-b931-23f77132322c','4eda734f-4ac9-4f05-9eeb-0a4e4b122988','Strawberry Sting','food',18000),
 ('8bc9eef5-dcd5-46b1-b931-23f77132322c','1917ec7d-c11e-4ed6-aced-c679d2104fba','Coca-Cola Zero','food',18000),
 ('8bc9eef5-dcd5-46b1-b931-23f77132322c','8ce1a136-f51a-4ee6-a14e-73184a874646','Fanta Orange','food',18000),
 ('8bc9eef5-dcd5-46b1-b931-23f77132322c','f14286a6-63c8-46c9-acb6-8cc518de0bfa','Sprite','food',18000),
 ('3a268807-771f-4fd4-84fe-e1b0b00de40a','be7c2540-5a92-48bd-b2be-221652e5e09d','Coca-Cola','food',18000),
 ('3a268807-771f-4fd4-84fe-e1b0b00de40a','d79cd51a-e09a-469c-a0ac-b1bf3a79a792','Strawberry Sting','food',18000),
 ('3a268807-771f-4fd4-84fe-e1b0b00de40a','d8b74df7-e4ee-45b2-ada1-316121dcc64e','Coca-Cola Zero','food',18000),
 ('3a268807-771f-4fd4-84fe-e1b0b00de40a','47790989-c0df-4340-b101-8eef975271f0','Fanta Orange','food',18000),
 ('3a268807-771f-4fd4-84fe-e1b0b00de40a','8ab0ef6a-8452-4661-ae0b-3824a87b3a46','Sprite','food',18000);

-- An existing quoted request retains its agreed 8% even after Coke becomes 10%.
INSERT INTO public.direct_order_requests(id,restaurant_id,state)
VALUES('11111111-1111-4111-8111-111111111111','3a268807-771f-4fd4-84fe-e1b0b00de40a','quoted');
INSERT INTO public.direct_order_request_items(request_id,restaurant_id,menu_item_id,vat_category,unit_price,quantity)
VALUES('11111111-1111-4111-8111-111111111111','3a268807-771f-4fd4-84fe-e1b0b00de40a','be7c2540-5a92-48bd-b2be-221652e5e09d','food',18000,1);
CREATE TABLE fixture_direct_before_beverage_seed AS SELECT to_jsonb(i) AS snapshot FROM public.direct_order_request_items i;
