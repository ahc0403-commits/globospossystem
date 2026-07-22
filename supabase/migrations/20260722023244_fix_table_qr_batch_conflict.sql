-- Fix batch table QR export on PostgreSQL when the RETURNS TABLE output
-- variable `table_id` conflicts with an ON CONFLICT inference column.

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_get_or_create_table_qrs(
  p_store_id uuid,
  p_table_ids uuid[] DEFAULT NULL
) RETURNS TABLE (
  token_id uuid,
  table_id uuid,
  table_number text,
  floor_label text,
  layout_sort_order integer,
  store_name text,
  token text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog'
AS $$
DECLARE
  v_requested_count integer;
  v_matched_count integer;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_ID_REQUIRED';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  IF p_table_ids IS NOT NULL THEN
    SELECT count(DISTINCT requested_id), count(t.id)
    INTO v_requested_count, v_matched_count
    FROM (
      SELECT DISTINCT requested_id
      FROM unnest(p_table_ids) requested(requested_id)
    ) requested
    LEFT JOIN public.tables t
      ON t.id = requested.requested_id
     AND t.restaurant_id = p_store_id;

    IF v_requested_count <> COALESCE(v_matched_count, 0) THEN
      RAISE EXCEPTION 'TABLE_SCOPE_INVALID';
    END IF;
  END IF;

  PERFORM 1
  FROM public.tables t
  WHERE t.restaurant_id = p_store_id
    AND (p_table_ids IS NULL OR t.id = ANY(p_table_ids))
  ORDER BY t.layout_sort_order, t.table_number, t.id
  FOR UPDATE;

  WITH candidates AS (
    SELECT t.id, t.restaurant_id
    FROM public.tables t
    WHERE t.restaurant_id = p_store_id
      AND (p_table_ids IS NULL OR t.id = ANY(p_table_ids))
  ), inserted AS (
    INSERT INTO public.table_qr_tokens (
      restaurant_id,
      table_id,
      token,
      created_by
    )
    SELECT
      candidate.restaurant_id,
      candidate.id,
      replace(
        replace(
          rtrim(encode(extensions.gen_random_bytes(24), 'base64'), '='),
          '+',
          '-'
        ),
        '/',
        '_'
      ),
      auth.uid()
    FROM candidates candidate
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.table_qr_tokens active_token
      WHERE active_token.table_id = candidate.id
        AND active_token.is_active = true
    )
    -- Any concurrent unique collision means another request already created
    -- the canonical active token. Omitting the inference column avoids the
    -- PL/pgSQL RETURNS TABLE `table_id` ambiguity seen in production.
    ON CONFLICT DO NOTHING
    RETURNING id, restaurant_id, table_id
  )
  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  )
  SELECT
    auth.uid(),
    'qr_token_created',
    'tables',
    inserted.table_id,
    jsonb_build_object(
      'store_id', inserted.restaurant_id,
      'qr_token_id', inserted.id,
      'source', 'batch_get_or_create'
    )
  FROM inserted;

  RETURN QUERY
  SELECT
    q.id AS token_id,
    t.id AS table_id,
    t.table_number,
    COALESCE(t.floor_label, '1F') AS floor_label,
    t.layout_sort_order,
    r.name AS store_name,
    q.token,
    q.created_at
  FROM public.tables t
  JOIN public.restaurants r
    ON r.id = t.restaurant_id
  JOIN public.table_qr_tokens q
    ON q.table_id = t.id
   AND q.restaurant_id = t.restaurant_id
   AND q.is_active = true
  WHERE t.restaurant_id = p_store_id
    AND (p_table_ids IS NULL OR t.id = ANY(p_table_ids))
  ORDER BY t.layout_sort_order, t.table_number, t.id;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_get_or_create_table_qrs(uuid, uuid[])
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_or_create_table_qrs(uuid, uuid[])
  TO authenticated, service_role;

COMMIT;
