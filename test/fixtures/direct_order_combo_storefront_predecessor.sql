CREATE OR REPLACE FUNCTION public.direct_order_public_storefront_v2(p_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE payload jsonb; BEGIN
 payload:=public.direct_order_public_storefront(p_slug);
 IF payload IS NULL THEN RETURN NULL; END IF;
 RETURN payload||jsonb_build_object('store_address',(SELECT address FROM public.restaurants WHERE id=(payload->>'store_id')::uuid));
END $function$;


CREATE OR REPLACE FUNCTION public.direct_order_is_within_hours(
  p_starts_at time, p_cutoff_at time, p_observed_at timestamptz DEFAULT now()
) RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog
AS $$
  SELECT (p_observed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::time >= p_starts_at
     AND (p_observed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::time < p_cutoff_at;
$$;
