-- Preserve direct-order chat originals and add server-generated KO/VI/EN copies.
-- Existing POS, payment, KDS, alert, and settlement objects are untouched.

ALTER TABLE public.direct_order_messages
  ADD COLUMN source_locale text,
  ADD COLUMN body_ko text,
  ADD COLUMN body_vi text,
  ADD COLUMN body_en text,
  ADD COLUMN translation_status text NOT NULL DEFAULT 'not_requested',
  ADD COLUMN translation_provider text;

ALTER TABLE public.direct_order_messages
  ADD CONSTRAINT direct_order_messages_source_locale_valid CHECK (
    source_locale IS NULL OR source_locale IN ('ko', 'vi', 'en')
  ),
  ADD CONSTRAINT direct_order_messages_translation_status_valid CHECK (
    translation_status IN ('not_requested', 'complete')
  ),
  ADD CONSTRAINT direct_order_messages_translations_valid CHECK (
    (
      translation_status = 'not_requested'
      AND source_locale IS NULL
      AND body_ko IS NULL
      AND body_vi IS NULL
      AND body_en IS NULL
      AND translation_provider IS NULL
    ) OR (
      translation_status = 'complete'
      AND message_type = 'text'
      AND source_locale IN ('ko', 'vi', 'en')
      AND char_length(body_ko) BETWEEN 1 AND 6000
      AND char_length(body_vi) BETWEEN 1 AND 6000
      AND char_length(body_en) BETWEEN 1 AND 6000
      AND translation_provider = 'google_cloud_translation_v2'
      AND CASE source_locale
        WHEN 'ko' THEN body_ko = body
        WHEN 'vi' THEN body_vi = body
        WHEN 'en' THEN body_en = body
        ELSE false
      END
    )
  );

