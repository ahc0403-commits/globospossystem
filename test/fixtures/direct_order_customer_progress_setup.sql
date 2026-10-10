-- Bring the reduced disposable fixture to the production KDS row contract.
ALTER TABLE public.emergency_fulfillment_items
 ADD COLUMN IF NOT EXISTS id uuid NOT NULL DEFAULT gen_random_uuid(),
 ADD COLUMN IF NOT EXISTS kitchen_done_quantity integer NOT NULL DEFAULT 0,
 ADD COLUMN IF NOT EXISTS needs_review boolean NOT NULL DEFAULT false;
ALTER TABLE public.emergency_fulfillment_items ALTER COLUMN id SET DEFAULT gen_random_uuid();
ALTER TABLE public.emergency_combo_component_items
 ADD COLUMN IF NOT EXISTS order_id uuid,
 ADD COLUMN IF NOT EXISTS ordered_quantity integer NOT NULL DEFAULT 1,
 ADD COLUMN IF NOT EXISTS kitchen_done_quantity integer NOT NULL DEFAULT 0,
 ADD COLUMN IF NOT EXISTS is_cancelled boolean NOT NULL DEFAULT false,
 ADD COLUMN IF NOT EXISTS needs_review boolean NOT NULL DEFAULT false;
CREATE TABLE public.emergency_fulfillment_events(order_id uuid,stage text,delta integer);

-- Emulate the existing atomic batch's individual quantity-event inserts. The
-- progress wrapper must aggregate only once, independently of allocation size.
CREATE FUNCTION public.kds_complete_kitchen_batch_v1(p_request_id uuid,p_allocations jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE allocation jsonb; o uuid;
BEGIN
 FOR allocation IN SELECT value FROM jsonb_array_elements(p_allocations) LOOP
  UPDATE public.emergency_fulfillment_items SET kitchen_done_quantity=ordered_quantity
  WHERE id=(allocation->>'item_id')::uuid RETURNING order_id INTO o;
  INSERT INTO public.emergency_fulfillment_events VALUES(o,'kitchen_done',1);
 END LOOP;
 RETURN jsonb_build_object('request_id',p_request_id,'changed_quantity',jsonb_array_length(p_allocations),'deduplicated',false);
END;
$$;
REVOKE ALL ON FUNCTION public.kds_complete_kitchen_batch_v1(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.kds_complete_kitchen_batch_v1(uuid,jsonb) TO authenticated;
