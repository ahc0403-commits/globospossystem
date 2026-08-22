BEGIN;

-- production-gate: self-verifying
-- Direct delivery ordering is isolated from the existing QR/POS/KDS domains.
-- Existing orders/payments are created only by direct_order_approve_payment(),
-- after a cashier has locked a quote and manually confirmed bank transfer.

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TABLE public.direct_order_storefronts (
  restaurant_id uuid PRIMARY KEY
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  public_slug text NOT NULL UNIQUE,
  is_enabled boolean NOT NULL DEFAULT false,
  is_paused boolean NOT NULL DEFAULT false,
  ordering_starts_at time NOT NULL DEFAULT '10:00',
  ordering_cutoff_at time NOT NULL DEFAULT '21:30',
  minimum_order_amount numeric(15,2) NOT NULL DEFAULT 0
    CHECK (minimum_order_amount >= 0),
  quote_ttl_minutes integer NOT NULL DEFAULT 20
    CHECK (quote_ttl_minutes BETWEEN 5 AND 120),
  default_latitude numeric(9,6),
  default_longitude numeric(9,6),
  bank_bin text,
  bank_account_number text,
  bank_account_holder text,
  bank_label text,
  delivery_fee_vat_rate numeric(5,2) NOT NULL DEFAULT 0
    CHECK (delivery_fee_vat_rate IN (0, 8, 10)),
  pii_retention_days integer NOT NULL DEFAULT 90
    CHECK (pii_retention_days BETWEEN 7 AND 730),
  analytics_min_cell_count integer NOT NULL DEFAULT 3
    CHECK (analytics_min_cell_count BETWEEN 2 AND 20),
  accounting_approved_at timestamptz,
  accounting_approved_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT direct_order_storefronts_slug_valid CHECK (
    public_slug = lower(public_slug)
    AND public_slug ~ '^[a-z0-9][a-z0-9-]{2,62}$'
  ),
  CONSTRAINT direct_order_storefronts_coordinates_valid CHECK (
    (default_latitude IS NULL AND default_longitude IS NULL)
    OR (
      default_latitude BETWEEN -90 AND 90
      AND default_longitude BETWEEN -180 AND 180
    )
  ),
  CONSTRAINT direct_order_storefronts_bank_fields_valid CHECK (
    NOT is_enabled OR (
      bank_bin ~ '^[0-9]{6}$'
      AND bank_account_number ~ '^[A-Za-z0-9]{5,19}$'
      AND length(btrim(bank_account_holder)) BETWEEN 2 AND 120
    )
  ),
  CONSTRAINT direct_order_storefronts_accounting_gate CHECK (
    NOT is_enabled OR (
      accounting_approved_at IS NOT NULL
      AND accounting_approved_by IS NOT NULL
    )
  ),
  CONSTRAINT direct_order_storefronts_window_valid CHECK (
    ordering_starts_at < ordering_cutoff_at
    AND ordering_cutoff_at <= '21:30'::time
  )
);

CREATE TABLE public.direct_order_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  secret_hash text NOT NULL UNIQUE,
  locale text NOT NULL DEFAULT 'vi' CHECK (locale IN ('ko', 'vi', 'en')),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '30 days'),
  revoked_at timestamptz,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT direct_order_sessions_hash_valid CHECK (
    secret_hash ~ '^[a-f0-9]{64}$'
  ),
  CONSTRAINT direct_order_sessions_expiry_valid CHECK (expires_at > created_at)
);

CREATE TABLE public.direct_order_public_access_limits (
  request_key text NOT NULL,
  window_started_at timestamptz NOT NULL,
  request_count integer NOT NULL DEFAULT 1 CHECK (request_count > 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_key, window_started_at)
);

CREATE TABLE public.direct_order_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  session_id uuid NOT NULL
    REFERENCES public.direct_order_sessions(id) ON DELETE CASCADE,
  client_request_id uuid NOT NULL UNIQUE,
  reference_code text NOT NULL UNIQUE,
  state text NOT NULL DEFAULT 'awaiting_quote' CHECK (state IN (
    'awaiting_quote', 'quoted', 'awaiting_payment_review', 'approved',
    'rejected', 'cancelled', 'expired'
  )),
  locale text NOT NULL DEFAULT 'vi' CHECK (locale IN ('ko', 'vi', 'en')),
  customer_note text,
  approved_at timestamptz,
  rejected_at timestamptz,
  cancelled_at timestamptz,
  pii_purged_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT direct_order_requests_reference_valid CHECK (
    reference_code ~ '^D[0-9A-Z]{8}$'
  ),
  CONSTRAINT direct_order_requests_note_valid CHECK (
    customer_note IS NULL OR char_length(customer_note) <= 500
  )
);

CREATE UNIQUE INDEX direct_order_requests_one_open_per_session
  ON public.direct_order_requests(session_id)
  WHERE state IN ('awaiting_quote', 'quoted', 'awaiting_payment_review');
CREATE INDEX direct_order_requests_store_state_created
  ON public.direct_order_requests(restaurant_id, state, created_at DESC, id DESC);
CREATE INDEX direct_order_requests_session_created
  ON public.direct_order_requests(session_id, created_at DESC);

CREATE TABLE public.direct_order_request_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL
    REFERENCES public.direct_order_requests(id) ON DELETE CASCADE,
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  menu_item_id uuid NOT NULL
    REFERENCES public.menu_items(id) ON DELETE RESTRICT,
  display_name text NOT NULL,
  name_ko text NOT NULL,
  name_vi text NOT NULL,
  name_en text NOT NULL,
  vat_category text NOT NULL CHECK (vat_category IN ('food', 'alcohol')),
  unit_price numeric(15,2) NOT NULL CHECK (unit_price >= 0),
  quantity integer NOT NULL CHECK (quantity BETWEEN 1 AND 50),
  item_note text,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (request_id, menu_item_id),
  CONSTRAINT direct_order_request_items_note_valid CHECK (
    item_note IS NULL OR char_length(item_note) <= 300
  )
);

CREATE INDEX direct_order_request_items_store_request
  ON public.direct_order_request_items(restaurant_id, request_id);
CREATE INDEX direct_order_request_items_menu
  ON public.direct_order_request_items(menu_item_id);

CREATE TABLE public.direct_order_request_addresses (
  request_id uuid PRIMARY KEY
    REFERENCES public.direct_order_requests(id) ON DELETE CASCADE,
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  customer_name text NOT NULL,
  customer_phone text NOT NULL,
  formatted_address text NOT NULL,
  detail_address text NOT NULL,
  latitude numeric(9,6) NOT NULL CHECK (latitude BETWEEN -90 AND 90),
  longitude numeric(9,6) NOT NULL CHECK (longitude BETWEEN -180 AND 180),
  google_place_id text,
  district text,
  ward text,
  address_source text NOT NULL CHECK (address_source IN ('search', 'map_pin')),
  location_verified boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT direct_order_address_name_valid CHECK (
    length(btrim(customer_name)) BETWEEN 1 AND 100
  ),
  CONSTRAINT direct_order_address_phone_valid CHECK (
    customer_phone ~ '^[+]?[0-9][0-9 -]{7,19}$'
  ),
  CONSTRAINT direct_order_address_formatted_valid CHECK (
    length(btrim(formatted_address)) BETWEEN 3 AND 500
  ),
  CONSTRAINT direct_order_address_detail_valid CHECK (
    length(btrim(detail_address)) BETWEEN 1 AND 300
  ),
  CONSTRAINT direct_order_address_place_id_valid CHECK (
    google_place_id IS NULL OR char_length(google_place_id) <= 255
  )
);

CREATE INDEX direct_order_request_addresses_store
  ON public.direct_order_request_addresses(restaurant_id, request_id);

CREATE TABLE public.direct_order_location_facts (
  request_id uuid PRIMARY KEY
    REFERENCES public.direct_order_requests(id) ON DELETE CASCADE,
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  district text,
  ward text,
  coarse_latitude numeric(6,3) NOT NULL,
  coarse_longitude numeric(6,3) NOT NULL,
  requested_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX direct_order_location_facts_store_time
  ON public.direct_order_location_facts(restaurant_id, requested_at DESC);
CREATE INDEX direct_order_location_facts_region_time
  ON public.direct_order_location_facts(
    restaurant_id, district, ward, requested_at DESC
  );

CREATE TABLE public.direct_order_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL
    REFERENCES public.direct_order_requests(id) ON DELETE CASCADE,
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  sender_type text NOT NULL CHECK (sender_type IN ('customer', 'cashier', 'system')),
  sender_auth_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  message_type text NOT NULL CHECK (message_type IN (
    'text', 'payment_proof', 'quote', 'grab_link', 'system'
  )),
  body text,
  attachment_storage_path text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT direct_order_messages_content_valid CHECK (
    (message_type = 'payment_proof' AND attachment_storage_path IS NOT NULL)
    OR (message_type <> 'payment_proof' AND body IS NOT NULL)
  ),
  CONSTRAINT direct_order_messages_body_valid CHECK (
    body IS NULL OR char_length(body) BETWEEN 1 AND 2000
  ),
  CONSTRAINT direct_order_messages_attachment_valid CHECK (
    attachment_storage_path IS NULL OR
    attachment_storage_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|jpeg|png|webp)$'
  )
);

CREATE INDEX direct_order_messages_request_created
  ON public.direct_order_messages(request_id, created_at, id);
CREATE INDEX direct_order_messages_store_created
  ON public.direct_order_messages(restaurant_id, created_at DESC);
CREATE UNIQUE INDEX direct_order_messages_attachment_unique
  ON public.direct_order_messages(attachment_storage_path)
  WHERE attachment_storage_path IS NOT NULL;

CREATE TABLE public.direct_order_quotes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL
    REFERENCES public.direct_order_requests(id) ON DELETE CASCADE,
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  version integer NOT NULL CHECK (version > 0),
  menu_pretax numeric(15,2) NOT NULL CHECK (menu_pretax >= 0),
  menu_vat numeric(15,2) NOT NULL CHECK (menu_vat >= 0),
  menu_total numeric(15,2) NOT NULL CHECK (menu_total >= 0),
  service_charge_pretax numeric(15,2) NOT NULL CHECK (service_charge_pretax >= 0),
  service_charge_vat numeric(15,2) NOT NULL CHECK (service_charge_vat >= 0),
  service_charge_total numeric(15,2) NOT NULL CHECK (service_charge_total >= 0),
  delivery_fee_pretax numeric(15,2) NOT NULL CHECK (delivery_fee_pretax >= 0),
  delivery_fee_vat numeric(15,2) NOT NULL CHECK (delivery_fee_vat >= 0),
  delivery_fee_total numeric(15,2) NOT NULL CHECK (delivery_fee_total >= 0),
  final_total numeric(15,2) NOT NULL CHECK (final_total > 0),
  delivery_fee_vat_rate numeric(5,2) NOT NULL CHECK (
    delivery_fee_vat_rate IN (0, 8, 10)
  ),
  status text NOT NULL DEFAULT 'active' CHECK (
    status IN ('active', 'superseded', 'locked', 'expired')
  ),
  cashier_note text,
  created_by uuid NOT NULL REFERENCES auth.users(id),
  expires_at timestamptz NOT NULL,
  locked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (request_id, version),
  CONSTRAINT direct_order_quotes_expiry_valid CHECK (expires_at > created_at),
  CONSTRAINT direct_order_quotes_note_valid CHECK (
    cashier_note IS NULL OR char_length(cashier_note) <= 500
  )
);

