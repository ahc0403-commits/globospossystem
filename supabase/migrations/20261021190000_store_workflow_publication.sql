-- Versioned kitchen routing. Existing stores stay on their current workflow until
-- an administrator explicitly publishes, devices acknowledge, and a super admin activates.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.store_workflow_releases (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
 definition jsonb NOT NULL, source_hash text NOT NULL, created_by uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(restaurant_id,id)
);
CREATE TABLE public.store_workflow_configs (
 restaurant_id uuid PRIMARY KEY REFERENCES public.restaurants(id) ON DELETE CASCADE,
 revision bigint NOT NULL DEFAULT 0, draft jsonb, candidate_id uuid, active_id uuid,
 validated_hash text, validated_at timestamptz,
 FOREIGN KEY(restaurant_id,candidate_id) REFERENCES public.store_workflow_releases(restaurant_id,id),
 FOREIGN KEY(restaurant_id,active_id) REFERENCES public.store_workflow_releases(restaurant_id,id)
);
CREATE TABLE public.store_workflow_devices (
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
 user_id uuid NOT NULL, device_id uuid NOT NULL, release_id uuid NOT NULL,
 quiesced boolean NOT NULL DEFAULT false, pending_count integer NOT NULL CHECK(pending_count>=0), seen_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(restaurant_id,user_id,device_id),
 FOREIGN KEY(restaurant_id,release_id) REFERENCES public.store_workflow_releases(restaurant_id,id)
);
ALTER TABLE public.orders ADD COLUMN operating_release_id uuid REFERENCES public.store_workflow_releases(id);
ALTER TABLE public.direct_order_requests ADD COLUMN operating_release_id uuid REFERENCES public.store_workflow_releases(id);
CREATE INDEX orders_operating_release ON public.orders(operating_release_id) WHERE operating_release_id IS NOT NULL;
CREATE INDEX direct_requests_operating_release ON public.direct_order_requests(operating_release_id) WHERE operating_release_id IS NOT NULL;

