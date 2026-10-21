CREATE TABLE public.orders(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid,status text);
ALTER TABLE public.emergency_fulfillment_items ADD COLUMN restaurant_id uuid, ADD COLUMN excused_quantity int NOT NULL DEFAULT 0;
ALTER TABLE public.emergency_floor_direct_items ADD COLUMN restaurant_id uuid, ADD COLUMN excused_quantity int NOT NULL DEFAULT 0;
CREATE TABLE public.leftover_packaging_requests(restaurant_id uuid,status text);
CREATE FUNCTION public.kds_is_direct_floor_store(uuid) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
 SELECT coalesce($1='273b057e-3b69-46e3-93c1-6194c2802849'::uuid,false); $$;
CREATE TABLE public.emergency_order_queue(id uuid DEFAULT gen_random_uuid(),restaurant_id uuid,kitchen_direct_to_floor boolean DEFAULT false,
 CONSTRAINT kds_direct_floor_store_scope CHECK(NOT kitchen_direct_to_floor OR public.kds_is_direct_floor_store(restaurant_id)));
CREATE FUNCTION public.kds_assign_direct_floor_workflow() RETURNS trigger LANGUAGE plpgsql AS $$
 BEGIN NEW.kitchen_direct_to_floor:=public.kds_is_direct_floor_store(NEW.restaurant_id); RETURN NEW; END; $$;
CREATE TRIGGER kds_assign_direct_floor_workflow BEFORE INSERT ON public.emergency_order_queue
 FOR EACH ROW EXECUTE FUNCTION public.kds_assign_direct_floor_workflow();
INSERT INTO public.restaurants(id,name) VALUES
 ('273b057e-3b69-46e3-93c1-6194c2802849','JeonGabok'),
 ('8bc9eef5-dcd5-46b1-b931-23f77132322c','BunsikClub'),
 ('20000000-0000-4000-8000-000000000004','New store');
INSERT INTO public.restaurant_settings(restaurant_id) VALUES
 ('273b057e-3b69-46e3-93c1-6194c2802849'),('8bc9eef5-dcd5-46b1-b931-23f77132322c');

CREATE FUNCTION public.emergency_add_order_batch_timings(p_orders jsonb) RETURNS jsonb LANGUAGE sql STABLE AS $$
 SELECT jsonb_agg(public.kds_is_direct_floor_store(q.restaurant_id)) FROM public.emergency_order_queue q;
$$;

CREATE TABLE public.workflow_fixture_events(id uuid DEFAULT gen_random_uuid(),restaurant_id uuid,queue_id uuid,stage text,details jsonb);
CREATE TABLE public.workflow_fixture_changes(id uuid DEFAULT gen_random_uuid(),restaurant_id uuid,payload jsonb,target_stations text[]);
CREATE TABLE public.workflow_fixture_deliveries(direct boolean);
CREATE FUNCTION public.kds_capture_fulfillment_event() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_queue public.emergency_order_queue%ROWTYPE; v_payload jsonb; v_delivery boolean:=false;
BEGIN
 SELECT * INTO v_queue FROM public.emergency_order_queue WHERE id=NEW.queue_id;
 IF public.kds_is_direct_floor_store(NEW.restaurant_id) THEN PERFORM 1; END IF;
 v_payload:=jsonb_build_object('stage',NEW.stage);
 v_payload := v_payload || jsonb_build_object('no_floor_delivery', v_delivery);
 INSERT INTO public.workflow_fixture_changes(restaurant_id,payload,target_stations) VALUES(NEW.restaurant_id,v_payload,ARRAY['kitchen','tray']);
 RETURN NEW;
END $$;
CREATE FUNCTION public.kds_direct_filter_targets() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
 IF NOT public.kds_is_direct_floor_store(NEW.restaurant_id) THEN RETURN NEW; END IF;
 NEW.target_stations:=ARRAY['kitchen','floor']; RETURN NEW;
END $$;
CREATE FUNCTION public.kds_broadcast_change() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_change public.workflow_fixture_changes%ROWTYPE;
BEGIN
 SELECT * INTO v_change FROM public.workflow_fixture_changes WHERE id=NEW.id;
 IF public.kds_is_direct_floor_store(v_change.restaurant_id) THEN
  INSERT INTO public.workflow_fixture_deliveries VALUES(true);
 ELSE INSERT INTO public.workflow_fixture_deliveries VALUES(false); END IF;
 RETURN NEW;
END $$;
CREATE FUNCTION public.sync_direct_delivery_ticket_from_kds() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
 IF public.kds_is_direct_floor_store(NEW.restaurant_id) AND NEW.stage='kitchen_done' THEN RETURN NEW; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER workflow_capture AFTER INSERT ON public.workflow_fixture_events FOR EACH ROW EXECUTE FUNCTION public.kds_capture_fulfillment_event();
CREATE TRIGGER workflow_delivery AFTER INSERT ON public.workflow_fixture_events FOR EACH ROW EXECUTE FUNCTION public.sync_direct_delivery_ticket_from_kds();
CREATE TRIGGER workflow_filter BEFORE INSERT ON public.workflow_fixture_changes FOR EACH ROW EXECUTE FUNCTION public.kds_direct_filter_targets();
CREATE TRIGGER workflow_broadcast AFTER INSERT ON public.workflow_fixture_changes FOR EACH ROW EXECUTE FUNCTION public.kds_broadcast_change();
