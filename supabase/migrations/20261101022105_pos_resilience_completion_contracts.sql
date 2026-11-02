-- production-gate: self-verifying
BEGIN;

-- Additive signal extension. Old clients still receive the original INSERT
-- and reload through RLS. New clients also merge subsequent UPDATE signals.
ALTER TABLE public.pos_live_events ADD COLUMN affected_ids uuid[];
ALTER TABLE public.pos_live_events ADD CONSTRAINT pos_live_events_affected_ids_bound
  CHECK (affected_ids IS NULL OR cardinality(affected_ids)<=100);

CREATE FUNCTION public.emit_menu_discount_quantity_batch_v2() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE source_sql text; batch record; event_map jsonb; event_id bigint; ids uuid[];
BEGIN
  IF TG_OP='INSERT' THEN
    source_sql:='SELECT restaurant_id,menu_item_id FROM new_quotas';
  ELSIF TG_OP='DELETE' THEN
    source_sql:='SELECT restaurant_id,menu_item_id FROM old_quotas';
  ELSE
    source_sql:=$q$
      SELECT n.restaurant_id,n.menu_item_id FROM new_quotas n LEFT JOIN old_quotas o USING(menu_item_id)
      WHERE (n.restaurant_id,n.remaining) IS DISTINCT FROM (o.restaurant_id,o.remaining)
      UNION SELECT o.restaurant_id,o.menu_item_id FROM old_quotas o LEFT JOIN new_quotas n USING(menu_item_id)
      WHERE (n.restaurant_id,n.remaining) IS DISTINCT FROM (o.restaurant_id,o.remaining)
    $q$;
  END IF;
  event_map:=coalesce(nullif(current_setting('pos.quota_event_ids_v2',true),''),'{}')::jsonb;
  -- One grouped metadata operation per affected store/statement, never per item.
  -- Window/filter bounds the emitted array without constructing an unbounded one.
  FOR batch IN EXECUTE 'WITH changed AS ('||source_sql||'), unique_ids AS (
    SELECT DISTINCT restaurant_id,menu_item_id FROM changed WHERE restaurant_id IS NOT NULL
  ), numbered AS (SELECT *,row_number() OVER(PARTITION BY restaurant_id ORDER BY menu_item_id) ordinal
    FROM unique_ids) SELECT restaurant_id,count(*) item_count,
    array_agg(menu_item_id ORDER BY menu_item_id) FILTER(WHERE ordinal<=101) item_ids
    FROM numbered GROUP BY restaurant_id'
  LOOP
    ids:=CASE WHEN batch.item_count<=100 THEN batch.item_ids ELSE NULL END;
    event_id:=(event_map->>batch.restaurant_id::text)::bigint;
    IF event_id IS NULL THEN
      INSERT INTO public.pos_live_events(restaurant_id,domain,source_table,event_type,affected_ids)
      VALUES(batch.restaurant_id,'menu','menu_discount_quantities',TG_OP,ids) RETURNING id INTO event_id;
      event_map:=event_map||jsonb_build_object(batch.restaurant_id::text,event_id::text);
      PERFORM set_config('pos.quota_event_ids_v2',event_map::text,true);
    ELSE
      UPDATE public.pos_live_events e SET affected_ids=CASE
        WHEN e.affected_ids IS NULL OR ids IS NULL THEN NULL
        ELSE (SELECT CASE WHEN count(*)<=100 THEN array_agg(id ORDER BY id) ELSE NULL END
          FROM (SELECT DISTINCT unnest(e.affected_ids||ids) id) unique_ids) END
      WHERE e.id=event_id AND e.restaurant_id=batch.restaurant_id;
    END IF;
  END LOOP;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.emit_menu_discount_quantity_batch_v2() FROM PUBLIC,anon,authenticated,service_role;
DROP TRIGGER pos_live_event_trigger ON public.menu_discount_quantities;
CREATE TRIGGER menu_discount_quantity_insert AFTER INSERT ON public.menu_discount_quantities
  REFERENCING NEW TABLE AS new_quotas FOR EACH STATEMENT
  EXECUTE FUNCTION public.emit_menu_discount_quantity_batch_v2();
CREATE TRIGGER menu_discount_quantity_update AFTER UPDATE ON public.menu_discount_quantities
  REFERENCING OLD TABLE AS old_quotas NEW TABLE AS new_quotas FOR EACH STATEMENT
  EXECUTE FUNCTION public.emit_menu_discount_quantity_batch_v2();
CREATE TRIGGER menu_discount_quantity_delete AFTER DELETE ON public.menu_discount_quantities
  REFERENCING OLD TABLE AS old_quotas FOR EACH STATEMENT
  EXECUTE FUNCTION public.emit_menu_discount_quantity_batch_v2();

DO $$ BEGIN
  IF (SELECT count(*) FROM pg_trigger WHERE tgrelid='public.menu_discount_quantities'::regclass
      AND tgfoid='public.emit_menu_discount_quantity_batch_v2()'::regprocedure AND NOT tgisinternal)<>3
    OR EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.menu_discount_quantities'::regclass
      AND tgfoid='public.emit_menu_discount_quantity_event_v1()'::regprocedure AND NOT tgisinternal)
    OR has_function_privilege('authenticated','public.emit_menu_discount_quantity_batch_v2()','EXECUTE')
    OR has_function_privilege('anon','public.emit_menu_discount_quantity_batch_v2()','EXECUTE') THEN
    RAISE EXCEPTION 'MENU_QUANTITY_BATCH_CONTRACT_FAILED';
  END IF;
END $$;
COMMIT;