CREATE FUNCTION public.store_workflow_source(p_store_id uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT md5(jsonb_build_object('opening',public.store_operating_source_v1(p_store_id),'menus',
  (SELECT jsonb_agg(jsonb_build_array(id,size_parent_id,m.menu_option_key,price,is_available,is_archived,is_visible_public,fulfillment_route,name_ko,name_vi,name_en) ORDER BY id)
   FROM public.menu_items m WHERE restaurant_id=p_store_id))::text);
$$;
CREATE FUNCTION public.store_workflow_path(p_definition jsonb,p_menu_id uuid,p_channel text,p_parent_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT coalesce((SELECT r->'path' FROM jsonb_array_elements(p_definition->'routes')r
  WHERE (r->'menu_ids' ? p_menu_id::text OR r->'menu_ids' ? p_parent_id::text) AND r->'channels' ? CASE p_channel WHEN 'takeaway' THEN 'pickup' ELSE p_channel END ORDER BY CASE WHEN r->'menu_ids' ? p_menu_id::text THEN 0 ELSE 1 END LIMIT 1),p_definition->'default_path');
$$;
CREATE FUNCTION public.store_workflow_validate(p_store_id uuid,p_definition jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE source jsonb:=public.store_operating_source_v1(p_store_id); total integer;
BEGIN
 IF source IS NULL OR NOT (source->>'within_bounds')::boolean THEN RAISE EXCEPTION 'WORKFLOW_STORE_INVALID'; END IF;
 IF p_definition IS NULL OR octet_length(p_definition::text)>65536 OR p_definition->>'schema' IS DISTINCT FROM '1'
  OR jsonb_typeof(p_definition->'stations') IS DISTINCT FROM 'array'
  OR jsonb_array_length(p_definition->'stations') NOT BETWEEN 1 AND 8
  OR jsonb_typeof(p_definition->'routes') IS DISTINCT FROM 'array'
  OR jsonb_array_length(p_definition->'routes')>100
  OR jsonb_typeof(p_definition->'default_path') IS DISTINCT FROM 'array'
  OR p_definition->>'workflow' IS DISTINCT FROM source->>'workflow'
  OR p_definition->>'fulfillment_mode' IS DISTINCT FROM source->>'fulfillment_mode'
 THEN RAISE EXCEPTION 'WORKFLOW_DEFINITION_INVALID'; END IF;
 -- Physical printing still serves its existing single kitchen. Multi-station routing
 -- requires the paperless station protocol; no claim that a print job is a device test.
 IF source->>'fulfillment_mode'<>'paperless' THEN RAISE EXCEPTION 'WORKFLOW_PAPERLESS_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_definition->'stations')s
  WHERE nullif(btrim(s->>'name'),'') IS NULL OR length(s->>'name')>80
   OR (s->>'id')::uuid IS NULL OR jsonb_typeof(s->'user_ids') IS DISTINCT FROM 'array' OR jsonb_array_length(s->'user_ids')=0)
 OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p_definition->'stations')s WHERE s->>'id'=coalesce(p_definition->>'packaging_station_id',p_definition->'default_path'->>0))
 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_definition->'stations')s GROUP BY s->>'id' HAVING count(*)>1)
 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_definition->'stations')s,jsonb_array_elements_text(s->'user_ids')u GROUP BY u HAVING count(*)>1)
 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_definition->'stations')s JOIN public.store_service_stations st ON st.id=(s->>'id')::uuid WHERE st.restaurant_id<>p_store_id OR st.kind<>'kitchen')
 THEN RAISE EXCEPTION 'WORKFLOW_STATION_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_definition->'stations')s,jsonb_array_elements_text(s->'user_ids')u
  LEFT JOIN public.users usr ON usr.id=u::uuid AND usr.restaurant_id=p_store_id AND usr.is_active
  LEFT JOIN public.emergency_station_assignments a ON a.user_id=usr.id AND a.restaurant_id=p_store_id AND a.is_active AND a.station_type='kitchen'
  WHERE usr.id IS NULL OR a.id IS NULL)
 THEN RAISE EXCEPTION 'WORKFLOW_ASSIGNMENT_INVALID'; END IF;
 -- Every current kitchen account is bound exactly once; tray/floor retain explicit legacy assignments.
 IF EXISTS(SELECT 1 FROM public.emergency_station_assignments a WHERE a.restaurant_id=p_store_id AND a.is_active AND a.station_type='kitchen'
  AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p_definition->'stations')s WHERE s->'user_ids' ? a.user_id::text))
 THEN RAISE EXCEPTION 'WORKFLOW_ASSIGNMENT_MISSING'; END IF;
 IF EXISTS(WITH paths AS (SELECT p_definition->'default_path' path UNION ALL SELECT r->'path' FROM jsonb_array_elements(p_definition->'routes')r)
  SELECT 1 FROM paths WHERE jsonb_typeof(path) IS DISTINCT FROM 'array' OR jsonb_array_length(path) NOT BETWEEN 1 AND 8
   OR (SELECT count(DISTINCT v) FROM jsonb_array_elements_text(path)v)<>jsonb_array_length(path)
   OR EXISTS(SELECT 1 FROM jsonb_array_elements_text(path)v WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p_definition->'stations')s WHERE s->>'id'=v)))
 THEN RAISE EXCEPTION 'WORKFLOW_PATH_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_definition->'routes')r WHERE jsonb_typeof(r->'menu_ids') IS DISTINCT FROM 'array'
  OR jsonb_array_length(r->'menu_ids') NOT BETWEEN 1 AND 500 OR jsonb_typeof(r->'channels') IS DISTINCT FROM 'array'
  OR jsonb_array_length(r->'channels') NOT BETWEEN 1 AND 3)
 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_definition->'routes')r,jsonb_array_elements_text(r->'channels')c WHERE c NOT IN ('dine_in','pickup','delivery'))
 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_definition->'routes')r,jsonb_array_elements_text(r->'menu_ids')m
  LEFT JOIN public.menu_items mi ON mi.id=m::uuid AND mi.restaurant_id=p_store_id WHERE mi.id IS NULL)
 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_definition->'routes')r,jsonb_array_elements_text(r->'menu_ids')m,jsonb_array_elements_text(r->'channels')c GROUP BY m,c HAVING count(*)>1)
 THEN RAISE EXCEPTION 'WORKFLOW_ROUTE_INVALID'; END IF;
 SELECT count(*) INTO total FROM public.menu_items WHERE restaurant_id=p_store_id;
 IF total>4000 THEN RAISE EXCEPTION 'WORKFLOW_MENU_LIMIT'; END IF;
 RETURN jsonb_build_object('menu_count',total,'channel_cases',total*3,'station_count',jsonb_array_length(p_definition->'stations'),
  'source_hash',public.store_workflow_source(p_store_id),'definition_hash',md5(p_definition::text),
  'paths', (SELECT jsonb_agg(jsonb_build_object('channel',c,'menu_count',n,'path',path)) FROM (
   SELECT c,public.store_workflow_path(p_definition,m.id,c,m.size_parent_id) path,count(*) n FROM public.menu_items m CROSS JOIN unnest(ARRAY['dine_in','pickup','delivery'])c
   WHERE m.restaurant_id=p_store_id GROUP BY c,path)x));