CREATE UNIQUE INDEX direct_order_quotes_one_live
  ON public.direct_order_quotes(request_id)
  WHERE status IN ('active', 'locked');
CREATE INDEX direct_order_quotes_store_created
  ON public.direct_order_quotes(restaurant_id, created_at DESC);

CREATE TABLE public.direct_order_sepay_candidates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL
    REFERENCES public.direct_order_requests(id) ON DELETE CASCADE,
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  sepay_transaction_id uuid NOT NULL
    REFERENCES public.sepay_transactions(id) ON DELETE RESTRICT,
  linked_by uuid NOT NULL REFERENCES auth.users(id),
  linked_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (request_id, sepay_transaction_id)
);

CREATE INDEX direct_order_sepay_candidates_store
  ON public.direct_order_sepay_candidates(restaurant_id, linked_at DESC);
CREATE INDEX direct_order_sepay_candidates_transaction
  ON public.direct_order_sepay_candidates(sepay_transaction_id);

CREATE TABLE public.direct_order_financials (
  request_id uuid PRIMARY KEY
    REFERENCES public.direct_order_requests(id) ON DELETE RESTRICT,
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE RESTRICT,
  quote_id uuid NOT NULL UNIQUE
    REFERENCES public.direct_order_quotes(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL UNIQUE
    REFERENCES public.orders(id) ON DELETE RESTRICT,
  payment_id uuid NOT NULL UNIQUE
    REFERENCES public.payments(id) ON DELETE RESTRICT,
  delivery_fee_item_id uuid NOT NULL UNIQUE
    REFERENCES public.order_items(id) ON DELETE RESTRICT,
  menu_total numeric(15,2) NOT NULL CHECK (menu_total >= 0),
  service_charge_total numeric(15,2) NOT NULL CHECK (service_charge_total >= 0),
  delivery_fee_total numeric(15,2) NOT NULL CHECK (delivery_fee_total >= 0),
  final_total numeric(15,2) NOT NULL CHECK (final_total > 0),
  confirmed_bank_reference text,
  approved_by uuid NOT NULL REFERENCES auth.users(id),
  approved_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT direct_order_financials_reference_valid CHECK (
    confirmed_bank_reference IS NULL OR
    char_length(confirmed_bank_reference) <= 200
  )
);

CREATE INDEX direct_order_financials_store_approved
  ON public.direct_order_financials(restaurant_id, approved_at DESC);

CREATE TABLE public.direct_delivery_fulfillment_tickets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL UNIQUE
    REFERENCES public.direct_order_requests(id) ON DELETE RESTRICT,
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN (
    'pending', 'preparing', 'ready', 'dispatched', 'completed', 'cancelled'
  )),
  pickup_code text NOT NULL,
  version integer NOT NULL DEFAULT 1 CHECK (version > 0),
  accepted_at timestamptz,
  ready_at timestamptz,
  dispatched_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT direct_delivery_ticket_pickup_code_valid CHECK (
    pickup_code ~ '^D[0-9A-Z]{8}$'
  )
);

CREATE INDEX direct_delivery_tickets_store_status_created
  ON public.direct_delivery_fulfillment_tickets(
    restaurant_id, status, created_at, id
  );

CREATE TABLE public.direct_delivery_fulfillment_ticket_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id uuid NOT NULL
    REFERENCES public.direct_delivery_fulfillment_tickets(id) ON DELETE CASCADE,
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE RESTRICT,
  menu_item_id uuid NOT NULL
    REFERENCES public.menu_items(id) ON DELETE RESTRICT,
  display_name_ko text NOT NULL,
  display_name_vi text NOT NULL,
  display_name_en text NOT NULL,
  quantity integer NOT NULL CHECK (quantity BETWEEN 1 AND 50),
  item_note text,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT direct_delivery_ticket_item_note_valid CHECK (
    item_note IS NULL OR char_length(item_note) <= 300
  )
);

CREATE INDEX direct_delivery_ticket_items_ticket
  ON public.direct_delivery_fulfillment_ticket_items(ticket_id, sort_order, id);
CREATE INDEX direct_delivery_ticket_items_store
  ON public.direct_delivery_fulfillment_ticket_items(restaurant_id, ticket_id);

CREATE TABLE public.direct_order_dispatches (
  request_id uuid PRIMARY KEY
    REFERENCES public.direct_order_requests(id) ON DELETE RESTRICT,
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE RESTRICT,
  grab_tracking_url text NOT NULL,
  customer_delivery_fee numeric(15,2) NOT NULL
    CHECK (customer_delivery_fee >= 0),
  actual_grab_fee numeric(15,2) CHECK (actual_grab_fee >= 0),
  fee_variance numeric(15,2),
  sent_by uuid NOT NULL REFERENCES auth.users(id),
  sent_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT direct_order_dispatches_url_valid CHECK (
    lower(grab_tracking_url) ~
      '^(https://([[:alnum:]-]+[.])*grab[.]com([/:?#]|$)|https://grab[.]onelink[.]me([/:?#]|$))'
    AND char_length(grab_tracking_url) <= 2000
  )
);

CREATE INDEX direct_order_dispatches_store_sent
  ON public.direct_order_dispatches(restaurant_id, sent_at DESC);

INSERT INTO storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
) VALUES (
  'direct-order-proofs',
  'direct-order-proofs',
  false,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
SET public = false,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

ALTER TABLE public.direct_order_storefronts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_order_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_order_public_access_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_order_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_order_request_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_order_request_addresses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_order_location_facts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_order_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_order_quotes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_order_sepay_candidates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_order_financials ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_delivery_fulfillment_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_delivery_fulfillment_ticket_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_order_dispatches ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE
  public.direct_order_storefronts,
  public.direct_order_sessions,
  public.direct_order_public_access_limits,
  public.direct_order_requests,
  public.direct_order_request_items,
  public.direct_order_request_addresses,
  public.direct_order_location_facts,
  public.direct_order_messages,
  public.direct_order_quotes,
  public.direct_order_sepay_candidates,
  public.direct_order_financials,
  public.direct_delivery_fulfillment_tickets,
  public.direct_delivery_fulfillment_ticket_items,
  public.direct_order_dispatches
FROM PUBLIC, anon;
REVOKE ALL ON TABLE
  public.direct_order_storefronts,
  public.direct_order_sessions,
  public.direct_order_public_access_limits,
  public.direct_order_requests,
  public.direct_order_request_items,
  public.direct_order_request_addresses,
  public.direct_order_location_facts,
  public.direct_order_messages,
  public.direct_order_quotes,
  public.direct_order_sepay_candidates,
  public.direct_order_financials,
  public.direct_delivery_fulfillment_tickets,
  public.direct_delivery_fulfillment_ticket_items,
  public.direct_order_dispatches
FROM authenticated;

GRANT ALL ON TABLE
  public.direct_order_storefronts,
  public.direct_order_sessions,
  public.direct_order_public_access_limits,
  public.direct_order_requests,
  public.direct_order_request_items,
  public.direct_order_request_addresses,
  public.direct_order_location_facts,
  public.direct_order_messages,
  public.direct_order_quotes,
  public.direct_order_sepay_candidates,
  public.direct_order_financials,
  public.direct_delivery_fulfillment_tickets,
  public.direct_delivery_fulfillment_ticket_items,
  public.direct_order_dispatches
TO service_role;

-- No direct storage policy is created. All proof access is through short-lived
-- signed URLs issued by the Edge boundary after session or staff validation.

CREATE OR REPLACE FUNCTION public.direct_order_require_actor(
  p_store_id uuid,
  p_allowed_roles text[]
) RETURNS public.users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  IF p_store_id IS NULL OR p_allowed_roles IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_ACTOR_INPUT_REQUIRED';
  END IF;

  SELECT * INTO v_actor
  FROM public.users user_row
  WHERE user_row.auth_id = (SELECT auth.uid())
    AND user_row.is_active = true
  LIMIT 1;

  IF NOT FOUND OR NOT (v_actor.role = ANY(p_allowed_roles)) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores((SELECT auth.uid())) scope(store_id)
       WHERE scope.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_FORBIDDEN';
  END IF;

  RETURN v_actor;
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_require_actor(uuid, text[])
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.direct_order_consume_public_rate(
  p_request_key text,
  p_limit integer DEFAULT 60,
  p_window_seconds integer DEFAULT 60
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_bucket timestamptz;
  v_count integer;
BEGIN
  IF NULLIF(btrim(COALESCE(p_request_key, '')), '') IS NULL
     OR p_limit NOT BETWEEN 1 AND 1000
     OR p_window_seconds NOT BETWEEN 10 AND 3600 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_RATE_INPUT_INVALID';
  END IF;

  v_bucket := to_timestamp(
    floor(extract(epoch FROM clock_timestamp()) / p_window_seconds)
    * p_window_seconds
  );

  INSERT INTO public.direct_order_public_access_limits(
    request_key, window_started_at, request_count
  ) VALUES (p_request_key, v_bucket, 1)
  ON CONFLICT (request_key, window_started_at)
  DO UPDATE SET
    request_count = direct_order_public_access_limits.request_count + 1,
    updated_at = now()
  RETURNING request_count INTO v_count;

  RETURN v_count <= p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_consume_public_rate(text, integer, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_consume_public_rate(text, integer, integer)
  TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_public_storefront(
  p_slug text
) RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  SELECT jsonb_build_object(
    'store_id', store.id,
    'store_name', store.name,
    'slug', storefront.public_slug,
    'paused', storefront.is_paused,
    'ordering_starts_at', storefront.ordering_starts_at,
    'ordering_cutoff_at', storefront.ordering_cutoff_at,
    'minimum_order_amount', storefront.minimum_order_amount,
    'default_latitude', storefront.default_latitude,
    'default_longitude', storefront.default_longitude,
    'bank', jsonb_build_object(
      'bin', storefront.bank_bin,
      'account_number', storefront.bank_account_number,
      'account_holder', storefront.bank_account_holder,
      'label', storefront.bank_label
    ),
    'categories', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', category.id,
        'name_ko', COALESCE(NULLIF(category.name_ko, ''), category.name),
        'name_vi', COALESCE(NULLIF(category.name_vi, ''), category.name),
        'name_en', COALESCE(NULLIF(category.name_en, ''), category.name),
        'sort_order', category.sort_order
      ) ORDER BY category.sort_order, category.id)
      FROM public.menu_categories category
      WHERE category.restaurant_id = store.id
        AND category.is_active = true
        AND EXISTS (
          SELECT 1 FROM public.menu_items menu
          WHERE menu.restaurant_id = store.id
            AND menu.category_id = category.id
            AND menu.is_available = true
            AND menu.is_visible_public = true
            AND COALESCE(menu.combo_drink_choice_count, 0) = 0
        )
    ), '[]'::jsonb),
    'items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', menu.id,
        'category_id', menu.category_id,
        'name_ko', COALESCE(NULLIF(menu.name_ko, ''), menu.name),
        'name_vi', COALESCE(NULLIF(menu.name_vi, ''), menu.name),
        'name_en', COALESCE(NULLIF(menu.name_en, ''), menu.name),
        'description', menu.description,
        'price', menu.price,
        'image_url', menu.image_url,
        'vat_category', menu.vat_category,
        'sort_order', menu.sort_order
      ) ORDER BY menu.sort_order, menu.id)
      FROM public.menu_items menu
      WHERE menu.restaurant_id = store.id
        AND menu.is_available = true
        AND menu.is_visible_public = true
        AND COALESCE(menu.combo_drink_choice_count, 0) = 0
    ), '[]'::jsonb)
  )
  FROM public.direct_order_storefronts storefront
  JOIN public.restaurants store ON store.id = storefront.restaurant_id
  WHERE storefront.public_slug = lower(btrim(p_slug))
    AND storefront.is_enabled = true
    AND store.is_active = true;
