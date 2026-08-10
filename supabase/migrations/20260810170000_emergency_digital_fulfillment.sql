BEGIN;

-- production-gate: self-verifying

-- Emergency digital fulfilment is an opt-in, store-scoped fallback for an
-- unavailable print station. It deliberately owns a separate quantity ledger:
-- the existing order/order-item lifecycle remains the source of truth for POS
-- payment and normal printer-first operation.

ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_account_type_check;
ALTER TABLE public.users
  ADD CONSTRAINT users_account_type_check CHECK (account_type IN (
    'legacy_user', 'master', 'brand_manager', 'store_manager',
    'device_pos', 'device_tablet', 'device_kitchen',
    'device_print_station', 'device_customer_display',
    'device_emergency_station', 'store_operator'
  ));

ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE public.users
  ADD CONSTRAINT users_role_check CHECK (role IN (
    'super_admin', 'master_admin', 'brand_admin', 'store_admin', 'admin',
    'waiter', 'kitchen', 'cashier', 'print_station', 'customer_display',
    'emergency_station', 'photo_objet_master', 'photo_objet_store_admin',
    'photo_objet_store_operator'
  ));

ALTER TABLE public.store_fixed_account_requirements
  DROP CONSTRAINT IF EXISTS store_fixed_account_requirements_type_check;
ALTER TABLE public.store_fixed_account_requirements
  ADD CONSTRAINT store_fixed_account_requirements_type_check CHECK (
    account_type IN (
      'brand_manager', 'store_manager', 'device_pos', 'device_tablet',
      'device_kitchen', 'device_print_station', 'device_customer_display',
      'device_emergency_station', 'store_operator'
    )
  );

ALTER TABLE public.store_fixed_account_requirements
  DROP CONSTRAINT IF EXISTS store_fixed_account_requirements_role_check;
ALTER TABLE public.store_fixed_account_requirements
  ADD CONSTRAINT store_fixed_account_requirements_role_check CHECK (role IN (
    'brand_admin', 'store_admin', 'cashier', 'kitchen', 'print_station',
    'customer_display', 'emergency_station', 'photo_objet_master',
    'photo_objet_store_operator'
  ));

ALTER TABLE public.store_fixed_account_requirements
  DROP CONSTRAINT IF EXISTS store_fixed_account_requirements_role_type_check;
ALTER TABLE public.store_fixed_account_requirements
  ADD CONSTRAINT store_fixed_account_requirements_role_type_check CHECK (
    (account_type = 'brand_manager'
      AND role IN ('brand_admin', 'photo_objet_master') AND scope = 'brand')
    OR (account_type = 'store_manager'
      AND role = 'store_admin' AND scope = 'store')
    OR (account_type IN ('device_pos', 'device_tablet')
      AND role = 'cashier' AND scope = 'store')
    OR (account_type = 'device_kitchen'
      AND role = 'kitchen' AND scope = 'store')
    OR (account_type = 'device_print_station'
      AND role = 'print_station' AND scope = 'store')
    OR (account_type = 'device_customer_display'
      AND role = 'customer_display' AND scope = 'store')
    OR (account_type = 'device_emergency_station'
      AND role = 'emergency_station' AND scope = 'store')
    OR (account_type = 'store_operator'
      AND role = 'photo_objet_store_operator' AND scope = 'store')
  );

-- Keep store setup able to round-trip the new account requirement. This is the
-- current workforce configuration function with only the new device/role
-- values added to its validation and store-code scoping lists.
CREATE OR REPLACE FUNCTION public.admin_configure_store_workforce(
  p_store_id uuid,
  p_short_code text,
  p_management_model text,
  p_brand_manager_slots integer,
  p_account_templates jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_brand_id uuid;
  v_existing_short_code text;
  v_item jsonb;
  v_count integer := 0;
BEGIN
  v_actor := public.require_workforce_manager(p_store_id);
  SELECT brand_id, short_code INTO v_brand_id, v_existing_short_code
  FROM public.restaurants WHERE id = p_store_id;
  IF v_brand_id IS NULL THEN RAISE EXCEPTION 'STORE_BRAND_REQUIRED'; END IF;
  IF upper(btrim(p_short_code)) !~ '^[A-Z0-9]{2,6}$' THEN
    RAISE EXCEPTION 'STORE_SHORT_CODE_INVALID';
  END IF;
  IF p_management_model NOT IN ('brand_centralized', 'store_managed') THEN
    RAISE EXCEPTION 'MANAGEMENT_MODEL_INVALID';
  END IF;
  IF p_brand_manager_slots NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION 'BRAND_MANAGER_SLOTS_INVALID';
  END IF;
  IF jsonb_typeof(p_account_templates) <> 'array'
     OR jsonb_array_length(p_account_templates) = 0 THEN
    RAISE EXCEPTION 'ACCOUNT_TEMPLATES_REQUIRED';
  END IF;
  IF jsonb_array_length(p_account_templates) > 50 THEN
    RAISE EXCEPTION 'ACCOUNT_TEMPLATE_LIMIT';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_account_templates) item(value)
    GROUP BY lower(value->>'account_code') HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'ACCOUNT_TEMPLATE_DUPLICATE_CODE';
  END IF;
  IF (
    SELECT count(*) FROM jsonb_array_elements(p_account_templates) item(value)
    WHERE value->>'account_type' = 'brand_manager'
  ) NOT IN (0, p_brand_manager_slots) THEN
    RAISE EXCEPTION 'BRAND_MANAGER_TEMPLATE_COUNT_INVALID';
  END IF;
  IF v_existing_short_code IS NOT NULL
     AND v_existing_short_code <> upper(btrim(p_short_code))
     AND (
       EXISTS (SELECT 1 FROM public.store_employees WHERE store_id = p_store_id)
       OR EXISTS (
         SELECT 1 FROM public.store_fixed_account_requirements
         WHERE store_id = p_store_id AND provisioned_user_id IS NOT NULL
       )
     ) THEN
    RAISE EXCEPTION 'STORE_SHORT_CODE_IMMUTABLE_AFTER_USE';
  END IF;

  UPDATE public.restaurants SET short_code = upper(btrim(p_short_code))
  WHERE id = p_store_id;
  UPDATE public.brands SET
    management_model = p_management_model,
    brand_manager_slots = p_brand_manager_slots
  WHERE id = v_brand_id;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_account_templates) LOOP
    IF COALESCE(v_item->>'account_code', '') !~ '^[a-z][a-z0-9_]{1,31}$'
       OR COALESCE(v_item->>'scope', '') NOT IN ('brand', 'store')
       OR COALESCE(v_item->>'account_type', '') NOT IN (
         'brand_manager', 'store_manager', 'device_pos', 'device_tablet',
         'device_kitchen', 'device_print_station', 'device_customer_display',
         'device_emergency_station', 'store_operator'
       )
       OR COALESCE(v_item->>'role', '') NOT IN (
         'brand_admin', 'store_admin', 'cashier', 'kitchen', 'print_station',
         'customer_display', 'emergency_station', 'photo_objet_master',
         'photo_objet_store_operator'
       )
       OR NULLIF(btrim(COALESCE(v_item->>'display_name', '')), '') IS NULL THEN
      RAISE EXCEPTION 'ACCOUNT_TEMPLATE_INVALID';
    END IF;
    IF (v_item->>'account_type') = 'brand_manager'
       AND v_actor.role <> 'super_admin' THEN
      RAISE EXCEPTION 'BRAND_MANAGER_TEMPLATE_FORBIDDEN';
    END IF;
    IF (v_item->>'account_type') = 'store_manager'
       AND v_actor.role NOT IN ('super_admin', 'brand_admin') THEN
      RAISE EXCEPTION 'STORE_MANAGER_TEMPLATE_FORBIDDEN';
    END IF;
    IF p_management_model = 'brand_centralized'
       AND (v_item->>'account_type') = 'store_manager' THEN
      RAISE EXCEPTION 'CENTRALIZED_STORE_MANAGER_FORBIDDEN';
    END IF;
    IF (v_item->>'account_type') IN (
      'device_pos', 'device_tablet', 'device_kitchen',
      'device_print_station', 'device_customer_display',
      'device_emergency_station', 'store_operator'
    ) AND (v_item->>'account_code') NOT LIKE
      lower(upper(btrim(p_short_code))) || '\_%' ESCAPE '\' THEN
      RAISE EXCEPTION 'STORE_ACCOUNT_CODE_PREFIX_INVALID';
    END IF;
    INSERT INTO public.store_fixed_account_requirements(
      store_id, account_code, account_type, role, display_name, scope
    ) VALUES (
      p_store_id, v_item->>'account_code', v_item->>'account_type',
      v_item->>'role', btrim(v_item->>'display_name'), v_item->>'scope'
    ) ON CONFLICT (store_id, account_code) DO UPDATE SET
      account_type = EXCLUDED.account_type,
      role = EXCLUDED.role,
      display_name = EXCLUDED.display_name,
      scope = EXCLUDED.scope,
      is_active = true,
      updated_at = now();
    v_count := v_count + 1;
  END LOOP;
  UPDATE public.store_fixed_account_requirements q SET
    is_active = false,
    updated_at = now()
  WHERE q.store_id = p_store_id
    AND q.provisioned_user_id IS NULL
    AND q.is_active = true
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_account_templates) item(value)
      WHERE lower(value->>'account_code') = lower(q.account_code)
    );
  RETURN jsonb_build_object(
    'configured', true,
    'store_id', p_store_id,
    'short_code', upper(btrim(p_short_code)),
    'management_model', p_management_model,
    'template_count', v_count
  );
