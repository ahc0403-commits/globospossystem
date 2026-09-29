DO $$ BEGIN
 IF EXISTS((SELECT to_jsonb(i) FROM public.direct_order_request_items i EXCEPT SELECT snapshot FROM fixture_direct_before_beverage_seed)
   UNION ALL (SELECT snapshot FROM fixture_direct_before_beverage_seed EXCEPT SELECT to_jsonb(i) FROM public.direct_order_request_items i)) THEN
   RAISE EXCEPTION 'BUNSIK_EXISTING_DIRECT_REQUEST_CHANGED'; END IF;
 IF (SELECT state FROM public.direct_order_requests WHERE id='11111111-1111-4111-8111-111111111111')<>'quoted' THEN
   RAISE EXCEPTION 'BUNSIK_EXISTING_DIRECT_STATE_CHANGED'; END IF;
 IF (SELECT (public.calculate_item_vat(vat_profile_snapshot,unit_price*quantity,'exclusive')->>'total')::numeric
   FROM public.direct_order_request_items WHERE request_id='11111111-1111-4111-8111-111111111111')<>19440 THEN
   RAISE EXCEPTION 'BUNSIK_EXISTING_QUOTE_REPRICED'; END IF;
 IF (SELECT effective_vat_rate FROM public.menu_items WHERE id='be7c2540-5a92-48bd-b2be-221652e5e09d')<>10 THEN
   RAISE EXCEPTION 'BUNSIK_NEW_COKE_RATE_NOT_ACTIVE'; END IF;
END $$;