CREATE OR REPLACE FUNCTION public.direct_order_public_message_translated(
  p_session_id uuid,
  p_secret_hash text,
  p_request_id uuid,
  p_body text,
  p_source_locale text,
  p_body_ko text,
  p_body_vi text,
  p_body_en text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_session public.direct_order_sessions%ROWTYPE;
  v_request public.direct_order_requests%ROWTYPE;
  v_message public.direct_order_messages%ROWTYPE;
  v_body text := btrim(COALESCE(p_body, ''));
BEGIN
  v_session := public.direct_order_validate_session(
    p_session_id, p_secret_hash
  );
  SELECT * INTO v_request
  FROM public.direct_order_requests request_row
  WHERE request_row.id = p_request_id
    AND request_row.session_id = v_session.id
    AND request_row.restaurant_id = v_session.restaurant_id;
  IF NOT FOUND OR v_request.state IN ('rejected', 'cancelled', 'expired') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_CHATABLE';
  END IF;
  IF length(v_body) NOT BETWEEN 1 AND 2000
     OR p_source_locale NOT IN ('ko', 'vi', 'en')
     OR length(btrim(COALESCE(p_body_ko, ''))) NOT BETWEEN 1 AND 6000
     OR length(btrim(COALESCE(p_body_vi, ''))) NOT BETWEEN 1 AND 6000
     OR length(btrim(COALESCE(p_body_en, ''))) NOT BETWEEN 1 AND 6000
     OR (CASE p_source_locale
       WHEN 'ko' THEN btrim(p_body_ko) <> v_body
       WHEN 'vi' THEN btrim(p_body_vi) <> v_body
       WHEN 'en' THEN btrim(p_body_en) <> v_body
       ELSE true
     END) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_TRANSLATION_INVALID';
  END IF;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, message_type, body,
    source_locale, body_ko, body_vi, body_en,
    translation_status, translation_provider
  ) VALUES (
    v_request.id, v_request.restaurant_id, 'customer', 'text', v_body,
    p_source_locale, btrim(p_body_ko), btrim(p_body_vi), btrim(p_body_en),
    'complete', 'google_cloud_translation_v2'
  ) RETURNING * INTO v_message;

  RETURN jsonb_build_object(
    'message_id', v_message.id,
    'created_at', v_message.created_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_public_message_translated(
  uuid, text, uuid, text, text, text, text, text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_message_translated(
  uuid, text, uuid, text, text, text, text, text
) TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_staff_message_translated(
  p_actor_auth_id uuid,
  p_store_id uuid,
  p_request_id uuid,
  p_body text,
  p_source_locale text,
  p_body_ko text,
  p_body_vi text,
  p_body_en text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_message public.direct_order_messages%ROWTYPE;
  v_body text := btrim(COALESCE(p_body, ''));
BEGIN
  SELECT * INTO v_actor
  FROM public.users user_row
  WHERE user_row.auth_id = p_actor_auth_id
    AND user_row.is_active = true
    AND user_row.role = ANY(
      ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
    )
  LIMIT 1;
  IF NOT FOUND OR (
    v_actor.role <> 'super_admin'
    AND NOT EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(p_actor_auth_id) scope(store_id)
      WHERE scope.store_id = p_store_id
    )
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_FORBIDDEN';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.direct_order_requests request_row
    WHERE request_row.id = p_request_id
      AND request_row.restaurant_id = p_store_id
      AND request_row.state NOT IN ('rejected', 'cancelled', 'expired')
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_CHATABLE';
  END IF;
  IF length(v_body) NOT BETWEEN 1 AND 2000
     OR p_source_locale NOT IN ('ko', 'vi', 'en')
     OR length(btrim(COALESCE(p_body_ko, ''))) NOT BETWEEN 1 AND 6000
     OR length(btrim(COALESCE(p_body_vi, ''))) NOT BETWEEN 1 AND 6000
     OR length(btrim(COALESCE(p_body_en, ''))) NOT BETWEEN 1 AND 6000
     OR (CASE p_source_locale
       WHEN 'ko' THEN btrim(p_body_ko) <> v_body
       WHEN 'vi' THEN btrim(p_body_vi) <> v_body
       WHEN 'en' THEN btrim(p_body_en) <> v_body
       ELSE true
     END) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_TRANSLATION_INVALID';
  END IF;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, sender_auth_id,
    message_type, body, source_locale, body_ko, body_vi, body_en,
    translation_status, translation_provider
  ) VALUES (
    p_request_id, p_store_id, 'cashier', p_actor_auth_id,
    'text', v_body, p_source_locale,
    btrim(p_body_ko), btrim(p_body_vi), btrim(p_body_en),
    'complete', 'google_cloud_translation_v2'
  ) RETURNING * INTO v_message;

  RETURN jsonb_build_object(
    'message_id', v_message.id,
    'created_at', v_message.created_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_staff_message_translated(
  uuid, uuid, uuid, text, text, text, text, text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_message_translated(
  uuid, uuid, uuid, text, text, text, text, text
) TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_public_message_translations(
  p_session_id uuid,
  p_secret_hash text,
  p_request_id uuid,
  p_target_locale text,
  p_message_ids uuid[]
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_session public.direct_order_sessions%ROWTYPE;
BEGIN
  v_session := public.direct_order_validate_session(
    p_session_id, p_secret_hash
  );
  IF p_target_locale NOT IN ('ko', 'vi', 'en')
     OR p_message_ids IS NULL
     OR cardinality(p_message_ids) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_TRANSLATION_INVALID';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.direct_order_requests request_row
    WHERE request_row.id = p_request_id
      AND request_row.session_id = v_session.id
      AND request_row.restaurant_id = v_session.restaurant_id
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND';
  END IF;

  RETURN jsonb_build_object(
    'translations', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'message_id', message.id,
        'body', CASE p_target_locale
          WHEN 'ko' THEN message.body_ko
          WHEN 'vi' THEN message.body_vi
          WHEN 'en' THEN message.body_en
        END
      ) ORDER BY message.created_at, message.id)
      FROM public.direct_order_messages message
      WHERE message.request_id = p_request_id
        AND message.id = ANY(p_message_ids)
        AND message.message_type = 'text'
        AND message.translation_status = 'complete'
    ), '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_public_message_translations(
  uuid, text, uuid, text, uuid[]
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_message_translations(
  uuid, text, uuid, text, uuid[]
) TO service_role;

COMMENT ON COLUMN public.direct_order_messages.body IS
  'Original user-entered direct-order chat text; never overwritten by translation.';
COMMENT ON COLUMN public.direct_order_messages.source_locale IS
  'Viewer locale selected by the sender when the text message was submitted.';
COMMENT ON COLUMN public.direct_order_messages.translation_provider IS
  'Server-only translation provider identifier; API credentials are never stored.';
