-- ============================================================
-- Admin mutation audit trace surfacing
-- 2026-04-09
-- Scope:
-- - read-only recent audit trace for hardened admin mutation domains
-- - restaurants, tables, menu_categories, menu_items only
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_admin_mutation_audit_trace(
  p_restaurant_id UUID,
  p_limit INT DEFAULT 10
) RETURNS TABLE (
  audit_log_id UUID,
  created_at TIMESTAMPTZ,
  action TEXT,
  entity_type TEXT,
  entity_id UUID,
  actor_id UUID,
  actor_name TEXT,
  changed_fields JSONB,
  old_values JSONB,
  new_values JSONB
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_limit INT := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50);
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'AUDIT_TRACE_RESTAURANT_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'AUDIT_TRACE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'AUDIT_TRACE_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    al.id AS audit_log_id,
    al.created_at,
    al.action,
    al.entity_type,
    al.entity_id,
    al.actor_id,
    COALESCE(u.full_name, '알 수 없음') AS actor_name,
    COALESCE(al.details -> 'changed_fields', '[]'::jsonb) AS changed_fields,
    COALESCE(al.details -> 'old_values', '{}'::jsonb) AS old_values,
    COALESCE(al.details -> 'new_values', '{}'::jsonb) AS new_values
  FROM public.audit_logs al
  LEFT JOIN public.users u
    ON u.auth_id = al.actor_id
  WHERE al.entity_type = ANY (
      ARRAY['restaurants', 'tables', 'menu_categories', 'menu_items']
    )
    AND (
      NULLIF(al.details ->> 'restaurant_id', '')::UUID = p_restaurant_id
      OR (
        al.entity_type = 'restaurants'
        AND al.entity_id = p_restaurant_id
      )
    )
    AND al.action = ANY (
      ARRAY[
        'admin_create_restaurant',
        'admin_update_restaurant',
        'admin_deactivate_restaurant',
        'admin_update_restaurant_settings',
        'admin_create_table',
        'admin_update_table',
        'admin_delete_table',
        'admin_create_menu_category',
        'admin_update_menu_category',
        'admin_delete_menu_category',
        'admin_create_menu_item',
        'admin_update_menu_item',
        'admin_delete_menu_item'
      ]
    )
  ORDER BY al.created_at DESC
  LIMIT v_limit;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