END;
$$;

CREATE TABLE public.emergency_fulfillment_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'closed')),
  reason text NOT NULL,
  activated_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  activated_at timestamptz NOT NULL DEFAULT now(),
  closed_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  closed_at timestamptz,
  close_reason text,
  close_resolution text
    CHECK (close_resolution IS NULL OR close_resolution IN (
      'digital_completed', 'reprint', 'dismiss'
    )),
  force_closed boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT emergency_session_reason_present CHECK (btrim(reason) <> ''),
  CONSTRAINT emergency_session_closed_state CHECK (
    (status = 'active' AND closed_at IS NULL AND closed_by IS NULL)
    OR (status = 'closed' AND closed_at IS NOT NULL AND closed_by IS NOT NULL
        AND close_resolution IS NOT NULL)
  )
);

CREATE UNIQUE INDEX emergency_one_active_session_per_store
  ON public.emergency_fulfillment_sessions (restaurant_id)
  WHERE status = 'active';

CREATE TABLE public.emergency_station_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  station_type text NOT NULL CHECK (station_type IN ('kitchen', 'tray', 'floor')),
  floor_label text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT emergency_station_floor_contract CHECK (
    (station_type = 'floor' AND floor_label IN ('1F', '2F'))
    OR (station_type <> 'floor' AND floor_label IS NULL)
  ),
  UNIQUE (restaurant_id, user_id)
);

CREATE TABLE public.emergency_order_queue (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES public.emergency_fulfillment_sessions(id)
    ON DELETE CASCADE,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  queue_no integer NOT NULL CHECK (queue_no > 0),
  table_number text NOT NULL,
  floor_label text NOT NULL CHECK (floor_label IN ('1F', '2F')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (session_id, order_id),
  UNIQUE (session_id, queue_no)
);

CREATE TABLE public.emergency_fulfillment_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES public.emergency_fulfillment_sessions(id)
    ON DELETE CASCADE,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  queue_id uuid NOT NULL REFERENCES public.emergency_order_queue(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  order_item_id uuid NOT NULL REFERENCES public.order_items(id) ON DELETE CASCADE,
  source_quantity integer NOT NULL CHECK (source_quantity > 0),
  ordered_quantity integer NOT NULL CHECK (ordered_quantity > 0),
  kitchen_done_quantity integer NOT NULL DEFAULT 0,
  tray_received_quantity integer NOT NULL DEFAULT 0,
  tray_dispatched_quantity integer NOT NULL DEFAULT 0,
  floor_served_quantity integer NOT NULL DEFAULT 0,
  is_cancelled boolean NOT NULL DEFAULT false,
  needs_review boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (session_id, order_item_id),
  CONSTRAINT emergency_fulfillment_quantity_chain CHECK (
    floor_served_quantity >= 0
    AND floor_served_quantity <= tray_dispatched_quantity
    AND tray_dispatched_quantity <= tray_received_quantity
    AND tray_received_quantity <= kitchen_done_quantity
    AND kitchen_done_quantity <= ordered_quantity
  )
);

CREATE TABLE public.emergency_fulfillment_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL UNIQUE,
  session_id uuid NOT NULL REFERENCES public.emergency_fulfillment_sessions(id)
    ON DELETE CASCADE,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  order_item_id uuid REFERENCES public.order_items(id) ON DELETE SET NULL,
  stage text NOT NULL CHECK (stage IN (
    'order_received', 'kitchen_done', 'tray_received',
    'tray_dispatched', 'floor_served'
  )),
  delta integer NOT NULL CHECK (delta <> 0),
  actor_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.emergency_web_push_devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  station_assignment_id uuid NOT NULL
    REFERENCES public.emergency_station_assignments(id) ON DELETE CASCADE,
  token text NOT NULL UNIQUE,
  browser_label text,
  is_enabled boolean NOT NULL DEFAULT true,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT emergency_push_token_present CHECK (length(btrim(token)) >= 16)
);