END;
$$;

CREATE FUNCTION public.admin_store_workflow_v1(p_store_id uuid,p_action text DEFAULT 'load',p_expected_revision bigint DEFAULT NULL,p_definition jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE cfg public.store_workflow_configs%ROWTYPE; proof jsonb; candidate uuid; result jsonb;
BEGIN
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 PERFORM pg_advisory_xact_lock(hashtextextended('store-opening:'||p_store_id::text,0));
 INSERT INTO public.store_workflow_configs(restaurant_id) VALUES(p_store_id) ON CONFLICT DO NOTHING;
 SELECT * INTO cfg FROM public.store_workflow_configs WHERE restaurant_id=p_store_id FOR UPDATE;
 IF p_action IS NULL OR p_action NOT IN ('load','save','validate','publish','activate','deactivate','retire_device') THEN RAISE EXCEPTION 'WORKFLOW_ACTION_INVALID'; END IF;
 IF p_action<>'load' AND cfg.revision IS DISTINCT FROM p_expected_revision THEN RAISE EXCEPTION 'WORKFLOW_CHANGED'; END IF;
 IF p_action='save' THEN
  proof:=public.store_workflow_validate(p_store_id,p_definition);
  UPDATE public.store_workflow_configs SET draft=p_definition,revision=revision+1,validated_hash=NULL,validated_at=NULL,candidate_id=NULL WHERE restaurant_id=p_store_id;
 ELSIF p_action='validate' THEN
  proof:=public.store_workflow_validate(p_store_id,cfg.draft);
  UPDATE public.store_workflow_configs SET validated_hash=md5(cfg.draft::text||public.store_workflow_source(p_store_id)),validated_at=now(),revision=revision+1 WHERE restaurant_id=p_store_id;
 ELSIF p_action='publish' THEN
  proof:=public.store_workflow_validate(p_store_id,cfg.draft);
  IF cfg.validated_at<now()-interval '30 minutes' OR cfg.validated_hash IS DISTINCT FROM md5(cfg.draft::text||public.store_workflow_source(p_store_id)) THEN RAISE EXCEPTION 'WORKFLOW_REVALIDATE'; END IF;
  INSERT INTO public.store_service_stations(id,restaurant_id,code,kind)
  SELECT (s->>'id')::uuid,p_store_id,'kitchen:'||(s->>'id'),'kitchen' FROM jsonb_array_elements(cfg.draft->'stations')s ON CONFLICT(id) DO NOTHING;
  INSERT INTO public.store_workflow_releases(restaurant_id,definition,source_hash,created_by)
   VALUES(p_store_id,cfg.draft,public.store_workflow_source(p_store_id),auth.uid()) RETURNING id INTO candidate;
  UPDATE public.store_workflow_configs SET candidate_id=candidate,revision=revision+1 WHERE restaurant_id=p_store_id;
 ELSIF p_action='retire_device' THEN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'WORKFLOW_SUPER_ADMIN_REQUIRED'; END IF;
  DELETE FROM public.store_workflow_devices WHERE restaurant_id=p_store_id
   AND user_id=(p_definition->>'user_id')::uuid AND device_id=(p_definition->>'device_id')::uuid
   AND pending_count=0 AND seen_at<now()-interval '5 minutes' RETURNING to_jsonb(store_workflow_devices) INTO proof;
  IF NOT FOUND THEN RAISE EXCEPTION 'WORKFLOW_DEVICE_NOT_RETIRABLE'; END IF;
  UPDATE public.store_workflow_configs SET revision=revision+1 WHERE restaurant_id=p_store_id;
 ELSIF p_action IN ('activate','deactivate') THEN
  IF NOT public.is_super_admin() THEN RAISE EXCEPTION 'WORKFLOW_SUPER_ADMIN_REQUIRED'; END IF;
  IF p_action='activate' THEN
   IF to_regprocedure('public.store_workflow_notify(uuid)') IS NULL THEN RAISE EXCEPTION 'WORKFLOW_SERVER_UPDATE_REQUIRED'; END IF;
   SELECT definition INTO result FROM public.store_workflow_releases WHERE id=cfg.candidate_id AND source_hash=public.store_workflow_source(p_store_id) AND created_at>now()-interval '30 minutes';
   IF NOT FOUND THEN RAISE EXCEPTION 'WORKFLOW_REVALIDATE'; END IF;
   proof:=public.store_workflow_validate(p_store_id,result);
   IF EXISTS(SELECT 1 FROM public.emergency_station_assignments a WHERE a.restaurant_id=p_store_id AND a.is_active
    AND NOT EXISTS(SELECT 1 FROM public.store_workflow_devices d WHERE d.restaurant_id=p_store_id AND d.user_id=a.user_id
     AND d.release_id=cfg.candidate_id AND d.quiesced AND d.pending_count=0 AND d.seen_at>now()-interval '5 minutes'))
    OR EXISTS(SELECT 1 FROM public.store_workflow_devices d WHERE d.restaurant_id=p_store_id AND (d.pending_count>0 OR d.seen_at<now()-interval '5 minutes' OR d.release_id<>cfg.candidate_id))
   THEN RAISE EXCEPTION 'WORKFLOW_DEVICES_NOT_READY'; END IF;
  END IF;
  IF EXISTS(SELECT 1 FROM public.orders WHERE restaurant_id=p_store_id AND status NOT IN ('completed','cancelled'))
   OR EXISTS(SELECT 1 FROM public.direct_order_requests r WHERE restaurant_id=p_store_id AND (state IN ('awaiting_quote','quoted','awaiting_payment_review') OR state='approved' AND NOT EXISTS(SELECT 1 FROM public.direct_delivery_fulfillment_tickets t WHERE t.request_id=r.id AND t.status IN ('completed','cancelled'))))
   OR EXISTS(SELECT 1 FROM public.leftover_packaging_requests WHERE restaurant_id=p_store_id AND status NOT IN ('completed','cancelled'))
   OR EXISTS(SELECT 1 FROM public.direct_delivery_fulfillment_tickets WHERE restaurant_id=p_store_id AND status NOT IN ('completed','cancelled'))
   OR EXISTS(SELECT 1 FROM public.emergency_fulfillment_items i WHERE restaurant_id=p_store_id AND NOT is_cancelled AND floor_served_quantity+excused_quantity<ordered_quantity AND NOT EXISTS(SELECT 1 FROM public.direct_order_financials f JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id=f.request_id WHERE f.order_id=i.order_id AND t.status IN ('completed','cancelled')))
   OR EXISTS(SELECT 1 FROM public.emergency_combo_component_items i WHERE restaurant_id=p_store_id AND NOT is_cancelled AND floor_served_quantity+excused_quantity<ordered_quantity AND NOT EXISTS(SELECT 1 FROM public.direct_order_financials f JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id=f.request_id WHERE f.order_id=i.order_id AND t.status IN ('completed','cancelled')))
   OR EXISTS(SELECT 1 FROM public.emergency_floor_direct_items i WHERE restaurant_id=p_store_id AND NOT is_cancelled AND floor_served_quantity+excused_quantity<ordered_quantity AND NOT EXISTS(SELECT 1 FROM public.direct_order_financials f JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id=f.request_id WHERE f.order_id=i.order_id AND t.status IN ('completed','cancelled')))
  THEN RAISE EXCEPTION 'WORKFLOW_DRAIN_REQUIRED'; END IF;
  IF p_action='deactivate' AND EXISTS(SELECT 1 FROM public.store_workflow_devices WHERE restaurant_id=p_store_id AND (pending_count>0 OR seen_at<now()-interval '5 minutes')) THEN RAISE EXCEPTION 'WORKFLOW_DEVICES_NOT_READY'; END IF;
  UPDATE public.store_workflow_configs SET active_id=CASE WHEN p_action='activate' THEN candidate_id END,revision=revision+1 WHERE restaurant_id=p_store_id;
  UPDATE public.store_workflow_devices SET quiesced=false WHERE restaurant_id=p_store_id;
 END IF;
 IF p_action<>'load' THEN
  INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'store_workflow_'||p_action,'restaurants',p_store_id,jsonb_build_object('previous_revision',cfg.revision,'candidate_id',coalesce(candidate,cfg.candidate_id),'active_id',cfg.active_id,'proof',proof));
 END IF;
 SELECT to_jsonb(c)||jsonb_build_object('proof',proof,'current_workflow',(public.store_operating_source_v1(p_store_id))->>'workflow','fulfillment_mode',(public.store_operating_source_v1(p_store_id))->>'fulfillment_mode',
  'accounts',(SELECT jsonb_agg(jsonb_build_object('id',u.id,'name',u.full_name,'kind',a.station_type,'floor',a.floor_label) ORDER BY a.station_type,u.full_name)
    FROM public.emergency_station_assignments a JOIN public.users u ON u.id=a.user_id AND u.is_active WHERE a.restaurant_id=p_store_id AND a.is_active),
  'devices',(SELECT jsonb_agg(to_jsonb(d)-'restaurant_id') FROM public.store_workflow_devices d WHERE d.restaurant_id=p_store_id),
  'releases',(SELECT jsonb_agg(to_jsonb(v) ORDER BY v.created_at DESC) FROM (SELECT id,definition,created_at FROM public.store_workflow_releases WHERE restaurant_id=p_store_id ORDER BY created_at DESC LIMIT 20)v)) INTO result
 FROM public.store_workflow_configs c WHERE c.restaurant_id=p_store_id;
 RETURN result;
