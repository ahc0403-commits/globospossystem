DO $verification$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'force_print_job_combo_labels_vi'
      AND tgrelid = 'public.print_jobs'::regclass
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'VIETNAMESE_COMBO_PRINTER_VERIFY_TRIGGER_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.print_jobs job
    CROSS JOIN LATERAL jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(job.payload -> 'items') = 'array'
          THEN job.payload -> 'items'
        ELSE '[]'::jsonb
      END
    ) item
    CROSS JOIN LATERAL jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(item -> 'components') = 'array'
          THEN item -> 'components'
        ELSE '[]'::jsonb
      END
    ) component
    LEFT JOIN public.menu_items menu
      ON menu.id = CASE
        WHEN COALESCE(component ->> 'menu_item_id', '') ~
             '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
          THEN (component ->> 'menu_item_id')::uuid
        ELSE NULL
      END
     AND menu.restaurant_id = job.restaurant_id
    WHERE job.order_id IS NOT NULL
      AND job.status IN ('pending', 'failed')
      AND component ->> 'label' IS DISTINCT FROM CASE
        WHEN NULLIF(btrim(menu.name_vi), '') IS NOT NULL
             AND btrim(menu.name_vi) !~ '[가-힣]'
          THEN btrim(menu.name_vi)
        ELSE 'Món'
      END
  ) THEN
    RAISE EXCEPTION 'VIETNAMESE_COMBO_PRINTER_VERIFY_LABEL_MISMATCH';
  END IF;
END;
$verification$;
