-- Disposable DB only. A reference, a mismatched store and a store with no policy.
ALTER TABLE public.brands ADD COLUMN code text;
UPDATE public.brands SET code = 'bunsikclub' WHERE id = test_uuid(901);
UPDATE public.brands SET code = 'jeongabok' WHERE id = test_uuid(902);
UPDATE public.restaurants SET short_code = 'BT' WHERE id = test_uuid(101);
INSERT INTO public.procurement_store_policies (
  restaurant_id, enabled, three_stage_required, two_stage_required,
  new_requests_enabled, stock_freshness_hours
) VALUES (test_uuid(101), true, true, true, true, 24)
ON CONFLICT (restaurant_id) DO UPDATE SET
  enabled = true, three_stage_required = true, two_stage_required = true,
  new_requests_enabled = true, stock_freshness_hours = 24,
  high_value_amount = NULL, max_price_increase_percent = NULL,
  quantity_review_multiplier = NULL;
INSERT INTO public.procurement_store_policies (
  restaurant_id, enabled, three_stage_required, two_stage_required,
  new_requests_enabled, stock_freshness_hours
) VALUES (test_uuid(102), false, false, false, false, 72)
ON CONFLICT (restaurant_id) DO UPDATE SET enabled = false,
  three_stage_required = false, two_stage_required = false,
  new_requests_enabled = false, stock_freshness_hours = 72;
DELETE FROM public.procurement_store_policies WHERE restaurant_id = test_uuid(103);

INSERT INTO public.restaurants(id, brand_id, name, is_active) VALUES
  (test_uuid(18100), test_uuid(902), 'Inactive restaurant', false),
  (test_uuid(18101), test_uuid(902), 'Non-ordering store', true),
  (test_uuid(18102), test_uuid(902), 'Inactive ordering requirement', true);
INSERT INTO public.store_fixed_account_requirements (
  store_id, account_code, account_type, role, display_name, scope, is_active
) VALUES
  (test_uuid(101), 'bt_order', 'inventory_orderer', 'inventory_orderer', 'BT order', 'store', true),
  (test_uuid(101), 'bt_pr1', 'inventory_orderer', 'inventory_orderer', 'BT PR', 'store', true),
  (test_uuid(102), 'jgbt_order', 'inventory_orderer', 'inventory_orderer', 'JG order', 'store', true),
  (test_uuid(102), 'jgbt_pr1', 'inventory_orderer', 'inventory_orderer', 'JG PR', 'store', true),
  (test_uuid(103), 'sp_order', 'inventory_orderer', 'inventory_orderer', 'SP order', 'store', true),
  (test_uuid(103), 'sp_pr1', 'inventory_orderer', 'inventory_orderer', 'SP PR', 'store', true),
  (test_uuid(18100), 'inactive_order', 'inventory_orderer', 'inventory_orderer', 'Inactive order', 'store', true),
  (test_uuid(18101), 'other_pos', 'device_pos', 'cashier', 'POS only', 'store', true),
  (test_uuid(18102), 'paused_order', 'inventory_orderer', 'inventory_orderer', 'Inactive requirement', 'store', false);

-- Reproduce the real receiver distinction: reference already has both stages,
-- while JeonGabok has only receiving. The PR identity is separate.
UPDATE public.users SET fixed_account_code=CASE id WHEN test_uuid(1) THEN 'bt_order' ELSE 'jgbt_order' END,
  account_type='inventory_orderer', primary_store_id=restaurant_id WHERE id IN (test_uuid(1),test_uuid(5));
UPDATE public.store_fixed_account_requirements SET provisioned_user_id=CASE store_id WHEN test_uuid(101) THEN test_uuid(1) ELSE test_uuid(5) END
WHERE account_code IN ('bt_order','jgbt_order');
INSERT INTO public.procurement_role_roster(restaurant_id,system,subject_id,person_id,account_kind,stage,display_name,valid_from,valid_until,reason,assigned_by)
VALUES (test_uuid(101),'pos',test_uuid(1),NULL,'shared_role','receiver','BT receiver',now()-interval '1 day',now()+interval '1 year','Fixture','{}'),
 (test_uuid(101),'pos',test_uuid(1),NULL,'shared_role','verifier','BT receiver',now()-interval '1 day',now()+interval '1 year','Fixture','{}'),
 (test_uuid(102),'pos',test_uuid(5),NULL,'shared_role','receiver','JG receiver',now()-interval '1 day',now()+interval '1 year','Fixture','{}')
ON CONFLICT(restaurant_id,system,subject_id,stage) DO UPDATE SET account_kind='shared_role',person_id=NULL,
 valid_from=EXCLUDED.valid_from,valid_until=EXCLUDED.valid_until;
DELETE FROM public.procurement_role_roster WHERE restaurant_id=test_uuid(102) AND subject_id=test_uuid(5) AND stage='verifier';

CREATE TABLE public.test_procurement_parity_before AS
SELECT
  (SELECT jsonb_agg(to_jsonb(u) ORDER BY id) FROM public.users u) AS users,
  (SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM public.restaurants r) AS stores,
  (SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM public.inventory_purchase_requests r) AS requests,
  (SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM public.inventory_purchase_orders p) AS orders,
  (SELECT jsonb_agg(to_jsonb(q) ORDER BY id) FROM public.store_fixed_account_requirements q) AS requirements,
  (SELECT to_jsonb(p) FROM public.procurement_store_policies p WHERE restaurant_id = test_uuid(101)) AS reference,
  (SELECT row_version FROM public.procurement_store_policies WHERE restaurant_id = test_uuid(102)) AS target_version;