END;
$$;

CREATE FUNCTION public.store_workflow_capture_order() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 PERFORM pg_advisory_xact_lock_shared(hashtextextended('store-opening:'||NEW.restaurant_id::text,0));
 SELECT active_id INTO NEW.operating_release_id FROM public.store_workflow_configs WHERE restaurant_id=NEW.restaurant_id;
 RETURN NEW;
END;
$$;
CREATE TRIGGER aa_workflow_capture BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION public.store_workflow_capture_order();
CREATE TRIGGER aa_workflow_capture BEFORE INSERT ON public.direct_order_requests FOR EACH ROW EXECUTE FUNCTION public.store_workflow_capture_order();
CREATE FUNCTION public.store_workflow_guard_version() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN IF NEW.operating_release_id IS DISTINCT FROM OLD.operating_release_id THEN RAISE EXCEPTION 'WORKFLOW_VERSION_IMMUTABLE'; END IF; RETURN NEW; END;
$$;
CREATE TRIGGER aa_workflow_immutable BEFORE UPDATE OF operating_release_id ON public.orders FOR EACH ROW EXECUTE FUNCTION public.store_workflow_guard_version();
CREATE TRIGGER aa_workflow_immutable BEFORE UPDATE OF operating_release_id ON public.direct_order_requests FOR EACH ROW EXECUTE FUNCTION public.store_workflow_guard_version();
CREATE TRIGGER workflow_release_delete_guard AFTER DELETE ON public.store_workflow_releases REFERENCING OLD TABLE AS deleted_operating_rows FOR EACH STATEMENT EXECUTE FUNCTION public.store_operating_guard_delete_v1();
CREATE TRIGGER workflow_release_immutable BEFORE UPDATE ON public.store_workflow_releases FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();

ALTER TABLE public.store_workflow_releases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_workflow_configs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_workflow_devices ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.store_workflow_releases,public.store_workflow_configs,public.store_workflow_devices FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.store_workflow_source(uuid),public.store_workflow_path(jsonb,uuid,text,uuid),public.store_workflow_validate(uuid,jsonb),public.store_workflow_capture_order(),public.store_workflow_guard_version() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.admin_store_workflow_v1(uuid,text,bigint,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_store_workflow_v1(uuid,text,bigint,jsonb) TO authenticated,service_role;
DO $verify$ BEGIN
 IF has_function_privilege('anon','public.admin_store_workflow_v1(uuid,text,bigint,jsonb)','EXECUTE')
 OR has_function_privilege('authenticated','public.store_workflow_validate(uuid,jsonb)','EXECUTE')
 OR has_table_privilege('authenticated','public.store_workflow_configs','UPDATE')
 OR NOT has_function_privilege('authenticated','public.admin_store_workflow_v1(uuid,text,bigint,jsonb)','EXECUTE')
 THEN RAISE EXCEPTION 'WORKFLOW_PUBLICATION_CONTRACT_INVALID'; END IF;
END $verify$;
COMMIT;
