-- Keep nested combo component labels Vietnamese-only in every physical print
-- job. The parent item label is normalized by force_print_job_menu_labels_vi().

CREATE OR REPLACE FUNCTION public.force_print_job_combo_labels_vi()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_items jsonb;
BEGIN
  IF jsonb_typeof(COALESCE(NEW.payload -> 'items', 'null'::jsonb)) <> 'array' THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      CASE
        WHEN jsonb_typeof(item.raw -> 'components') = 'array' THEN
          item.raw || jsonb_build_object(
            'components',
            (
              SELECT COALESCE(
                jsonb_agg(
                  component.raw || jsonb_build_object(
                    'label',
                    CASE
                      WHEN NULLIF(btrim(menu.name_vi), '') IS NOT NULL
                           AND btrim(menu.name_vi) !~ '[가-힣]'
                        THEN btrim(menu.name_vi)
                      ELSE 'Món'
                    END
                  )
                  ORDER BY component.ord
                ),
                '[]'::jsonb
              )
              FROM jsonb_array_elements(item.raw -> 'components')
                WITH ORDINALITY AS component(raw, ord)
              LEFT JOIN public.menu_items menu
                ON menu.id = CASE
                  WHEN COALESCE(component.raw ->> 'menu_item_id', '') ~
                       '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                    THEN (component.raw ->> 'menu_item_id')::uuid
                  ELSE NULL
                END
               AND menu.restaurant_id = NEW.restaurant_id
            )
          )
        ELSE item.raw
      END
      ORDER BY item.ord
    ),
    '[]'::jsonb
  )
  INTO v_items
  FROM jsonb_array_elements(NEW.payload -> 'items')
    WITH ORDINALITY AS item(raw, ord);

  NEW.payload := jsonb_set(NEW.payload, '{items}', v_items, false);
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.force_print_job_combo_labels_vi()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS force_print_job_combo_labels_vi
  ON public.print_jobs;
CREATE TRIGGER force_print_job_combo_labels_vi
BEFORE INSERT OR UPDATE OF payload ON public.print_jobs
FOR EACH ROW
EXECUTE FUNCTION public.force_print_job_combo_labels_vi();

-- Re-run both Vietnamese label triggers for jobs that can still be printed.
UPDATE public.print_jobs
SET payload = payload
WHERE order_id IS NOT NULL
  AND status IN ('pending', 'failed');