CREATE TABLE public.emergency_push_deliveries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.emergency_fulfillment_events(event_id)
    ON DELETE CASCADE,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  device_id uuid NOT NULL REFERENCES public.emergency_web_push_devices(id)
    ON DELETE CASCADE,
  push_token text NOT NULL,
  station_type text NOT NULL CHECK (station_type IN ('kitchen', 'tray', 'floor')),
  floor_label text,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  stage text NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'sending', 'sent', 'failed', 'cancelled')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  provider_message_id text,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (event_id, device_id)
);

CREATE INDEX emergency_queue_store_session
  ON public.emergency_order_queue (restaurant_id, session_id, queue_no);
CREATE INDEX emergency_items_order
  ON public.emergency_fulfillment_items (session_id, order_id);
CREATE INDEX emergency_push_pending
  ON public.emergency_push_deliveries (status, next_attempt_at)
  WHERE status IN ('pending', 'failed');

ALTER TABLE public.print_jobs
  ADD COLUMN IF NOT EXISTS emergency_session_id uuid
    REFERENCES public.emergency_fulfillment_sessions(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS emergency_held_at timestamptz,
  ADD COLUMN IF NOT EXISTS emergency_resolution text
    CHECK (emergency_resolution IS NULL OR emergency_resolution IN (
      'digital_completed', 'reprint', 'dismiss'
    ));

CREATE OR REPLACE FUNCTION public.emergency_floor_label(
  p_store_id uuid,
  p_floor_label text,
  p_table_number text
) RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    -- BunsikClub Binh Thanh has two service floors and no G floor. Its legacy
    -- storage labels are retained to avoid breaking printer/table history.
    WHEN p_store_id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid THEN
      CASE
        WHEN COALESCE(p_table_number, '') ~ '^2'
          OR upper(COALESCE(p_floor_label, '')) = '3F' THEN '2F'
        ELSE '1F'
      END
    WHEN upper(COALESCE(p_floor_label, '')) IN ('2F', '3F') THEN '2F'
    ELSE '1F'
  END;
$$;

CREATE OR REPLACE FUNCTION public.emergency_enqueue_push(
  p_event_id uuid,
  p_store_id uuid,
  p_order_id uuid,
  p_target_station text,
  p_floor_label text,
  p_stage text
) RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
  INSERT INTO public.emergency_push_deliveries (
    event_id, restaurant_id, device_id, push_token, station_type,
    floor_label, order_id, stage
  )
  SELECT
    p_event_id, p_store_id, device.id, device.token,
    assignment.station_type, assignment.floor_label, p_order_id, p_stage
  FROM public.emergency_web_push_devices device
  JOIN public.emergency_station_assignments assignment
    ON assignment.id = device.station_assignment_id
   AND assignment.restaurant_id = p_store_id
   AND assignment.is_active = true
  WHERE device.restaurant_id = p_store_id
    AND device.is_enabled = true
    AND assignment.station_type = p_target_station
    AND (p_target_station <> 'floor' OR assignment.floor_label = p_floor_label)
  ON CONFLICT (event_id, device_id) DO NOTHING;
$$;

CREATE OR REPLACE FUNCTION public.emergency_sync_order_item()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_session public.emergency_fulfillment_sessions%ROWTYPE;
  v_queue public.emergency_order_queue%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_table record;
  v_existing public.emergency_fulfillment_items%ROWTYPE;
  v_queue_created boolean := false;
  v_event_id uuid;
BEGIN
  SELECT * INTO v_session
  FROM public.emergency_fulfillment_sessions
  WHERE restaurant_id = NEW.restaurant_id AND status = 'active'
  FOR UPDATE;
  IF NOT FOUND THEN RETURN NEW; END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = NEW.order_id;
  IF NOT FOUND OR v_order.status IN ('completed', 'cancelled') THEN
    RETURN NEW;
  END IF;

  IF COALESCE(NEW.is_service_item, false)
     OR NEW.item_type IN ('wet_tissue_charge', 'buffet_cover_charge') THEN
    RETURN NEW;
  END IF;

  SELECT table_number, floor_label INTO v_table
  FROM public.tables WHERE id = v_order.table_id;

  SELECT * INTO v_queue
  FROM public.emergency_order_queue
  WHERE session_id = v_session.id AND order_id = NEW.order_id;

  IF NOT FOUND THEN
    INSERT INTO public.emergency_order_queue (
      session_id, restaurant_id, order_id, queue_no, table_number, floor_label
    ) VALUES (
      v_session.id,
      NEW.restaurant_id,
      NEW.order_id,
      COALESCE((SELECT max(queue_no) + 1
        FROM public.emergency_order_queue WHERE session_id = v_session.id), 1),
      COALESCE(v_table.table_number, 'STAFF'),
      public.emergency_floor_label(
        NEW.restaurant_id, v_table.floor_label, v_table.table_number
      )
    ) RETURNING * INTO v_queue;
    v_queue_created := true;
  END IF;

  SELECT * INTO v_existing
  FROM public.emergency_fulfillment_items
  WHERE session_id = v_session.id AND order_item_id = NEW.id
  FOR UPDATE;

  IF FOUND THEN
    UPDATE public.emergency_fulfillment_items
    SET source_quantity = NEW.quantity,
        ordered_quantity = greatest(
          NEW.quantity,
          kitchen_done_quantity,
          tray_received_quantity,
          tray_dispatched_quantity,
          floor_served_quantity
        ),
        is_cancelled = NEW.status = 'cancelled',
        needs_review = NEW.quantity < greatest(
          kitchen_done_quantity,
          tray_received_quantity,
          tray_dispatched_quantity,
          floor_served_quantity
        ),
        updated_at = now()
    WHERE id = v_existing.id;
  ELSE
    INSERT INTO public.emergency_fulfillment_items (
      session_id, restaurant_id, queue_id, order_id, order_item_id,
      source_quantity, ordered_quantity, is_cancelled
    ) VALUES (
      v_session.id, NEW.restaurant_id, v_queue.id, NEW.order_id, NEW.id,
      NEW.quantity, NEW.quantity, NEW.status = 'cancelled'
    );
  END IF;

  IF v_queue_created THEN
    v_event_id := gen_random_uuid();
    INSERT INTO public.emergency_fulfillment_events (
      event_id, session_id, restaurant_id, order_id, stage, delta, details
    ) VALUES (
      v_event_id, v_session.id, NEW.restaurant_id, NEW.order_id,
      'order_received', 1, jsonb_build_object('queue_no', v_queue.queue_no)
    );
    PERFORM public.emergency_enqueue_push(
      v_event_id, NEW.restaurant_id, NEW.order_id,
      'kitchen', v_queue.floor_label, 'order_received'
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS emergency_sync_order_item_trigger ON public.order_items;
CREATE TRIGGER emergency_sync_order_item_trigger
AFTER INSERT OR UPDATE OF quantity, status ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.emergency_sync_order_item();

CREATE OR REPLACE FUNCTION public.emergency_hold_print_job()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_session_id uuid;
BEGIN
  IF NEW.copy_type = 'receipt' THEN RETURN NEW; END IF;
  SELECT id INTO v_session_id
  FROM public.emergency_fulfillment_sessions
  WHERE restaurant_id = NEW.restaurant_id AND status = 'active';
  IF v_session_id IS NOT NULL THEN
    NEW.emergency_session_id := v_session_id;
    NEW.emergency_held_at := now();
    NEW.emergency_resolution := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS emergency_hold_print_job_trigger ON public.print_jobs;
CREATE TRIGGER emergency_hold_print_job_trigger
BEFORE INSERT ON public.print_jobs
FOR EACH ROW EXECUTE FUNCTION public.emergency_hold_print_job();

CREATE OR REPLACE FUNCTION public.sync_emergency_station_assignment_for_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_station text;
  v_floor text;
BEGIN
  IF NEW.fixed_account_code IS NULL OR NEW.restaurant_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.fixed_account_code ~ '_tray1$' THEN
    v_station := 'tray';
  ELSIF NEW.fixed_account_code ~ '_floor_1f$' THEN
    v_station := 'floor'; v_floor := '1F';
  ELSIF NEW.fixed_account_code ~ '_floor_2f$' THEN
    v_station := 'floor'; v_floor := '2F';
  ELSIF NEW.fixed_account_code ~ '_kit1$' THEN
    v_station := 'kitchen';
  ELSE
    RETURN NEW;
  END IF;

  INSERT INTO public.emergency_station_assignments (
    restaurant_id, user_id, station_type, floor_label, is_active
  ) VALUES (
    NEW.restaurant_id, NEW.id, v_station, v_floor, NEW.is_active
  ) ON CONFLICT (restaurant_id, user_id) DO UPDATE SET
    station_type = EXCLUDED.station_type,
    floor_label = EXCLUDED.floor_label,
    is_active = EXCLUDED.is_active,
    updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_emergency_station_assignment_user_trigger
  ON public.users;
CREATE TRIGGER sync_emergency_station_assignment_user_trigger
AFTER INSERT OR UPDATE OF fixed_account_code, restaurant_id, is_active
ON public.users
FOR EACH ROW EXECUTE FUNCTION public.sync_emergency_station_assignment_for_user();

CREATE OR REPLACE FUNCTION public.super_admin_set_emergency_mode(
  p_store_id uuid,
  p_enabled boolean,
  p_reason text,
  p_resolution text DEFAULT 'digital_completed',
  p_force boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_session public.emergency_fulfillment_sessions%ROWTYPE;
  v_unresolved integer := 0;
BEGIN
  SELECT * INTO v_actor FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'EMERGENCY_MODE_SUPER_ADMIN_REQUIRED';
  END IF;
  IF p_store_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.restaurants WHERE id = p_store_id AND is_active = true
  ) THEN RAISE EXCEPTION 'EMERGENCY_STORE_UNAVAILABLE'; END IF;
  IF NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'EMERGENCY_REASON_REQUIRED';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_store_id::text));
  SELECT * INTO v_session
  FROM public.emergency_fulfillment_sessions
  WHERE restaurant_id = p_store_id AND status = 'active'
  FOR UPDATE;

  IF p_enabled THEN
    IF FOUND THEN
      RETURN jsonb_build_object('active', true, 'session_id', v_session.id,
        'already_active', true);
    END IF;

    INSERT INTO public.emergency_fulfillment_sessions (
      restaurant_id, reason, activated_by
    ) VALUES (p_store_id, btrim(p_reason), v_actor.id)
    RETURNING * INTO v_session;

    INSERT INTO public.emergency_order_queue (
      session_id, restaurant_id, order_id, queue_no, table_number, floor_label
    )
    SELECT
      v_session.id, order_row.restaurant_id, order_row.id,
      row_number() OVER (ORDER BY order_row.created_at, order_row.id)::integer,
      COALESCE(table_row.table_number, 'STAFF'),
      public.emergency_floor_label(
        p_store_id, table_row.floor_label, table_row.table_number
      )
    FROM public.orders order_row
    LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
    WHERE order_row.restaurant_id = p_store_id
      AND order_row.status IN ('pending', 'confirmed', 'serving')
      AND EXISTS (
        SELECT 1 FROM public.order_items candidate
        WHERE candidate.order_id = order_row.id
          AND candidate.status <> 'cancelled'
          AND NOT COALESCE(candidate.is_service_item, false)
          AND candidate.item_type NOT IN (
            'wet_tissue_charge', 'buffet_cover_charge'
          )
      );

    INSERT INTO public.emergency_fulfillment_items (
      session_id, restaurant_id, queue_id, order_id, order_item_id,
      source_quantity, ordered_quantity
    )
    SELECT
      v_session.id, item.restaurant_id, queue.id, item.order_id, item.id,
      item.quantity, item.quantity
    FROM public.order_items item
    JOIN public.emergency_order_queue queue
      ON queue.session_id = v_session.id AND queue.order_id = item.order_id
    WHERE item.restaurant_id = p_store_id
      AND item.status <> 'cancelled'
      AND NOT COALESCE(item.is_service_item, false)
      AND item.item_type NOT IN ('wet_tissue_charge', 'buffet_cover_charge');

    WITH received AS (
      INSERT INTO public.emergency_fulfillment_events (
        event_id, session_id, restaurant_id, order_id, stage, delta, details
      )
      SELECT gen_random_uuid(), v_session.id, p_store_id, queue.order_id,
        'order_received', 1, jsonb_build_object('queue_no', queue.queue_no)
      FROM public.emergency_order_queue queue
      WHERE queue.session_id = v_session.id
      RETURNING event_id, order_id
    )
    INSERT INTO public.emergency_push_deliveries (
      event_id, restaurant_id, device_id, push_token, station_type,
      floor_label, order_id, stage
    )
    SELECT received.event_id, p_store_id, device.id, device.token,
      assignment.station_type, assignment.floor_label, received.order_id,
      'order_received'
    FROM received
    JOIN public.emergency_web_push_devices device
      ON device.restaurant_id = p_store_id AND device.is_enabled = true
    JOIN public.emergency_station_assignments assignment
      ON assignment.id = device.station_assignment_id
     AND assignment.station_type = 'kitchen' AND assignment.is_active = true
    ON CONFLICT (event_id, device_id) DO NOTHING;

    UPDATE public.print_jobs
    SET emergency_session_id = v_session.id,
        emergency_held_at = now(),
        emergency_resolution = NULL,
        updated_at = now()
    WHERE restaurant_id = p_store_id
      AND copy_type <> 'receipt'
      AND status IN ('pending', 'failed')
      AND emergency_held_at IS NULL;

    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (auth.uid(), 'emergency_mode_activated', 'restaurants', p_store_id,
      jsonb_build_object('session_id', v_session.id, 'reason', btrim(p_reason)));
    RETURN jsonb_build_object('active', true, 'session_id', v_session.id,
      'already_active', false);
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('active', false, 'already_closed', true);
  END IF;
  IF p_resolution NOT IN ('digital_completed', 'reprint', 'dismiss') THEN
    RAISE EXCEPTION 'EMERGENCY_CLOSE_RESOLUTION_INVALID';
  END IF;

  SELECT COALESCE(sum(ordered_quantity - floor_served_quantity), 0)::integer
  INTO v_unresolved
  FROM public.emergency_fulfillment_items
  WHERE session_id = v_session.id AND is_cancelled = false;

  IF v_unresolved > 0 AND NOT COALESCE(p_force, false) THEN
    RAISE EXCEPTION 'EMERGENCY_UNRESOLVED_ITEMS:%', v_unresolved;
  END IF;
  IF v_unresolved > 0 AND p_resolution = 'digital_completed' THEN
    RAISE EXCEPTION 'EMERGENCY_UNRESOLVED_RESOLUTION_REQUIRED';
  END IF;

  UPDATE public.emergency_fulfillment_sessions
  SET status = 'closed', closed_by = v_actor.id, closed_at = now(),
      close_reason = btrim(p_reason), close_resolution = p_resolution,
      force_closed = COALESCE(p_force, false), updated_at = now()
  WHERE id = v_session.id;

  IF p_resolution = 'reprint' THEN
    UPDATE public.print_jobs
    SET emergency_held_at = NULL, emergency_resolution = 'reprint',
        status = CASE WHEN destination_id IS NULL THEN 'failed' ELSE 'pending' END,
        last_error = CASE WHEN destination_id IS NULL THEN 'NO_DESTINATION' ELSE NULL END,
        next_retry_at = now(), updated_at = now()
    WHERE emergency_session_id = v_session.id
      AND status IN ('pending', 'failed');
  ELSE
    UPDATE public.print_jobs
    SET status = 'cancelled', emergency_resolution = p_resolution,
        last_error = CASE p_resolution
          WHEN 'dismiss' THEN 'EMERGENCY_DISMISSED'
          ELSE 'EMERGENCY_DIGITAL_COMPLETED' END,
        updated_at = now()
    WHERE emergency_session_id = v_session.id
      AND status IN ('pending', 'failed');
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (auth.uid(), 'emergency_mode_closed', 'restaurants', p_store_id,
    jsonb_build_object('session_id', v_session.id, 'reason', btrim(p_reason),
      'resolution', p_resolution, 'force', COALESCE(p_force, false),
      'unresolved_quantity', v_unresolved));
  RETURN jsonb_build_object('active', false, 'session_id', v_session.id,
    'unresolved_quantity', v_unresolved, 'resolution', p_resolution);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_emergency_station_snapshot()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_session public.emergency_fulfillment_sessions%ROWTYPE;
  v_orders jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_user FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;

  SELECT * INTO v_assignment
  FROM public.emergency_station_assignments
  WHERE user_id = v_user.id AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('assigned', false, 'active', false,
      'restaurant_id', v_user.restaurant_id, 'orders', '[]'::jsonb);
  END IF;

  SELECT * INTO v_session
  FROM public.emergency_fulfillment_sessions
  WHERE restaurant_id = v_assignment.restaurant_id AND status = 'active';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('assigned', true, 'active', false,
      'restaurant_id', v_assignment.restaurant_id,
      'station_type', v_assignment.station_type,
      'floor_label', v_assignment.floor_label, 'orders', '[]'::jsonb);
  END IF;

  SELECT COALESCE(jsonb_agg(order_payload ORDER BY queue_no), '[]'::jsonb)
  INTO v_orders
  FROM (
    SELECT queue.queue_no,
      jsonb_build_object(
        'queue_id', queue.id,
        'order_id', queue.order_id,
        'queue_no', queue.queue_no,
        'table_number', queue.table_number,
        'floor_label', queue.floor_label,
        'created_at', queue.created_at,
        'items', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'id', fulfillment.id,
            'order_item_id', fulfillment.order_item_id,
            'name_ko', COALESCE(NULLIF(item.label, ''), NULLIF(item.display_name, ''), menu.name, '메뉴'),
            'name_vi', COALESCE(menu.name_vi, 'Món'),
            'name_en', COALESCE(menu.name_en, 'Item'),
            'ordered_quantity', fulfillment.ordered_quantity,
            'kitchen_done_quantity', fulfillment.kitchen_done_quantity,
            'tray_received_quantity', fulfillment.tray_received_quantity,
            'tray_dispatched_quantity', fulfillment.tray_dispatched_quantity,
            'floor_served_quantity', fulfillment.floor_served_quantity,
            'needs_review', fulfillment.needs_review
          ) ORDER BY item.created_at, item.id)
          FROM public.emergency_fulfillment_items fulfillment
          JOIN public.order_items item ON item.id = fulfillment.order_item_id
          LEFT JOIN public.menu_items menu ON menu.id = item.menu_item_id
          WHERE fulfillment.queue_id = queue.id
            AND fulfillment.is_cancelled = false
        ), '[]'::jsonb)
      ) AS order_payload
    FROM public.emergency_order_queue queue
    WHERE queue.session_id = v_session.id
      AND (v_assignment.station_type <> 'floor'
        OR queue.floor_label = v_assignment.floor_label)
  ) rows;

  RETURN jsonb_build_object(
    'assigned', true, 'active', true,
    'session_id', v_session.id,
    'restaurant_id', v_assignment.restaurant_id,
    'station_type', v_assignment.station_type,
    'floor_label', v_assignment.floor_label,
    'activated_at', v_session.activated_at,
    'orders', v_orders
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.emergency_record_progress(
  p_fulfillment_item_id uuid,
  p_stage text,
  p_delta integer,
  p_event_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_item public.emergency_fulfillment_items%ROWTYPE;
  v_queue public.emergency_order_queue%ROWTYPE;
  v_existing_event public.emergency_fulfillment_events%ROWTYPE;
  v_kitchen integer;
  v_received integer;
  v_dispatched integer;
  v_served integer;
  v_target text;
BEGIN
  IF p_event_id IS NULL OR p_delta NOT IN (-1, 1) THEN
    RAISE EXCEPTION 'EMERGENCY_PROGRESS_INPUT_INVALID';
  END IF;
  SELECT * INTO v_user FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;
  SELECT * INTO v_assignment FROM public.emergency_station_assignments
  WHERE user_id = v_user.id AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_STATION_REQUIRED'; END IF;

  SELECT * INTO v_existing_event FROM public.emergency_fulfillment_events
  WHERE event_id = p_event_id;
  IF FOUND THEN
    RETURN jsonb_build_object('event_id', p_event_id, 'deduplicated', true);
  END IF;

  SELECT * INTO v_item FROM public.emergency_fulfillment_items
  WHERE id = p_fulfillment_item_id FOR UPDATE;
  IF NOT FOUND OR v_item.restaurant_id <> v_assignment.restaurant_id
     OR v_item.is_cancelled THEN
    RAISE EXCEPTION 'EMERGENCY_ITEM_UNAVAILABLE';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.emergency_fulfillment_sessions
    WHERE id = v_item.session_id AND status = 'active') THEN
    RAISE EXCEPTION 'EMERGENCY_SESSION_NOT_ACTIVE';
  END IF;
  SELECT * INTO v_queue FROM public.emergency_order_queue WHERE id = v_item.queue_id;

  IF (p_stage = 'kitchen_done' AND v_assignment.station_type <> 'kitchen')
     OR (p_stage IN ('tray_received', 'tray_dispatched')
       AND v_assignment.station_type <> 'tray')
     OR (p_stage = 'floor_served' AND (
       v_assignment.station_type <> 'floor'
       OR v_assignment.floor_label <> v_queue.floor_label))
     OR p_stage NOT IN (
       'kitchen_done', 'tray_received', 'tray_dispatched', 'floor_served'
     ) THEN RAISE EXCEPTION 'EMERGENCY_STAGE_FORBIDDEN'; END IF;

  v_kitchen := v_item.kitchen_done_quantity
    + CASE WHEN p_stage = 'kitchen_done' THEN p_delta ELSE 0 END;
  v_received := v_item.tray_received_quantity
    + CASE WHEN p_stage = 'tray_received' THEN p_delta ELSE 0 END;
  v_dispatched := v_item.tray_dispatched_quantity
    + CASE WHEN p_stage = 'tray_dispatched' THEN p_delta ELSE 0 END;
  v_served := v_item.floor_served_quantity
    + CASE WHEN p_stage = 'floor_served' THEN p_delta ELSE 0 END;
  IF v_served < 0 OR v_served > v_dispatched
     OR v_dispatched < v_served OR v_dispatched > v_received
     OR v_received < v_dispatched OR v_received > v_kitchen
     OR v_kitchen < v_received OR v_kitchen > v_item.ordered_quantity THEN
    RAISE EXCEPTION 'EMERGENCY_QUANTITY_CHAIN_VIOLATION';
  END IF;

  UPDATE public.emergency_fulfillment_items
  SET kitchen_done_quantity = v_kitchen,
      tray_received_quantity = v_received,
      tray_dispatched_quantity = v_dispatched,
      floor_served_quantity = v_served,
      updated_at = now()
  WHERE id = v_item.id;
  INSERT INTO public.emergency_fulfillment_events (
    event_id, session_id, restaurant_id, order_id, order_item_id,
    stage, delta, actor_user_id
  ) VALUES (
    p_event_id, v_item.session_id, v_item.restaurant_id, v_item.order_id,
    v_item.order_item_id, p_stage, p_delta, v_user.id
  );

  IF p_delta > 0 AND p_stage = 'kitchen_done' THEN v_target := 'tray'; END IF;
  IF p_delta > 0 AND p_stage = 'tray_dispatched' THEN v_target := 'floor'; END IF;
  IF v_target IS NOT NULL THEN
    PERFORM public.emergency_enqueue_push(
      p_event_id, v_item.restaurant_id, v_item.order_id,
      v_target, v_queue.floor_label, p_stage
    );
  END IF;
  RETURN jsonb_build_object('event_id', p_event_id, 'deduplicated', false,
    'kitchen_done_quantity', v_kitchen,
    'tray_received_quantity', v_received,
    'tray_dispatched_quantity', v_dispatched,
    'floor_served_quantity', v_served);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_emergency_order_summaries(
  p_order_ids uuid[]
) RETURNS TABLE (order_id uuid, emergency_active boolean, unserved_quantity integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
  IF p_order_ids IS NULL OR cardinality(p_order_ids) = 0 THEN RETURN; END IF;
  RETURN QUERY
  SELECT item.order_id, true,
    COALESCE(sum(item.ordered_quantity - item.floor_served_quantity), 0)::integer
  FROM public.emergency_fulfillment_items item
  JOIN public.emergency_fulfillment_sessions session ON session.id = item.session_id
  WHERE item.order_id = ANY(p_order_ids)
    AND session.status = 'active' AND item.is_cancelled = false
    AND (public.is_super_admin() OR EXISTS (
      SELECT 1 FROM public.user_accessible_stores(auth.uid()) scope(store_id)
      WHERE scope.store_id = item.restaurant_id
    ))
  GROUP BY item.order_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.super_admin_get_emergency_store_statuses()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'EMERGENCY_MODE_SUPER_ADMIN_REQUIRED';
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'restaurant_id', restaurant.id,
      'restaurant_name', restaurant.name,
      'active', session.id IS NOT NULL,
      'session_id', session.id,
      'activated_at', session.activated_at,
      'reason', session.reason,
      'unresolved_quantity', COALESCE(summary.unresolved_quantity, 0),
      'order_count', COALESCE(summary.order_count, 0)
    ) ORDER BY restaurant.name)
    FROM public.restaurants restaurant
    LEFT JOIN public.emergency_fulfillment_sessions session
      ON session.restaurant_id = restaurant.id AND session.status = 'active'
    LEFT JOIN LATERAL (
      SELECT
        COALESCE(sum(item.ordered_quantity - item.floor_served_quantity), 0)::integer
          AS unresolved_quantity,
        count(DISTINCT item.order_id)::integer AS order_count
      FROM public.emergency_fulfillment_items item
      WHERE item.session_id = session.id AND item.is_cancelled = false
    ) summary ON true
    WHERE restaurant.is_active = true
  ), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION public.register_emergency_web_push_device(
  p_token text,
  p_browser_label text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_id uuid;
BEGIN
  SELECT * INTO v_user FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  SELECT * INTO v_assignment FROM public.emergency_station_assignments
  WHERE user_id = v_user.id AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_STATION_REQUIRED'; END IF;
  IF length(btrim(COALESCE(p_token, ''))) < 16 THEN
    RAISE EXCEPTION 'EMERGENCY_PUSH_TOKEN_INVALID';
  END IF;
  INSERT INTO public.emergency_web_push_devices (
    restaurant_id, user_id, station_assignment_id, token, browser_label
  ) VALUES (
    v_assignment.restaurant_id, v_user.id, v_assignment.id,
    btrim(p_token), NULLIF(btrim(COALESCE(p_browser_label, '')), '')
  ) ON CONFLICT (token) DO UPDATE SET
    restaurant_id = EXCLUDED.restaurant_id,
    user_id = EXCLUDED.user_id,
    station_assignment_id = EXCLUDED.station_assignment_id,
    browser_label = EXCLUDED.browser_label,
    is_enabled = true, last_seen_at = now(), updated_at = now()
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_emergency_push_deliveries(
  p_limit integer DEFAULT 100
) RETURNS SETOF public.emergency_push_deliveries
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'EMERGENCY_PUSH_SERVICE_REQUIRED';
  END IF;
  RETURN QUERY
  WITH candidate AS (
    SELECT id FROM public.emergency_push_deliveries
    WHERE status IN ('pending', 'failed') AND next_attempt_at <= now()
      AND attempt_count < 10
    ORDER BY created_at, id
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500)
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.emergency_push_deliveries delivery
  SET status = 'sending', attempt_count = attempt_count + 1, updated_at = now()
  FROM candidate WHERE delivery.id = candidate.id
  RETURNING delivery.*;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_emergency_push_delivery(
  p_delivery_id uuid,
  p_accepted boolean,
  p_provider_message_id text DEFAULT NULL,
  p_error text DEFAULT NULL,
  p_retry_after_seconds integer DEFAULT 30
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'EMERGENCY_PUSH_SERVICE_REQUIRED';
  END IF;
  UPDATE public.emergency_push_deliveries
  SET status = CASE WHEN p_accepted THEN 'sent' ELSE 'failed' END,
      provider_message_id = p_provider_message_id,
      last_error = CASE WHEN p_accepted THEN NULL ELSE p_error END,
      next_attempt_at = CASE WHEN p_accepted THEN next_attempt_at
        ELSE now() + make_interval(secs => LEAST(
          GREATEST(COALESCE(p_retry_after_seconds, 30), 5), 3600
        )) END,
      updated_at = now()
  WHERE id = p_delivery_id;
END;
$$;

-- Replaces the only claim_print_jobs definition. Receipts remain claimable;
-- operational copies are held while a store emergency session is active.
CREATE OR REPLACE FUNCTION public.claim_print_jobs(
  p_store_id uuid,
  p_limit int DEFAULT 10
) RETURNS SETOF public.print_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50);
BEGIN
  IF NOT public.print_routing_actor_can_run(p_store_id) THEN
    RAISE EXCEPTION 'PRINT_CLAIM_FORBIDDEN';
  END IF;
  RETURN QUERY
  WITH candidates AS (
    SELECT id FROM public.print_jobs
    WHERE restaurant_id = p_store_id
      AND status IN ('pending', 'failed')
      AND destination_id IS NOT NULL
      AND next_retry_at <= now() AND attempts < 10
      AND emergency_held_at IS NULL
      AND (copy_type = 'receipt' OR NOT EXISTS (
        SELECT 1 FROM public.emergency_fulfillment_sessions session
        WHERE session.restaurant_id = p_store_id AND session.status = 'active'
      ))
    ORDER BY created_at, id
    LIMIT v_limit FOR UPDATE SKIP LOCKED
  )
  UPDATE public.print_jobs job
  SET status = 'printing', claimed_by = auth.uid(),
      attempts = attempts + 1, updated_at = now()
  FROM candidates WHERE job.id = candidates.id
  RETURNING job.*;
END;
$$;

ALTER TABLE public.emergency_fulfillment_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.emergency_station_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.emergency_order_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.emergency_fulfillment_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.emergency_fulfillment_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.emergency_web_push_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.emergency_push_deliveries ENABLE ROW LEVEL SECURITY;

CREATE POLICY emergency_sessions_store_read ON public.emergency_fulfillment_sessions
FOR SELECT TO authenticated USING (public.is_super_admin() OR EXISTS (
  SELECT 1 FROM public.user_accessible_stores(auth.uid()) scope(store_id)
  WHERE scope.store_id = restaurant_id
));
CREATE POLICY emergency_assignments_store_read ON public.emergency_station_assignments
FOR SELECT TO authenticated USING (public.is_super_admin() OR EXISTS (
  SELECT 1 FROM public.users actor
  WHERE actor.auth_id = auth.uid() AND actor.id = user_id
));
CREATE POLICY emergency_queue_store_read ON public.emergency_order_queue
FOR SELECT TO authenticated USING (public.is_super_admin() OR EXISTS (
  SELECT 1 FROM public.user_accessible_stores(auth.uid()) scope(store_id)
  WHERE scope.store_id = restaurant_id
));
CREATE POLICY emergency_items_store_read ON public.emergency_fulfillment_items
FOR SELECT TO authenticated USING (public.is_super_admin() OR EXISTS (
  SELECT 1 FROM public.user_accessible_stores(auth.uid()) scope(store_id)
  WHERE scope.store_id = restaurant_id
));
CREATE POLICY emergency_events_store_read ON public.emergency_fulfillment_events
FOR SELECT TO authenticated USING (public.is_super_admin() OR EXISTS (
  SELECT 1 FROM public.user_accessible_stores(auth.uid()) scope(store_id)
  WHERE scope.store_id = restaurant_id
));
CREATE POLICY emergency_devices_own_read ON public.emergency_web_push_devices
FOR SELECT TO authenticated USING (public.is_super_admin() OR EXISTS (
  SELECT 1 FROM public.users actor
  WHERE actor.auth_id = auth.uid() AND actor.id = user_id
));

REVOKE ALL ON public.emergency_fulfillment_sessions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.emergency_station_assignments FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.emergency_order_queue FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.emergency_fulfillment_items FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.emergency_fulfillment_events FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.emergency_web_push_devices FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.emergency_push_deliveries FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.emergency_fulfillment_sessions,
  public.emergency_station_assignments, public.emergency_order_queue,
  public.emergency_fulfillment_items, public.emergency_fulfillment_events,
  public.emergency_web_push_devices TO authenticated;
GRANT ALL ON public.emergency_fulfillment_sessions,
  public.emergency_station_assignments, public.emergency_order_queue,
  public.emergency_fulfillment_items, public.emergency_fulfillment_events,
  public.emergency_web_push_devices, public.emergency_push_deliveries
  TO service_role;

REVOKE ALL ON FUNCTION public.super_admin_set_emergency_mode(uuid,boolean,text,text,boolean)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_emergency_station_snapshot() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.emergency_record_progress(uuid,text,integer,uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_emergency_order_summaries(uuid[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.super_admin_get_emergency_store_statuses()
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.register_emergency_web_push_device(text,text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.emergency_enqueue_push(uuid,uuid,uuid,text,text,text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.emergency_sync_order_item()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.emergency_hold_print_job()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sync_emergency_station_assignment_for_user()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_emergency_push_deliveries(integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_emergency_push_delivery(
  uuid,boolean,text,text,integer
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.super_admin_set_emergency_mode(uuid,boolean,text,text,boolean)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_snapshot() TO authenticated;
GRANT EXECUTE ON FUNCTION public.emergency_record_progress(uuid,text,integer,uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_emergency_order_summaries(uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.super_admin_get_emergency_store_statuses()
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.register_emergency_web_push_device(text,text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_emergency_push_deliveries(integer),
  public.complete_emergency_push_delivery(uuid,boolean,text,text,integer)
  TO service_role;

DO $emergency_push_schedule$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    PERFORM cron.unschedule(jobid)
    FROM cron.job
    WHERE jobname = 'emergency-fulfillment-dispatcher-every-minute';
    PERFORM cron.schedule(
      'emergency-fulfillment-dispatcher-every-minute',
      '* * * * *',
      $job$
      SELECT net.http_post(
        url := 'https://ynriuoomotxuwhuxxmhj.supabase.co/functions/v1/emergency-fulfillment-dispatcher',
        headers := jsonb_build_object(
          'Authorization', 'Bearer ' || (
            SELECT decrypted_secret
            FROM vault.decrypted_secrets
            WHERE name IN ('cron_secret', 'app.settings.cron_secret')
            ORDER BY (name = 'cron_secret') DESC
            LIMIT 1
          ),
          'Content-Type', 'application/json'
        ),
        body := '{}'::jsonb
      )
      $job$
    );
  END IF;
EXCEPTION
  WHEN invalid_schema_name OR undefined_function OR insufficient_privilege THEN
    RAISE NOTICE 'pg_cron/pg_net unavailable; skipped emergency push schedule.';
END
$emergency_push_schedule$;

DO $bunsik_binh_thanh$
DECLARE
  v_store_id constant uuid := '8bc9eef5-dcd5-46b1-b931-23f77132322c';
BEGIN
  IF EXISTS (SELECT 1 FROM public.restaurants WHERE id = v_store_id) THEN
    INSERT INTO public.store_fixed_account_requirements (
      store_id, account_code, account_type, role, display_name, scope, is_active
    ) VALUES
      (v_store_id, 'bt_tray1', 'device_emergency_station',
        'emergency_station', 'BT Emergency Tray', 'store', true),
      (v_store_id, 'bt_floor_1f', 'device_emergency_station',
        'emergency_station', 'BT Emergency Floor 1F', 'store', true),
      (v_store_id, 'bt_floor_2f', 'device_emergency_station',
        'emergency_station', 'BT Emergency Floor 2F', 'store', true)
    ON CONFLICT (store_id, account_code) DO UPDATE SET
      account_type = EXCLUDED.account_type,
      role = EXCLUDED.role,
      display_name = EXCLUDED.display_name,
      scope = EXCLUDED.scope,
      is_active = true,
      updated_at = now();

    INSERT INTO public.emergency_station_assignments (
      restaurant_id, user_id, station_type, floor_label, is_active
    )
    SELECT v_store_id, user_row.id, 'kitchen', NULL, user_row.is_active
    FROM public.users user_row
    WHERE user_row.restaurant_id = v_store_id
      AND user_row.fixed_account_code = 'bt_kit1'
    ON CONFLICT (restaurant_id, user_id) DO UPDATE SET
      station_type = 'kitchen', floor_label = NULL,
      is_active = EXCLUDED.is_active, updated_at = now();
  END IF;
END;
$bunsik_binh_thanh$;

DO $realtime$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
        AND tablename = 'emergency_order_queue') THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.emergency_order_queue;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
        AND tablename = 'emergency_fulfillment_items') THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.emergency_fulfillment_items;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
        AND tablename = 'emergency_fulfillment_sessions') THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.emergency_fulfillment_sessions;
    END IF;
  END IF;
END;
$realtime$;

DO $verify$
BEGIN
  IF EXISTS (SELECT 1 FROM public.emergency_station_assignments
    WHERE floor_label NOT IN ('1F', '2F')) THEN
    RAISE EXCEPTION 'EMERGENCY_G_FLOOR_FORBIDDEN';
  END IF;
  IF position('emergency_held_at IS NULL' IN pg_get_functiondef(
    'public.claim_print_jobs(uuid,integer)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'EMERGENCY_PRINT_HOLD_VERIFICATION_FAILED';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
    WHERE conname = 'emergency_fulfillment_quantity_chain') THEN
    RAISE EXCEPTION 'EMERGENCY_QUANTITY_CHAIN_VERIFICATION_FAILED';
  END IF;
END;
$verify$;

COMMIT;