$$;

REVOKE ALL ON FUNCTION public.direct_order_public_storefront(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_storefront(text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_public_create_session(
  p_slug text,
  p_secret_hash text,
  p_locale text DEFAULT 'vi'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_storefront public.direct_order_storefronts%ROWTYPE;
  v_session public.direct_order_sessions%ROWTYPE;
BEGIN
  IF p_secret_hash !~ '^[a-f0-9]{64}$'
     OR p_locale NOT IN ('ko', 'vi', 'en') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_SESSION_INPUT_INVALID';
  END IF;

  SELECT storefront.* INTO v_storefront
  FROM public.direct_order_storefronts storefront
  JOIN public.restaurants store ON store.id = storefront.restaurant_id
  WHERE storefront.public_slug = lower(btrim(p_slug))
    AND storefront.is_enabled = true
    AND store.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DIRECT_ORDER_STOREFRONT_NOT_FOUND';
  END IF;

  INSERT INTO public.direct_order_sessions(
    restaurant_id, secret_hash, locale
  ) VALUES (
    v_storefront.restaurant_id, p_secret_hash, p_locale
  ) RETURNING * INTO v_session;

  RETURN jsonb_build_object(
    'session_id', v_session.id,
    'store_id', v_session.restaurant_id,
    'expires_at', v_session.expires_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_public_create_session(text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_create_session(text, text, text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_validate_session(
  p_session_id uuid,
  p_secret_hash text
) RETURNS public.direct_order_sessions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_session public.direct_order_sessions%ROWTYPE;
BEGIN
  SELECT * INTO v_session
  FROM public.direct_order_sessions session_row
  WHERE session_row.id = p_session_id
    AND session_row.secret_hash = p_secret_hash
    AND session_row.revoked_at IS NULL
    AND session_row.expires_at > now();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DIRECT_ORDER_SESSION_INVALID';
  END IF;

  UPDATE public.direct_order_sessions
  SET last_seen_at = now()
  WHERE id = v_session.id;

  RETURN v_session;
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_validate_session(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_validate_session(uuid, text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_public_submit(
  p_session_id uuid,
  p_secret_hash text,
  p_client_request_id uuid,
  p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_session public.direct_order_sessions%ROWTYPE;
  v_storefront public.direct_order_storefronts%ROWTYPE;
  v_request public.direct_order_requests%ROWTYPE;
  v_existing public.direct_order_requests%ROWTYPE;
  v_address jsonb;
  v_item jsonb;
  v_menu public.menu_items%ROWTYPE;
  v_item_count integer := 0;
  v_total_quantity integer := 0;
  v_reference text;
  v_local_time time;
BEGIN
  IF p_client_request_id IS NULL
     OR p_payload IS NULL
     OR jsonb_typeof(p_payload) <> 'object'
     OR jsonb_typeof(p_payload->'items') <> 'array'
     OR jsonb_array_length(p_payload->'items') NOT BETWEEN 1 AND 50
     OR jsonb_typeof(p_payload->'address') <> 'object'
     OR COALESCE(p_payload->>'locale', '') NOT IN ('ko', 'vi', 'en') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_INPUT_INVALID';
  END IF;

  v_session := public.direct_order_validate_session(
    p_session_id, p_secret_hash
  );

  SELECT * INTO v_existing
  FROM public.direct_order_requests request_row
  WHERE request_row.client_request_id = p_client_request_id;
  IF FOUND THEN
    IF v_existing.session_id <> v_session.id
       OR v_existing.restaurant_id <> v_session.restaurant_id THEN
      RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_INPUT_INVALID';
    END IF;
    RETURN jsonb_build_object(
      'request_id', v_existing.id,
      'reference_code', v_existing.reference_code,
      'state', v_existing.state,
      'idempotent', true
    );
  END IF;

  SELECT * INTO v_storefront
  FROM public.direct_order_storefronts storefront
  WHERE storefront.restaurant_id = v_session.restaurant_id
    AND storefront.is_enabled = true
  FOR SHARE;

  IF NOT FOUND OR v_storefront.is_paused THEN
    RAISE EXCEPTION 'DIRECT_ORDER_STOREFRONT_PAUSED';
  END IF;

  v_local_time := (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::time;
  IF v_local_time < v_storefront.ordering_starts_at
     OR v_local_time >= v_storefront.ordering_cutoff_at THEN
    RAISE EXCEPTION 'DIRECT_ORDER_OUTSIDE_HOURS';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.direct_order_requests open_request
    WHERE open_request.session_id = p_session_id
      AND open_request.state IN (
        'awaiting_quote', 'quoted', 'awaiting_payment_review'
      )
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_OPEN_REQUEST_EXISTS';
  END IF;

  v_address := p_payload->'address';
  IF COALESCE((v_address->>'location_verified')::boolean, false) = false
     OR COALESCE(v_address->>'address_source', '') NOT IN ('search', 'map_pin')
     OR NULLIF(btrim(COALESCE(v_address->>'customer_name', '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(v_address->>'customer_phone', '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(v_address->>'formatted_address', '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(v_address->>'detail_address', '')), '') IS NULL
     OR (v_address->>'latitude') IS NULL
     OR (v_address->>'longitude') IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
  END IF;

  v_reference := 'D' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

  INSERT INTO public.direct_order_requests(
    restaurant_id, session_id, client_request_id, reference_code,
    state, locale, customer_note
  ) VALUES (
    v_session.restaurant_id,
    v_session.id,
    p_client_request_id,
    v_reference,
    'awaiting_quote',
    COALESCE(NULLIF(p_payload->>'locale', ''), v_session.locale),
    NULLIF(btrim(COALESCE(p_payload->>'customer_note', '')), '')
  ) RETURNING * INTO v_request;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'items')
  LOOP
    IF (v_item->>'menu_item_id') IS NULL
       OR COALESCE((v_item->>'quantity')::integer, 0) NOT BETWEEN 1 AND 50 THEN
      RAISE EXCEPTION 'DIRECT_ORDER_ITEM_INVALID';
    END IF;

    SELECT * INTO v_menu
    FROM public.menu_items menu
    WHERE menu.id = (v_item->>'menu_item_id')::uuid
      AND menu.restaurant_id = v_session.restaurant_id
      AND menu.is_available = true
      AND menu.is_visible_public = true
      AND COALESCE(menu.combo_drink_choice_count, 0) = 0;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'DIRECT_ORDER_MENU_UNAVAILABLE';
    END IF;

    INSERT INTO public.direct_order_request_items(
      request_id, restaurant_id, menu_item_id, display_name,
      name_ko, name_vi, name_en, vat_category, unit_price, quantity,
      item_note, sort_order
    ) VALUES (
      v_request.id,
      v_request.restaurant_id,
      v_menu.id,
      v_menu.name,
      COALESCE(NULLIF(v_menu.name_ko, ''), v_menu.name),
      COALESCE(NULLIF(v_menu.name_vi, ''), v_menu.name),
      COALESCE(NULLIF(v_menu.name_en, ''), v_menu.name),
      COALESCE(v_menu.vat_category, 'food'),
      v_menu.price,
      (v_item->>'quantity')::integer,
      NULLIF(btrim(COALESCE(v_item->>'note', '')), ''),
      v_item_count
    );

    v_item_count := v_item_count + 1;
    v_total_quantity := v_total_quantity + (v_item->>'quantity')::integer;
  END LOOP;

  IF v_total_quantity > 100 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_QUANTITY_LIMIT';
  END IF;

  INSERT INTO public.direct_order_request_addresses(
    request_id, restaurant_id, customer_name, customer_phone,
    formatted_address, detail_address, latitude, longitude,
    google_place_id, district, ward, address_source, location_verified
  ) VALUES (
    v_request.id,
    v_request.restaurant_id,
    btrim(v_address->>'customer_name'),
    btrim(v_address->>'customer_phone'),
    btrim(v_address->>'formatted_address'),
    btrim(v_address->>'detail_address'),
    (v_address->>'latitude')::numeric,
    (v_address->>'longitude')::numeric,
    NULLIF(btrim(COALESCE(v_address->>'google_place_id', '')), ''),
    NULLIF(btrim(COALESCE(v_address->>'district', '')), ''),
    NULLIF(btrim(COALESCE(v_address->>'ward', '')), ''),
    v_address->>'address_source',
    true
  );

  INSERT INTO public.direct_order_location_facts(
    request_id, restaurant_id, district, ward,
    coarse_latitude, coarse_longitude, requested_at
  ) VALUES (
    v_request.id,
    v_request.restaurant_id,
    NULLIF(btrim(COALESCE(v_address->>'district', '')), ''),
    NULLIF(btrim(COALESCE(v_address->>'ward', '')), ''),
    round((v_address->>'latitude')::numeric, 3),
    round((v_address->>'longitude')::numeric, 3),
    v_request.created_at
  );

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, message_type, body
  ) VALUES (
    v_request.id,
    v_request.restaurant_id,
    'system',
    'system',
    'DIRECT_ORDER_REQUEST_RECEIVED'
  );

  RETURN jsonb_build_object(
    'request_id', v_request.id,
    'reference_code', v_request.reference_code,
    'state', v_request.state,
    'idempotent', false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_public_submit(uuid, text, uuid, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_submit(uuid, text, uuid, jsonb)
  TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_public_message(
  p_session_id uuid,
  p_secret_hash text,
  p_request_id uuid,
  p_body text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_session public.direct_order_sessions%ROWTYPE;
  v_request public.direct_order_requests%ROWTYPE;
  v_message public.direct_order_messages%ROWTYPE;
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
  IF length(btrim(COALESCE(p_body, ''))) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_MESSAGE_INVALID';
  END IF;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, message_type, body
  ) VALUES (
    v_request.id, v_request.restaurant_id, 'customer', 'text', btrim(p_body)
  ) RETURNING * INTO v_message;

  RETURN jsonb_build_object('message_id', v_message.id, 'created_at', v_message.created_at);
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_public_message(uuid, text, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_message(uuid, text, uuid, text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_public_cancel(
  p_session_id uuid,
  p_secret_hash text,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_session public.direct_order_sessions%ROWTYPE;
  v_request public.direct_order_requests%ROWTYPE;
BEGIN
  v_session := public.direct_order_validate_session(
    p_session_id, p_secret_hash
  );
  SELECT * INTO v_request
  FROM public.direct_order_requests request_row
  WHERE request_row.id = p_request_id
    AND request_row.session_id = v_session.id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
  IF v_request.state NOT IN ('awaiting_quote', 'quoted') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_CANCELLABLE';
  END IF;

  UPDATE public.direct_order_requests
  SET state = 'cancelled', cancelled_at = now(), updated_at = now()
  WHERE id = v_request.id;
  UPDATE public.direct_order_quotes
  SET status = 'expired'
  WHERE request_id = v_request.id AND status = 'active';
  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, message_type, body
  ) VALUES (
    v_request.id, v_request.restaurant_id, 'system', 'system',
    'DIRECT_ORDER_CANCELLED_BY_CUSTOMER'
  );
  RETURN jsonb_build_object('request_id', v_request.id, 'state', 'cancelled');
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_public_cancel(uuid, text, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_cancel(uuid, text, uuid)
  TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_public_commit_proof(
  p_session_id uuid,
  p_secret_hash text,
  p_request_id uuid,
  p_storage_path text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_session public.direct_order_sessions%ROWTYPE;
  v_request public.direct_order_requests%ROWTYPE;
  v_quote public.direct_order_quotes%ROWTYPE;
  v_message public.direct_order_messages%ROWTYPE;
  v_expected_prefix text;
BEGIN
  v_session := public.direct_order_validate_session(
    p_session_id, p_secret_hash
  );
  SELECT * INTO v_request
  FROM public.direct_order_requests request_row
  WHERE request_row.id = p_request_id
    AND request_row.session_id = v_session.id
  FOR UPDATE;
  IF NOT FOUND OR v_request.state NOT IN ('quoted', 'awaiting_payment_review') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PROOF_NOT_ALLOWED';
  END IF;

  SELECT * INTO v_quote
  FROM public.direct_order_quotes quote_row
  WHERE quote_row.request_id = v_request.id
    AND quote_row.status IN ('active', 'locked')
    AND quote_row.expires_at > now()
  ORDER BY quote_row.version DESC
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_EXPIRED';
  END IF;

  v_expected_prefix := v_request.restaurant_id::text || '/'
    || v_request.id::text || '/';
  IF p_storage_path !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|jpeg|png|webp)$'
     OR position(v_expected_prefix IN p_storage_path) <> 1 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PROOF_PATH_INVALID';
  END IF;

  SELECT * INTO v_message
  FROM public.direct_order_messages message
  WHERE message.request_id = v_request.id
    AND message.restaurant_id = v_request.restaurant_id
    AND message.message_type = 'payment_proof'
    AND message.attachment_storage_path = p_storage_path;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'message_id', v_message.id,
      'state', 'awaiting_payment_review'
    );
  END IF;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, message_type,
    attachment_storage_path, metadata
  ) VALUES (
    v_request.id,
    v_request.restaurant_id,
    'customer',
    'payment_proof',
    p_storage_path,
    jsonb_build_object('quote_id', v_quote.id, 'quote_version', v_quote.version)
  ) RETURNING * INTO v_message;

  UPDATE public.direct_order_quotes
  SET status = 'locked', locked_at = COALESCE(locked_at, now())
  WHERE id = v_quote.id;

  UPDATE public.direct_order_requests
  SET state = 'awaiting_payment_review', updated_at = now()
  WHERE id = v_request.id;

  RETURN jsonb_build_object(
    'message_id', v_message.id,
    'state', 'awaiting_payment_review'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_public_commit_proof(uuid, text, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_commit_proof(uuid, text, uuid, text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_public_status(
  p_session_id uuid,
  p_secret_hash text,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_session public.direct_order_sessions%ROWTYPE;
  v_request public.direct_order_requests%ROWTYPE;
BEGIN
  v_session := public.direct_order_validate_session(
    p_session_id, p_secret_hash
  );
  SELECT * INTO v_request
  FROM public.direct_order_requests request_row
  WHERE request_row.id = p_request_id
    AND request_row.session_id = v_session.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND';
  END IF;

  RETURN jsonb_build_object(
    'request_id', v_request.id,
    'store_id', v_request.restaurant_id,
    'reference_code', v_request.reference_code,
    'state', v_request.state,
    'created_at', v_request.created_at,
    'items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'menu_item_id', item.menu_item_id,
        'name_ko', item.name_ko,
        'name_vi', item.name_vi,
        'name_en', item.name_en,
        'unit_price', item.unit_price,
        'quantity', item.quantity,
        'note', item.item_note
      ) ORDER BY item.sort_order, item.id)
      FROM public.direct_order_request_items item
      WHERE item.request_id = v_request.id
    ), '[]'::jsonb),
    'quote', (
      SELECT jsonb_build_object(
        'id', quote_row.id,
        'version', quote_row.version,
        'menu_total', quote_row.menu_total,
        'service_charge_total', quote_row.service_charge_total,
        'delivery_fee_total', quote_row.delivery_fee_total,
        'final_total', quote_row.final_total,
        'status', quote_row.status,
        'expires_at', quote_row.expires_at
      )
      FROM public.direct_order_quotes quote_row
      WHERE quote_row.request_id = v_request.id
        AND quote_row.status IN ('active', 'locked')
      ORDER BY quote_row.version DESC
      LIMIT 1
    ),
    'messages', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', message.id,
        'sender_type', message.sender_type,
        'message_type', message.message_type,
        'body', message.body,
        'has_attachment', message.attachment_storage_path IS NOT NULL,
        'created_at', message.created_at
      ) ORDER BY message.created_at, message.id)
      FROM public.direct_order_messages message
      WHERE message.request_id = v_request.id
    ), '[]'::jsonb),
    'fulfillment', (
      SELECT jsonb_build_object(
        'status', ticket.status,
        'pickup_code', ticket.pickup_code,
        'updated_at', ticket.updated_at
      )
      FROM public.direct_delivery_fulfillment_tickets ticket
      WHERE ticket.request_id = v_request.id
    ),
    'dispatch', (
      SELECT jsonb_build_object(
        'grab_tracking_url', dispatch.grab_tracking_url,
        'sent_at', dispatch.sent_at
      )
      FROM public.direct_order_dispatches dispatch
      WHERE dispatch.request_id = v_request.id
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_public_status(uuid, text, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_status(uuid, text, uuid)
  TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_admin_upsert_storefront(
  p_store_id uuid,
  p_public_slug text,
  p_is_enabled boolean,
  p_is_paused boolean,
  p_ordering_starts_at time,
  p_ordering_cutoff_at time,
  p_minimum_order_amount numeric,
  p_quote_ttl_minutes integer,
  p_default_latitude numeric,
  p_default_longitude numeric,
  p_bank_bin text,
  p_bank_account_number text,
  p_bank_account_holder text,
  p_bank_label text,
  p_delivery_fee_vat_rate numeric DEFAULT 0,
  p_pii_retention_days integer DEFAULT 90,
  p_analytics_min_cell_count integer DEFAULT 3,
  p_accounting_approved boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_row public.direct_order_storefronts%ROWTYPE;
BEGIN
  v_actor := public.direct_order_require_actor(
    p_store_id,
    ARRAY['admin', 'store_admin', 'brand_admin', 'super_admin']
  );

  INSERT INTO public.direct_order_storefronts(
    restaurant_id, public_slug, is_enabled, is_paused,
    ordering_starts_at, ordering_cutoff_at, minimum_order_amount,
    quote_ttl_minutes, default_latitude, default_longitude,
    bank_bin, bank_account_number, bank_account_holder, bank_label,
    delivery_fee_vat_rate, pii_retention_days, analytics_min_cell_count,
    accounting_approved_at, accounting_approved_by, created_by, updated_by
  ) VALUES (
    p_store_id,
    lower(btrim(p_public_slug)),
    COALESCE(p_is_enabled, false),
    COALESCE(p_is_paused, false),
    COALESCE(p_ordering_starts_at, '10:00'::time),
    COALESCE(p_ordering_cutoff_at, '21:30'::time),
    COALESCE(p_minimum_order_amount, 0),
    COALESCE(p_quote_ttl_minutes, 20),
    p_default_latitude,
    p_default_longitude,
    NULLIF(btrim(COALESCE(p_bank_bin, '')), ''),
    NULLIF(regexp_replace(COALESCE(p_bank_account_number, ''), '[^A-Za-z0-9]', '', 'g'), ''),
    NULLIF(btrim(COALESCE(p_bank_account_holder, '')), ''),
    NULLIF(btrim(COALESCE(p_bank_label, '')), ''),
    COALESCE(p_delivery_fee_vat_rate, 0),
    COALESCE(p_pii_retention_days, 90),
    COALESCE(p_analytics_min_cell_count, 3),
    CASE WHEN COALESCE(p_accounting_approved, false) THEN now() ELSE NULL END,
    CASE WHEN COALESCE(p_accounting_approved, false)
      THEN (SELECT auth.uid()) ELSE NULL END,
    (SELECT auth.uid()),
    (SELECT auth.uid())
  )
  ON CONFLICT (restaurant_id) DO UPDATE SET
    public_slug = EXCLUDED.public_slug,
    is_enabled = EXCLUDED.is_enabled,
    is_paused = EXCLUDED.is_paused,
    ordering_starts_at = EXCLUDED.ordering_starts_at,
    ordering_cutoff_at = EXCLUDED.ordering_cutoff_at,
    minimum_order_amount = EXCLUDED.minimum_order_amount,
    quote_ttl_minutes = EXCLUDED.quote_ttl_minutes,
    default_latitude = EXCLUDED.default_latitude,
    default_longitude = EXCLUDED.default_longitude,
    bank_bin = EXCLUDED.bank_bin,
    bank_account_number = EXCLUDED.bank_account_number,
    bank_account_holder = EXCLUDED.bank_account_holder,
    bank_label = EXCLUDED.bank_label,
    delivery_fee_vat_rate = EXCLUDED.delivery_fee_vat_rate,
    pii_retention_days = EXCLUDED.pii_retention_days,
    analytics_min_cell_count = EXCLUDED.analytics_min_cell_count,
    accounting_approved_at = CASE
      WHEN COALESCE(p_accounting_approved, false)
        THEN COALESCE(
          direct_order_storefronts.accounting_approved_at,
          now()
        )
      ELSE NULL
    END,
    accounting_approved_by = CASE
      WHEN COALESCE(p_accounting_approved, false)
        THEN COALESCE(
          direct_order_storefronts.accounting_approved_by,
          (SELECT auth.uid())
        )
      ELSE NULL
    END,
    updated_by = EXCLUDED.updated_by,
    updated_at = now()
  RETURNING * INTO v_row;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    (SELECT auth.uid()),
    'direct_order_storefront_upsert',
    'direct_order_storefronts',
    p_store_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'is_enabled', v_row.is_enabled,
      'is_paused', v_row.is_paused,
      'slug', v_row.public_slug
    )
  );

  RETURN to_jsonb(v_row) - ARRAY['created_by', 'updated_by'];
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_admin_upsert_storefront(
  uuid, text, boolean, boolean, time, time, numeric, integer,
  numeric, numeric, text, text, text, text, numeric, integer, integer,
  boolean
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_admin_upsert_storefront(
  uuid, text, boolean, boolean, time, time, numeric, integer,
  numeric, numeric, text, text, text, text, numeric, integer, integer,
  boolean
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_admin_get_storefront(
  p_store_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_row public.direct_order_storefronts%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  SELECT * INTO v_row
  FROM public.direct_order_storefronts storefront
  WHERE storefront.restaurant_id = p_store_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'restaurant_id', p_store_id,
      'is_enabled', false,
      'is_paused', false,
      'accounting_approved', false
    );
  END IF;
  RETURN (
    to_jsonb(v_row) - ARRAY[
      'created_by', 'updated_by', 'accounting_approved_by'
    ]
  ) || jsonb_build_object(
    'accounting_approved', v_row.accounting_approved_at IS NOT NULL
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_admin_get_storefront(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_admin_get_storefront(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_staff_list(
  p_store_id uuid,
  p_states text[] DEFAULT NULL,
  p_after_created_at timestamptz DEFAULT NULL,
  p_after_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 50
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF p_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_LIMIT_INVALID';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(row_payload ORDER BY created_at DESC, id DESC)
    FROM (
      SELECT
        request_row.created_at,
        request_row.id,
        jsonb_build_object(
          'id', request_row.id,
          'reference_code', request_row.reference_code,
          'state', request_row.state,
          'created_at', request_row.created_at,
          'customer_name', address.customer_name,
          'formatted_address', address.formatted_address,
          'district', address.district,
          'item_count', (
            SELECT COALESCE(sum(item.quantity), 0)
            FROM public.direct_order_request_items item
            WHERE item.request_id = request_row.id
          ),
          'final_total', quote_row.final_total,
          'has_payment_proof', EXISTS (
            SELECT 1 FROM public.direct_order_messages message
            WHERE message.request_id = request_row.id
              AND message.message_type = 'payment_proof'
          ),
          'last_message_at', (
            SELECT max(message.created_at)
            FROM public.direct_order_messages message
            WHERE message.request_id = request_row.id
          )
        ) AS row_payload
      FROM public.direct_order_requests request_row
      LEFT JOIN public.direct_order_request_addresses address
        ON address.request_id = request_row.id
      LEFT JOIN LATERAL (
        SELECT quote.final_total
        FROM public.direct_order_quotes quote
        WHERE quote.request_id = request_row.id
          AND quote.status IN ('active', 'locked')
        ORDER BY quote.version DESC LIMIT 1
      ) quote_row ON true
      WHERE request_row.restaurant_id = p_store_id
        AND (p_states IS NULL OR request_row.state = ANY(p_states))
        AND (
          p_after_created_at IS NULL
          OR (request_row.created_at, request_row.id)
             < (p_after_created_at, p_after_id)
        )
      ORDER BY request_row.created_at DESC, request_row.id DESC
      LIMIT p_limit
    ) page
  ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_staff_list(
  uuid, text[], timestamptz, uuid, integer
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_list(
  uuid, text[], timestamptz, uuid, integer
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_staff_detail(
  p_store_id uuid,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_request public.direct_order_requests%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  SELECT * INTO v_request
  FROM public.direct_order_requests request_row
  WHERE request_row.id = p_request_id
    AND request_row.restaurant_id = p_store_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;

  RETURN jsonb_build_object(
    'request', to_jsonb(v_request) - ARRAY['session_id'],
    'address', (
      SELECT to_jsonb(address) - ARRAY['restaurant_id']
      FROM public.direct_order_request_addresses address
      WHERE address.request_id = v_request.id
    ),
    'items', COALESCE((
      SELECT jsonb_agg(to_jsonb(item) - ARRAY['restaurant_id']
        ORDER BY item.sort_order, item.id)
      FROM public.direct_order_request_items item
      WHERE item.request_id = v_request.id
    ), '[]'::jsonb),
    'quotes', COALESCE((
      SELECT jsonb_agg(to_jsonb(quote) - ARRAY['restaurant_id']
        ORDER BY quote.version DESC)
      FROM public.direct_order_quotes quote
      WHERE quote.request_id = v_request.id
    ), '[]'::jsonb),
    'messages', COALESCE((
      SELECT jsonb_agg((to_jsonb(message) - ARRAY[
          'restaurant_id', 'attachment_storage_path'
        ]) || jsonb_build_object(
          'has_attachment', message.attachment_storage_path IS NOT NULL
        ) ORDER BY message.created_at, message.id)
      FROM public.direct_order_messages message
      WHERE message.request_id = v_request.id
    ), '[]'::jsonb),
    'financial', (
      SELECT to_jsonb(financial) - ARRAY['restaurant_id']
      FROM public.direct_order_financials financial
      WHERE financial.request_id = v_request.id
    ),
    'dispatch', (
      SELECT to_jsonb(dispatch) - ARRAY['restaurant_id']
      FROM public.direct_order_dispatches dispatch
      WHERE dispatch.request_id = v_request.id
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_staff_detail(uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_detail(uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_staff_quote(
  p_store_id uuid,
  p_request_id uuid,
  p_delivery_fee_total numeric,
  p_cashier_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_request public.direct_order_requests%ROWTYPE;
  v_storefront public.direct_order_storefronts%ROWTYPE;
  v_brand public.brands%ROWTYPE;
  v_vat_pricing_mode text;
  v_line record;
  v_line_gross numeric(15,2);
  v_line_pretax numeric(15,2);
  v_line_vat numeric(15,2);
  v_line_total numeric(15,2);
  v_vat_rate numeric(5,2);
  v_food_pretax numeric(15,2) := 0;
  v_alcohol_pretax numeric(15,2) := 0;
  v_menu_pretax numeric(15,2) := 0;
  v_menu_vat numeric(15,2) := 0;
  v_menu_total numeric(15,2) := 0;
  v_sc_pretax numeric(15,2) := 0;
  v_sc_vat numeric(15,2) := 0;
  v_sc_total numeric(15,2) := 0;
  v_fee_pretax numeric(15,2);
  v_fee_vat numeric(15,2);
  v_final_total numeric(15,2);
  v_version integer;
  v_quote public.direct_order_quotes%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF p_delivery_fee_total IS NULL OR p_delivery_fee_total < 0
     OR char_length(COALESCE(p_cashier_note, '')) > 500 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_INPUT_INVALID';
  END IF;

  SELECT * INTO v_request
  FROM public.direct_order_requests request_row
  WHERE request_row.id = p_request_id
    AND request_row.restaurant_id = p_store_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
  IF v_request.state NOT IN ('awaiting_quote', 'quoted') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_QUOTABLE';
  END IF;

  SELECT * INTO v_storefront
  FROM public.direct_order_storefronts storefront
  WHERE storefront.restaurant_id = p_store_id
    AND storefront.is_enabled = true
    AND storefront.is_paused = false
  FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_STOREFRONT_DISABLED'; END IF;
  IF v_storefront.accounting_approved_at IS NULL
     OR v_storefront.accounting_approved_by IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_ACCOUNTING_APPROVAL_REQUIRED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.direct_order_request_items request_item
    LEFT JOIN public.menu_items menu ON menu.id = request_item.menu_item_id
    WHERE request_item.request_id = v_request.id
      AND (
        menu.id IS NULL
        OR menu.restaurant_id <> p_store_id
        OR menu.is_available = false
        OR menu.is_visible_public = false
        OR menu.price IS DISTINCT FROM request_item.unit_price
      )
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_MENU_CHANGED';
  END IF;

  SELECT COALESCE(store.vat_pricing_mode, 'exclusive')
  INTO v_vat_pricing_mode
  FROM public.restaurants store
  WHERE store.id = p_store_id;

  SELECT brand.* INTO v_brand
  FROM public.restaurants store
  JOIN public.brands brand ON brand.id = store.brand_id
  WHERE store.id = p_store_id;

  FOR v_line IN
    SELECT item.*
    FROM public.direct_order_request_items item
    WHERE item.request_id = v_request.id
    ORDER BY item.sort_order, item.id
  LOOP
    v_line_gross := round(v_line.unit_price * v_line.quantity, 2);
    v_vat_rate := CASE v_line.vat_category WHEN 'alcohol' THEN 10 ELSE 8 END;
    IF v_vat_pricing_mode = 'inclusive' THEN
      v_line_total := v_line_gross;
      v_line_pretax := round(v_line_total / (1 + v_vat_rate / 100), 2);
      v_line_vat := v_line_total - v_line_pretax;
    ELSE
      v_line_pretax := v_line_gross;
      v_line_vat := round(v_line_pretax * v_vat_rate / 100, 2);
      v_line_total := v_line_pretax + v_line_vat;
    END IF;
    v_menu_pretax := v_menu_pretax + v_line_pretax;
    v_menu_vat := v_menu_vat + v_line_vat;
    v_menu_total := v_menu_total + v_line_total;
    IF v_line.vat_category = 'alcohol' THEN
      v_alcohol_pretax := v_alcohol_pretax + v_line_pretax;
    ELSE
      v_food_pretax := v_food_pretax + v_line_pretax;
    END IF;
  END LOOP;

  IF COALESCE(v_brand.service_charge_enabled, false)
     AND COALESCE(v_brand.service_charge_rate, 0) > 0 THEN
    IF v_food_pretax > 0 THEN
      v_line_pretax := round(v_food_pretax * v_brand.service_charge_rate / 100, 2);
      v_line_vat := round(v_line_pretax * 8 / 100, 2);
      v_sc_pretax := v_sc_pretax + v_line_pretax;
      v_sc_vat := v_sc_vat + v_line_vat;
      v_sc_total := v_sc_total + v_line_pretax + v_line_vat;
    END IF;
    IF v_alcohol_pretax > 0 THEN
      v_line_pretax := round(v_alcohol_pretax * v_brand.service_charge_rate / 100, 2);
      v_line_vat := round(v_line_pretax * 10 / 100, 2);
      v_sc_pretax := v_sc_pretax + v_line_pretax;
      v_sc_vat := v_sc_vat + v_line_vat;
      v_sc_total := v_sc_total + v_line_pretax + v_line_vat;
    END IF;
  END IF;

  IF v_storefront.delivery_fee_vat_rate = 0 THEN
    v_fee_pretax := round(p_delivery_fee_total, 2);
    v_fee_vat := 0;
  ELSE
    v_fee_pretax := round(
      p_delivery_fee_total / (1 + v_storefront.delivery_fee_vat_rate / 100),
      2
    );
    v_fee_vat := round(p_delivery_fee_total, 2) - v_fee_pretax;
  END IF;

  v_menu_pretax := round(v_menu_pretax, 2);
  v_menu_vat := round(v_menu_vat, 2);
  v_menu_total := round(v_menu_total, 2);
  v_sc_pretax := round(v_sc_pretax, 2);
  v_sc_vat := round(v_sc_vat, 2);
  v_sc_total := round(v_sc_total, 2);
  v_final_total := round(v_menu_total + v_sc_total + p_delivery_fee_total, 2);

  IF v_menu_total < v_storefront.minimum_order_amount THEN
    RAISE EXCEPTION 'DIRECT_ORDER_BELOW_MINIMUM';
  END IF;

  UPDATE public.direct_order_quotes
  SET status = 'superseded'
  WHERE request_id = v_request.id
    AND status = 'active';

  SELECT COALESCE(max(version), 0) + 1 INTO v_version
  FROM public.direct_order_quotes
  WHERE request_id = v_request.id;

  INSERT INTO public.direct_order_quotes(
    request_id, restaurant_id, version,
    menu_pretax, menu_vat, menu_total,
    service_charge_pretax, service_charge_vat, service_charge_total,
    delivery_fee_pretax, delivery_fee_vat, delivery_fee_total,
    final_total, delivery_fee_vat_rate, status, cashier_note,
    created_by, expires_at
  ) VALUES (
    v_request.id, p_store_id, v_version,
    v_menu_pretax, v_menu_vat, v_menu_total,
    v_sc_pretax, v_sc_vat, v_sc_total,
    v_fee_pretax, v_fee_vat, round(p_delivery_fee_total, 2),
    v_final_total, v_storefront.delivery_fee_vat_rate, 'active',
    NULLIF(btrim(COALESCE(p_cashier_note, '')), ''),
    (SELECT auth.uid()),
    now() + make_interval(mins => v_storefront.quote_ttl_minutes)
  ) RETURNING * INTO v_quote;

  UPDATE public.direct_order_requests
  SET state = 'quoted', updated_at = now()
  WHERE id = v_request.id;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, sender_auth_id,
    message_type, body, metadata
  ) VALUES (
    v_request.id,
    p_store_id,
    'cashier',
    (SELECT auth.uid()),
    'quote',
    'DIRECT_ORDER_QUOTE_SENT',
    jsonb_build_object(
      'quote_id', v_quote.id,
      'version', v_quote.version,
      'delivery_fee_total', v_quote.delivery_fee_total,
      'final_total', v_quote.final_total,
      'expires_at', v_quote.expires_at
    )
  );

  RETURN to_jsonb(v_quote) - ARRAY['restaurant_id', 'created_by'];
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_staff_quote(uuid, uuid, numeric, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_quote(uuid, uuid, numeric, text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_staff_message(
  p_store_id uuid,
  p_request_id uuid,
  p_body text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_message public.direct_order_messages%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF length(btrim(COALESCE(p_body, ''))) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_MESSAGE_INVALID';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.direct_order_requests request_row
    WHERE request_row.id = p_request_id
      AND request_row.restaurant_id = p_store_id
      AND request_row.state NOT IN ('rejected', 'cancelled', 'expired')
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_CHATABLE';
  END IF;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, sender_auth_id,
    message_type, body
  ) VALUES (
    p_request_id, p_store_id, 'cashier', (SELECT auth.uid()),
    'text', btrim(p_body)
  ) RETURNING * INTO v_message;
  RETURN jsonb_build_object('message_id', v_message.id, 'created_at', v_message.created_at);
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_staff_message(uuid, uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_message(uuid, uuid, text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_staff_reject(
  p_store_id uuid,
  p_request_id uuid,
  p_reason text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_request public.direct_order_requests%ROWTYPE;
  v_reason text := btrim(COALESCE(p_reason, ''));
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF length(v_reason) NOT BETWEEN 3 AND 500 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REJECTION_REASON_INVALID';
  END IF;
  SELECT * INTO v_request
  FROM public.direct_order_requests request_row
  WHERE request_row.id = p_request_id
    AND request_row.restaurant_id = p_store_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
  IF v_request.state NOT IN (
    'awaiting_quote', 'quoted', 'awaiting_payment_review'
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_REJECTABLE';
  END IF;

  UPDATE public.direct_order_requests
  SET state = 'rejected', rejected_at = now(), updated_at = now()
  WHERE id = v_request.id;
  UPDATE public.direct_order_quotes
  SET status = 'expired'
  WHERE request_id = v_request.id AND status IN ('active', 'locked');
  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, sender_auth_id,
    message_type, body
  ) VALUES (
    v_request.id, p_store_id, 'cashier', (SELECT auth.uid()),
    'system', v_reason
  );
  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    (SELECT auth.uid()), 'direct_order_rejected',
    'direct_order_requests', v_request.id,
    jsonb_build_object('store_id', p_store_id, 'reason', v_reason)
  );
  RETURN jsonb_build_object('request_id', v_request.id, 'state', 'rejected');
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_staff_reject(uuid, uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_reject(uuid, uuid, text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_staff_sepay_candidates(
  p_store_id uuid,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_quote public.direct_order_quotes%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  SELECT quote.* INTO v_quote
  FROM public.direct_order_quotes quote
  WHERE quote.request_id = p_request_id
    AND quote.restaurant_id = p_store_id
    AND quote.status IN ('active', 'locked')
  ORDER BY quote.version DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_NOT_FOUND'; END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', transaction_row.id,
      'amount', transaction_row.transfer_amount,
      'payment_code', transaction_row.payment_code,
      'reference_code', transaction_row.reference_code,
      'transaction_at', transaction_row.transaction_at,
      'received_at', transaction_row.received_at
    ) ORDER BY COALESCE(transaction_row.transaction_at, transaction_row.received_at) DESC)
    FROM (
      SELECT transaction_row.*
      FROM public.sepay_transactions transaction_row
      WHERE transaction_row.restaurant_id = p_store_id
        AND transaction_row.transfer_type = 'in'
        AND transaction_row.resolution_status = 'matched'
        AND transaction_row.transfer_amount::numeric = v_quote.final_total
        AND transaction_row.received_at >= now() - interval '2 days'
      ORDER BY COALESCE(transaction_row.transaction_at, transaction_row.received_at) DESC
      LIMIT 20
    ) transaction_row
  ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_staff_sepay_candidates(uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_sepay_candidates(uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_staff_link_sepay(
  p_store_id uuid,
  p_request_id uuid,
  p_transaction_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_link public.direct_order_sepay_candidates%ROWTYPE;
  v_quote public.direct_order_quotes%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  SELECT * INTO v_quote FROM public.direct_order_quotes quote
  WHERE quote.request_id = p_request_id
    AND quote.restaurant_id = p_store_id
    AND quote.status IN ('active', 'locked')
  ORDER BY quote.version DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_NOT_FOUND'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.sepay_transactions transaction_row
    WHERE transaction_row.id = p_transaction_id
      AND transaction_row.restaurant_id = p_store_id
      AND transaction_row.transfer_type = 'in'
      AND transaction_row.resolution_status = 'matched'
      AND transaction_row.transfer_amount::numeric = v_quote.final_total
      AND transaction_row.received_at >= now() - interval '2 days'
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_SEPAY_CANDIDATE_INVALID';
  END IF;

  INSERT INTO public.direct_order_sepay_candidates(
    request_id, restaurant_id, sepay_transaction_id, linked_by
  ) VALUES (
    p_request_id, p_store_id, p_transaction_id, (SELECT auth.uid())
  )
  ON CONFLICT (request_id, sepay_transaction_id) DO UPDATE
  SET linked_by = EXCLUDED.linked_by, linked_at = now()
  RETURNING * INTO v_link;
  RETURN to_jsonb(v_link) - ARRAY['restaurant_id', 'linked_by'];
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_staff_link_sepay(uuid, uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_link_sepay(uuid, uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_approve_payment(
  p_store_id uuid,
  p_request_id uuid,
  p_confirmed_amount numeric,
  p_confirmed_bank_reference text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_request public.direct_order_requests%ROWTYPE;
  v_quote public.direct_order_quotes%ROWTYPE;
  v_existing public.direct_order_financials%ROWTYPE;
  v_storefront public.direct_order_storefronts%ROWTYPE;
  v_mode text;
  v_order public.orders%ROWTYPE;
  v_payment public.payments%ROWTYPE;
  v_delivery_item public.order_items%ROWTYPE;
  v_ticket public.direct_delivery_fulfillment_tickets%ROWTYPE;
  v_order_total numeric(15,2);
  v_local_time time;
BEGIN
  v_actor := public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF p_confirmed_amount IS NULL OR p_confirmed_amount <= 0
     OR char_length(COALESCE(p_confirmed_bank_reference, '')) > 200 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_APPROVAL_INPUT_INVALID';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('direct-order-approval:' || p_request_id::text, 0)
  );

  SELECT * INTO v_existing
  FROM public.direct_order_financials financial
  WHERE financial.request_id = p_request_id
    AND financial.restaurant_id = p_store_id;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'request_id', v_existing.request_id,
      'order_id', v_existing.order_id,
      'payment_id', v_existing.payment_id,
      'ticket_id', (
        SELECT ticket.id
        FROM public.direct_delivery_fulfillment_tickets ticket
        WHERE ticket.request_id = v_existing.request_id
          AND ticket.restaurant_id = p_store_id
      ),
      'final_total', v_existing.final_total,
      'idempotent', true
    );
  END IF;

  SELECT * INTO v_request
  FROM public.direct_order_requests request_row
  WHERE request_row.id = p_request_id
    AND request_row.restaurant_id = p_store_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
  IF v_request.state <> 'awaiting_payment_review' THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_APPROVABLE';
  END IF;

  SELECT * INTO v_storefront
  FROM public.direct_order_storefronts storefront
  WHERE storefront.restaurant_id = p_store_id
    AND storefront.is_enabled = true
    AND storefront.is_paused = false
  FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_STOREFRONT_DISABLED'; END IF;

  v_local_time := (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::time;
  IF v_local_time >= LEAST(v_storefront.ordering_cutoff_at, '21:30'::time) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_APPROVAL_CUTOFF';
  END IF;

  SELECT COALESCE(settings.fulfillment_mode, 'pos_print') INTO v_mode
  FROM public.restaurant_settings settings
  WHERE settings.restaurant_id = p_store_id;
  v_mode := COALESCE(v_mode, 'pos_print');
  IF v_mode <> 'pos_print' THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUIRES_POS_PRINT';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_sessions session_row
    WHERE session_row.restaurant_id = p_store_id
      AND session_row.status = 'active'
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_EMERGENCY_ACTIVE';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.store_promotions promotion
    WHERE promotion.restaurant_id = p_store_id
      AND promotion.is_active = true
      AND now() >= promotion.starts_at
      AND now() < promotion.ends_at
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PROMOTION_ACTIVE';
  END IF;

  SELECT * INTO v_quote
  FROM public.direct_order_quotes quote
  WHERE quote.request_id = v_request.id
    AND quote.restaurant_id = p_store_id
    AND quote.status = 'locked'
  ORDER BY quote.version DESC
  LIMIT 1
  FOR UPDATE;
  IF NOT FOUND OR v_quote.expires_at <= now() THEN
    RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_EXPIRED';
  END IF;
  IF round(p_confirmed_amount, 2) IS DISTINCT FROM round(v_quote.final_total, 2) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_AMOUNT_MISMATCH';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.direct_order_messages message
    WHERE message.request_id = v_request.id
      AND message.message_type = 'payment_proof'
      AND message.attachment_storage_path IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_PROOF_REQUIRED';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.direct_order_request_items request_item
    LEFT JOIN public.menu_items menu ON menu.id = request_item.menu_item_id
    WHERE request_item.request_id = v_request.id
      AND (
        menu.id IS NULL OR menu.restaurant_id <> p_store_id
        OR menu.is_available = false OR menu.is_visible_public = false
        OR menu.price IS DISTINCT FROM request_item.unit_price
      )
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_MENU_CHANGED';
  END IF;

  INSERT INTO public.orders(
    restaurant_id, table_id, sales_channel, status, guest_count,
    created_by, notes, order_source, order_purpose,
    fulfillment_mode_snapshot
  ) VALUES (
    p_store_id, NULL, 'delivery', 'serving', NULL,
    (SELECT auth.uid()),
    'Direct delivery ' || v_request.reference_code,
    'staff', 'customer', 'pos_print'
  ) RETURNING * INTO v_order;

  INSERT INTO public.order_items(
    restaurant_id, order_id, menu_item_id, item_type, label,
    display_name, unit_price, quantity, status, notes,
    vat_rate, vat_amount, total_amount_ex_tax, paying_amount_inc_tax,
    is_service_item, fulfillment_mode_snapshot
  )
  SELECT
    p_store_id,
    v_order.id,
    item.menu_item_id,
    'menu_item',
    item.display_name,
    item.display_name,
    item.unit_price,
    item.quantity,
    'served',
    item.item_note,
    0, 0, 0, 0,
    false,
    'pos_print'
  FROM public.direct_order_request_items item
  WHERE item.request_id = v_request.id
  ORDER BY item.sort_order, item.id;

  INSERT INTO public.order_items(
    restaurant_id, order_id, menu_item_id, item_type, label,
    display_name, unit_price, quantity, status,
    vat_rate, vat_amount, total_amount_ex_tax, paying_amount_inc_tax,
    is_service_item, fulfillment_mode_snapshot
  ) VALUES (
    p_store_id, v_order.id, NULL, 'service_charge', 'Phí giao hàng',
    'Phí giao hàng', v_quote.delivery_fee_pretax, 1, 'served',
    v_quote.delivery_fee_vat_rate, v_quote.delivery_fee_vat,
    v_quote.delivery_fee_pretax, v_quote.delivery_fee_total,
    false, 'pos_print'
  ) RETURNING * INTO v_delivery_item;

  INSERT INTO public.direct_delivery_fulfillment_tickets(
    request_id, restaurant_id, pickup_code, updated_by
  ) VALUES (
    v_request.id, p_store_id, v_request.reference_code, (SELECT auth.uid())
  ) RETURNING * INTO v_ticket;

  INSERT INTO public.direct_delivery_fulfillment_ticket_items(
    ticket_id, restaurant_id, menu_item_id,
    display_name_ko, display_name_vi, display_name_en,
    quantity, item_note, sort_order
  )
  SELECT
    v_ticket.id, p_store_id, item.menu_item_id,
    item.name_ko, item.name_vi, item.name_en,
    item.quantity, item.item_note, item.sort_order
  FROM public.direct_order_request_items item
  WHERE item.request_id = v_request.id
  ORDER BY item.sort_order, item.id;

  -- This is the unchanged, authoritative payment anchor. It also produces
  -- brand service-charge lines, VAT snapshots, inventory deductions, and the
  -- asynchronous MISA queue record. Any mismatch below rolls all of it back.
  v_payment := public.process_payment(
    v_order.id, p_store_id, v_quote.final_total, 'BANKTRANSFER'
  );

  SELECT round(COALESCE(sum(item.paying_amount_inc_tax), 0), 2)
  INTO v_order_total
  FROM public.order_items item
  WHERE item.order_id = v_order.id
    AND item.status <> 'cancelled'
    AND COALESCE(item.is_service_item, false) = false;

  IF v_order_total IS DISTINCT FROM round(v_quote.final_total, 2)
     OR round(v_payment.amount_portion, 2) IS DISTINCT FROM round(v_quote.final_total, 2)
     OR NOT EXISTS (
       SELECT 1 FROM public.orders completed_order
       WHERE completed_order.id = v_order.id
         AND completed_order.status = 'completed'
     ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_FINANCIAL_RECONCILIATION_FAILED';
  END IF;

  INSERT INTO public.direct_order_financials(
    request_id, restaurant_id, quote_id, order_id, payment_id,
    delivery_fee_item_id, menu_total, service_charge_total,
    delivery_fee_total, final_total, confirmed_bank_reference,
    approved_by
  ) VALUES (
    v_request.id, p_store_id, v_quote.id, v_order.id, v_payment.id,
    v_delivery_item.id, v_quote.menu_total, v_quote.service_charge_total,
    v_quote.delivery_fee_total, v_quote.final_total,
    NULLIF(btrim(COALESCE(p_confirmed_bank_reference, '')), ''),
    (SELECT auth.uid())
  );

  UPDATE public.direct_order_requests
  SET state = 'approved', approved_at = now(), updated_at = now()
  WHERE id = v_request.id;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, message_type, body,
    metadata
  ) VALUES (
    v_request.id, p_store_id, 'system', 'system',
    'DIRECT_ORDER_PAYMENT_APPROVED',
    jsonb_build_object('order_id', v_order.id, 'ticket_id', v_ticket.id)
  );

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    (SELECT auth.uid()),
    'direct_order_payment_approved',
    'direct_order_requests',
    v_request.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'quote_id', v_quote.id,
      'order_id', v_order.id,
      'payment_id', v_payment.id,
      'ticket_id', v_ticket.id,
      'final_total', v_quote.final_total
    )
  );

  RETURN jsonb_build_object(
    'request_id', v_request.id,
    'order_id', v_order.id,
    'payment_id', v_payment.id,
    'ticket_id', v_ticket.id,
    'final_total', v_quote.final_total,
    'idempotent', false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_approve_payment(uuid, uuid, numeric, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_approve_payment(uuid, uuid, numeric, text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_delivery_ticket_list(
  p_store_id uuid,
  p_statuses text[] DEFAULT NULL,
  p_after_created_at timestamptz DEFAULT NULL,
  p_after_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['kitchen', 'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF p_limit NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_LIMIT_INVALID';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(payload ORDER BY created_at, id)
    FROM (
      SELECT ticket.created_at, ticket.id, jsonb_build_object(
        'id', ticket.id,
        'request_id', ticket.request_id,
        'status', ticket.status,
        'pickup_code', ticket.pickup_code,
        'version', ticket.version,
        'created_at', ticket.created_at,
        'updated_at', ticket.updated_at,
        'items', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'id', item.id,
            'name_ko', item.display_name_ko,
            'name_vi', item.display_name_vi,
            'name_en', item.display_name_en,
            'quantity', item.quantity,
            'note', item.item_note
          ) ORDER BY item.sort_order, item.id)
          FROM public.direct_delivery_fulfillment_ticket_items item
          WHERE item.ticket_id = ticket.id
        ), '[]'::jsonb)
      ) AS payload
      FROM public.direct_delivery_fulfillment_tickets ticket
      WHERE ticket.restaurant_id = p_store_id
        AND (p_statuses IS NULL OR ticket.status = ANY(p_statuses))
        AND (
          p_after_created_at IS NULL
          OR (ticket.created_at, ticket.id)
             > (p_after_created_at, p_after_id)
        )
      ORDER BY ticket.created_at, ticket.id
      LIMIT p_limit
    ) page
  ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.direct_delivery_ticket_list(
  uuid, text[], timestamptz, uuid, integer
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_delivery_ticket_list(
  uuid, text[], timestamptz, uuid, integer
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_delivery_ticket_transition(
  p_store_id uuid,
  p_ticket_id uuid,
  p_expected_version integer,
  p_next_status text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_ticket public.direct_delivery_fulfillment_tickets%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['kitchen', 'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  SELECT * INTO v_ticket
  FROM public.direct_delivery_fulfillment_tickets ticket
  WHERE ticket.id = p_ticket_id
    AND ticket.restaurant_id = p_store_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_DELIVERY_TICKET_NOT_FOUND'; END IF;
  IF v_ticket.version <> p_expected_version THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_TICKET_VERSION_CONFLICT';
  END IF;
  IF NOT (
    (v_ticket.status = 'pending' AND p_next_status IN ('preparing', 'cancelled'))
    OR (v_ticket.status = 'preparing' AND p_next_status IN ('ready', 'cancelled'))
    OR (v_ticket.status = 'ready' AND p_next_status IN ('dispatched', 'cancelled'))
    OR (v_ticket.status = 'dispatched' AND p_next_status = 'completed')
  ) THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_TICKET_TRANSITION_INVALID';
  END IF;

  UPDATE public.direct_delivery_fulfillment_tickets
  SET status = p_next_status,
      version = version + 1,
      accepted_at = CASE WHEN p_next_status = 'preparing' THEN now() ELSE accepted_at END,
      ready_at = CASE WHEN p_next_status = 'ready' THEN now() ELSE ready_at END,
      dispatched_at = CASE WHEN p_next_status = 'dispatched' THEN now() ELSE dispatched_at END,
      completed_at = CASE WHEN p_next_status = 'completed' THEN now() ELSE completed_at END,
      cancelled_at = CASE WHEN p_next_status = 'cancelled' THEN now() ELSE cancelled_at END,
      updated_by = (SELECT auth.uid()),
      updated_at = now()
  WHERE id = v_ticket.id
  RETURNING * INTO v_ticket;

  RETURN to_jsonb(v_ticket) - ARRAY['restaurant_id', 'updated_by'];
END;
$$;

REVOKE ALL ON FUNCTION public.direct_delivery_ticket_transition(uuid, uuid, integer, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_delivery_ticket_transition(uuid, uuid, integer, text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_set_dispatch(
  p_store_id uuid,
  p_request_id uuid,
  p_grab_tracking_url text,
  p_actual_grab_fee numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_financial public.direct_order_financials%ROWTYPE;
  v_dispatch public.direct_order_dispatches%ROWTYPE;
  v_ticket public.direct_delivery_fulfillment_tickets%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF lower(COALESCE(p_grab_tracking_url, '')) !~
       '^(https://([[:alnum:]-]+[.])*grab[.]com([/:?#]|$)|https://grab[.]onelink[.]me([/:?#]|$))'
     OR char_length(p_grab_tracking_url) > 2000
     OR (p_actual_grab_fee IS NOT NULL AND p_actual_grab_fee < 0) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_DISPATCH_INPUT_INVALID';
  END IF;
  SELECT * INTO v_financial
  FROM public.direct_order_financials financial
  WHERE financial.request_id = p_request_id
    AND financial.restaurant_id = p_store_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_NOT_APPROVED'; END IF;

  INSERT INTO public.direct_order_dispatches(
    request_id, restaurant_id, grab_tracking_url,
    customer_delivery_fee, actual_grab_fee, fee_variance, sent_by
  ) VALUES (
    p_request_id, p_store_id, p_grab_tracking_url,
    v_financial.delivery_fee_total, p_actual_grab_fee,
    CASE WHEN p_actual_grab_fee IS NULL THEN NULL
      ELSE v_financial.delivery_fee_total - p_actual_grab_fee END,
    (SELECT auth.uid())
  )
  ON CONFLICT (request_id) DO UPDATE SET
    grab_tracking_url = EXCLUDED.grab_tracking_url,
    actual_grab_fee = EXCLUDED.actual_grab_fee,
    fee_variance = EXCLUDED.fee_variance,
    sent_by = EXCLUDED.sent_by,
    sent_at = now(),
    updated_at = now()
  RETURNING * INTO v_dispatch;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, sender_auth_id,
    message_type, body
  ) VALUES (
    p_request_id, p_store_id, 'cashier', (SELECT auth.uid()),
    'grab_link', p_grab_tracking_url
  );

  SELECT * INTO v_ticket
  FROM public.direct_delivery_fulfillment_tickets ticket
  WHERE ticket.request_id = p_request_id
  FOR UPDATE;
  IF FOUND AND v_ticket.status = 'ready' THEN
    UPDATE public.direct_delivery_fulfillment_tickets
    SET status = 'dispatched',
        version = version + 1,
        dispatched_at = now(),
        updated_by = (SELECT auth.uid()),
        updated_at = now()
    WHERE id = v_ticket.id;
  END IF;

  RETURN to_jsonb(v_dispatch) - ARRAY['restaurant_id', 'sent_by'];
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_set_dispatch(uuid, uuid, text, numeric)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_set_dispatch(uuid, uuid, text, numeric)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_analytics(
  p_store_id uuid,
  p_from_date date,
  p_to_date date
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_min_count integer;
  v_start timestamptz;
  v_end timestamptz;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF p_from_date IS NULL OR p_to_date IS NULL
     OR p_to_date < p_from_date
     OR p_to_date - p_from_date > 366 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_ANALYTICS_RANGE_INVALID';
  END IF;
  SELECT analytics_min_cell_count INTO v_min_count
  FROM public.direct_order_storefronts
  WHERE restaurant_id = p_store_id;
  v_min_count := COALESCE(v_min_count, 3);
  v_start := p_from_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_end := (p_to_date + 1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';

  RETURN jsonb_build_object(
    'summary', (
      SELECT jsonb_build_object(
        'order_count', count(*),
        'gross_sales', COALESCE(sum(financial.final_total), 0),
        'menu_sales', COALESCE(sum(financial.menu_total), 0),
        'service_charge_sales', COALESCE(sum(financial.service_charge_total), 0),
        'delivery_fee_sales', COALESCE(sum(financial.delivery_fee_total), 0),
        'average_order_value', CASE WHEN count(*) = 0 THEN 0
          ELSE round(sum(financial.final_total) / count(*), 2) END,
        'grab_cost', COALESCE(sum(dispatch.actual_grab_fee), 0),
        'delivery_fee_variance', COALESCE(sum(dispatch.fee_variance), 0)
      )
      FROM public.direct_order_financials financial
      LEFT JOIN public.direct_order_dispatches dispatch
        ON dispatch.request_id = financial.request_id
      WHERE financial.restaurant_id = p_store_id
        AND financial.approved_at >= v_start
        AND financial.approved_at < v_end
    ),
    'daily', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'date', day_key,
        'order_count', order_count,
        'gross_sales', gross_sales,
        'delivery_fee_sales', delivery_fee_sales
      ) ORDER BY day_key)
      FROM (
        SELECT
          (financial.approved_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS day_key,
          count(*) AS order_count,
          sum(financial.final_total) AS gross_sales,
          sum(financial.delivery_fee_total) AS delivery_fee_sales
        FROM public.direct_order_financials financial
        WHERE financial.restaurant_id = p_store_id
          AND financial.approved_at >= v_start
          AND financial.approved_at < v_end
        GROUP BY 1
      ) day_rows
    ), '[]'::jsonb),
    'hourly', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'hour', hour_key,
        'order_count', order_count,
        'gross_sales', gross_sales
      ) ORDER BY hour_key)
      FROM (
        SELECT
          extract(hour FROM financial.approved_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::integer AS hour_key,
          count(*) AS order_count,
          sum(financial.final_total) AS gross_sales
        FROM public.direct_order_financials financial
        WHERE financial.restaurant_id = p_store_id
          AND financial.approved_at >= v_start
          AND financial.approved_at < v_end
        GROUP BY 1
      ) hour_rows
    ), '[]'::jsonb),
    'regions', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'district', CASE WHEN order_count >= v_min_count THEN district ELSE 'suppressed' END,
        'ward', CASE WHEN order_count >= v_min_count THEN ward ELSE NULL END,
        'coarse_latitude', CASE WHEN order_count >= v_min_count THEN coarse_latitude ELSE NULL END,
        'coarse_longitude', CASE WHEN order_count >= v_min_count THEN coarse_longitude ELSE NULL END,
        'order_count', order_count
      ) ORDER BY order_count DESC, district, ward)
      FROM (
        SELECT
          fact.district,
          fact.ward,
          fact.coarse_latitude,
          fact.coarse_longitude,
          count(*) AS order_count
        FROM public.direct_order_location_facts fact
        JOIN public.direct_order_financials financial
          ON financial.request_id = fact.request_id
        WHERE fact.restaurant_id = p_store_id
          AND financial.approved_at >= v_start
          AND financial.approved_at < v_end
        GROUP BY 1, 2, 3, 4
      ) region_rows
    ), '[]'::jsonb),
    'privacy_min_cell_count', v_min_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_analytics(uuid, date, date)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_analytics(uuid, date, date)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.direct_order_cleanup_expired_pii(
  p_request_ids uuid[]
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_address_count integer;
  v_message_count integer;
BEGIN
  IF p_request_ids IS NULL OR cardinality(p_request_ids) = 0
     OR cardinality(p_request_ids) > 500 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CLEANUP_INPUT_INVALID';
  END IF;
  IF (
    SELECT count(DISTINCT request_row.id)
    FROM public.direct_order_requests request_row
    JOIN public.direct_order_storefronts storefront
      ON storefront.restaurant_id = request_row.restaurant_id
    WHERE request_row.id = ANY(p_request_ids)
      AND request_row.state IN ('approved', 'rejected', 'cancelled', 'expired')
      AND request_row.pii_purged_at IS NULL
      AND request_row.created_at <
        now() - make_interval(days => storefront.pii_retention_days)
  ) <> cardinality(p_request_ids) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CLEANUP_NOT_ELIGIBLE';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.direct_order_requests request_row
    JOIN public.direct_order_storefronts storefront
      ON storefront.restaurant_id = request_row.restaurant_id
    WHERE request_row.id = ANY(p_request_ids)
      AND request_row.created_at >= now() - make_interval(days => storefront.pii_retention_days)
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CLEANUP_TOO_EARLY';
  END IF;

  DELETE FROM public.direct_order_messages message
  WHERE message.request_id = ANY(p_request_ids);
  GET DIAGNOSTICS v_message_count = ROW_COUNT;
  DELETE FROM public.direct_order_request_addresses address
  WHERE address.request_id = ANY(p_request_ids);
  GET DIAGNOSTICS v_address_count = ROW_COUNT;
  UPDATE public.direct_order_requests
  SET customer_note = NULL, pii_purged_at = now(), updated_at = now()
  WHERE id = ANY(p_request_ids);
  DELETE FROM public.direct_order_sessions session_row
  WHERE session_row.expires_at < now() - interval '30 days'
    AND NOT EXISTS (
      SELECT 1 FROM public.direct_order_requests request_row
      WHERE request_row.session_id = session_row.id
        AND request_row.pii_purged_at IS NULL
    );
  DELETE FROM public.direct_order_public_access_limits limit_row
  WHERE limit_row.window_started_at < now() - interval '1 day';

  RETURN jsonb_build_object(
    'requests', cardinality(p_request_ids),
    'addresses_deleted', v_address_count,
    'messages_deleted', v_message_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_cleanup_expired_pii(uuid[])
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_cleanup_expired_pii(uuid[])
  TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_cleanup_candidates(
  p_limit integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF p_limit NOT BETWEEN 1 AND 500 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CLEANUP_LIMIT_INVALID';
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'request_id', candidate.id,
      'proof_paths', candidate.proof_paths
    ) ORDER BY candidate.created_at, candidate.id)
    FROM (
      SELECT
        request_row.id,
        request_row.created_at,
        COALESCE((
          SELECT jsonb_agg(message.attachment_storage_path)
          FROM public.direct_order_messages message
          WHERE message.request_id = request_row.id
            AND message.attachment_storage_path IS NOT NULL
        ), '[]'::jsonb) AS proof_paths
      FROM public.direct_order_requests request_row
      JOIN public.direct_order_storefronts storefront
        ON storefront.restaurant_id = request_row.restaurant_id
      WHERE request_row.state IN (
        'approved', 'rejected', 'cancelled', 'expired'
      )
        AND request_row.pii_purged_at IS NULL
        AND request_row.created_at <
          now() - make_interval(days => storefront.pii_retention_days)
      ORDER BY request_row.created_at, request_row.id
      LIMIT p_limit
    ) candidate
  ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_cleanup_candidates(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_cleanup_candidates(integer)
  TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_orphan_proof_candidates(
  p_limit integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, storage, pg_catalog
AS $$
BEGIN
  IF p_limit NOT BETWEEN 1 AND 500 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CLEANUP_LIMIT_INVALID';
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(candidate.name ORDER BY candidate.created_at, candidate.id)
    FROM (
      SELECT object_row.id, object_row.name, object_row.created_at
      FROM storage.objects object_row
      WHERE object_row.bucket_id = 'direct-order-proofs'
        AND object_row.created_at < now() - interval '1 day'
        AND NOT EXISTS (
          SELECT 1
          FROM public.direct_order_messages message
          WHERE message.attachment_storage_path = object_row.name
        )
      ORDER BY object_row.created_at, object_row.id
      LIMIT p_limit
    ) candidate
  ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_orphan_proof_candidates(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_orphan_proof_candidates(integer)
  TO service_role;

-- Ensure Edge/service-only functions cannot be reached by regular clients.
DO $$
DECLARE
  v_function regprocedure;
BEGIN
  FOREACH v_function IN ARRAY ARRAY[
    'public.direct_order_public_storefront(text)'::regprocedure,
    'public.direct_order_public_create_session(text,text,text)'::regprocedure,
    'public.direct_order_validate_session(uuid,text)'::regprocedure,
    'public.direct_order_public_submit(uuid,text,uuid,jsonb)'::regprocedure,
    'public.direct_order_public_message(uuid,text,uuid,text)'::regprocedure,
    'public.direct_order_public_cancel(uuid,text,uuid)'::regprocedure,
    'public.direct_order_public_commit_proof(uuid,text,uuid,text)'::regprocedure,
    'public.direct_order_public_status(uuid,text,uuid)'::regprocedure,
    'public.direct_order_cleanup_candidates(integer)'::regprocedure,
    'public.direct_order_orphan_proof_candidates(integer)'::regprocedure,
    'public.direct_order_cleanup_expired_pii(uuid[])'::regprocedure
  ] LOOP
    IF has_function_privilege('anon', v_function, 'EXECUTE')
       OR has_function_privilege('authenticated', v_function, 'EXECUTE') THEN
      RAISE EXCEPTION 'DIRECT_ORDER_PUBLIC_FUNCTION_PRIVILEGE_LEAK:%', v_function;
    END IF;
  END LOOP;
END;
$$;

DO $$
DECLARE
  v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'direct_order_storefronts',
    'direct_order_sessions',
    'direct_order_requests',
    'direct_order_request_items',
    'direct_order_request_addresses',
    'direct_order_location_facts',
    'direct_order_messages',
    'direct_order_quotes',
    'direct_order_financials',
    'direct_delivery_fulfillment_tickets',
    'direct_delivery_fulfillment_ticket_items',
    'direct_order_dispatches'
  ] LOOP
    IF to_regclass('public.' || v_table) IS NULL THEN
      RAISE EXCEPTION 'DIRECT_ORDER_PREFLIGHT_TABLE_MISSING:%', v_table;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_class class_row
      JOIN pg_namespace namespace_row ON namespace_row.oid = class_row.relnamespace
      WHERE namespace_row.nspname = 'public'
        AND class_row.relname = v_table
        AND class_row.relrowsecurity = true
    ) THEN
      RAISE EXCEPTION 'DIRECT_ORDER_RLS_DISABLED:%', v_table;
    END IF;
  END LOOP;

  IF NOT EXISTS (
    SELECT 1 FROM storage.buckets bucket
    WHERE bucket.id = 'direct-order-proofs'
      AND bucket.public = false
      AND bucket.file_size_limit = 5242880
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PROOF_BUCKET_INVALID';
  END IF;

  IF to_regprocedure(
    'public.process_payment(uuid,uuid,numeric,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_ANCHOR_MISSING';
  END IF;
END;
$$;

COMMIT;
