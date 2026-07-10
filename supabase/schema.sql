


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';


SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."order_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "order_id" "uuid" NOT NULL,
    "menu_item_id" "uuid",
    "item_type" "text" DEFAULT 'menu_item'::"text" NOT NULL,
    "label" "text",
    "unit_price" numeric(12,2) NOT NULL,
    "quantity" integer DEFAULT 1 NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "display_name" "text" NOT NULL,
    "vat_rate" numeric(5,2) DEFAULT 0 NOT NULL,
    "vat_amount" numeric(15,2) DEFAULT 0 NOT NULL,
    "total_amount_ex_tax" numeric(15,2) DEFAULT 0 NOT NULL,
    "paying_amount_inc_tax" numeric(15,2) DEFAULT 0 NOT NULL,
    CONSTRAINT "order_items_item_type_check" CHECK (("item_type" = ANY (ARRAY['menu_item'::"text", 'service_charge'::"text"]))),
    CONSTRAINT "order_items_item_type_menu_item_check" CHECK (((("item_type" = 'menu_item'::"text") AND ("menu_item_id" IS NOT NULL)) OR (("item_type" = 'service_charge'::"text") AND ("menu_item_id" IS NULL)))),
    CONSTRAINT "order_items_quantity_check" CHECK (("quantity" > 0)),
    CONSTRAINT "order_items_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'preparing'::"text", 'ready'::"text", 'served'::"text", 'cancelled'::"text"]))),
    CONSTRAINT "order_items_unit_price_check" CHECK (("unit_price" >= (0)::numeric))
);


ALTER TABLE "public"."order_items" OWNER TO "postgres";


COMMENT ON TABLE "public"."order_items" IS '주문 아이템 (가격 스냅샷)';



COMMENT ON COLUMN "public"."order_items"."item_type" IS 'menu_item = real menu line; service_charge = virtual line for brand service charge (Step 8). Migrated from standard/buffet_base/a_la_carte → menu_item.';



COMMENT ON COLUMN "public"."order_items"."display_name" IS 'Human-readable name snapshot at order creation. Backfilled from menu_items.name.';



COMMENT ON COLUMN "public"."order_items"."vat_rate" IS 'VAT rate snapshot at order creation (8.00 food, 10.00 alcohol). Immutable after completion (Invariant I11). 0 for pre-WeTax rows.';



COMMENT ON COLUMN "public"."order_items"."vat_amount" IS 'VAT amount = total_amount_ex_tax × vat_rate / 100. Immutable (I11).';



COMMENT ON COLUMN "public"."order_items"."total_amount_ex_tax" IS 'Pre-tax line subtotal. Immutable (I11).';



COMMENT ON COLUMN "public"."order_items"."paying_amount_inc_tax" IS 'Total incl. VAT. Immutable (I11).';



CREATE OR REPLACE FUNCTION "public"."add_items_to_order"("p_order_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb") RETURNS SETOF "public"."order_items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
  v_inserted_count int := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  SELECT *
  INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::int, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    LEFT JOIN menu_items m
      ON m.id = (item->>'menu_item_id')::uuid
     AND m.restaurant_id = p_store_id
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  RETURN QUERY
  INSERT INTO order_items (
    order_id, menu_item_id, quantity, unit_price,
    label, display_name, restaurant_id, item_type
  )
  SELECT
    p_order_id, m.id, (item->>'quantity')::int, m.price,
    m.name, m.name, p_store_id, 'menu_item'
  FROM jsonb_array_elements(p_items) item
  JOIN menu_items m
    ON m.id = (item->>'menu_item_id')::uuid
   AND m.restaurant_id = p_store_id
   AND m.is_available = TRUE
  RETURNING *;

  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

  UPDATE orders
  SET updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'add_items_to_order',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'added_item_count', v_inserted_count
    )
  );
END;
$$;


ALTER FUNCTION "public"."add_items_to_order"("p_order_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."menu_categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."menu_categories" OWNER TO "postgres";


COMMENT ON TABLE "public"."menu_categories" IS '메뉴 카테고리';



CREATE OR REPLACE FUNCTION "public"."admin_create_menu_category"("p_restaurant_id" "uuid", "p_name" "text", "p_sort_order" integer DEFAULT 0) RETURNS "public"."menu_categories"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_created public.menu_categories%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_restaurant_id);

  IF NULLIF(btrim(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NAME_REQUIRED';
  END IF;

  INSERT INTO public.menu_categories (
    restaurant_id,
    name,
    sort_order,
    is_active,
    created_at
  )
  VALUES (
    p_restaurant_id,
    btrim(p_name),
    COALESCE(p_sort_order, 0),
    TRUE,
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_create_menu_category',
    'menu_categories',
    v_created.id,
    jsonb_build_object(
      'restaurant_id', v_created.restaurant_id,
      'created_at_utc', now(),
      'new_values', jsonb_build_object(
        'name', v_created.name,
        'sort_order', v_created.sort_order,
        'is_active', v_created.is_active
      )
    )
  );

  RETURN v_created;
END;
$$;


ALTER FUNCTION "public"."admin_create_menu_category"("p_restaurant_id" "uuid", "p_name" "text", "p_sort_order" integer) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."menu_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "category_id" "uuid",
    "name" "text" NOT NULL,
    "description" "text",
    "price" numeric(12,2) NOT NULL,
    "is_available" boolean DEFAULT true NOT NULL,
    "is_visible_public" boolean DEFAULT false NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "vat_category" "text" DEFAULT 'food'::"text" NOT NULL,
    CONSTRAINT "menu_items_price_check" CHECK (("price" >= (0)::numeric)),
    CONSTRAINT "menu_items_vat_category_check" CHECK (("vat_category" = ANY (ARRAY['food'::"text", 'alcohol'::"text"])))
);


ALTER TABLE "public"."menu_items" OWNER TO "postgres";


COMMENT ON TABLE "public"."menu_items" IS '메뉴 아이템 (가격 포함)';



COMMENT ON COLUMN "public"."menu_items"."vat_category" IS 'VAT category. food=8%, alcohol=10%. Existing items defaulted to food — store owners must reclassify alcohol items manually.';



CREATE OR REPLACE FUNCTION "public"."admin_create_menu_item"("p_restaurant_id" "uuid", "p_category_id" "uuid", "p_name" "text", "p_price" numeric, "p_sort_order" integer DEFAULT 0, "p_description" "text" DEFAULT NULL::"text", "p_is_available" boolean DEFAULT true, "p_is_visible_public" boolean DEFAULT false) RETURNS "public"."menu_items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_created public.menu_items%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_restaurant_id);

  IF NULLIF(btrim(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_NAME_REQUIRED';
  END IF;

  IF p_category_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.menu_categories
    WHERE id = p_category_id
      AND restaurant_id = p_restaurant_id
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  INSERT INTO public.menu_items (
    restaurant_id,
    category_id,
    name,
    description,
    price,
    is_available,
    is_visible_public,
    sort_order,
    created_at,
    updated_at
  )
  VALUES (
    p_restaurant_id,
    p_category_id,
    btrim(p_name),
    NULLIF(btrim(COALESCE(p_description, '')), ''),
    p_price,
    COALESCE(p_is_available, TRUE),
    COALESCE(p_is_visible_public, FALSE),
    COALESCE(p_sort_order, 0),
    now(),
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_create_menu_item',
    'menu_items',
    v_created.id,
    jsonb_build_object(
      'restaurant_id', v_created.restaurant_id,
      'created_at_utc', now(),
      'new_values', jsonb_build_object(
        'category_id', v_created.category_id,
        'name', v_created.name,
        'description', v_created.description,
        'price', v_created.price,
        'is_available', v_created.is_available,
        'is_visible_public', v_created.is_visible_public,
        'sort_order', v_created.sort_order
      )
    )
  );

  RETURN v_created;
END;
$$;


ALTER FUNCTION "public"."admin_create_menu_item"("p_restaurant_id" "uuid", "p_category_id" "uuid", "p_name" "text", "p_price" numeric, "p_sort_order" integer, "p_description" "text", "p_is_available" boolean, "p_is_visible_public" boolean) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."restaurants" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "address" "text",
    "slug" "text",
    "operation_mode" "text" DEFAULT 'standard'::"text" NOT NULL,
    "per_person_charge" numeric(12,2),
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "brand_id" "uuid" NOT NULL,
    "store_type" "text" DEFAULT 'direct'::"text" NOT NULL,
    "tax_entity_id" "uuid" NOT NULL,
    "vat_pricing_mode" "text" DEFAULT 'exclusive'::"text" NOT NULL,
    CONSTRAINT "restaurants_check" CHECK (((("operation_mode" = 'standard'::"text") AND ("per_person_charge" IS NULL)) OR (("operation_mode" = ANY (ARRAY['buffet'::"text", 'hybrid'::"text"])) AND ("per_person_charge" IS NOT NULL) AND ("per_person_charge" > (0)::numeric)))),
    CONSTRAINT "restaurants_operation_mode_check" CHECK (("operation_mode" = ANY (ARRAY['standard'::"text", 'buffet'::"text", 'hybrid'::"text"]))),
    CONSTRAINT "restaurants_store_type_check" CHECK (("store_type" = ANY (ARRAY['direct'::"text", 'external'::"text"]))),
    CONSTRAINT "restaurants_vat_pricing_mode_check" CHECK (("vat_pricing_mode" = ANY (ARRAY['exclusive'::"text", 'inclusive'::"text"])))
);


ALTER TABLE "public"."restaurants" OWNER TO "postgres";


COMMENT ON TABLE "public"."restaurants" IS 'F&B 레스토랑 테넌트';



COMMENT ON COLUMN "public"."restaurants"."brand_id" IS 'FK to brands. NOT NULL enforced in Step 5 (all existing rows had values).';



COMMENT ON COLUMN "public"."restaurants"."store_type" IS 'direct = 직영(Office 연동), external = 외부(POS super_admin 전용, Office 비노출)';



COMMENT ON COLUMN "public"."restaurants"."tax_entity_id" IS 'Authoritative tax axis anchor (Invariant I1). Dev rows use placeholder — replace with real tax_entity during onboarding.';



COMMENT ON COLUMN "public"."restaurants"."vat_pricing_mode" IS 'VAT pricing mode for POS menu prices. exclusive=current behavior adds VAT on top; inclusive=treats menu price as VAT-included and derives pretax/VAT at payment time.';



CREATE OR REPLACE VIEW "public"."stores" AS
 SELECT "id",
    "name",
    "address",
    "slug",
    "operation_mode",
    "per_person_charge",
    "is_active",
    "created_at",
    "brand_id",
    "store_type"
   FROM "public"."restaurants";


ALTER VIEW "public"."stores" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_create_restaurant"("p_name" "text", "p_slug" "text", "p_operation_mode" "text", "p_address" "text" DEFAULT NULL::"text", "p_per_person_charge" numeric DEFAULT NULL::numeric, "p_brand_id" "uuid" DEFAULT NULL::"uuid", "p_store_type" "text" DEFAULT 'direct'::"text") RETURNS "public"."stores"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_created public.stores%ROWTYPE;
BEGIN
  IF NULLIF(btrim(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_NAME_REQUIRED';
  END IF;

  IF NULLIF(btrim(COALESCE(p_operation_mode, '')), '') IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_OPERATION_MODE_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'RESTAURANT_CREATE_FORBIDDEN';
  END IF;

  INSERT INTO public.stores (
    name,
    address,
    slug,
    operation_mode,
    per_person_charge,
    brand_id,
    store_type,
    is_active,
    created_at
  )
  VALUES (
    btrim(p_name),
    NULLIF(btrim(COALESCE(p_address, '')), ''),
    NULLIF(btrim(COALESCE(p_slug, '')), ''),
    lower(p_operation_mode),
    p_per_person_charge,
    p_brand_id,
    COALESCE(p_store_type, 'direct'),
    TRUE,
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_create_restaurant',
    'restaurants',
    v_created.id,
    jsonb_build_object(
      'restaurant_id', v_created.id,
      'created_at_utc', now(),
      'new_values', jsonb_build_object(
        'name', v_created.name,
        'address', v_created.address,
        'slug', v_created.slug,
        'operation_mode', v_created.operation_mode,
        'per_person_charge', v_created.per_person_charge,
        'brand_id', v_created.brand_id,
        'store_type', v_created.store_type,
        'is_active', v_created.is_active
      )
    )
  );

  RETURN v_created;
END;
$$;


ALTER FUNCTION "public"."admin_create_restaurant"("p_name" "text", "p_slug" "text", "p_operation_mode" "text", "p_address" "text", "p_per_person_charge" numeric, "p_brand_id" "uuid", "p_store_type" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tables" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "table_number" "text" NOT NULL,
    "seat_count" integer,
    "status" "text" DEFAULT 'available'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "tables_status_check" CHECK (("status" = ANY (ARRAY['available'::"text", 'occupied'::"text"])))
);


ALTER TABLE "public"."tables" OWNER TO "postgres";


COMMENT ON TABLE "public"."tables" IS '레스토랑 테이블';



CREATE OR REPLACE FUNCTION "public"."admin_create_table"("p_restaurant_id" "uuid", "p_table_number" "text", "p_seat_count" integer) RETURNS "public"."tables"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_created public.tables%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_restaurant_id);

  IF NULLIF(btrim(COALESCE(p_table_number, '')), '') IS NULL THEN
    RAISE EXCEPTION 'TABLE_NUMBER_REQUIRED';
  END IF;

  INSERT INTO public.tables (
    restaurant_id,
    table_number,
    seat_count,
    status,
    created_at,
    updated_at
  )
  VALUES (
    p_restaurant_id,
    btrim(p_table_number),
    p_seat_count,
    'available',
    now(),
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_create_table',
    'tables',
    v_created.id,
    jsonb_build_object(
      'restaurant_id', v_created.restaurant_id,
      'created_at_utc', now(),
      'new_values', jsonb_build_object(
        'table_number', v_created.table_number,
        'seat_count', v_created.seat_count,
        'status', v_created.status
      )
    )
  );

  RETURN v_created;
END;
$$;


ALTER FUNCTION "public"."admin_create_table"("p_restaurant_id" "uuid", "p_table_number" "text", "p_seat_count" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_deactivate_restaurant"("p_restaurant_id" "uuid") RETURNS "public"."stores"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_existing public.stores%ROWTYPE;
  v_updated public.stores%ROWTYPE;
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.stores
  WHERE id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RESTAURANT_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.id);

  UPDATE public.stores
  SET is_active = FALSE
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_deactivate_restaurant',
    'restaurants',
    v_updated.id,
    jsonb_build_object(
      'restaurant_id', v_updated.id,
      'changed_fields', jsonb_build_array('is_active'),
      'old_values', jsonb_build_object('is_active', v_existing.is_active),
      'new_values', jsonb_build_object('is_active', v_updated.is_active),
      'updated_at_utc', now()
    )
  );

  RETURN v_updated;
END;
$$;


ALTER FUNCTION "public"."admin_deactivate_restaurant"("p_restaurant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_delete_menu_category"("p_category_id" "uuid") RETURNS "public"."menu_categories"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_existing public.menu_categories%ROWTYPE;
BEGIN
  IF p_category_id IS NULL THEN
    RAISE EXCEPTION 'MENU_CATEGORY_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_categories
  WHERE id = p_category_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);

  DELETE FROM public.menu_categories
  WHERE id = v_existing.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_delete_menu_category',
    'menu_categories',
    v_existing.id,
    jsonb_build_object(
      'restaurant_id', v_existing.restaurant_id,
      'deleted_at_utc', now(),
      'old_values', jsonb_build_object(
        'name', v_existing.name,
        'sort_order', v_existing.sort_order,
        'is_active', v_existing.is_active
      )
    )
  );

  RETURN v_existing;
END;
$$;


ALTER FUNCTION "public"."admin_delete_menu_category"("p_category_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_delete_menu_item"("p_item_id" "uuid") RETURNS "public"."menu_items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_existing public.menu_items%ROWTYPE;
BEGIN
  IF p_item_id IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_items
  WHERE id = p_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);

  DELETE FROM public.menu_items
  WHERE id = v_existing.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_delete_menu_item',
    'menu_items',
    v_existing.id,
    jsonb_build_object(
      'restaurant_id', v_existing.restaurant_id,
      'deleted_at_utc', now(),
      'old_values', jsonb_build_object(
        'category_id', v_existing.category_id,
        'name', v_existing.name,
        'description', v_existing.description,
        'price', v_existing.price,
        'is_available', v_existing.is_available,
        'is_visible_public', v_existing.is_visible_public,
        'sort_order', v_existing.sort_order
      )
    )
  );

  RETURN v_existing;
END;
$$;


ALTER FUNCTION "public"."admin_delete_menu_item"("p_item_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_delete_table"("p_table_id" "uuid") RETURNS "public"."tables"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_existing public.tables%ROWTYPE;
BEGIN
  IF p_table_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.tables
  WHERE id = p_table_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);

  DELETE FROM public.tables
  WHERE id = v_existing.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_delete_table',
    'tables',
    v_existing.id,
    jsonb_build_object(
      'restaurant_id', v_existing.restaurant_id,
      'deleted_at_utc', now(),
      'old_values', jsonb_build_object(
        'table_number', v_existing.table_number,
        'seat_count', v_existing.seat_count,
        'status', v_existing.status
      )
    )
  );

  RETURN v_existing;
END;
$$;


ALTER FUNCTION "public"."admin_delete_table"("p_table_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_mark_resolved_einvoice_job"("p_job_id" "uuid", "p_store_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_job public.einvoice_jobs%ROWTYPE;
  v_job_store_id uuid;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'EINVOICE_RESOLVE_FORBIDDEN';
  END IF;

  IF p_job_id IS NULL OR p_store_id IS NULL THEN
    RAISE EXCEPTION 'EINVOICE_RESOLVE_INVALID';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_job
  FROM public.einvoice_jobs ej
  WHERE ej.id = p_job_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EINVOICE_JOB_NOT_FOUND';
  END IF;

  SELECT o.restaurant_id
  INTO v_job_store_id
  FROM public.orders o
  WHERE o.id = v_job.order_id
  LIMIT 1;

  IF v_job_store_id IS DISTINCT FROM p_store_id THEN
    RAISE EXCEPTION 'EINVOICE_JOB_STORE_MISMATCH';
  END IF;

  IF v_job.status NOT IN ('failed_terminal', 'stale') THEN
    RAISE EXCEPTION 'EINVOICE_JOB_NOT_RESOLVABLE';
  END IF;

  IF COALESCE(v_job.error_classification, '') IN ('duplicate_resolved', 'manual_resolved') THEN
    RAISE EXCEPTION 'EINVOICE_JOB_ALREADY_RESOLVED';
  END IF;

  UPDATE public.einvoice_jobs
  SET error_classification = 'manual_resolved',
      updated_at = now()
  WHERE id = v_job.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_mark_resolved_einvoice_job',
    'einvoice_jobs',
    v_job.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'status', v_job.status,
      'previous_error_classification', v_job.error_classification,
      'ref_id', v_job.ref_id
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'job_id', v_job.id,
    'ref_id', v_job.ref_id,
    'error_classification', 'manual_resolved'
  );
END;
$$;


ALTER FUNCTION "public"."admin_mark_resolved_einvoice_job"("p_job_id" "uuid", "p_store_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_retry_einvoice_job"("p_job_id" "uuid", "p_store_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_job public.einvoice_jobs%ROWTYPE;
  v_job_store_id uuid;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'EINVOICE_RETRY_FORBIDDEN';
  END IF;

  IF p_job_id IS NULL OR p_store_id IS NULL THEN
    RAISE EXCEPTION 'EINVOICE_RETRY_INVALID';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_job
  FROM public.einvoice_jobs ej
  WHERE ej.id = p_job_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EINVOICE_JOB_NOT_FOUND';
  END IF;

  SELECT o.restaurant_id
  INTO v_job_store_id
  FROM public.orders o
  WHERE o.id = v_job.order_id
  LIMIT 1;

  IF v_job_store_id IS DISTINCT FROM p_store_id THEN
    RAISE EXCEPTION 'EINVOICE_JOB_STORE_MISMATCH';
  END IF;

  IF v_job.status NOT IN ('failed_terminal', 'stale') THEN
    RAISE EXCEPTION 'EINVOICE_JOB_NOT_RETRYABLE';
  END IF;

  IF COALESCE(v_job.error_classification, '') IN ('duplicate_resolved', 'manual_resolved') THEN
    RAISE EXCEPTION 'EINVOICE_JOB_ALREADY_RESOLVED';
  END IF;

  UPDATE public.einvoice_jobs
  SET status = 'pending',
      dispatch_attempts = 0,
      error_classification = NULL,
      error_message = NULL,
      request_einvoice_retry_count = 0,
      request_einvoice_next_retry_at = NULL,
      updated_at = now()
  WHERE id = v_job.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_retry_einvoice_job',
    'einvoice_jobs',
    v_job.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'previous_status', v_job.status,
      'previous_error_classification', v_job.error_classification,
      'ref_id', v_job.ref_id
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'job_id', v_job.id,
    'ref_id', v_job.ref_id,
    'status', 'pending'
  );
END;
$$;


ALTER FUNCTION "public"."admin_retry_einvoice_job"("p_job_id" "uuid", "p_store_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_update_menu_category"("p_category_id" "uuid", "p_name" "text" DEFAULT NULL::"text", "p_sort_order" integer DEFAULT NULL::integer, "p_is_active" boolean DEFAULT NULL::boolean) RETURNS "public"."menu_categories"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_existing public.menu_categories%ROWTYPE;
  v_updated public.menu_categories%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_name TEXT := NULLIF(btrim(COALESCE(p_name, '')), '');
BEGIN
  IF p_category_id IS NULL THEN
    RAISE EXCEPTION 'MENU_CATEGORY_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_categories
  WHERE id = p_category_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);

  IF p_name IS NOT NULL THEN
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'MENU_CATEGORY_NAME_REQUIRED';
    END IF;
    IF v_name IS DISTINCT FROM v_existing.name THEN
      v_changed_fields := array_append(v_changed_fields, 'name');
      v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
      v_new_values := v_new_values || jsonb_build_object('name', v_name);
    END IF;
  ELSE
    v_name := v_existing.name;
  END IF;

  IF p_sort_order IS NOT NULL AND p_sort_order IS DISTINCT FROM v_existing.sort_order THEN
    v_changed_fields := array_append(v_changed_fields, 'sort_order');
    v_old_values := v_old_values || jsonb_build_object('sort_order', v_existing.sort_order);
    v_new_values := v_new_values || jsonb_build_object('sort_order', p_sort_order);
  END IF;

  IF p_is_active IS NOT NULL AND p_is_active IS DISTINCT FROM v_existing.is_active THEN
    v_changed_fields := array_append(v_changed_fields, 'is_active');
    v_old_values := v_old_values || jsonb_build_object('is_active', v_existing.is_active);
    v_new_values := v_new_values || jsonb_build_object('is_active', p_is_active);
  END IF;

  UPDATE public.menu_categories
  SET name = v_name,
      sort_order = COALESCE(p_sort_order, v_existing.sort_order),
      is_active = COALESCE(p_is_active, v_existing.is_active)
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_menu_category',
      'menu_categories',
      v_updated.id,
      jsonb_build_object(
        'restaurant_id', v_updated.restaurant_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$;


ALTER FUNCTION "public"."admin_update_menu_category"("p_category_id" "uuid", "p_name" "text", "p_sort_order" integer, "p_is_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_update_menu_item"("p_item_id" "uuid", "p_category_id" "uuid" DEFAULT NULL::"uuid", "p_name" "text" DEFAULT NULL::"text", "p_description" "text" DEFAULT NULL::"text", "p_price" numeric DEFAULT NULL::numeric, "p_is_available" boolean DEFAULT NULL::boolean, "p_is_visible_public" boolean DEFAULT NULL::boolean, "p_sort_order" integer DEFAULT NULL::integer) RETURNS "public"."menu_items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_existing public.menu_items%ROWTYPE;
  v_updated public.menu_items%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_name TEXT := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_description TEXT := NULLIF(btrim(COALESCE(p_description, '')), '');
BEGIN
  IF p_item_id IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_items
  WHERE id = p_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);

  IF p_category_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.menu_categories
    WHERE id = p_category_id
      AND restaurant_id = v_existing.restaurant_id
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  IF p_name IS NOT NULL THEN
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'MENU_ITEM_NAME_REQUIRED';
    END IF;
    IF v_name IS DISTINCT FROM v_existing.name THEN
      v_changed_fields := array_append(v_changed_fields, 'name');
      v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
      v_new_values := v_new_values || jsonb_build_object('name', v_name);
    END IF;
  ELSE
    v_name := v_existing.name;
  END IF;

  IF p_category_id IS NOT NULL AND p_category_id IS DISTINCT FROM v_existing.category_id THEN
    v_changed_fields := array_append(v_changed_fields, 'category_id');
    v_old_values := v_old_values || jsonb_build_object('category_id', v_existing.category_id);
    v_new_values := v_new_values || jsonb_build_object('category_id', p_category_id);
  END IF;

  IF p_description IS NOT NULL AND v_description IS DISTINCT FROM v_existing.description THEN
    v_changed_fields := array_append(v_changed_fields, 'description');
    v_old_values := v_old_values || jsonb_build_object('description', v_existing.description);
    v_new_values := v_new_values || jsonb_build_object('description', v_description);
  END IF;

  IF p_price IS NOT NULL AND p_price IS DISTINCT FROM v_existing.price THEN
    v_changed_fields := array_append(v_changed_fields, 'price');
    v_old_values := v_old_values || jsonb_build_object('price', v_existing.price);
    v_new_values := v_new_values || jsonb_build_object('price', p_price);
  END IF;

  IF p_is_available IS NOT NULL AND p_is_available IS DISTINCT FROM v_existing.is_available THEN
    v_changed_fields := array_append(v_changed_fields, 'is_available');
    v_old_values := v_old_values || jsonb_build_object('is_available', v_existing.is_available);
    v_new_values := v_new_values || jsonb_build_object('is_available', p_is_available);
  END IF;

  IF p_is_visible_public IS NOT NULL AND p_is_visible_public IS DISTINCT FROM v_existing.is_visible_public THEN
    v_changed_fields := array_append(v_changed_fields, 'is_visible_public');
    v_old_values := v_old_values || jsonb_build_object('is_visible_public', v_existing.is_visible_public);
    v_new_values := v_new_values || jsonb_build_object('is_visible_public', p_is_visible_public);
  END IF;

  IF p_sort_order IS NOT NULL AND p_sort_order IS DISTINCT FROM v_existing.sort_order THEN
    v_changed_fields := array_append(v_changed_fields, 'sort_order');
    v_old_values := v_old_values || jsonb_build_object('sort_order', v_existing.sort_order);
    v_new_values := v_new_values || jsonb_build_object('sort_order', p_sort_order);
  END IF;

  UPDATE public.menu_items
  SET category_id = COALESCE(p_category_id, v_existing.category_id),
      name = v_name,
      description = CASE
        WHEN p_description IS NULL THEN v_existing.description
        ELSE v_description
      END,
      price = COALESCE(p_price, v_existing.price),
      is_available = COALESCE(p_is_available, v_existing.is_available),
      is_visible_public = COALESCE(p_is_visible_public, v_existing.is_visible_public),
      sort_order = COALESCE(p_sort_order, v_existing.sort_order),
      updated_at = now()
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_menu_item',
      'menu_items',
      v_updated.id,
      jsonb_build_object(
        'restaurant_id', v_updated.restaurant_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$;


ALTER FUNCTION "public"."admin_update_menu_item"("p_item_id" "uuid", "p_category_id" "uuid", "p_name" "text", "p_description" "text", "p_price" numeric, "p_is_available" boolean, "p_is_visible_public" boolean, "p_sort_order" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_update_restaurant"("p_restaurant_id" "uuid", "p_name" "text", "p_slug" "text", "p_operation_mode" "text", "p_address" "text" DEFAULT NULL::"text", "p_per_person_charge" numeric DEFAULT NULL::numeric, "p_brand_id" "uuid" DEFAULT NULL::"uuid", "p_store_type" "text" DEFAULT 'direct'::"text") RETURNS "public"."stores"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_existing public.stores%ROWTYPE;
  v_updated public.stores%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_name TEXT := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_slug TEXT := NULLIF(btrim(COALESCE(p_slug, '')), '');
  v_operation_mode TEXT := lower(COALESCE(p_operation_mode, ''));
  v_address TEXT := NULLIF(btrim(COALESCE(p_address, '')), '');
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_ID_REQUIRED';
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_NAME_REQUIRED';
  END IF;

  IF v_operation_mode = '' THEN
    RAISE EXCEPTION 'RESTAURANT_OPERATION_MODE_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.stores
  WHERE id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RESTAURANT_NOT_FOUND';
  END IF;

  v_actor := public.require_admin_actor_for_restaurant(v_existing.id);

  IF v_name IS DISTINCT FROM v_existing.name THEN
    v_changed_fields := array_append(v_changed_fields, 'name');
    v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
    v_new_values := v_new_values || jsonb_build_object('name', v_name);
  END IF;

  IF v_address IS DISTINCT FROM v_existing.address THEN
    v_changed_fields := array_append(v_changed_fields, 'address');
    v_old_values := v_old_values || jsonb_build_object('address', v_existing.address);
    v_new_values := v_new_values || jsonb_build_object('address', v_address);
  END IF;

  IF v_slug IS DISTINCT FROM v_existing.slug THEN
    v_changed_fields := array_append(v_changed_fields, 'slug');
    v_old_values := v_old_values || jsonb_build_object('slug', v_existing.slug);
    v_new_values := v_new_values || jsonb_build_object('slug', v_slug);
  END IF;

  IF v_operation_mode IS DISTINCT FROM v_existing.operation_mode THEN
    v_changed_fields := array_append(v_changed_fields, 'operation_mode');
    v_old_values := v_old_values || jsonb_build_object('operation_mode', v_existing.operation_mode);
    v_new_values := v_new_values || jsonb_build_object('operation_mode', v_operation_mode);
  END IF;

  IF p_per_person_charge IS DISTINCT FROM v_existing.per_person_charge THEN
    v_changed_fields := array_append(v_changed_fields, 'per_person_charge');
    v_old_values := v_old_values || jsonb_build_object('per_person_charge', v_existing.per_person_charge);
    v_new_values := v_new_values || jsonb_build_object('per_person_charge', p_per_person_charge);
  END IF;

  IF p_brand_id IS DISTINCT FROM v_existing.brand_id THEN
    v_changed_fields := array_append(v_changed_fields, 'brand_id');
    v_old_values := v_old_values || jsonb_build_object('brand_id', v_existing.brand_id);
    v_new_values := v_new_values || jsonb_build_object('brand_id', p_brand_id);
  END IF;

  IF COALESCE(p_store_type, 'direct') IS DISTINCT FROM v_existing.store_type THEN
    v_changed_fields := array_append(v_changed_fields, 'store_type');
    v_old_values := v_old_values || jsonb_build_object('store_type', v_existing.store_type);
    v_new_values := v_new_values || jsonb_build_object('store_type', COALESCE(p_store_type, 'direct'));
  END IF;

  UPDATE public.stores
  SET name = v_name,
      address = v_address,
      slug = v_slug,
      operation_mode = v_operation_mode,
      per_person_charge = p_per_person_charge,
      brand_id = p_brand_id,
      store_type = COALESCE(p_store_type, 'direct')
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_restaurant',
      'restaurants',
      v_updated.id,
      jsonb_build_object(
        'restaurant_id', v_updated.id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$;


ALTER FUNCTION "public"."admin_update_restaurant"("p_restaurant_id" "uuid", "p_name" "text", "p_slug" "text", "p_operation_mode" "text", "p_address" "text", "p_per_person_charge" numeric, "p_brand_id" "uuid", "p_store_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_update_restaurant_settings"("p_store_id" "uuid", "p_name" "text", "p_operation_mode" "text", "p_address" "text" DEFAULT NULL::"text", "p_per_person_charge" numeric DEFAULT NULL::numeric, "p_vat_pricing_mode" "text" DEFAULT 'exclusive'::"text") RETURNS "public"."restaurants"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_existing public.restaurants%ROWTYPE;
  v_updated public.restaurants%ROWTYPE;
  v_changed_fields text[] := ARRAY[]::text[];
  v_old_values jsonb := '{}'::jsonb;
  v_new_values jsonb := '{}'::jsonb;
  v_name text := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_operation_mode text := lower(COALESCE(p_operation_mode, ''));
  v_address text := NULLIF(btrim(COALESCE(p_address, '')), '');
  v_vat_pricing_mode text := lower(COALESCE(p_vat_pricing_mode, 'exclusive'));
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_ID_REQUIRED';
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_NAME_REQUIRED';
  END IF;

  IF v_operation_mode = '' THEN
    RAISE EXCEPTION 'RESTAURANT_OPERATION_MODE_REQUIRED';
  END IF;

  IF v_vat_pricing_mode NOT IN ('exclusive', 'inclusive') THEN
    RAISE EXCEPTION 'RESTAURANT_VAT_PRICING_MODE_INVALID';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.restaurants
  WHERE id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RESTAURANT_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.id);

  IF v_name IS DISTINCT FROM v_existing.name THEN
    v_changed_fields := array_append(v_changed_fields, 'name');
    v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
    v_new_values := v_new_values || jsonb_build_object('name', v_name);
  END IF;

  IF v_address IS DISTINCT FROM v_existing.address THEN
    v_changed_fields := array_append(v_changed_fields, 'address');
    v_old_values := v_old_values || jsonb_build_object('address', v_existing.address);
    v_new_values := v_new_values || jsonb_build_object('address', v_address);
  END IF;

  IF v_operation_mode IS DISTINCT FROM v_existing.operation_mode THEN
    v_changed_fields := array_append(v_changed_fields, 'operation_mode');
    v_old_values := v_old_values || jsonb_build_object('operation_mode', v_existing.operation_mode);
    v_new_values := v_new_values || jsonb_build_object('operation_mode', v_operation_mode);
  END IF;

  IF p_per_person_charge IS DISTINCT FROM v_existing.per_person_charge THEN
    v_changed_fields := array_append(v_changed_fields, 'per_person_charge');
    v_old_values := v_old_values || jsonb_build_object('per_person_charge', v_existing.per_person_charge);
    v_new_values := v_new_values || jsonb_build_object('per_person_charge', p_per_person_charge);
  END IF;

  IF v_vat_pricing_mode IS DISTINCT FROM COALESCE(v_existing.vat_pricing_mode, 'exclusive') THEN
    v_changed_fields := array_append(v_changed_fields, 'vat_pricing_mode');
    v_old_values := v_old_values || jsonb_build_object('vat_pricing_mode', v_existing.vat_pricing_mode);
    v_new_values := v_new_values || jsonb_build_object('vat_pricing_mode', v_vat_pricing_mode);
  END IF;

  UPDATE public.restaurants
  SET name = v_name,
      address = v_address,
      operation_mode = v_operation_mode,
      per_person_charge = p_per_person_charge,
      vat_pricing_mode = v_vat_pricing_mode
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_restaurant_settings',
      'restaurants',
      v_updated.id,
      jsonb_build_object(
        'store_id', v_updated.id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$;


ALTER FUNCTION "public"."admin_update_restaurant_settings"("p_store_id" "uuid", "p_name" "text", "p_operation_mode" "text", "p_address" "text", "p_per_person_charge" numeric, "p_vat_pricing_mode" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "auth_id" "uuid" NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "full_name" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "extra_permissions" "text"[] DEFAULT '{}'::"text"[],
    "brand_id" "uuid",
    "primary_store_id" "uuid",
    CONSTRAINT "users_role_check" CHECK (("role" = ANY (ARRAY['super_admin'::"text", 'master_admin'::"text", 'brand_admin'::"text", 'store_admin'::"text", 'admin'::"text", 'waiter'::"text", 'kitchen'::"text", 'cashier'::"text", 'photo_objet_master'::"text", 'photo_objet_store_admin'::"text"])))
);


ALTER TABLE "public"."users" OWNER TO "postgres";


COMMENT ON TABLE "public"."users" IS 'POS 사용자 (Supabase Auth 연동)';



COMMENT ON COLUMN "public"."users"."brand_id" IS 'Primary brand affiliation for the user. Added for the brand/store multi-access model. Nullable during transition and backfilled later.';



COMMENT ON COLUMN "public"."users"."primary_store_id" IS 'Primary working store for the user. restaurants remains the physical store table during the transition. Nullable during transition and backfilled later.';



CREATE OR REPLACE FUNCTION "public"."admin_update_staff_account"("p_user_id" "uuid", "p_restaurant_id" "uuid", "p_full_name" "text" DEFAULT NULL::"text", "p_is_active" boolean DEFAULT NULL::boolean, "p_extra_permissions" "text"[] DEFAULT NULL::"text"[]) RETURNS "public"."users"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_target public.users%ROWTYPE;
  v_updated public.users%ROWTYPE;
  v_target_brand_id uuid;
  v_actor_store_id uuid;
  v_full_name text := NULLIF(btrim(COALESCE(p_full_name, '')), '');
  v_changed_fields text[] := ARRAY[]::text[];
  v_old_values jsonb := '{}'::jsonb;
  v_new_values jsonb := '{}'::jsonb;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  IF p_user_id IS NULL OR p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_INVALID';
  END IF;

  v_actor_store_id := COALESCE(v_actor.primary_store_id, v_actor.restaurant_id);

  SELECT brand_id
  INTO v_target_brand_id
  FROM public.restaurants
  WHERE id = p_restaurant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_INVALID';
  END IF;

  IF v_actor.role IN ('admin', 'store_admin')
     AND v_actor_store_id IS DISTINCT FROM p_restaurant_id THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  IF v_actor.role = 'brand_admin'
     AND (v_actor.brand_id IS NULL OR v_actor.brand_id IS DISTINCT FROM v_target_brand_id) THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_target
  FROM public.users
  WHERE id = p_user_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_NOT_FOUND';
  END IF;

  IF v_actor.role IN ('admin', 'store_admin')
     AND v_target.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin', 'photo_objet_master') THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  IF v_actor.role = 'brand_admin'
     AND v_target.role IN ('brand_admin', 'super_admin', 'photo_objet_master') THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  IF p_full_name IS NOT NULL THEN
    IF v_full_name IS NULL THEN
      RAISE EXCEPTION 'USER_FULL_NAME_REQUIRED';
    END IF;
    IF v_full_name IS DISTINCT FROM v_target.full_name THEN
      v_changed_fields := array_append(v_changed_fields, 'full_name');
      v_old_values := v_old_values || jsonb_build_object('full_name', v_target.full_name);
      v_new_values := v_new_values || jsonb_build_object('full_name', v_full_name);
    END IF;
  ELSE
    v_full_name := v_target.full_name;
  END IF;

  IF p_is_active IS NOT NULL AND p_is_active IS DISTINCT FROM v_target.is_active THEN
    v_changed_fields := array_append(v_changed_fields, 'is_active');
    v_old_values := v_old_values || jsonb_build_object('is_active', v_target.is_active);
    v_new_values := v_new_values || jsonb_build_object('is_active', p_is_active);
  END IF;

  IF p_extra_permissions IS NOT NULL
     AND COALESCE(p_extra_permissions, ARRAY[]::text[]) IS DISTINCT FROM COALESCE(v_target.extra_permissions, ARRAY[]::text[]) THEN
    v_changed_fields := array_append(v_changed_fields, 'extra_permissions');
    v_old_values := v_old_values || jsonb_build_object('extra_permissions', COALESCE(v_target.extra_permissions, ARRAY[]::text[]));
    v_new_values := v_new_values || jsonb_build_object('extra_permissions', COALESCE(p_extra_permissions, ARRAY[]::text[]));
  END IF;

  UPDATE public.users
  SET full_name = v_full_name,
      is_active = COALESCE(p_is_active, v_target.is_active),
      extra_permissions = CASE
        WHEN p_extra_permissions IS NULL THEN v_target.extra_permissions
        ELSE COALESCE(p_extra_permissions, ARRAY[]::text[])
      END
  WHERE id = v_target.id
  RETURNING * INTO v_updated;

  IF array_length(v_changed_fields, 1) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_staff_account',
      'users',
      v_updated.id,
      jsonb_build_object(
        'restaurant_id', v_updated.restaurant_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values
      )
    );

    PERFORM public.refresh_user_claims(v_target.auth_id);
  END IF;

  RETURN v_updated;
END;
$$;


ALTER FUNCTION "public"."admin_update_staff_account"("p_user_id" "uuid", "p_restaurant_id" "uuid", "p_full_name" "text", "p_is_active" boolean, "p_extra_permissions" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_update_table"("p_table_id" "uuid", "p_table_number" "text" DEFAULT NULL::"text", "p_seat_count" integer DEFAULT NULL::integer, "p_status" "text" DEFAULT NULL::"text") RETURNS "public"."tables"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_existing public.tables%ROWTYPE;
  v_updated public.tables%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_table_number TEXT := NULLIF(btrim(COALESCE(p_table_number, '')), '');
BEGIN
  IF p_table_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.tables
  WHERE id = p_table_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);

  IF p_table_number IS NOT NULL THEN
    IF v_table_number IS NULL THEN
      RAISE EXCEPTION 'TABLE_NUMBER_REQUIRED';
    END IF;
    IF v_table_number IS DISTINCT FROM v_existing.table_number THEN
      v_changed_fields := array_append(v_changed_fields, 'table_number');
      v_old_values := v_old_values || jsonb_build_object('table_number', v_existing.table_number);
      v_new_values := v_new_values || jsonb_build_object('table_number', v_table_number);
    END IF;
  ELSE
    v_table_number := v_existing.table_number;
  END IF;

  IF p_seat_count IS NOT NULL AND p_seat_count IS DISTINCT FROM v_existing.seat_count THEN
    v_changed_fields := array_append(v_changed_fields, 'seat_count');
    v_old_values := v_old_values || jsonb_build_object('seat_count', v_existing.seat_count);
    v_new_values := v_new_values || jsonb_build_object('seat_count', p_seat_count);
  END IF;

  IF p_status IS NOT NULL AND p_status IS DISTINCT FROM v_existing.status THEN
    v_changed_fields := array_append(v_changed_fields, 'status');
    v_old_values := v_old_values || jsonb_build_object('status', v_existing.status);
    v_new_values := v_new_values || jsonb_build_object('status', p_status);
  END IF;

  UPDATE public.tables
  SET table_number = v_table_number,
      seat_count = COALESCE(p_seat_count, v_existing.seat_count),
      status = COALESCE(p_status, v_existing.status),
      updated_at = now()
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_table',
      'tables',
      v_updated.id,
      jsonb_build_object(
        'restaurant_id', v_updated.restaurant_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$;


ALTER FUNCTION "public"."admin_update_table"("p_table_id" "uuid", "p_table_number" "text", "p_seat_count" integer, "p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_inventory_physical_count_line"("p_restaurant_id" "uuid", "p_count_date" "date", "p_ingredient_id" "uuid", "p_actual_quantity_g" numeric, "p_note" "text" DEFAULT NULL::"text") RETURNS TABLE("ingredient_id" "uuid", "count_date" "date", "theoretical_quantity_g" numeric, "actual_quantity_g" numeric, "variance_quantity_g" numeric, "inventory_transaction_id" "uuid", "last_updated" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_ingredient public.inventory_items%ROWTYPE;
  v_existing_count public.inventory_physical_counts%ROWTYPE;
  v_count_row public.inventory_physical_counts%ROWTYPE;
  v_transaction public.inventory_transactions%ROWTYPE;
  v_old_stock DECIMAL(12,3);
  v_variance DECIMAL(12,3);
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_WRITE_FORBIDDEN';
  END IF;

  IF p_count_date IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_DATE_REQUIRED';
  END IF;

  IF p_ingredient_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_INGREDIENT_REQUIRED';
  END IF;

  IF p_actual_quantity_g IS NULL OR p_actual_quantity_g < 0 THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_ACTUAL_INVALID';
  END IF;

  SELECT ii.*
  INTO v_ingredient
  FROM public.inventory_items ii
  WHERE ii.id = p_ingredient_id
    AND ii.restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_INGREDIENT_NOT_FOUND';
  END IF;

  v_old_stock := v_ingredient.current_stock;
  v_variance := p_actual_quantity_g - v_old_stock;

  SELECT ipc.*
  INTO v_existing_count
  FROM public.inventory_physical_counts ipc
  WHERE ipc.restaurant_id = p_restaurant_id
    AND ipc.ingredient_id = p_ingredient_id
    AND ipc.count_date = p_count_date
  FOR UPDATE;

  INSERT INTO public.inventory_physical_counts (
    restaurant_id,
    ingredient_id,
    count_date,
    actual_quantity_g,
    theoretical_quantity_g,
    variance_g,
    counted_by,
    updated_at
  )
  VALUES (
    p_restaurant_id,
    p_ingredient_id,
    p_count_date,
    p_actual_quantity_g,
    v_old_stock,
    v_variance,
    auth.uid(),
    now()
  )
  ON CONFLICT ON CONSTRAINT inventory_physical_counts_ingredient_id_count_date_key
  DO UPDATE SET
    actual_quantity_g = EXCLUDED.actual_quantity_g,
    theoretical_quantity_g = EXCLUDED.theoretical_quantity_g,
    variance_g = EXCLUDED.variance_g,
    counted_by = EXCLUDED.counted_by,
    updated_at = now()
  RETURNING * INTO v_count_row;

  UPDATE public.inventory_items ii
  SET current_stock = p_actual_quantity_g,
      updated_at = now()
  WHERE ii.id = p_ingredient_id
    AND ii.restaurant_id = p_restaurant_id;

  INSERT INTO public.inventory_transactions (
    restaurant_id,
    ingredient_id,
    transaction_type,
    quantity_g,
    reference_type,
    reference_id,
    note,
    created_by
  )
  VALUES (
    p_restaurant_id,
    p_ingredient_id,
    'adjust',
    v_variance,
    'physical_count',
    v_count_row.id,
    COALESCE(
      v_note,
      format('실재고 실사 (%s)', to_char(p_count_date, 'YYYY-MM-DD'))
    ),
    auth.uid()
  )
  RETURNING * INTO v_transaction;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_physical_count_applied',
    'inventory_physical_counts',
    v_count_row.id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'ingredient_id', p_ingredient_id,
      'count_date', p_count_date,
      'old_stock', v_old_stock,
      'new_stock', p_actual_quantity_g,
      'variance_quantity_g', v_variance,
      'note', v_note,
      'previous_count', CASE
        WHEN v_existing_count.id IS NULL THEN NULL
        ELSE jsonb_build_object(
          'actual_quantity_g', v_existing_count.actual_quantity_g,
          'theoretical_quantity_g', v_existing_count.theoretical_quantity_g,
          'variance_g', v_existing_count.variance_g
        )
      END
    )
  );

  RETURN QUERY
  SELECT
    p_ingredient_id AS ingredient_id,
    p_count_date AS count_date,
    v_old_stock AS theoretical_quantity_g,
    p_actual_quantity_g AS actual_quantity_g,
    v_variance AS variance_quantity_g,
    v_transaction.id AS inventory_transaction_id,
    v_count_row.updated_at AS last_updated;
END;
$$;


ALTER FUNCTION "public"."apply_inventory_physical_count_line"("p_restaurant_id" "uuid", "p_count_date" "date", "p_ingredient_id" "uuid", "p_actual_quantity_g" numeric, "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."attach_payment_proof"("p_payment_id" "uuid", "p_store_id" "uuid", "p_proof_photo_url" "text", "p_taken_at" timestamp with time zone DEFAULT "now"()) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_payment public.payments%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'PAYMENT_PROOF_FORBIDDEN';
  END IF;

  IF p_payment_id IS NULL OR p_store_id IS NULL OR COALESCE(trim(p_proof_photo_url), '') = '' THEN
    RAISE EXCEPTION 'PAYMENT_PROOF_INVALID';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_payment
  FROM public.payments
  WHERE id = p_payment_id
    AND restaurant_id = p_store_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PAYMENT_NOT_FOUND';
  END IF;

  UPDATE public.payments
  SET proof_required = TRUE,
      proof_photo_url = p_proof_photo_url,
      proof_photo_taken_at = COALESCE(p_taken_at, now()),
      proof_photo_by = v_actor.id
  WHERE id = v_payment.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'attach_payment_proof',
    'payments',
    v_payment.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_payment.order_id,
      'proof_photo_url', p_proof_photo_url
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'payment_id', v_payment.id,
    'proof_photo_url', p_proof_photo_url
  );
END;
$$;


ALTER FUNCTION "public"."attach_payment_proof"("p_payment_id" "uuid", "p_store_id" "uuid", "p_proof_photo_url" "text", "p_taken_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_access_inventory_purchase_store"("p_store_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
BEGIN
  IF p_store_id IS NULL THEN
    RETURN FALSE;
  END IF;

  IF auth.role() = 'service_role' THEN
    RETURN TRUE;
  END IF;

  IF public.has_any_role(ARRAY['super_admin']) THEN
    RETURN TRUE;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) s(store_id)
    WHERE s.store_id = p_store_id
  ) THEN
    RETURN TRUE;
  END IF;

  RETURN FALSE;
END;
$$;


ALTER FUNCTION "public"."can_access_inventory_purchase_store"("p_store_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_office_review_inventory_purchase_store"("p_store_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
BEGIN
  IF p_store_id IS NULL THEN
    RETURN FALSE;
  END IF;

  IF auth.role() = 'service_role' THEN
    RETURN TRUE;
  END IF;

  IF public.has_any_role(ARRAY['super_admin']) THEN
    RETURN TRUE;
  END IF;

  RETURN FALSE;
END;
$$;


ALTER FUNCTION "public"."can_office_review_inventory_purchase_store"("p_store_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "table_id" "uuid",
    "sales_channel" "text" DEFAULT 'dine_in'::"text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "guest_count" integer,
    "created_by" "uuid",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "orders_guest_count_check" CHECK ((("guest_count" IS NULL) OR ("guest_count" > 0))),
    CONSTRAINT "orders_sales_channel_check" CHECK (("sales_channel" = ANY (ARRAY['dine_in'::"text", 'takeaway'::"text", 'delivery'::"text"]))),
    CONSTRAINT "orders_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'confirmed'::"text", 'serving'::"text", 'completed'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."orders" OWNER TO "postgres";


COMMENT ON TABLE "public"."orders" IS '주문 (dine_in/takeaway)';



CREATE OR REPLACE FUNCTION "public"."cancel_order"("p_order_id" "uuid", "p_restaurant_id" "uuid") RETURNS "public"."orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status NOT IN ('pending', 'confirmed') THEN
    RAISE EXCEPTION 'ORDER_NOT_CANCELLABLE';
  END IF;

  UPDATE orders
  SET status = 'cancelled',
      updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  IF v_order.table_id IS NOT NULL THEN
    UPDATE tables
    SET status = 'available',
        updated_at = now()
    WHERE id = v_order.table_id;
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'cancel_order',
    'orders',
    p_order_id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'from_status', 'pending_or_confirmed',
      'to_status', 'cancelled'
    )
  );

  RETURN v_order;
END;
$$;


ALTER FUNCTION "public"."cancel_order"("p_order_id" "uuid", "p_restaurant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_order_item"("p_item_id" "uuid", "p_restaurant_id" "uuid") RETURNS "public"."order_items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_item order_items%ROWTYPE;
  v_order_status TEXT;
  v_from_status TEXT;
BEGIN
  -- Actor validation
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  -- Lock item
  SELECT *
  INTO v_item
  FROM order_items
  WHERE id = p_item_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  -- Check order is mutable
  SELECT status
  INTO v_order_status
  FROM orders
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  -- Only pending/preparing items can be cancelled
  IF v_item.status NOT IN ('pending', 'preparing') THEN
    RAISE EXCEPTION 'ITEM_NOT_CANCELLABLE';
  END IF;

  v_from_status := v_item.status;

  UPDATE order_items
  SET status = 'cancelled'
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  -- Update order timestamp
  UPDATE orders
  SET updated_at = now()
  WHERE id = v_item.order_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'cancel_order_item',
    'order_items',
    p_item_id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'order_id', v_item.order_id,
      'from_status', v_from_status,
      'to_status', 'cancelled',
      'label', v_item.label,
      'quantity', v_item.quantity,
      'unit_price', v_item.unit_price
    )
  );

  RETURN v_item;
END;
$$;


ALTER FUNCTION "public"."cancel_order_item"("p_item_id" "uuid", "p_restaurant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."complete_onboarding_account_setup"("p_restaurant_id" "uuid", "p_full_name" "text", "p_role" "text") RETURNS "public"."users"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_updated public.users%ROWTYPE;
  v_full_name TEXT := NULLIF(btrim(COALESCE(p_full_name, '')), '');
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'ONBOARDING_RESTAURANT_REQUIRED';
  END IF;

  IF v_full_name IS NULL THEN
    RAISE EXCEPTION 'USER_FULL_NAME_REQUIRED';
  END IF;

  IF p_role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'ONBOARDING_ROLE_INVALID';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'ONBOARDING_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  UPDATE public.users
  SET restaurant_id = p_restaurant_id,
      full_name = v_full_name,
      role = p_role
  WHERE id = v_actor.id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'complete_onboarding_account_setup',
    'users',
    v_updated.id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'new_role', p_role
    )
  );

  RETURN v_updated;
END;
$$;


ALTER FUNCTION "public"."complete_onboarding_account_setup"("p_restaurant_id" "uuid", "p_full_name" "text", "p_role" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."delivery_settlements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "source_system" "text" NOT NULL,
    "period_start" "date" NOT NULL,
    "period_end" "date" NOT NULL,
    "period_label" "text" NOT NULL,
    "gross_total" numeric(12,2) NOT NULL,
    "total_deductions" numeric(12,2) DEFAULT 0 NOT NULL,
    "net_settlement" numeric(12,2) NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "received_at" timestamp with time zone,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "delivery_settlements_gross_total_check" CHECK (("gross_total" >= (0)::numeric)),
    CONSTRAINT "delivery_settlements_source_system_check" CHECK (("source_system" = 'deliberry'::"text")),
    CONSTRAINT "delivery_settlements_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'calculated'::"text", 'received'::"text", 'disputed'::"text", 'adjusted'::"text"]))),
    CONSTRAINT "delivery_settlements_total_deductions_check" CHECK (("total_deductions" >= (0)::numeric))
);


ALTER TABLE "public"."delivery_settlements" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."confirm_delivery_settlement_received"("p_settlement_id" "uuid", "p_restaurant_id" "uuid") RETURNS "public"."delivery_settlements"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor_id UUID := auth.uid();
  v_actor users%ROWTYPE;
  v_settlement delivery_settlements%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = v_actor_id
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'SETTLEMENT_CONFIRM_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_settlement
  FROM delivery_settlements
  WHERE id = p_settlement_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SETTLEMENT_NOT_FOUND';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'SETTLEMENT_CONFIRM_FORBIDDEN';
  END IF;

  IF v_settlement.status <> 'calculated' THEN
    RAISE EXCEPTION 'INVALID_SETTLEMENT_STATUS';
  END IF;

  UPDATE delivery_settlements
  SET status = 'received',
      received_at = now(),
      updated_at = now()
  WHERE id = p_settlement_id
  RETURNING * INTO v_settlement;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    v_actor_id,
    'confirm_delivery_settlement_received',
    'delivery_settlements',
    p_settlement_id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'from_status', 'calculated',
      'to_status', 'received'
    )
  );

  RETURN v_settlement;
END;
$$;


ALTER FUNCTION "public"."confirm_delivery_settlement_received"("p_settlement_id" "uuid", "p_restaurant_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_purchase_orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "purchase_order_no" "text" NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "brand_id" "uuid",
    "supplier_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "order_type" "text" DEFAULT 'recommended'::"text" NOT NULL,
    "source" "text" DEFAULT 'pos'::"text" NOT NULL,
    "requested_delivery_date" "date",
    "ordered_at" timestamp with time zone,
    "submitted_by" "uuid",
    "office_reviewed_by" "uuid",
    "office_reviewed_at" timestamp with time zone,
    "office_rejection_reason" "text",
    "office_review_comment" "text",
    "total_supply_amount" numeric(12,2) DEFAULT 0 NOT NULL,
    "tax_amount" numeric(12,2) DEFAULT 0 NOT NULL,
    "total_amount" numeric(12,2) DEFAULT 0 NOT NULL,
    "pdf_url" "text",
    "memo" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "inventory_purchase_orders_order_type_check" CHECK (("order_type" = ANY (ARRAY['recommended'::"text", 'manual'::"text", 'repeat'::"text"]))),
    CONSTRAINT "inventory_purchase_orders_source_check" CHECK (("source" = ANY (ARRAY['pos'::"text", 'mobile'::"text", 'office'::"text"]))),
    CONSTRAINT "inventory_purchase_orders_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'submitted'::"text", 'office_approved'::"text", 'office_returned'::"text", 'office_rejected'::"text", 'ordered'::"text", 'partially_received'::"text", 'received'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."inventory_purchase_orders" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."confirm_inventory_purchase_receipt"("p_purchase_order_id" "uuid", "p_memo" "text" DEFAULT NULL::"text", "p_lines" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "public"."inventory_purchase_orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_receipt_id UUID;
  v_line JSONB;
  v_line_id UUID;
  v_accepted_quantity_base NUMERIC(12,3);
  v_rejected_quantity_base NUMERIC(12,3);
  v_line_memo TEXT;
  v_ordered_total NUMERIC(12,3);
  v_accepted_total NUMERIC(12,3);
BEGIN
  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  IF NOT public.can_access_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;

  IF v_order.status NOT IN ('office_approved', 'ordered', 'partially_received') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_RECEIVABLE';
  END IF;

  INSERT INTO public.inventory_receipts (
    purchase_order_id,
    restaurant_id,
    supplier_id,
    received_by,
    status,
    memo
  )
  VALUES (
    p_purchase_order_id,
    v_order.restaurant_id,
    v_order.supplier_id,
    auth.uid(),
    'confirmed',
    NULLIF(btrim(COALESCE(p_memo, '')), '')
  )
  RETURNING id INTO v_receipt_id;

  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' AND jsonb_array_length(p_lines) > 0 THEN
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
      v_line_id := NULLIF(v_line->>'line_id', '')::UUID;
      v_accepted_quantity_base := COALESCE(NULLIF(v_line->>'accepted_quantity_base', '')::NUMERIC, 0);
      v_rejected_quantity_base := COALESCE(NULLIF(v_line->>'rejected_quantity_base', '')::NUMERIC, 0);
      v_line_memo := NULLIF(btrim(COALESCE(v_line->>'memo', '')), '');

      INSERT INTO public.inventory_receipt_lines (
        receipt_id,
        purchase_order_line_id,
        product_id,
        received_quantity_base,
        accepted_quantity_base,
        rejected_quantity_base,
        memo
      )
      SELECT
        v_receipt_id,
        pol.id,
        pol.product_id,
        v_accepted_quantity_base + v_rejected_quantity_base,
        v_accepted_quantity_base,
        v_rejected_quantity_base,
        v_line_memo
      FROM public.inventory_purchase_order_lines pol
      WHERE pol.id = v_line_id
        AND pol.purchase_order_id = p_purchase_order_id;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'INVENTORY_PURCHASE_LINE_NOT_FOUND';
      END IF;
    END LOOP;
  ELSE
    INSERT INTO public.inventory_receipt_lines (
      receipt_id,
      purchase_order_line_id,
      product_id,
      received_quantity_base,
      accepted_quantity_base,
      rejected_quantity_base
    )
    SELECT
      v_receipt_id,
      pol.id,
      pol.product_id,
      GREATEST(pol.ordered_quantity_base - COALESCE(received.accepted_quantity_base, 0), 0),
      GREATEST(pol.ordered_quantity_base - COALESCE(received.accepted_quantity_base, 0), 0),
      0
    FROM public.inventory_purchase_order_lines pol
    LEFT JOIN (
      SELECT
        irl.purchase_order_line_id,
        SUM(irl.accepted_quantity_base) AS accepted_quantity_base
      FROM public.inventory_receipt_lines irl
      JOIN public.inventory_receipts ir
        ON ir.id = irl.receipt_id
       AND ir.status = 'confirmed'
      WHERE ir.purchase_order_id = p_purchase_order_id
      GROUP BY irl.purchase_order_line_id
    ) received
      ON received.purchase_order_line_id = pol.id
    WHERE pol.purchase_order_id = p_purchase_order_id
      AND GREATEST(pol.ordered_quantity_base - COALESCE(received.accepted_quantity_base, 0), 0) > 0;
  END IF;

  UPDATE public.inventory_items ii
  SET current_stock = COALESCE(current_stock, 0) + received.accepted_quantity_base,
      quantity = COALESCE(quantity, 0) + received.accepted_quantity_base,
      updated_at = now()
  FROM (
    SELECT
      ip.inventory_item_id,
      SUM(irl.accepted_quantity_base) AS accepted_quantity_base
    FROM public.inventory_receipt_lines irl
    JOIN public.inventory_products ip
      ON ip.id = irl.product_id
    WHERE irl.receipt_id = v_receipt_id
      AND ip.inventory_item_id IS NOT NULL
    GROUP BY ip.inventory_item_id
  ) received
  WHERE ii.id = received.inventory_item_id
    AND ii.restaurant_id = v_order.restaurant_id;

  SELECT COALESCE(SUM(ordered_quantity_base), 0)
  INTO v_ordered_total
  FROM public.inventory_purchase_order_lines
  WHERE purchase_order_id = p_purchase_order_id;

  SELECT COALESCE(SUM(irl.accepted_quantity_base), 0)
  INTO v_accepted_total
  FROM public.inventory_receipt_lines irl
  JOIN public.inventory_receipts ir
    ON ir.id = irl.receipt_id
   AND ir.status = 'confirmed'
  WHERE ir.purchase_order_id = p_purchase_order_id;

  UPDATE public.inventory_purchase_orders
  SET status = CASE
        WHEN v_accepted_total >= v_ordered_total THEN 'received'
        ELSE 'partially_received'
      END,
      updated_at = now()
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_order;

  RETURN v_order;
END;
$$;


ALTER FUNCTION "public"."confirm_inventory_purchase_receipt"("p_purchase_order_id" "uuid", "p_memo" "text", "p_lines" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_buffet_order"("p_store_id" "uuid", "p_table_id" "uuid", "p_guest_count" integer, "p_extra_items" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "public"."orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_table tables%ROWTYPE;
  v_operation_mode text;
  v_per_person_charge decimal(12,2);
  v_order orders%ROWTYPE;
  v_extra_item_count int := 0;
  v_buffet_pretax decimal(15,2);
  v_buffet_vat decimal(15,2);
  v_buffet_total decimal(15,2);
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'ORDER_STORE_REQUIRED';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_table
  FROM tables
  WHERE id = p_table_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  IF v_table.status = 'occupied' THEN
    RAISE EXCEPTION 'TABLE_ALREADY_OCCUPIED';
  END IF;

  SELECT operation_mode, per_person_charge
  INTO v_operation_mode, v_per_person_charge
  FROM restaurants
  WHERE id = p_store_id;

  IF v_operation_mode NOT IN ('buffet', 'hybrid') THEN
    RAISE EXCEPTION 'OPERATION_MODE_MISMATCH';
  END IF;

  IF p_guest_count IS NULL OR p_guest_count < 1 THEN
    RAISE EXCEPTION 'BUFFET_GUEST_COUNT_REQUIRED';
  END IF;

  IF jsonb_typeof(p_extra_items) <> 'array' THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_extra_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::int, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_extra_items) item
    LEFT JOIN menu_items m
      ON m.id = (item->>'menu_item_id')::uuid
     AND m.restaurant_id = p_store_id
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  INSERT INTO orders (
    restaurant_id,
    table_id,
    status,
    created_by,
    guest_count
  )
  VALUES (p_store_id, p_table_id, 'pending', auth.uid(), p_guest_count)
  RETURNING * INTO v_order;

  v_buffet_pretax := ROUND(v_per_person_charge * p_guest_count, 2);
  v_buffet_vat := ROUND(v_buffet_pretax * 8 / 100, 2);
  v_buffet_total := v_buffet_pretax + v_buffet_vat;

  INSERT INTO order_items (
    order_id,
    restaurant_id,
    item_type,
    display_name,
    label,
    unit_price,
    quantity,
    status,
    vat_rate,
    vat_amount,
    total_amount_ex_tax,
    paying_amount_inc_tax
  )
  VALUES (
    v_order.id,
    p_store_id,
    'service_charge',
    'Buffet Base Charge',
    'Buffet Base Charge',
    v_per_person_charge,
    p_guest_count,
    'served',
    8,
    v_buffet_vat,
    v_buffet_pretax,
    v_buffet_total
  );

  IF jsonb_array_length(p_extra_items) > 0 THEN
    INSERT INTO order_items (
      order_id,
      menu_item_id,
      quantity,
      unit_price,
      label,
      display_name,
      restaurant_id,
      item_type
    )
    SELECT
      v_order.id,
      m.id,
      (item->>'quantity')::int,
      m.price,
      m.name,
      m.name,
      p_store_id,
      'menu_item'
    FROM jsonb_array_elements(p_extra_items) item
    JOIN menu_items m
      ON m.id = (item->>'menu_item_id')::uuid
     AND m.restaurant_id = p_store_id
     AND m.is_available = TRUE;

    GET DIAGNOSTICS v_extra_item_count = ROW_COUNT;
  END IF;

  UPDATE tables
  SET status = 'occupied',
      updated_at = now()
  WHERE id = p_table_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'create_buffet_order',
    'orders',
    v_order.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'table_id', p_table_id,
      'guest_count', p_guest_count,
      'extra_item_count', v_extra_item_count,
      'operation_mode', v_operation_mode,
      'buffet_base_total_ex_tax', v_buffet_pretax
    )
  );

  RETURN v_order;
END;
$$;


ALTER FUNCTION "public"."create_buffet_order"("p_store_id" "uuid", "p_table_id" "uuid", "p_guest_count" integer, "p_extra_items" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_daily_closing"("p_restaurant_id" "uuid", "p_notes" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_closing_date DATE;
  v_existing_id UUID;
  v_orders_total INT;
  v_orders_completed INT;
  v_orders_cancelled INT;
  v_items_cancelled INT;
  v_payments_count INT;
  v_payments_total NUMERIC;
  v_payments_cash NUMERIC;
  v_payments_card NUMERIC;
  v_payments_pay NUMERIC;
  v_service_count INT;
  v_service_total NUMERIC;
  v_low_stock_count INT;
  v_day_start TIMESTAMPTZ;
  v_new_id UUID;
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'DAILY_CLOSING_RESTAURANT_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'DAILY_CLOSING_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'DAILY_CLOSING_FORBIDDEN';
  END IF;

  -- Vietnam timezone for closing date
  v_closing_date := (NOW() AT TIME ZONE 'Asia/Ho_Chi_Minh')::DATE;
  v_day_start := v_closing_date::TIMESTAMPTZ;

  -- Check duplicate
  SELECT id INTO v_existing_id
  FROM daily_closings
  WHERE restaurant_id = p_restaurant_id
    AND closing_date = v_closing_date;

  IF FOUND THEN
    RAISE EXCEPTION 'DAILY_CLOSING_ALREADY_EXISTS';
  END IF;

  -- Compute order metrics
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END), 0)
  INTO v_orders_total, v_orders_completed, v_orders_cancelled
  FROM public.orders
  WHERE restaurant_id = p_restaurant_id
    AND created_at >= v_day_start;

  -- Cancelled items
  SELECT COALESCE(COUNT(*), 0)
  INTO v_items_cancelled
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE o.restaurant_id = p_restaurant_id
    AND oi.status = 'cancelled'
    AND o.created_at >= v_day_start;

  -- Revenue payments
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'cash' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'card' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) NOT IN ('cash', 'card') THEN amount ELSE 0 END), 0)
  INTO v_payments_count, v_payments_total, v_payments_cash, v_payments_card, v_payments_pay
  FROM public.payments
  WHERE restaurant_id = p_restaurant_id
    AND is_revenue = TRUE
    AND created_at >= v_day_start;

  -- Service payments
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0)
  INTO v_service_count, v_service_total
  FROM public.payments
  WHERE restaurant_id = p_restaurant_id
    AND is_revenue = FALSE
    AND created_at >= v_day_start;

  -- Low-stock count (snapshot at closing time).
  -- NOTE: inventory_items has no is_active column; filter only on
  -- reorder_point and current_stock which exist since inventory_v2.
  SELECT COALESCE(COUNT(*), 0)
  INTO v_low_stock_count
  FROM public.inventory_items
  WHERE restaurant_id = p_restaurant_id
    AND reorder_point IS NOT NULL
    AND current_stock <= reorder_point;

  -- Insert closing record
  INSERT INTO daily_closings (
    restaurant_id, closing_date, closed_by,
    orders_total, orders_completed, orders_cancelled, items_cancelled,
    payments_count, payments_total, payments_cash, payments_card, payments_pay,
    service_count, service_total, low_stock_count, notes
  ) VALUES (
    p_restaurant_id, v_closing_date, auth.uid(),
    v_orders_total, v_orders_completed, v_orders_cancelled, v_items_cancelled,
    v_payments_count, v_payments_total, v_payments_cash, v_payments_card, v_payments_pay,
    v_service_count, v_service_total, v_low_stock_count, p_notes
  ) RETURNING id INTO v_new_id;

  -- Audit log
  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'create_daily_closing',
    'daily_closings',
    v_new_id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'closing_date', v_closing_date,
      'orders_total', v_orders_total,
      'payments_total', v_payments_total,
      'low_stock_count', v_low_stock_count
    )
  );

  RETURN jsonb_build_object(
    'id', v_new_id,
    'closing_date', v_closing_date,
    'orders_total', v_orders_total,
    'orders_completed', v_orders_completed,
    'orders_cancelled', v_orders_cancelled,
    'items_cancelled', v_items_cancelled,
    'payments_count', v_payments_count,
    'payments_total', v_payments_total,
    'payments_cash', v_payments_cash,
    'payments_card', v_payments_card,
    'payments_pay', v_payments_pay,
    'service_count', v_service_count,
    'service_total', v_service_total,
    'low_stock_count', v_low_stock_count
  );
END;
$$;


ALTER FUNCTION "public"."create_daily_closing"("p_restaurant_id" "uuid", "p_notes" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "quantity" numeric(12,2) DEFAULT 0 NOT NULL,
    "unit" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "current_stock" numeric(12,3) DEFAULT 0,
    "reorder_point" numeric(12,3),
    "cost_per_unit" numeric(12,2),
    "supplier_name" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    CONSTRAINT "inventory_items_quantity_check" CHECK (("quantity" >= (0)::numeric))
);


ALTER TABLE "public"."inventory_items" OWNER TO "postgres";


COMMENT ON TABLE "public"."inventory_items" IS '재고 항목';



COMMENT ON COLUMN "public"."inventory_items"."is_active" IS 'Soft-delete / deactivation flag. Default true. Phase 2 Step 3 (C-01).';



CREATE OR REPLACE FUNCTION "public"."create_inventory_item"("p_restaurant_id" "uuid", "p_name" "text", "p_unit" "text", "p_current_stock" numeric DEFAULT NULL::numeric, "p_reorder_point" numeric DEFAULT NULL::numeric, "p_cost_per_unit" numeric DEFAULT NULL::numeric, "p_supplier_name" "text" DEFAULT NULL::"text") RETURNS "public"."inventory_items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_created public.inventory_items%ROWTYPE;
  v_name TEXT := btrim(COALESCE(p_name, ''));
  v_unit TEXT := btrim(COALESCE(p_unit, ''));
  v_current_stock DECIMAL(12,3) := COALESCE(p_current_stock, 0);
  v_reorder_point DECIMAL(12,3) := p_reorder_point;
  v_cost_per_unit DECIMAL(12,2) := p_cost_per_unit;
  v_supplier_name TEXT := NULLIF(btrim(COALESCE(p_supplier_name, '')), '');
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_WRITE_FORBIDDEN';
  END IF;

  IF v_name = '' THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_NAME_REQUIRED';
  END IF;

  IF v_unit NOT IN ('g', 'ml', 'ea') THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_UNIT_INVALID';
  END IF;

  IF v_current_stock < 0 THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_CURRENT_STOCK_INVALID';
  END IF;

  IF v_reorder_point IS NOT NULL AND v_reorder_point < 0 THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_REORDER_POINT_INVALID';
  END IF;

  IF v_cost_per_unit IS NOT NULL AND v_cost_per_unit < 0 THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_COST_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_items ii
    WHERE ii.restaurant_id = p_restaurant_id
      AND lower(btrim(ii.name)) = lower(v_name)
  ) THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_NAME_DUPLICATE';
  END IF;

  INSERT INTO public.inventory_items (
    restaurant_id,
    name,
    unit,
    current_stock,
    reorder_point,
    cost_per_unit,
    supplier_name,
    updated_at
  )
  VALUES (
    p_restaurant_id,
    v_name,
    v_unit,
    v_current_stock,
    v_reorder_point,
    v_cost_per_unit,
    v_supplier_name,
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_item_created',
    'inventory_items',
    v_created.id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'new_values', jsonb_build_object(
        'name', v_created.name,
        'unit', v_created.unit,
        'current_stock', v_created.current_stock,
        'reorder_point', v_created.reorder_point,
        'cost_per_unit', v_created.cost_per_unit,
        'supplier_name', v_created.supplier_name
      )
    )
  );

  RETURN v_created;
END;
$$;


ALTER FUNCTION "public"."create_inventory_item"("p_restaurant_id" "uuid", "p_name" "text", "p_unit" "text", "p_current_stock" numeric, "p_reorder_point" numeric, "p_cost_per_unit" numeric, "p_supplier_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_inventory_menu_with_recipe"("p_store_id" "uuid", "p_category_id" "uuid" DEFAULT NULL::"uuid", "p_name" "text" DEFAULT NULL::"text", "p_price" numeric DEFAULT 0, "p_description" "text" DEFAULT NULL::"text", "p_recipe_lines" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "public"."menu_items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_menu public.menu_items%ROWTYPE;
  v_line JSONB;
  v_ingredient_id UUID;
  v_quantity_g NUMERIC;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_MENU_CREATE_FORBIDDEN';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_NAME_REQUIRED';
  END IF;

  IF COALESCE(p_price, 0) < 0 THEN
    RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID';
  END IF;

  IF jsonb_typeof(COALESCE(p_recipe_lines, '[]'::JSONB)) <> 'array'
     OR jsonb_array_length(COALESCE(p_recipe_lines, '[]'::JSONB)) = 0 THEN
    RAISE EXCEPTION 'MENU_RECIPE_LINES_REQUIRED';
  END IF;

  IF p_category_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.menu_categories
    WHERE id = p_category_id
      AND restaurant_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  INSERT INTO public.menu_items (
    restaurant_id,
    category_id,
    name,
    description,
    price,
    is_available,
    is_visible_public,
    sort_order,
    created_at,
    updated_at
  ) VALUES (
    p_store_id,
    p_category_id,
    BTRIM(p_name),
    NULLIF(BTRIM(COALESCE(p_description, '')), ''),
    COALESCE(p_price, 0),
    TRUE,
    FALSE,
    0,
    now(),
    now()
  )
  RETURNING * INTO v_menu;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_recipe_lines)
  LOOP
    v_ingredient_id := NULLIF(v_line->>'ingredient_id', '')::UUID;
    v_quantity_g := COALESCE(NULLIF(v_line->>'quantity_g', '')::NUMERIC, 0);

    IF v_ingredient_id IS NULL OR v_quantity_g <= 0 THEN
      RAISE EXCEPTION 'MENU_RECIPE_LINE_INVALID';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.inventory_products ip
      WHERE ip.inventory_item_id = v_ingredient_id
        AND ip.restaurant_id = p_store_id
        AND ip.is_active = TRUE
        AND ip.base_unit = 'g'
    ) THEN
      RAISE EXCEPTION 'MENU_RECIPE_PRODUCT_NOT_FOUND';
    END IF;

    INSERT INTO public.menu_recipes (
      restaurant_id,
      menu_item_id,
      ingredient_id,
      quantity_g,
      updated_at
    ) VALUES (
      p_store_id,
      v_menu.id,
      v_ingredient_id,
      v_quantity_g,
      now()
    );
  END LOOP;

  RETURN v_menu;
END;
$$;


ALTER FUNCTION "public"."create_inventory_menu_with_recipe"("p_store_id" "uuid", "p_category_id" "uuid", "p_name" "text", "p_price" numeric, "p_description" "text", "p_recipe_lines" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_manual_inventory_purchase_order"("p_store_id" "uuid", "p_supplier_id" "uuid", "p_lines" "jsonb", "p_requested_delivery_date" "date" DEFAULT NULL::"date", "p_memo" "text" DEFAULT NULL::"text") RETURNS "public"."inventory_purchase_orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_brand_id UUID;
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_line JSONB;
  v_supplier_item public.inventory_supplier_items%ROWTYPE;
  v_ordered_quantity_unit NUMERIC(12,3);
  v_line_memo TEXT;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_FORBIDDEN';
  END IF;

  IF p_supplier_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_SUPPLIER_REQUIRED';
  END IF;

  IF p_lines IS NULL
     OR jsonb_typeof(p_lines) <> 'array'
     OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_LINES_REQUIRED';
  END IF;

  SELECT brand_id
  INTO v_brand_id
  FROM public.restaurants
  WHERE id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_STORE_NOT_FOUND';
  END IF;

  INSERT INTO public.inventory_purchase_orders (
    purchase_order_no,
    restaurant_id,
    brand_id,
    supplier_id,
    status,
    order_type,
    source,
    requested_delivery_date,
    submitted_by,
    memo
  )
  VALUES (
    'PO-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || upper(substr(replace(gen_random_uuid()::TEXT, '-', ''), 1, 6)),
    p_store_id,
    v_brand_id,
    p_supplier_id,
    'submitted',
    'manual',
    'pos',
    p_requested_delivery_date,
    auth.uid(),
    NULLIF(btrim(COALESCE(p_memo, '')), '')
  )
  RETURNING * INTO v_order;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_ordered_quantity_unit := NULLIF(v_line->>'ordered_quantity_unit', '')::NUMERIC;
    v_line_memo := NULLIF(btrim(COALESCE(v_line->>'memo', '')), '');

    IF v_ordered_quantity_unit IS NULL OR v_ordered_quantity_unit <= 0 THEN
      RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_QUANTITY_INVALID';
    END IF;

    SELECT *
    INTO v_supplier_item
    FROM public.inventory_supplier_items
    WHERE id = NULLIF(v_line->>'supplier_item_id', '')::UUID
      AND supplier_id = p_supplier_id
      AND is_active = TRUE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_SUPPLIER_ITEM_NOT_FOUND';
    END IF;

    v_ordered_quantity_unit := GREATEST(v_ordered_quantity_unit, v_supplier_item.min_order_quantity);

    INSERT INTO public.inventory_purchase_order_lines (
      purchase_order_id,
      product_id,
      supplier_item_id,
      recommended_quantity_base,
      ordered_quantity_base,
      ordered_quantity_unit,
      order_unit,
      unit_price,
      supply_amount,
      tax_amount,
      memo,
      recommendation_snapshot
    )
    VALUES (
      v_order.id,
      v_supplier_item.product_id,
      v_supplier_item.id,
      0,
      v_ordered_quantity_unit * v_supplier_item.order_unit_quantity_base,
      v_ordered_quantity_unit,
      v_supplier_item.order_unit,
      v_supplier_item.unit_price,
      ROUND(v_ordered_quantity_unit * v_supplier_item.unit_price, 2),
      ROUND(v_ordered_quantity_unit * v_supplier_item.unit_price * COALESCE(v_supplier_item.tax_rate, 0) / 100, 2),
      v_line_memo,
      jsonb_build_object(
        'source', 'manual_pos',
        'supplier_item_id', v_supplier_item.id,
        'order_unit_quantity_base', v_supplier_item.order_unit_quantity_base
      )
    );
  END LOOP;

  PERFORM public.recalculate_inventory_purchase_order_totals(v_order.id);

  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = v_order.id;

  RETURN v_order;
END;
$$;


ALTER FUNCTION "public"."create_manual_inventory_purchase_order"("p_store_id" "uuid", "p_supplier_id" "uuid", "p_lines" "jsonb", "p_requested_delivery_date" "date", "p_memo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_order"("p_store_id" "uuid", "p_table_id" "uuid", "p_items" "jsonb") RETURNS "public"."orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_table tables%ROWTYPE;
  v_order orders%ROWTYPE;
  v_item_count int := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  SELECT *
  INTO v_table
  FROM tables
  WHERE id = p_table_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  IF v_table.status = 'occupied' THEN
    RAISE EXCEPTION 'TABLE_ALREADY_OCCUPIED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::int, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    LEFT JOIN menu_items m
      ON m.id = (item->>'menu_item_id')::uuid
     AND m.restaurant_id = p_store_id
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  INSERT INTO orders (restaurant_id, table_id, status, created_by)
  VALUES (p_store_id, p_table_id, 'pending', auth.uid())
  RETURNING * INTO v_order;

  INSERT INTO order_items (
    order_id,
    menu_item_id,
    quantity,
    unit_price,
    label,
    display_name,
    restaurant_id,
    item_type
  )
  SELECT
    v_order.id,
    m.id,
    (item->>'quantity')::int,
    m.price,
    m.name,
    m.name,
    p_store_id,
    'menu_item'
  FROM jsonb_array_elements(p_items) item
  JOIN menu_items m
    ON m.id = (item->>'menu_item_id')::uuid
   AND m.restaurant_id = p_store_id
   AND m.is_available = TRUE;

  GET DIAGNOSTICS v_item_count = ROW_COUNT;

  UPDATE tables
  SET status = 'occupied',
      updated_at = now()
  WHERE id = p_table_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'create_order',
    'orders',
    v_order.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'table_id', p_table_id,
      'item_count', v_item_count,
      'sales_channel', 'dine_in'
    )
  );

  RETURN v_order;
END;
$$;


ALTER FUNCTION "public"."create_order"("p_store_id" "uuid", "p_table_id" "uuid", "p_items" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_purchase_orders_from_recommendation"("p_run_id" "uuid", "p_requested_delivery_date" "date" DEFAULT NULL::"date") RETURNS SETOF "public"."inventory_purchase_orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_run public.inventory_recommendation_runs%ROWTYPE;
  v_supplier_id UUID;
  v_order public.inventory_purchase_orders%ROWTYPE;
BEGIN
  SELECT *
  INTO v_run
  FROM public.inventory_recommendation_runs
  WHERE id = p_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECOMMENDATION_RUN_NOT_FOUND';
  END IF;

  IF NOT public.can_access_inventory_purchase_store(v_run.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;

  FOR v_supplier_id IN
    SELECT DISTINCT supplier_id
    FROM public.inventory_recommendation_lines
    WHERE run_id = p_run_id
      AND supplier_id IS NOT NULL
      AND recommended_order_units > 0
  LOOP
    INSERT INTO public.inventory_purchase_orders (
      purchase_order_no,
      restaurant_id,
      brand_id,
      supplier_id,
      status,
      order_type,
      source,
      requested_delivery_date,
      submitted_by
    )
    VALUES (
      'PO-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || upper(substr(replace(gen_random_uuid()::TEXT, '-', ''), 1, 6)),
      v_run.restaurant_id,
      v_run.brand_id,
      v_supplier_id,
      'submitted',
      'recommended',
      'pos',
      p_requested_delivery_date,
      auth.uid()
    )
    RETURNING * INTO v_order;

    INSERT INTO public.inventory_purchase_order_lines (
      purchase_order_id,
      product_id,
      supplier_item_id,
      recommended_quantity_base,
      ordered_quantity_base,
      ordered_quantity_unit,
      order_unit,
      unit_price,
      supply_amount,
      tax_amount,
      recommendation_snapshot
    )
    SELECT
      v_order.id,
      rl.product_id,
      isi.id,
      rl.recommended_quantity_base,
      rl.recommended_order_units * isi.order_unit_quantity_base,
      rl.recommended_order_units,
      isi.order_unit,
      isi.unit_price,
      ROUND(rl.recommended_order_units * isi.unit_price, 2),
      ROUND(rl.recommended_order_units * isi.unit_price * COALESCE(isi.tax_rate, 0) / 100, 2),
      jsonb_build_object(
        'run_id', p_run_id,
        'current_stock_base', rl.current_stock_base,
        'avg_daily_consumption_base', rl.avg_daily_consumption_base,
        'target_stock_days', rl.target_stock_days,
        'recommended_quantity_base', rl.recommended_quantity_base,
        'recommended_order_units', rl.recommended_order_units,
        'estimated_days_remaining', rl.estimated_days_remaining,
        'risk_status', rl.risk_status
      )
    FROM public.inventory_recommendation_lines rl
    JOIN public.inventory_supplier_items isi
      ON isi.product_id = rl.product_id
     AND isi.supplier_id = rl.supplier_id
     AND isi.is_active = TRUE
    WHERE rl.run_id = p_run_id
      AND rl.supplier_id = v_supplier_id
      AND rl.recommended_order_units > 0;

    PERFORM public.recalculate_inventory_purchase_order_totals(v_order.id);

    SELECT *
    INTO v_order
    FROM public.inventory_purchase_orders
    WHERE id = v_order.id;

    RETURN NEXT v_order;
  END LOOP;

  RETURN;
END;
$$;


ALTER FUNCTION "public"."create_purchase_orders_from_recommendation"("p_run_id" "uuid", "p_requested_delivery_date" "date") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."qc_followups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "source_check_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "assigned_to_name" "text",
    "resolution_notes" "text",
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_at" timestamp with time zone,
    CONSTRAINT "qc_followups_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'in_progress'::"text", 'resolved'::"text"])))
);


ALTER TABLE "public"."qc_followups" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_qc_followup"("p_restaurant_id" "uuid", "p_source_check_id" "uuid", "p_assigned_to_name" "text" DEFAULT NULL::"text") RETURNS "public"."qc_followups"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor      public.users%ROWTYPE;
  v_check      public.qc_checks%ROWTYPE;
  v_created    public.qc_followups%ROWTYPE;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN';
  END IF;

  SELECT * INTO v_check
  FROM public.qc_checks
  WHERE id = p_source_check_id
    AND restaurant_id = p_restaurant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_CHECK_NOT_FOUND';
  END IF;

  IF v_check.result <> 'fail' THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_NOT_FAILED_CHECK';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.qc_followups
    WHERE source_check_id = p_source_check_id
  ) THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_ALREADY_EXISTS';
  END IF;

  INSERT INTO public.qc_followups (
    restaurant_id, source_check_id, status,
    assigned_to_name, created_by
  ) VALUES (
    p_restaurant_id, p_source_check_id, 'open',
    NULLIF(btrim(COALESCE(p_assigned_to_name, '')), ''),
    auth.uid()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_followup_created',
    'qc_followups',
    v_created.id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'source_check_id', p_source_check_id,
      'assigned_to_name', v_created.assigned_to_name
    )
  );

  RETURN v_created;
END;
$$;


ALTER FUNCTION "public"."create_qc_followup"("p_restaurant_id" "uuid", "p_source_check_id" "uuid", "p_assigned_to_name" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."qc_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid",
    "category" "text" NOT NULL,
    "criteria_text" "text" NOT NULL,
    "criteria_photo_url" "text",
    "sort_order" integer DEFAULT 0,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_global" boolean DEFAULT false NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "qsc_domain" "text",
    "requires_photo" boolean DEFAULT true NOT NULL,
    "required_photo_count" integer DEFAULT 1 NOT NULL,
    "weight" numeric(5,2) DEFAULT 1 NOT NULL,
    "sort_group" "text",
    "is_sv_required" boolean DEFAULT false NOT NULL,
    CONSTRAINT "qc_global_check" CHECK (((("is_global" = true) AND ("restaurant_id" IS NULL)) OR (("is_global" = false) AND ("restaurant_id" IS NOT NULL)))),
    CONSTRAINT "qc_templates_qsc_domain_check" CHECK ((("qsc_domain" IS NULL) OR ("qsc_domain" = ANY (ARRAY['quality'::"text", 'service'::"text", 'cleanliness'::"text"])))),
    CONSTRAINT "qc_templates_required_photo_count_check" CHECK (("required_photo_count" >= 0)),
    CONSTRAINT "qc_templates_weight_positive_check" CHECK (("weight" > (0)::numeric))
);


ALTER TABLE "public"."qc_templates" OWNER TO "postgres";


COMMENT ON COLUMN "public"."qc_templates"."qsc_domain" IS 'Upper QSC domain for the template: quality, service, cleanliness. Nullable in Wave 1 until category-to-domain mapping is confirmed.';



COMMENT ON COLUMN "public"."qc_templates"."requires_photo" IS 'Whether evidence photos are required for this template in QSC v2.';



COMMENT ON COLUMN "public"."qc_templates"."required_photo_count" IS 'Minimum number of evidence photos expected for this template.';



COMMENT ON COLUMN "public"."qc_templates"."weight" IS 'Weight used for QSC score calculation.';



COMMENT ON COLUMN "public"."qc_templates"."sort_group" IS 'Optional grouping key for mobile and admin presentation.';



COMMENT ON COLUMN "public"."qc_templates"."is_sv_required" IS 'Whether SV review is required for checks created from this template.';



CREATE OR REPLACE FUNCTION "public"."create_qc_template"("p_category" "text", "p_criteria_text" "text", "p_store_id" "uuid" DEFAULT NULL::"uuid", "p_criteria_photo_url" "text" DEFAULT NULL::"text", "p_sort_order" integer DEFAULT 0, "p_is_global" boolean DEFAULT false, "p_qsc_domain" "text" DEFAULT NULL::"text", "p_requires_photo" boolean DEFAULT true, "p_required_photo_count" integer DEFAULT 1, "p_weight" numeric DEFAULT 1, "p_sort_group" "text" DEFAULT NULL::"text", "p_is_sv_required" boolean DEFAULT false) RETURNS "public"."qc_templates"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_created public.qc_templates%ROWTYPE;
  v_category TEXT := NULLIF(btrim(COALESCE(p_category, '')), '');
  v_criteria TEXT := NULLIF(btrim(COALESCE(p_criteria_text, '')), '');
  v_photo TEXT := NULLIF(btrim(COALESCE(p_criteria_photo_url, '')), '');
  v_qsc_domain TEXT := NULLIF(lower(btrim(COALESCE(p_qsc_domain, ''))), '');
  v_sort_group TEXT := NULLIF(btrim(COALESCE(p_sort_group, '')), '');
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  IF v_category IS NULL THEN
    RAISE EXCEPTION 'QC_TEMPLATE_CATEGORY_REQUIRED';
  END IF;

  IF v_criteria IS NULL THEN
    RAISE EXCEPTION 'QC_TEMPLATE_TEXT_REQUIRED';
  END IF;

  IF p_sort_order IS NULL OR p_sort_order < 0 THEN
    RAISE EXCEPTION 'QC_TEMPLATE_SORT_INVALID';
  END IF;

  IF v_qsc_domain IS NOT NULL
     AND v_qsc_domain NOT IN ('quality', 'service', 'cleanliness') THEN
    RAISE EXCEPTION 'QC_TEMPLATE_QSC_DOMAIN_INVALID';
  END IF;

  IF p_required_photo_count IS NULL OR p_required_photo_count < 0 THEN
    RAISE EXCEPTION 'QC_TEMPLATE_REQUIRED_PHOTO_COUNT_INVALID';
  END IF;

  IF p_weight IS NULL OR p_weight <= 0 THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WEIGHT_INVALID';
  END IF;

  IF p_is_global THEN
    IF v_actor.role <> 'super_admin' THEN
      RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
    END IF;
  ELSE
    IF p_store_id IS NULL THEN
      RAISE EXCEPTION 'QC_TEMPLATE_RESTAURANT_REQUIRED';
    END IF;

    IF v_actor.role <> 'super_admin'
       AND NOT EXISTS (
         SELECT 1
         FROM public.user_accessible_stores(auth.uid()) s(store_id)
         WHERE s.store_id = p_store_id
       ) THEN
      RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
    END IF;
  END IF;

  INSERT INTO public.qc_templates (
    restaurant_id,
    category,
    criteria_text,
    criteria_photo_url,
    sort_order,
    is_global,
    updated_at,
    qsc_domain,
    requires_photo,
    required_photo_count,
    weight,
    sort_group,
    is_sv_required
  )
  VALUES (
    CASE WHEN p_is_global THEN NULL ELSE p_store_id END,
    v_category,
    v_criteria,
    v_photo,
    p_sort_order,
    p_is_global,
    now(),
    v_qsc_domain,
    COALESCE(p_requires_photo, TRUE),
    p_required_photo_count,
    p_weight,
    v_sort_group,
    COALESCE(p_is_sv_required, FALSE)
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_template_created',
    'qc_templates',
    v_created.id,
    jsonb_build_object(
      'store_id', v_created.restaurant_id,
      'is_global', v_created.is_global,
      'category', v_created.category,
      'criteria_text', v_created.criteria_text,
      'criteria_photo_url', v_created.criteria_photo_url,
      'sort_order', v_created.sort_order,
      'qsc_domain', v_created.qsc_domain,
      'requires_photo', v_created.requires_photo,
      'required_photo_count', v_created.required_photo_count,
      'weight', v_created.weight,
      'sort_group', v_created.sort_group,
      'is_sv_required', v_created.is_sv_required
    )
  );

  RETURN v_created;
END;
$$;


ALTER FUNCTION "public"."create_qc_template"("p_category" "text", "p_criteria_text" "text", "p_store_id" "uuid", "p_criteria_photo_url" "text", "p_sort_order" integer, "p_is_global" boolean, "p_qsc_domain" "text", "p_requires_photo" boolean, "p_required_photo_count" integer, "p_weight" numeric, "p_sort_group" "text", "p_is_sv_required" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."custom_access_token_hook"("event" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_uid            uuid;
  v_user           public.users%ROWTYPE;
  v_brand_ids      uuid[];
  v_store_ids      uuid[];
  v_tax_entity_ids uuid[];
  v_primary_store  uuid;
BEGIN
  v_uid := (event->>'user_id')::uuid;

  SELECT *
  INTO v_user
  FROM public.users
  WHERE auth_id = v_uid
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN event;
  END IF;

  v_brand_ids      := ARRAY(SELECT * FROM public.user_accessible_brands(v_uid));
  v_store_ids      := ARRAY(SELECT * FROM public.user_accessible_stores(v_uid));
  v_tax_entity_ids := ARRAY(SELECT * FROM public.user_accessible_tax_entities(v_uid));
  v_primary_store  := COALESCE(v_user.primary_store_id, v_user.restaurant_id);

  event := jsonb_set(
    event,
    '{claims,app_metadata,role}',
    to_jsonb(v_user.role),
    true
  );
  event := jsonb_set(
    event,
    '{claims,app_metadata,brand_ids}',
    to_jsonb(COALESCE(v_brand_ids, ARRAY[]::uuid[])),
    true
  );
  event := jsonb_set(
    event,
    '{claims,app_metadata,accessible_store_ids}',
    to_jsonb(COALESCE(v_store_ids, ARRAY[]::uuid[])),
    true
  );
  event := jsonb_set(
    event,
    '{claims,app_metadata,accessible_tax_entity_ids}',
    to_jsonb(COALESCE(v_tax_entity_ids, ARRAY[]::uuid[])),
    true
  );
  event := jsonb_set(
    event,
    '{claims,app_metadata,primary_store_id}',
    to_jsonb(v_primary_store),
    true
  );

  RETURN event;
END;
$$;


ALTER FUNCTION "public"."custom_access_token_hook"("event" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") IS 'Supabase custom access token hook. Populates app_metadata claims: role, brand_ids[], accessible_store_ids[], accessible_tax_entity_ids[], primary_store_id. Register in Dashboard hooks. Existing table-lookup fallback remains available during transition.';



CREATE OR REPLACE FUNCTION "public"."deactivate_qc_template"("p_template_id" "uuid") RETURNS "public"."qc_templates"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_existing public.qc_templates%ROWTYPE;
  v_updated public.qc_templates%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  SELECT qt.*
  INTO v_existing
  FROM public.qc_templates qt
  WHERE qt.id = p_template_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_TEMPLATE_NOT_FOUND';
  END IF;

  IF v_existing.is_global AND v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  IF NOT v_existing.is_global
     AND v_actor.role <> 'super_admin'
     AND v_existing.restaurant_id <> v_actor.restaurant_id THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  UPDATE public.qc_templates
  SET is_active = FALSE,
      updated_at = now()
  WHERE id = p_template_id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_template_deactivated',
    'qc_templates',
    v_updated.id,
    jsonb_build_object(
      'restaurant_id', v_updated.restaurant_id,
      'is_global', v_updated.is_global
    )
  );

  RETURN v_updated;
END;
$$;


ALTER FUNCTION "public"."deactivate_qc_template"("p_template_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_inventory_recipe_line"("p_store_id" "uuid", "p_recipe_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_deleted_id UUID;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_DELETE_FORBIDDEN';
  END IF;

  DELETE FROM public.menu_recipes
  WHERE id = p_recipe_id
    AND restaurant_id = p_store_id
  RETURNING id INTO v_deleted_id;

  IF v_deleted_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_NOT_FOUND';
  END IF;

  RETURN v_deleted_id;
END;
$$;


ALTER FUNCTION "public"."delete_inventory_recipe_line"("p_store_id" "uuid", "p_recipe_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."edit_order_item_quantity"("p_item_id" "uuid", "p_restaurant_id" "uuid", "p_new_quantity" integer) RETURNS "public"."order_items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_item order_items%ROWTYPE;
  v_order_status TEXT;
  v_old_quantity INT;
BEGIN
  -- Actor validation
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  -- Validate quantity
  IF p_new_quantity IS NULL OR p_new_quantity < 1 THEN
    RAISE EXCEPTION 'INVALID_QUANTITY';
  END IF;

  -- Lock item
  SELECT *
  INTO v_item
  FROM order_items
  WHERE id = p_item_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  -- Check order is mutable
  SELECT status
  INTO v_order_status
  FROM orders
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  -- Only pending items can be quantity-edited
  IF v_item.status <> 'pending' THEN
    RAISE EXCEPTION 'ITEM_NOT_EDITABLE';
  END IF;

  v_old_quantity := v_item.quantity;

  -- No-op if same quantity
  IF v_old_quantity = p_new_quantity THEN
    RETURN v_item;
  END IF;

  UPDATE order_items
  SET quantity = p_new_quantity
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  UPDATE orders
  SET updated_at = now()
  WHERE id = v_item.order_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'edit_order_item_quantity',
    'order_items',
    p_item_id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'order_id', v_item.order_id,
      'label', v_item.label,
      'old_quantity', v_old_quantity,
      'new_quantity', p_new_quantity
    )
  );

  RETURN v_item;
END;
$$;


ALTER FUNCTION "public"."edit_order_item_quantity"("p_item_id" "uuid", "p_restaurant_id" "uuid", "p_new_quantity" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_uuidv7"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  ts_ms   bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  rand_b  bytea  := extensions.gen_random_bytes(10);
  g1      text;
  g2      text;
  g3      text;
  vbyte   int;
  g4      text;
  g5      text;
BEGIN
  g1 := lpad(to_hex((ts_ms >> 16) & x'ffffffff'::bigint), 8, '0');
  g2 := lpad(to_hex(ts_ms & x'ffff'::bigint), 4, '0');
  g3 := '7' || substr(encode(rand_b, 'hex'), 1, 3);
  vbyte := (get_byte(rand_b, 2) & x'3f'::int) | x'80'::int;
  g4 := lpad(to_hex(vbyte), 2, '0') || substr(encode(rand_b, 'hex'), 7, 2);
  g5 := substr(encode(rand_b, 'hex'), 9, 12);
  RETURN g1 || '-' || g2 || '-' || g3 || '-' || g4 || '-' || g5;
END;
$$;


ALTER FUNCTION "public"."generate_uuidv7"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."generate_uuidv7"() IS 'Generates UUIDv7-format string (version nibble=7, RFC 4122 variant). Used for einvoice_jobs.ref_id (Invariant I8).';



CREATE OR REPLACE FUNCTION "public"."get_admin_mutation_audit_trace"("p_restaurant_id" "uuid", "p_limit" integer DEFAULT 10) RETURNS TABLE("audit_log_id" "uuid", "created_at" timestamp with time zone, "action" "text", "entity_type" "text", "entity_id" "uuid", "actor_id" "uuid", "actor_name" "text", "changed_fields" "jsonb", "old_values" "jsonb", "new_values" "jsonb")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
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
      ARRAY[
        'restaurants', 'tables', 'menu_categories', 'menu_items',
        'orders', 'order_items', 'payments'
      ]
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
        -- admin mutations (existing)
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
        'admin_delete_menu_item',
        -- order lifecycle (new)
        'create_order',
        'create_buffet_order',
        'add_items_to_order',
        'cancel_order',
        'cancel_order_item',
        'edit_order_item_quantity',
        'transfer_order_table',
        'process_payment',
        'update_order_item_status'
      ]
    )
  ORDER BY al.created_at DESC
  LIMIT v_limit;
END;
$$;


ALTER FUNCTION "public"."get_admin_mutation_audit_trace"("p_restaurant_id" "uuid", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_admin_today_summary"("p_restaurant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_today_start TIMESTAMPTZ;
  v_result JSONB;
  v_orders_pending INT;
  v_orders_confirmed INT;
  v_orders_serving INT;
  v_orders_completed INT;
  v_orders_cancelled INT;
  v_items_cancelled INT;
  v_payments_count INT;
  v_payments_total NUMERIC;
  v_payments_cash NUMERIC;
  v_payments_card NUMERIC;
  v_tables_total INT;
  v_tables_occupied INT;
  v_low_stock_count INT;
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'TODAY_SUMMARY_RESTAURANT_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'TODAY_SUMMARY_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'TODAY_SUMMARY_FORBIDDEN';
  END IF;

  -- Use Vietnam timezone for "today"
  v_today_start := (NOW() AT TIME ZONE 'Asia/Ho_Chi_Minh')::DATE::TIMESTAMPTZ;

  -- Order counts by status
  SELECT
    COALESCE(SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'confirmed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'serving' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END), 0)
  INTO v_orders_pending, v_orders_confirmed, v_orders_serving,
       v_orders_completed, v_orders_cancelled
  FROM public.orders
  WHERE restaurant_id = p_restaurant_id
    AND created_at >= v_today_start;

  -- Cancelled order items today
  SELECT COALESCE(COUNT(*), 0)
  INTO v_items_cancelled
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE o.restaurant_id = p_restaurant_id
    AND oi.status = 'cancelled'
    AND o.created_at >= v_today_start;

  -- Payment counts and totals (revenue only)
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'cash' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) <> 'cash' THEN amount ELSE 0 END), 0)
  INTO v_payments_count, v_payments_total, v_payments_cash, v_payments_card
  FROM public.payments
  WHERE restaurant_id = p_restaurant_id
    AND is_revenue = TRUE
    AND created_at >= v_today_start;

  -- Table occupancy snapshot (live, not time-filtered)
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(CASE WHEN status = 'occupied' THEN 1 ELSE 0 END), 0)
  INTO v_tables_total, v_tables_occupied
  FROM public.tables
  WHERE restaurant_id = p_restaurant_id;

  -- Live low-stock count.
  -- NOTE: inventory_items has no is_active column; filter only on
  -- reorder_point and current_stock which exist since inventory_v2.
  SELECT COALESCE(COUNT(*), 0)
  INTO v_low_stock_count
  FROM public.inventory_items
  WHERE restaurant_id = p_restaurant_id
    AND reorder_point IS NOT NULL
    AND current_stock <= reorder_point;

  v_result := jsonb_build_object(
    'orders_pending', v_orders_pending,
    'orders_confirmed', v_orders_confirmed,
    'orders_serving', v_orders_serving,
    'orders_completed', v_orders_completed,
    'orders_cancelled', v_orders_cancelled,
    'orders_total', v_orders_pending + v_orders_confirmed + v_orders_serving + v_orders_completed + v_orders_cancelled,
    'items_cancelled', v_items_cancelled,
    'payments_count', v_payments_count,
    'payments_total', v_payments_total,
    'payments_cash', v_payments_cash,
    'payments_card', v_payments_card,
    'tables_total', v_tables_total,
    'tables_occupied', v_tables_occupied,
    'low_stock_count', v_low_stock_count
  );

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."get_admin_today_summary"("p_restaurant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_attendance_log_view"("p_store_id" "uuid", "p_from" timestamp with time zone, "p_to" timestamp with time zone, "p_user_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("attendance_log_id" "uuid", "restaurant_id" "uuid", "user_id" "uuid", "user_full_name" "text", "user_role" "text", "attendance_type" "text", "photo_url" "text", "photo_thumbnail_url" "text", "logged_at" timestamp with time zone, "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'admin',
    'store_admin',
    'brand_admin',
    'super_admin',
    'photo_objet_master',
    'photo_objet_store_admin'
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_VIEW_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_VIEW_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_RANGE_REQUIRED';
  END IF;

  IF p_from > p_to THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_RANGE_INVALID';
  END IF;

  IF p_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = p_user_id
      AND u.restaurant_id = p_store_id
      AND u.is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_USER_NOT_FOUND';
  END IF;

  RETURN QUERY
  SELECT
    al.id AS attendance_log_id,
    al.restaurant_id,
    al.user_id,
    u.full_name AS user_full_name,
    u.role AS user_role,
    al.type AS attendance_type,
    al.photo_url,
    al.photo_thumbnail_url,
    al.logged_at,
    al.created_at
  FROM public.attendance_logs al
  JOIN public.users u
    ON u.id = al.user_id
   AND u.restaurant_id = al.restaurant_id
  WHERE al.restaurant_id = p_store_id
    AND al.logged_at >= p_from
    AND al.logged_at <= p_to
    AND (p_user_id IS NULL OR al.user_id = p_user_id)
  ORDER BY al.logged_at DESC, al.created_at DESC;
END;
$$;


ALTER FUNCTION "public"."get_attendance_log_view"("p_store_id" "uuid", "p_from" timestamp with time zone, "p_to" timestamp with time zone, "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_attendance_staff_directory"("p_store_id" "uuid") RETURNS TABLE("user_id" "uuid", "full_name" "text", "role" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ATTENDANCE_STAFF_DIRECTORY_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ATTENDANCE_STAFF_DIRECTORY_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    u.id AS user_id,
    u.full_name,
    u.role
  FROM public.users u
  WHERE u.restaurant_id = p_store_id
    AND u.is_active = TRUE
    AND u.role IN ('admin', 'waiter', 'kitchen', 'cashier')
  ORDER BY lower(u.full_name), u.created_at;
END;
$$;


ALTER FUNCTION "public"."get_attendance_staff_directory"("p_store_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_cashier_today_summary"("p_restaurant_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_today_start TIMESTAMPTZ;
  v_result JSONB;
  v_payments_count INT;
  v_payments_total NUMERIC;
  v_payments_cash NUMERIC;
  v_payments_card NUMERIC;
  v_payments_pay NUMERIC;
  v_service_count INT;
  v_service_total NUMERIC;
  v_orders_completed INT;
  v_orders_cancelled INT;
  v_orders_active INT;
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'CASHIER_SUMMARY_RESTAURANT_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'CASHIER_SUMMARY_FORBIDDEN';
  END IF;

  IF v_actor.role NOT IN ('admin', 'super_admin')
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'CASHIER_SUMMARY_FORBIDDEN';
  END IF;

  -- Use Vietnam timezone for "today"
  v_today_start := (NOW() AT TIME ZONE 'Asia/Ho_Chi_Minh')::DATE::TIMESTAMPTZ;

  -- Revenue payments (is_revenue = true)
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'cash' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'card' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) NOT IN ('cash', 'card') THEN amount ELSE 0 END), 0)
  INTO v_payments_count, v_payments_total, v_payments_cash, v_payments_card, v_payments_pay
  FROM public.payments
  WHERE restaurant_id = p_restaurant_id
    AND is_revenue = TRUE
    AND created_at >= v_today_start;

  -- Service payments (is_revenue = false)
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0)
  INTO v_service_count, v_service_total
  FROM public.payments
  WHERE restaurant_id = p_restaurant_id
    AND is_revenue = FALSE
    AND created_at >= v_today_start;

  -- Order status counts for today
  SELECT
    COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status NOT IN ('completed', 'cancelled') THEN 1 ELSE 0 END), 0)
  INTO v_orders_completed, v_orders_cancelled, v_orders_active
  FROM public.orders
  WHERE restaurant_id = p_restaurant_id
    AND created_at >= v_today_start;

  v_result := jsonb_build_object(
    'payments_count', v_payments_count,
    'payments_total', v_payments_total,
    'payments_cash', v_payments_cash,
    'payments_card', v_payments_card,
    'payments_pay', v_payments_pay,
    'service_count', v_service_count,
    'service_total', v_service_total,
    'orders_completed', v_orders_completed,
    'orders_cancelled', v_orders_cancelled,
    'orders_active', v_orders_active
  );

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."get_cashier_today_summary"("p_restaurant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_daily_closings"("p_restaurant_id" "uuid", "p_limit" integer DEFAULT 30) RETURNS TABLE("closing_id" "uuid", "closing_date" "date", "closed_by_name" "text", "orders_total" integer, "orders_completed" integer, "orders_cancelled" integer, "items_cancelled" integer, "payments_count" integer, "payments_total" numeric, "payments_cash" numeric, "payments_card" numeric, "payments_pay" numeric, "service_count" integer, "service_total" numeric, "low_stock_count" integer, "notes" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_limit INT := LEAST(GREATEST(COALESCE(p_limit, 30), 1), 90);
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'DAILY_CLOSINGS_RESTAURANT_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'DAILY_CLOSINGS_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'DAILY_CLOSINGS_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    dc.id AS closing_id,
    dc.closing_date,
    COALESCE(u.full_name, '알 수 없음') AS closed_by_name,
    dc.orders_total,
    dc.orders_completed,
    dc.orders_cancelled,
    dc.items_cancelled,
    dc.payments_count,
    dc.payments_total,
    dc.payments_cash,
    dc.payments_card,
    dc.payments_pay,
    dc.service_count,
    dc.service_total,
    dc.low_stock_count,
    dc.notes,
    dc.created_at
  FROM daily_closings dc
  LEFT JOIN public.users u ON u.auth_id = dc.closed_by
  WHERE dc.restaurant_id = p_restaurant_id
  ORDER BY dc.closing_date DESC
  LIMIT v_limit;
END;
$$;


ALTER FUNCTION "public"."get_daily_closings"("p_restaurant_id" "uuid", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_inventory_cost_analysis"("p_store_id" "uuid", "p_from" "date" DEFAULT (CURRENT_DATE - 6), "p_to" "date" DEFAULT CURRENT_DATE) RETURNS TABLE("product_id" "uuid", "product_name" "text", "category" "text", "consumed_quantity_base" numeric, "consumed_amount" numeric, "avg_unit_cost" numeric, "preferred_unit_cost" numeric, "cost_status" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_COST_ANALYSIS_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RAISE EXCEPTION 'INVENTORY_COST_ANALYSIS_DATE_RANGE_INVALID';
  END IF;

  RETURN QUERY
  WITH consumption AS (
    SELECT
      idc.product_id,
      SUM(idc.consumed_quantity_base)::NUMERIC(12,3) AS consumed_quantity_base,
      SUM(idc.consumed_amount)::NUMERIC(12,2) AS consumed_amount
    FROM public.inventory_daily_consumption idc
    WHERE idc.restaurant_id = p_store_id
      AND idc.consumption_date BETWEEN p_from AND p_to
    GROUP BY idc.product_id
  ),
  supplier_cost AS (
    SELECT DISTINCT ON (isi.product_id)
      isi.product_id,
      ROUND(
        isi.unit_price / NULLIF(isi.order_unit_quantity_base, 0),
        4
      ) AS preferred_unit_cost
    FROM public.inventory_supplier_items isi
    WHERE isi.is_active = TRUE
      AND isi.order_unit_quantity_base > 0
    ORDER BY isi.product_id, isi.is_preferred DESC, isi.updated_at DESC
  )
  SELECT
    ip.id AS product_id,
    ip.name AS product_name,
    COALESCE(ip.category, '-') AS category,
    COALESCE(c.consumed_quantity_base, 0)::NUMERIC(12,3),
    COALESCE(c.consumed_amount, 0)::NUMERIC(12,2),
    CASE
      WHEN COALESCE(c.consumed_quantity_base, 0) <= 0 THEN 0
      ELSE ROUND(c.consumed_amount / c.consumed_quantity_base, 4)
    END AS avg_unit_cost,
    COALESCE(sc.preferred_unit_cost, 0)::NUMERIC(12,4),
    CASE
      WHEN COALESCE(c.consumed_amount, 0) = 0 THEN 'stable'
      WHEN sc.preferred_unit_cost IS NULL THEN 'missing_supplier_cost'
      WHEN c.consumed_amount / NULLIF(c.consumed_quantity_base, 0) > sc.preferred_unit_cost * 1.1 THEN 'warning'
      ELSE 'normal'
    END AS cost_status
  FROM public.inventory_products ip
  LEFT JOIN consumption c
    ON c.product_id = ip.id
  LEFT JOIN supplier_cost sc
    ON sc.product_id = ip.id
  WHERE ip.restaurant_id = p_store_id
    AND ip.is_active = TRUE
  ORDER BY COALESCE(c.consumed_amount, 0) DESC, lower(ip.name);
END;
$$;


ALTER FUNCTION "public"."get_inventory_cost_analysis"("p_store_id" "uuid", "p_from" "date", "p_to" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_inventory_ingredient_catalog"("p_store_id" "uuid") RETURNS TABLE("id" "uuid", "restaurant_id" "uuid", "name" "text", "unit" "text", "current_stock" numeric, "reorder_point" numeric, "cost_per_unit" numeric, "supplier_name" "text", "needs_reorder" boolean, "last_updated" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'admin',
    'store_admin',
    'brand_admin',
    'super_admin',
    'photo_objet_master',
    'photo_objet_store_admin'
  ) THEN
    RAISE EXCEPTION 'INVENTORY_CATALOG_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'INVENTORY_CATALOG_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    ii.id,
    ii.restaurant_id,
    ii.name,
    ii.unit,
    ii.current_stock,
    ii.reorder_point,
    ii.cost_per_unit,
    ii.supplier_name,
    CASE
      WHEN ii.reorder_point IS NOT NULL AND ii.current_stock <= ii.reorder_point
        THEN TRUE
      ELSE FALSE
    END AS needs_reorder,
    ii.updated_at AS last_updated
  FROM public.inventory_items ii
  WHERE ii.restaurant_id = p_store_id
  ORDER BY lower(ii.name), ii.created_at;
END;
$$;


ALTER FUNCTION "public"."get_inventory_ingredient_catalog"("p_store_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_inventory_physical_count_sheet"("p_restaurant_id" "uuid", "p_count_date" "date") RETURNS TABLE("ingredient_id" "uuid", "ingredient_name" "text", "ingredient_unit" "text", "theoretical_quantity_g" numeric, "actual_quantity_g" numeric, "variance_quantity_g" numeric, "count_date" "date", "last_updated" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_FORBIDDEN';
  END IF;

  IF p_count_date IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_DATE_REQUIRED';
  END IF;

  RETURN QUERY
  SELECT
    ii.id AS ingredient_id,
    ii.name AS ingredient_name,
    ii.unit AS ingredient_unit,
    ii.current_stock AS theoretical_quantity_g,
    ipc.actual_quantity_g,
    ipc.variance_g AS variance_quantity_g,
    p_count_date AS count_date,
    COALESCE(ipc.updated_at, ipc.created_at, ii.updated_at) AS last_updated
  FROM public.inventory_items ii
  LEFT JOIN public.inventory_physical_counts ipc
    ON ipc.restaurant_id = p_restaurant_id
   AND ipc.ingredient_id = ii.id
   AND ipc.count_date = p_count_date
  WHERE ii.restaurant_id = p_restaurant_id
  ORDER BY lower(ii.name), ii.created_at;
END;
$$;


ALTER FUNCTION "public"."get_inventory_physical_count_sheet"("p_restaurant_id" "uuid", "p_count_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_inventory_purchase_dashboard"("p_store_id" "uuid" DEFAULT NULL::"uuid", "p_brand_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_scope_store_ids UUID[];
  v_total_inventory_amount NUMERIC(12,2);
  v_submitted_purchase_amount NUMERIC(12,2);
  v_approved_purchase_amount NUMERIC(12,2);
  v_low_stock_count INT;
BEGIN
  SELECT ARRAY_AGG(r.id)
  INTO v_scope_store_ids
  FROM public.restaurants r
  WHERE (p_store_id IS NULL OR r.id = p_store_id)
    AND (p_brand_id IS NULL OR r.brand_id = p_brand_id)
    AND public.can_access_inventory_purchase_store(r.id);

  IF v_scope_store_ids IS NULL OR array_length(v_scope_store_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;

  SELECT COALESCE(SUM(COALESCE(ii.current_stock, 0) * COALESCE(ii.cost_per_unit, 0)), 0)
  INTO v_total_inventory_amount
  FROM public.inventory_products ip
  LEFT JOIN public.inventory_items ii
    ON ii.id = ip.inventory_item_id
   AND ii.restaurant_id = ip.restaurant_id
  WHERE ip.restaurant_id = ANY(v_scope_store_ids)
    AND ip.is_active = TRUE;

  SELECT COALESCE(SUM(total_amount) FILTER (WHERE status = 'submitted'), 0),
         COALESCE(SUM(total_amount) FILTER (WHERE status = 'office_approved'), 0)
  INTO v_submitted_purchase_amount, v_approved_purchase_amount
  FROM public.inventory_purchase_orders
  WHERE restaurant_id = ANY(v_scope_store_ids);

  SELECT COUNT(*)::INT
  INTO v_low_stock_count
  FROM public.get_inventory_stock_status(COALESCE(p_store_id, v_scope_store_ids[1]), CURRENT_DATE)
  WHERE risk_status IN ('danger', 'warning');

  RETURN jsonb_build_object(
    'store_count', array_length(v_scope_store_ids, 1),
    'total_inventory_amount', v_total_inventory_amount,
    'submitted_purchase_amount', v_submitted_purchase_amount,
    'approved_purchase_amount', v_approved_purchase_amount,
    'low_stock_count', v_low_stock_count
  );
END;
$$;


ALTER FUNCTION "public"."get_inventory_purchase_dashboard"("p_store_id" "uuid", "p_brand_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_inventory_recipe_catalog"("p_restaurant_id" "uuid", "p_menu_item_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("recipe_id" "uuid", "restaurant_id" "uuid", "menu_item_id" "uuid", "menu_item_name" "text", "ingredient_id" "uuid", "ingredient_name" "text", "ingredient_unit" "text", "quantity_g" numeric, "last_updated" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_FORBIDDEN';
  END IF;

  IF p_menu_item_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.menu_items mi
    WHERE mi.id = p_menu_item_id
      AND mi.restaurant_id = p_restaurant_id
  ) THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_MENU_ITEM_NOT_FOUND';
  END IF;

  RETURN QUERY
  SELECT
    mr.id AS recipe_id,
    mr.restaurant_id,
    mr.menu_item_id,
    mi.name AS menu_item_name,
    mr.ingredient_id,
    ii.name AS ingredient_name,
    ii.unit AS ingredient_unit,
    mr.quantity_g,
    mr.updated_at AS last_updated
  FROM public.menu_recipes mr
  JOIN public.menu_items mi
    ON mi.id = mr.menu_item_id
   AND mi.restaurant_id = mr.restaurant_id
  JOIN public.inventory_items ii
    ON ii.id = mr.ingredient_id
   AND ii.restaurant_id = mr.restaurant_id
  WHERE mr.restaurant_id = p_restaurant_id
    AND (p_menu_item_id IS NULL OR mr.menu_item_id = p_menu_item_id)
  ORDER BY lower(mi.name), lower(ii.name), mr.created_at;
END;
$$;


ALTER FUNCTION "public"."get_inventory_recipe_catalog"("p_restaurant_id" "uuid", "p_menu_item_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_inventory_stock_status"("p_store_id" "uuid", "p_as_of_date" "date" DEFAULT CURRENT_DATE) RETURNS TABLE("product_id" "uuid", "product_name" "text", "category" "text", "stock_unit" "text", "base_unit" "text", "current_stock_base" numeric, "current_stock_display" numeric, "recent_4_day_avg" numeric, "recent_7_day_avg" numeric, "avg_daily_consumption_base" numeric, "estimated_days_remaining" numeric, "risk_status" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;

  RETURN QUERY
  WITH consumption AS (
    SELECT
      ip.id AS product_id,
      COALESCE(SUM(idc.consumed_quantity_base) FILTER (
        WHERE idc.consumption_date > p_as_of_date - 4
          AND idc.consumption_date <= p_as_of_date
      ), 0) / 4.0 AS recent_4_day_avg,
      COALESCE(SUM(idc.consumed_quantity_base) FILTER (
        WHERE idc.consumption_date > p_as_of_date - 7
          AND idc.consumption_date <= p_as_of_date
      ), 0) / 7.0 AS recent_7_day_avg
    FROM public.inventory_products ip
    LEFT JOIN public.inventory_daily_consumption idc
      ON idc.product_id = ip.id
     AND idc.restaurant_id = ip.restaurant_id
     AND idc.consumption_date > p_as_of_date - 7
     AND idc.consumption_date <= p_as_of_date
    WHERE ip.restaurant_id = p_store_id
      AND ip.is_active = TRUE
    GROUP BY ip.id
  ), stock AS (
    SELECT
      ip.id,
      ip.name,
      ip.category,
      ip.stock_unit,
      ip.base_unit,
      ip.base_unit_factor,
      COALESCE(ii.current_stock, 0) AS current_stock_base,
      c.recent_4_day_avg,
      c.recent_7_day_avg,
      -- Recommendation formula: recent_4_day_avg * 0.7 + recent_7_day_avg * 0.3
      (c.recent_4_day_avg * 0.7 + c.recent_7_day_avg * 0.3) AS avg_daily_consumption_base
    FROM public.inventory_products ip
    LEFT JOIN public.inventory_items ii
      ON ii.id = ip.inventory_item_id
     AND ii.restaurant_id = ip.restaurant_id
    JOIN consumption c
      ON c.product_id = ip.id
    WHERE ip.restaurant_id = p_store_id
      AND ip.is_active = TRUE
  )
  SELECT
    stock.id AS product_id,
    stock.name AS product_name,
    stock.category,
    stock.stock_unit,
    stock.base_unit,
    stock.current_stock_base,
    ROUND(stock.current_stock_base / NULLIF(stock.base_unit_factor, 0), 3) AS current_stock_display,
    ROUND(stock.recent_4_day_avg, 3) AS recent_4_day_avg,
    ROUND(stock.recent_7_day_avg, 3) AS recent_7_day_avg,
    ROUND(stock.avg_daily_consumption_base, 3) AS avg_daily_consumption_base,
    CASE
      WHEN stock.avg_daily_consumption_base <= 0 THEN NULL
      ELSE ROUND(stock.current_stock_base / stock.avg_daily_consumption_base, 2)
    END AS estimated_days_remaining,
    CASE
      WHEN stock.avg_daily_consumption_base <= 0 THEN 'stable'
      WHEN stock.current_stock_base / stock.avg_daily_consumption_base < 2 THEN 'danger'
      WHEN stock.current_stock_base / stock.avg_daily_consumption_base < 4 THEN 'warning'
      WHEN stock.current_stock_base / stock.avg_daily_consumption_base < 7 THEN 'normal'
      ELSE 'stable'
    END AS risk_status
  FROM stock
  ORDER BY risk_status, product_name;
END;
$$;


ALTER FUNCTION "public"."get_inventory_stock_status"("p_store_id" "uuid", "p_as_of_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_inventory_transaction_visibility"("p_restaurant_id" "uuid", "p_from" timestamp with time zone, "p_to" timestamp with time zone) RETURNS TABLE("id" "uuid", "restaurant_id" "uuid", "ingredient_id" "uuid", "ingredient_name" "text", "ingredient_unit" "text", "transaction_type" "text", "quantity_g" numeric, "reference_type" "text", "reference_id" "uuid", "note" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_RANGE_REQUIRED';
  END IF;

  IF p_from > p_to THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_RANGE_INVALID';
  END IF;

  RETURN QUERY
  SELECT
    it.id,
    it.restaurant_id,
    it.ingredient_id,
    ii.name AS ingredient_name,
    ii.unit AS ingredient_unit,
    it.transaction_type,
    it.quantity_g,
    it.reference_type,
    it.reference_id,
    it.note,
    it.created_at
  FROM public.inventory_transactions it
  JOIN public.inventory_items ii
    ON ii.id = it.ingredient_id
   AND ii.restaurant_id = it.restaurant_id
  WHERE it.restaurant_id = p_restaurant_id
    AND it.created_at >= p_from
    AND it.created_at <= p_to
  ORDER BY it.created_at DESC, ii.name;
END;
$$;


ALTER FUNCTION "public"."get_inventory_transaction_visibility"("p_restaurant_id" "uuid", "p_from" timestamp with time zone, "p_to" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_photo_objet_store_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  SELECT public.get_user_primary_store_id();
$$;


ALTER FUNCTION "public"."get_photo_objet_store_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_qc_analytics"("p_restaurant_id" "uuid", "p_from" "date", "p_to" "date") RETURNS TABLE("total_checks" bigint, "pass_count" bigint, "fail_count" bigint, "na_count" bigint, "pass_rate" numeric, "template_count" bigint, "coverage" numeric, "open_followups" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_can_check BOOLEAN;
  v_days INT;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_ANALYTICS_FORBIDDEN';
  END IF;

  v_can_check := v_actor.role IN ('admin', 'super_admin')
    OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check'];

  IF NOT v_can_check THEN
    RAISE EXCEPTION 'QC_ANALYTICS_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'QC_ANALYTICS_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RAISE EXCEPTION 'QC_ANALYTICS_RANGE_INVALID';
  END IF;

  v_days := (p_to - p_from) + 1;

  RETURN QUERY
  SELECT
    COUNT(*)::BIGINT AS total_checks,
    COUNT(*) FILTER (WHERE qc.result = 'pass')::BIGINT AS pass_count,
    COUNT(*) FILTER (WHERE qc.result = 'fail')::BIGINT AS fail_count,
    COUNT(*) FILTER (WHERE qc.result = 'na')::BIGINT AS na_count,
    CASE
      WHEN COUNT(*) FILTER (WHERE qc.result IN ('pass','fail')) = 0 THEN 0::NUMERIC
      ELSE ROUND(
        COUNT(*) FILTER (WHERE qc.result = 'pass')::NUMERIC
        / COUNT(*) FILTER (WHERE qc.result IN ('pass','fail'))::NUMERIC * 100,
        1
      )
    END AS pass_rate,
    (SELECT COUNT(*) FROM public.qc_templates qt
     WHERE qt.is_active = TRUE
       AND (qt.is_global = TRUE OR qt.restaurant_id = p_restaurant_id)
    )::BIGINT AS template_count,
    CASE
      WHEN (SELECT COUNT(*) FROM public.qc_templates qt
            WHERE qt.is_active = TRUE
              AND (qt.is_global = TRUE OR qt.restaurant_id = p_restaurant_id)) = 0
      THEN 0::NUMERIC
      ELSE ROUND(
        COUNT(*)::NUMERIC
        / ((SELECT COUNT(*) FROM public.qc_templates qt
            WHERE qt.is_active = TRUE
              AND (qt.is_global = TRUE OR qt.restaurant_id = p_restaurant_id))
           * v_days)::NUMERIC * 100,
        1
      )
    END AS coverage,
    (SELECT COUNT(*) FROM public.qc_followups f
     WHERE f.restaurant_id = p_restaurant_id
       AND f.status IN ('open', 'in_progress')
    )::BIGINT AS open_followups
  FROM public.qc_checks qc
  WHERE qc.restaurant_id = p_restaurant_id
    AND qc.check_date >= p_from
    AND qc.check_date <= p_to;
END;
$$;


ALTER FUNCTION "public"."get_qc_analytics"("p_restaurant_id" "uuid", "p_from" "date", "p_to" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_qc_checks"("p_store_id" "uuid", "p_from" "date", "p_to" "date") RETURNS TABLE("check_id" "uuid", "restaurant_id" "uuid", "template_id" "uuid", "check_date" "date", "checked_by" "uuid", "result" "text", "evidence_photo_url" "text", "note" "text", "created_at" timestamp with time zone, "template_category" "text", "template_criteria_text" "text", "template_criteria_photo_url" "text", "template_is_global" boolean, "submitted_at" timestamp with time zone, "submission_status" "text", "photo_required_count" integer, "photo_uploaded_count" integer, "score" numeric, "grade" "text", "sv_review_status" "text", "sv_reviewed_by" "uuid", "sv_reviewed_at" timestamp with time zone, "sv_score" numeric, "sv_note" "text", "visit_session_id" "uuid", "template_qsc_domain" "text", "template_requires_photo" boolean, "template_required_photo_count" integer, "template_weight" numeric, "template_sort_group" "text", "template_is_sv_required" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_can_check BOOLEAN;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_CHECK_READ_FORBIDDEN';
  END IF;

  v_can_check := v_actor.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
    OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check'];

  IF NOT v_can_check THEN
    RAISE EXCEPTION 'QC_CHECK_READ_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'QC_CHECK_READ_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL THEN
    RAISE EXCEPTION 'QC_CHECK_RANGE_REQUIRED';
  END IF;

  IF p_from > p_to THEN
    RAISE EXCEPTION 'QC_CHECK_RANGE_INVALID';
  END IF;

  RETURN QUERY
  SELECT
    qc.id AS check_id,
    qc.restaurant_id,
    qc.template_id,
    qc.check_date,
    qc.checked_by,
    qc.result,
    qc.evidence_photo_url,
    qc.note,
    qc.created_at,
    qt.category AS template_category,
    qt.criteria_text AS template_criteria_text,
    qt.criteria_photo_url AS template_criteria_photo_url,
    qt.is_global AS template_is_global,
    qc.submitted_at,
    qc.submission_status,
    qc.photo_required_count,
    qc.photo_uploaded_count,
    qc.score,
    qc.grade,
    qc.sv_review_status,
    qc.sv_reviewed_by,
    qc.sv_reviewed_at,
    qc.sv_score,
    qc.sv_note,
    qc.visit_session_id,
    qt.qsc_domain AS template_qsc_domain,
    qt.requires_photo AS template_requires_photo,
    qt.required_photo_count AS template_required_photo_count,
    qt.weight AS template_weight,
    qt.sort_group AS template_sort_group,
    qt.is_sv_required AS template_is_sv_required
  FROM public.qc_checks qc
  JOIN public.qc_templates qt
    ON qt.id = qc.template_id
  WHERE qc.restaurant_id = p_store_id
    AND qc.check_date >= p_from
    AND qc.check_date <= p_to
  ORDER BY qc.check_date DESC, lower(qt.category), qt.sort_order, qc.created_at DESC;
END;
$$;


ALTER FUNCTION "public"."get_qc_checks"("p_store_id" "uuid", "p_from" "date", "p_to" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_qc_followups"("p_restaurant_id" "uuid", "p_status_filter" "text" DEFAULT NULL::"text") RETURNS TABLE("followup_id" "uuid", "restaurant_id" "uuid", "source_check_id" "uuid", "status" "text", "assigned_to_name" "text", "resolution_notes" "text", "created_at" timestamp with time zone, "updated_at" timestamp with time zone, "resolved_at" timestamp with time zone, "check_date" "date", "check_result" "text", "check_note" "text", "template_category" "text", "template_criteria" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_READ_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_READ_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    f.id AS followup_id,
    f.restaurant_id,
    f.source_check_id,
    f.status,
    f.assigned_to_name,
    f.resolution_notes,
    f.created_at,
    f.updated_at,
    f.resolved_at,
    qc.check_date,
    qc.result AS check_result,
    qc.note AS check_note,
    qt.category AS template_category,
    qt.criteria_text AS template_criteria
  FROM public.qc_followups f
  JOIN public.qc_checks qc ON qc.id = f.source_check_id
  JOIN public.qc_templates qt ON qt.id = qc.template_id
  WHERE f.restaurant_id = p_restaurant_id
    AND (p_status_filter IS NULL OR f.status = p_status_filter)
  ORDER BY
    CASE f.status
      WHEN 'open' THEN 0
      WHEN 'in_progress' THEN 1
      WHEN 'resolved' THEN 2
    END,
    f.created_at DESC;
END;
$$;


ALTER FUNCTION "public"."get_qc_followups"("p_restaurant_id" "uuid", "p_status_filter" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_qc_superadmin_summary"("p_week_start" "date") RETURNS TABLE("restaurant_id" "uuid", "restaurant_name" "text", "coverage" numeric, "fail_count" bigint, "latest_check_date" "date")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_week_end DATE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'QC_SUMMARY_FORBIDDEN';
  END IF;

  IF p_week_start IS NULL THEN
    RAISE EXCEPTION 'QC_SUMMARY_WEEK_REQUIRED';
  END IF;

  v_week_end := p_week_start + 6;

  RETURN QUERY
  WITH active_restaurants AS (
    SELECT r.id, r.name
    FROM public.stores r
    WHERE r.is_active = TRUE
  ),
  template_counts AS (
    SELECT
      ar.id AS restaurant_id,
      COUNT(*) FILTER (
        WHERE qt.is_active = TRUE
          AND (qt.is_global = TRUE OR qt.restaurant_id = ar.id)
      )::INT AS template_count
    FROM active_restaurants ar
    LEFT JOIN public.qc_templates qt
      ON qt.is_active = TRUE
     AND (qt.is_global = TRUE OR qt.restaurant_id = ar.id)
    GROUP BY ar.id
  ),
  checks AS (
    SELECT
      qc.restaurant_id,
      COUNT(*)::BIGINT AS checked_count,
      COUNT(*) FILTER (WHERE qc.result = 'fail')::BIGINT AS fail_count,
      MAX(qc.check_date) AS latest_check_date
    FROM public.qc_checks qc
    WHERE qc.check_date >= p_week_start
      AND qc.check_date <= v_week_end
    GROUP BY qc.restaurant_id
  )
  SELECT
    ar.id AS restaurant_id,
    ar.name AS restaurant_name,
    CASE
      WHEN COALESCE(tc.template_count, 0) = 0 THEN 0::NUMERIC
      ELSE ROUND(
        COALESCE(ch.checked_count, 0)::NUMERIC
        / (tc.template_count * 7)::NUMERIC * 100,
        2
      )
    END AS coverage,
    COALESCE(ch.fail_count, 0) AS fail_count,
    ch.latest_check_date
  FROM active_restaurants ar
  LEFT JOIN template_counts tc
    ON tc.restaurant_id = ar.id
  LEFT JOIN checks ch
    ON ch.restaurant_id = ar.id
  ORDER BY lower(ar.name);
END;
$$;


ALTER FUNCTION "public"."get_qc_superadmin_summary"("p_week_start" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_qc_templates"("p_store_id" "uuid" DEFAULT NULL::"uuid", "p_scope" "text" DEFAULT 'visible'::"text") RETURNS TABLE("id" "uuid", "restaurant_id" "uuid", "category" "text", "criteria_text" "text", "criteria_photo_url" "text", "sort_order" integer, "is_global" boolean, "is_active" boolean, "created_at" timestamp with time zone, "updated_at" timestamp with time zone, "qsc_domain" "text", "requires_photo" boolean, "required_photo_count" integer, "weight" numeric, "sort_group" "text", "is_sv_required" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_TEMPLATE_READ_FORBIDDEN';
  END IF;

  IF p_scope NOT IN ('visible', 'global') THEN
    RAISE EXCEPTION 'QC_TEMPLATE_SCOPE_INVALID';
  END IF;

  IF p_scope = 'global' THEN
    IF v_actor.role <> 'super_admin' THEN
      RAISE EXCEPTION 'QC_TEMPLATE_READ_FORBIDDEN';
    END IF;
  ELSE
    IF p_store_id IS NULL THEN
      RAISE EXCEPTION 'QC_TEMPLATE_RESTAURANT_REQUIRED';
    END IF;

    IF v_actor.role <> 'super_admin'
       AND NOT EXISTS (
         SELECT 1
         FROM public.user_accessible_stores(auth.uid()) s(store_id)
         WHERE s.store_id = p_store_id
       ) THEN
      RAISE EXCEPTION 'QC_TEMPLATE_READ_FORBIDDEN';
    END IF;
  END IF;

  RETURN QUERY
  SELECT
    qt.id,
    qt.restaurant_id,
    qt.category,
    qt.criteria_text,
    qt.criteria_photo_url,
    qt.sort_order,
    qt.is_global,
    qt.is_active,
    qt.created_at,
    qt.updated_at,
    qt.qsc_domain,
    qt.requires_photo,
    qt.required_photo_count,
    qt.weight,
    qt.sort_group,
    qt.is_sv_required
  FROM public.qc_templates qt
  WHERE qt.is_active = TRUE
    AND (
      (p_scope = 'global' AND qt.is_global = TRUE)
      OR
      (
        p_scope = 'visible'
        AND (
          qt.is_global = TRUE
          OR qt.restaurant_id = p_store_id
        )
      )
    )
  ORDER BY qt.is_global DESC, lower(qt.category), qt.sort_order, qt.created_at;
END;
$$;


ALTER FUNCTION "public"."get_qc_templates"("p_store_id" "uuid", "p_scope" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_primary_store_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  SELECT COALESCE(u.primary_store_id, u.restaurant_id)
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = true
  LIMIT 1;
$$;


ALTER FUNCTION "public"."get_user_primary_store_id"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_user_primary_store_id"() IS 'Returns the current user''s primary working store, falling back to users.restaurant_id during the transition period.';



CREATE OR REPLACE FUNCTION "public"."get_user_restaurant_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  SELECT restaurant_id FROM users WHERE auth_id = auth.uid()
$$;


ALTER FUNCTION "public"."get_user_restaurant_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_role"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  SELECT role FROM users WHERE auth_id = auth.uid()
$$;


ALTER FUNCTION "public"."get_user_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_store_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
  SELECT public.get_user_restaurant_id()
$$;


ALTER FUNCTION "public"."get_user_store_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_tax_entity_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  SELECT r.tax_entity_id
  FROM users u
  JOIN restaurants r ON r.id = u.restaurant_id
  WHERE u.auth_id = auth.uid() AND u.is_active = TRUE
  LIMIT 1;
$$;


ALTER FUNCTION "public"."get_user_tax_entity_id"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_user_tax_entity_id"() IS 'Returns the tax_entity_id of the current user''s store. Enables tax-axis RLS for WeTax tables.';



CREATE OR REPLACE FUNCTION "public"."has_any_role"("required_roles" "text"[]) RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  SELECT role = ANY(required_roles)
  FROM users WHERE auth_id = auth.uid()
$$;


ALTER FUNCTION "public"."has_any_role"("required_roles" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_photo_objet_master"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  SELECT EXISTS(
    SELECT 1
    FROM public.users u
    WHERE u.auth_id = auth.uid()
      AND u.is_active = TRUE
      AND u.role IN ('photo_objet_master', 'super_admin')
  );
$$;


ALTER FUNCTION "public"."is_photo_objet_master"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_super_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM users WHERE auth_id = auth.uid() AND role = 'super_admin'
  )
$$;


ALTER FUNCTION "public"."is_super_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."lookup_b2b_buyer"("p_store_id" "uuid", "p_tax_code" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_tax_entity_id uuid;
  v_row b2b_buyer_cache%ROWTYPE;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_REQUIRED';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  SELECT tax_entity_id
  INTO v_tax_entity_id
  FROM restaurants
  WHERE id = p_store_id;

  SELECT *
  INTO v_row
  FROM b2b_buyer_cache
  WHERE buyer_tax_code = p_tax_code
    AND (
      store_id = p_store_id
      OR (v_tax_entity_id IS NOT NULL AND tax_entity_id = v_tax_entity_id)
    )
  ORDER BY (store_id = p_store_id) DESC, last_used_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'tax_company_name', v_row.tax_company_name,
    'tax_address', v_row.tax_address,
    'receiver_email', v_row.receiver_email,
    'receiver_email_cc', v_row.receiver_email_cc
  );
END;
$$;


ALTER FUNCTION "public"."lookup_b2b_buyer"("p_store_id" "uuid", "p_tax_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_payment_proof_required"("p_payment_id" "uuid", "p_store_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_payment public.payments%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'PAYMENT_PROOF_FORBIDDEN';
  END IF;

  IF p_payment_id IS NULL OR p_store_id IS NULL THEN
    RAISE EXCEPTION 'PAYMENT_PROOF_INVALID';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_payment
  FROM public.payments
  WHERE id = p_payment_id
    AND restaurant_id = p_store_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PAYMENT_NOT_FOUND';
  END IF;

  UPDATE public.payments
  SET proof_required = TRUE
  WHERE id = v_payment.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'mark_payment_proof_required',
    'payments',
    v_payment.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_payment.order_id,
      'method', v_payment.method
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'payment_id', v_payment.id,
    'proof_required', true
  );
END;
$$;


ALTER FUNCTION "public"."mark_payment_proof_required"("p_payment_id" "uuid", "p_store_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."office_approve_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_review_comment" "text" DEFAULT NULL::"text") RETURNS "public"."inventory_purchase_orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
BEGIN
  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  IF NOT public.can_office_review_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_OFFICE_FORBIDDEN';
  END IF;

  IF v_order.status NOT IN ('submitted', 'office_returned') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_EDITABLE';
  END IF;

  UPDATE public.inventory_purchase_orders
  SET status = 'office_approved',
      office_reviewed_by = auth.uid(),
      office_reviewed_at = now(),
      office_review_comment = NULLIF(btrim(COALESCE(p_office_review_comment, '')), ''),
      updated_at = now()
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_order;

  RETURN v_order;
END;
$$;


ALTER FUNCTION "public"."office_approve_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_review_comment" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."office_cancel_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_review_comment" "text" DEFAULT NULL::"text") RETURNS "public"."inventory_purchase_orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
BEGIN
  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  IF NOT public.can_office_review_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_OFFICE_FORBIDDEN';
  END IF;

  IF v_order.status IN ('received', 'partially_received') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_EDITABLE';
  END IF;

  UPDATE public.inventory_purchase_orders
  SET status = 'cancelled',
      office_reviewed_by = auth.uid(),
      office_reviewed_at = now(),
      office_review_comment = NULLIF(btrim(COALESCE(p_office_review_comment, '')), ''),
      updated_at = now()
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_order;

  RETURN v_order;
END;
$$;


ALTER FUNCTION "public"."office_cancel_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_review_comment" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payroll_records" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "period_start" "date" NOT NULL,
    "period_end" "date" NOT NULL,
    "total_hours" numeric(8,2),
    "total_amount" numeric(12,2),
    "breakdown" "jsonb",
    "status" "text" DEFAULT 'draft'::"text",
    "confirmed_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "payroll_records_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'store_submitted'::"text", 'office_confirmed'::"text", 'paid'::"text"])))
);


ALTER TABLE "public"."payroll_records" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."office_confirm_payroll"("p_payroll_id" "uuid") RETURNS "public"."payroll_records"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor_id UUID := auth.uid();
  v_payroll payroll_records;
BEGIN
  SELECT *
  INTO v_payroll
  FROM payroll_records
  WHERE id = p_payroll_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PAYROLL_NOT_FOUND';
  END IF;

  IF v_payroll.status <> 'store_submitted' THEN
    RAISE EXCEPTION 'INVALID_STATUS_TRANSITION';
  END IF;

  UPDATE payroll_records
  SET status = 'office_confirmed',
      updated_at = now()
  WHERE id = p_payroll_id
  RETURNING * INTO v_payroll;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    v_actor_id,
    'office_confirm_payroll',
    'payroll_records',
    p_payroll_id,
    jsonb_build_object(
      'from_status', 'store_submitted',
      'to_status', 'office_confirmed'
    )
  );

  RETURN v_payroll;
END;
$$;


ALTER FUNCTION "public"."office_confirm_payroll"("p_payroll_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."office_get_inventory_purchase_order_detail"("p_purchase_order_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_lines JSONB;
BEGIN
  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  IF NOT public.can_access_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_OFFICE_FORBIDDEN';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(line_row) ORDER BY line_row.created_at), '[]'::JSONB)
  INTO v_lines
  FROM (
    SELECT
      pol.id,
      pol.product_id,
      ip.name AS product_name,
      pol.supplier_item_id,
      pol.recommended_quantity_base,
      pol.ordered_quantity_base,
      pol.ordered_quantity_unit,
      pol.order_unit,
      pol.unit_price,
      pol.supply_amount,
      pol.tax_amount,
      pol.memo,
      pol.recommendation_snapshot,
      pol.created_at,
      pol.updated_at
    FROM public.inventory_purchase_order_lines pol
    JOIN public.inventory_products ip
      ON ip.id = pol.product_id
    WHERE pol.purchase_order_id = p_purchase_order_id
  ) line_row;

  RETURN jsonb_build_object(
    'order', to_jsonb(v_order),
    'lines', v_lines
  );
END;
$$;


ALTER FUNCTION "public"."office_get_inventory_purchase_order_detail"("p_purchase_order_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."office_get_inventory_purchase_orders"("p_brand_id" "uuid" DEFAULT NULL::"uuid", "p_store_id" "uuid" DEFAULT NULL::"uuid", "p_status" "text" DEFAULT NULL::"text") RETURNS TABLE("id" "uuid", "purchase_order_no" "text", "restaurant_id" "uuid", "brand_id" "uuid", "supplier_id" "uuid", "supplier_name" "text", "status" "text", "requested_delivery_date" "date", "total_supply_amount" numeric, "tax_amount" numeric, "total_amount" numeric, "office_reviewed_at" timestamp with time zone, "created_at" timestamp with time zone, "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    po.id,
    po.purchase_order_no,
    po.restaurant_id,
    po.brand_id,
    po.supplier_id,
    s.supplier_name,
    po.status,
    po.requested_delivery_date,
    po.total_supply_amount,
    po.tax_amount,
    po.total_amount,
    po.office_reviewed_at,
    po.created_at,
    po.updated_at
  FROM public.inventory_purchase_orders po
  JOIN public.inventory_suppliers s
    ON s.id = po.supplier_id
  WHERE public.can_access_inventory_purchase_store(po.restaurant_id)
    AND (p_brand_id IS NULL OR po.brand_id = p_brand_id)
    AND (p_store_id IS NULL OR po.restaurant_id = p_store_id)
    AND (p_status IS NULL OR po.status = p_status)
  ORDER BY po.created_at DESC, po.purchase_order_no DESC;
END;
$$;


ALTER FUNCTION "public"."office_get_inventory_purchase_orders"("p_brand_id" "uuid", "p_store_id" "uuid", "p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."office_reject_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_rejection_reason" "text") RETURNS "public"."inventory_purchase_orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_reason TEXT := NULLIF(btrim(COALESCE(p_office_rejection_reason, '')), '');
BEGIN
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_REJECTION_REASON_REQUIRED';
  END IF;

  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  IF NOT public.can_office_review_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_OFFICE_FORBIDDEN';
  END IF;

  IF v_order.status NOT IN ('submitted', 'office_returned') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_EDITABLE';
  END IF;

  UPDATE public.inventory_purchase_orders
  SET status = 'office_rejected',
      office_reviewed_by = auth.uid(),
      office_reviewed_at = now(),
      office_rejection_reason = v_reason,
      updated_at = now()
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_order;

  RETURN v_order;
END;
$$;


ALTER FUNCTION "public"."office_reject_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_rejection_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."office_return_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_review_comment" "text") RETURNS "public"."inventory_purchase_orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
BEGIN
  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  IF NOT public.can_office_review_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_OFFICE_FORBIDDEN';
  END IF;

  IF v_order.status <> 'submitted' THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_EDITABLE';
  END IF;

  UPDATE public.inventory_purchase_orders
  SET status = 'office_returned',
      office_reviewed_by = auth.uid(),
      office_reviewed_at = now(),
      office_review_comment = NULLIF(btrim(COALESCE(p_office_review_comment, '')), ''),
      updated_at = now()
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_order;

  RETURN v_order;
END;
$$;


ALTER FUNCTION "public"."office_return_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_review_comment" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."office_return_payroll"("p_payroll_id" "uuid") RETURNS "public"."payroll_records"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor_id UUID := auth.uid();
  v_payroll payroll_records;
BEGIN
  SELECT *
  INTO v_payroll
  FROM payroll_records
  WHERE id = p_payroll_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PAYROLL_NOT_FOUND';
  END IF;

  IF v_payroll.status <> 'store_submitted' THEN
    RAISE EXCEPTION 'INVALID_STATUS_TRANSITION';
  END IF;

  UPDATE payroll_records
  SET status = 'draft',
      updated_at = now()
  WHERE id = p_payroll_id
  RETURNING * INTO v_payroll;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    v_actor_id,
    'office_return_payroll',
    'payroll_records',
    p_payroll_id,
    jsonb_build_object(
      'from_status', 'store_submitted',
      'to_status', 'draft'
    )
  );

  RETURN v_payroll;
END;
$$;


ALTER FUNCTION "public"."office_return_payroll"("p_payroll_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."office_update_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_requested_delivery_date" "date" DEFAULT NULL::"date", "p_memo" "text" DEFAULT NULL::"text", "p_office_review_comment" "text" DEFAULT NULL::"text", "p_lines" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "public"."inventory_purchase_orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_line JSONB;
  v_line_id UUID;
  v_ordered_quantity_base NUMERIC(12,3);
  v_ordered_quantity_unit NUMERIC(12,3);
  v_unit_to_base_factor NUMERIC(12,6);
  v_tax_rate NUMERIC(8,6);
  v_line_memo TEXT;
  v_existing_line public.inventory_purchase_order_lines%ROWTYPE;
BEGIN
  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  IF NOT public.can_office_review_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_OFFICE_FORBIDDEN';
  END IF;

  IF v_order.status NOT IN ('submitted', 'office_returned') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_EDITABLE';
  END IF;

  UPDATE public.inventory_purchase_orders
  SET requested_delivery_date = COALESCE(p_requested_delivery_date, requested_delivery_date),
      memo = COALESCE(NULLIF(btrim(COALESCE(p_memo, '')), ''), memo),
      office_review_comment = COALESCE(NULLIF(btrim(COALESCE(p_office_review_comment, '')), ''), office_review_comment),
      updated_at = now()
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_order;

  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
      v_line_id := NULLIF(v_line->>'line_id', '')::UUID;
      v_ordered_quantity_base := NULLIF(v_line->>'ordered_quantity_base', '')::NUMERIC;
      v_line_memo := NULLIF(btrim(COALESCE(v_line->>'memo', '')), '');

      SELECT *
      INTO v_existing_line
      FROM public.inventory_purchase_order_lines
      WHERE id = v_line_id
        AND purchase_order_id = p_purchase_order_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'INVENTORY_PURCHASE_LINE_NOT_FOUND';
      END IF;

      IF v_ordered_quantity_base IS NULL OR v_ordered_quantity_base < 0 THEN
        RAISE EXCEPTION 'INVENTORY_PURCHASE_LINE_QUANTITY_INVALID';
      END IF;

      v_unit_to_base_factor := CASE
        WHEN v_existing_line.ordered_quantity_unit <= 0 THEN 1
        ELSE v_existing_line.ordered_quantity_base / v_existing_line.ordered_quantity_unit
      END;
      v_ordered_quantity_unit := CASE
        WHEN v_unit_to_base_factor <= 0 THEN v_ordered_quantity_base
        ELSE ROUND(v_ordered_quantity_base / v_unit_to_base_factor, 3)
      END;
      v_tax_rate := CASE
        WHEN v_existing_line.supply_amount <= 0 THEN 0
        ELSE v_existing_line.tax_amount / v_existing_line.supply_amount
      END;

      UPDATE public.inventory_purchase_order_lines
      SET ordered_quantity_base = v_ordered_quantity_base,
          ordered_quantity_unit = v_ordered_quantity_unit,
          supply_amount = ROUND(v_ordered_quantity_unit * v_existing_line.unit_price, 2),
          tax_amount = ROUND(v_ordered_quantity_unit * v_existing_line.unit_price * v_tax_rate, 2),
          memo = COALESCE(v_line_memo, memo),
          updated_at = now()
      WHERE id = v_line_id;
    END LOOP;
  END IF;

  PERFORM public.recalculate_inventory_purchase_order_totals(p_purchase_order_id);

  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id;

  RETURN v_order;
END;
$$;


ALTER FUNCTION "public"."office_update_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_requested_delivery_date" "date", "p_memo" "text", "p_office_review_comment" "text", "p_lines" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."on_payroll_store_submitted"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_brand_id UUID;
BEGIN
  SELECT brand_id
  INTO v_brand_id
  FROM stores
  WHERE id = NEW.restaurant_id;

  INSERT INTO office_payroll_reviews (
    source_payroll_id,
    restaurant_id,
    brand_id,
    period_start,
    period_end,
    status
  )
  VALUES (
    NEW.id,
    NEW.restaurant_id,
    v_brand_id,
    NEW.period_start,
    NEW.period_end,
    'pending_review'
  )
  ON CONFLICT (source_payroll_id, period_start, period_end) DO NOTHING;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."on_payroll_store_submitted"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "order_id" "uuid" NOT NULL,
    "amount" numeric(12,2) NOT NULL,
    "method" "text" NOT NULL,
    "is_revenue" boolean DEFAULT true NOT NULL,
    "processed_by" "uuid",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "amount_portion" numeric(15,2) NOT NULL,
    "proof_photo_url" "text",
    "proof_photo_taken_at" timestamp with time zone,
    "proof_photo_by" "uuid",
    "proof_required" boolean DEFAULT false NOT NULL,
    "settlement_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "settlement_batch_id" "uuid",
    CONSTRAINT "payments_amount_check" CHECK (("amount" > (0)::numeric)),
    CONSTRAINT "payments_amount_portion_positive" CHECK (("amount_portion" > (0)::numeric)),
    CONSTRAINT "payments_method_check" CHECK (("method" = ANY (ARRAY['CASH'::"text", 'CREDITCARD'::"text", 'ATM'::"text", 'MOMO'::"text", 'ZALOPAY'::"text", 'VNPAY'::"text", 'SHOPEEPAY'::"text", 'BANKTRANSFER'::"text", 'VOUCHER'::"text", 'CREDITSALE'::"text", 'OTHER'::"text"]))),
    CONSTRAINT "payments_settlement_status_check" CHECK (("settlement_status" = ANY (ARRAY['pending'::"text", 'reconciled'::"text", 'discrepancy'::"text"])))
);


ALTER TABLE "public"."payments" OWNER TO "postgres";


COMMENT ON TABLE "public"."payments" IS '결제 내역';



COMMENT ON COLUMN "public"."payments"."method" IS 'Payment method aligned with WeTax sendOrderInfo enum. Migrated from old values (cash→CASH, card→CREDITCARD, pay/service→OTHER).';



COMMENT ON COLUMN "public"."payments"."amount_portion" IS 'Portion of order total covered by this row. Backfilled = amount for pre-hybrid rows. Sum per order must equal orders.total_amount (Invariant I12).';



COMMENT ON COLUMN "public"."payments"."proof_photo_url" IS 'Supabase Storage URL of payment proof photo.';



COMMENT ON COLUMN "public"."payments"."proof_photo_taken_at" IS 'Timestamp when cashier captured the proof photo.';



COMMENT ON COLUMN "public"."payments"."proof_photo_by" IS 'FK to users. Cashier who captured the proof photo.';



COMMENT ON COLUMN "public"."payments"."proof_required" IS 'Whether a proof photo is required for this payment row.';



COMMENT ON COLUMN "public"."payments"."settlement_status" IS 'Reconciliation status: pending / reconciled / discrepancy.';



COMMENT ON COLUMN "public"."payments"."settlement_batch_id" IS 'Links to daily reconciliation batch (future table).';



CREATE OR REPLACE FUNCTION "public"."process_payment"("p_order_id" "uuid", "p_store_id" "uuid", "p_amount" numeric, "p_method" "text") RETURNS "public"."payments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor                  users%ROWTYPE;
  v_order                  orders%ROWTYPE;
  v_payment                payments%ROWTYPE;
  v_brand                  brands%ROWTYPE;
  v_table_id               uuid;
  v_item                   RECORD;
  v_recipe                 RECORD;
  v_deduct_qty             decimal(12,3);
  v_food_subtotal          decimal(15,2) := 0;
  v_alcohol_subtotal       decimal(15,2) := 0;
  v_sc_rate                decimal(5,2)  := 0;
  v_sc_pretax              decimal(15,2);
  v_sc_vat                 decimal(15,2);
  v_sc_total               decimal(15,2);
  v_ref_id                 text;
  v_tax_entity_id          uuid;
  v_einvoice_shop_id       uuid;
  v_send_payload           jsonb;
  v_products               jsonb := '[]'::jsonb;
  v_pretax                 decimal(15,2);
  v_vat_rate               decimal(5,2);
  v_vat_amt                decimal(15,2);
  v_total_inc              decimal(15,2);
  v_is_revenue             boolean := true;
  v_payment_method_storage text := p_method;
  v_order_total            decimal(15,2) := 0;
  v_total_paid_before      decimal(15,2) := 0;
  v_total_paid_after       decimal(15,2) := 0;
  v_should_complete        boolean := false;
  v_vat_pricing_mode       text := 'exclusive';
  v_line_gross             decimal(15,2);
  v_seq                    integer := 0;
  v_order_dt               text;
BEGIN
  SELECT * INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier','admin','store_admin','brand_admin','super_admin') THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'PAYMENT_STORE_REQUIRED';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN';
  END IF;

  IF p_method = 'SERVICE' THEN
    v_is_revenue := FALSE;
    v_payment_method_storage := 'OTHER';
  ELSIF p_method NOT IN (
    'CASH','CREDITCARD','ATM','MOMO','ZALOPAY',
    'VNPAY','SHOPEEPAY','BANKTRANSFER','VOUCHER','CREDITSALE','OTHER'
  ) THEN
    RAISE EXCEPTION 'INVALID_PAYMENT_METHOD';
  END IF;

  SELECT * INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed','cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_PAYABLE';
  END IF;

  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'PAYMENT_AMOUNT_INVALID';
  END IF;

  SELECT b.* INTO v_brand
  FROM restaurants r
  JOIN brands b ON b.id = r.brand_id
  WHERE r.id = p_store_id;

  SELECT COALESCE(r.vat_pricing_mode, 'exclusive')
  INTO v_vat_pricing_mode
  FROM restaurants r
  WHERE r.id = p_store_id;

  v_order_dt := to_char(now() AT TIME ZONE 'Asia/Ho_Chi_Minh', 'YYYYMMDDHH24MISS');

  IF FOUND AND v_brand.service_charge_enabled THEN
    v_sc_rate := COALESCE(v_brand.service_charge_rate, 0);
  END IF;

  FOR v_item IN
    SELECT
      oi.id,
      oi.menu_item_id,
      oi.unit_price,
      oi.quantity,
      oi.display_name,
      oi.label,
      COALESCE(mi.vat_category, 'food') AS vat_category
    FROM order_items oi
    LEFT JOIN menu_items mi ON mi.id = oi.menu_item_id
    WHERE oi.order_id = p_order_id
      AND oi.status <> 'cancelled'
      AND oi.item_type = 'menu_item'
  LOOP
    v_seq := v_seq + 1;
    v_line_gross := ROUND(v_item.unit_price * v_item.quantity, 2);
    v_vat_rate := CASE v_item.vat_category WHEN 'alcohol' THEN 10 ELSE 8 END;
    IF v_vat_pricing_mode = 'inclusive' THEN
      v_total_inc := v_line_gross;
      v_pretax := ROUND(v_line_gross / (1 + (v_vat_rate / 100)), 2);
      v_vat_amt := v_line_gross - v_pretax;
    ELSE
      v_pretax := v_line_gross;
      v_vat_amt := ROUND(v_pretax * v_vat_rate / 100, 2);
      v_total_inc := v_pretax + v_vat_amt;
    END IF;

    UPDATE order_items
    SET
      vat_rate = v_vat_rate,
      vat_amount = v_vat_amt,
      total_amount_ex_tax = v_pretax,
      paying_amount_inc_tax = v_total_inc
    WHERE id = v_item.id;

    IF v_item.vat_category = 'alcohol' THEN
      v_alcohol_subtotal := v_alcohol_subtotal + v_pretax;
    ELSE
      v_food_subtotal := v_food_subtotal + v_pretax;
    END IF;

    v_products := v_products || jsonb_build_object(
      'feature', '1',
      'seq', v_seq::text,
      'item_code', COALESCE(v_item.menu_item_id::text, ''),
      'item_name', COALESCE(NULLIF(v_item.display_name, ''), v_item.label, 'Item'),
      'uom', 'EA',
      'quantity', v_item.quantity::text,
      'unit_price', v_item.unit_price::text,
      'dc_rate', '',
      'dc_amt', '',
      'total_amount', v_pretax::text,
      'vat_rate', (v_vat_rate::int::text || '%'),
      'vat_amount', v_vat_amt::text,
      'paying_amount', v_total_inc::text
    );
  END LOOP;

  IF v_sc_rate > 0 AND v_food_subtotal > 0 THEN
    v_sc_pretax := ROUND(v_food_subtotal * v_sc_rate / 100, 2);
    v_sc_vat := ROUND(v_sc_pretax * 8 / 100, 2);
    v_sc_total := v_sc_pretax + v_sc_vat;
    v_seq := v_seq + 1;

    IF NOT EXISTS (
      SELECT 1 FROM order_items
      WHERE order_id = p_order_id
        AND item_type = 'service_charge'
        AND display_name = 'Service Charge (Food)'
    ) THEN
      INSERT INTO order_items (
        order_id, restaurant_id, item_type, display_name, menu_item_id,
        unit_price, quantity, label, status, vat_rate, vat_amount,
        total_amount_ex_tax, paying_amount_inc_tax
      )
      VALUES (
        p_order_id, p_store_id, 'service_charge', 'Service Charge (Food)', NULL,
        v_sc_pretax, 1, 'Service Charge (Food)', 'served', 8, v_sc_vat,
        v_sc_pretax, v_sc_total
      );
    END IF;

    v_products := v_products || jsonb_build_object(
      'feature', '1',
      'seq', v_seq::text,
      'item_code', '',
      'item_name', 'Service Charge (Food)',
      'uom', 'EA',
      'quantity', '1',
      'unit_price', v_sc_pretax::text,
      'dc_rate', '',
      'dc_amt', '',
      'total_amount', v_sc_pretax::text,
      'vat_rate', '8%',
      'vat_amount', v_sc_vat::text,
      'paying_amount', v_sc_total::text
    );
  END IF;

  IF v_sc_rate > 0 AND v_alcohol_subtotal > 0 THEN
    v_sc_pretax := ROUND(v_alcohol_subtotal * v_sc_rate / 100, 2);
    v_sc_vat := ROUND(v_sc_pretax * 10 / 100, 2);
    v_sc_total := v_sc_pretax + v_sc_vat;
    v_seq := v_seq + 1;

    IF NOT EXISTS (
      SELECT 1 FROM order_items
      WHERE order_id = p_order_id
        AND item_type = 'service_charge'
        AND display_name = 'Service Charge (Alcohol)'
    ) THEN
      INSERT INTO order_items (
        order_id, restaurant_id, item_type, display_name, menu_item_id,
        unit_price, quantity, label, status, vat_rate, vat_amount,
        total_amount_ex_tax, paying_amount_inc_tax
      )
      VALUES (
        p_order_id, p_store_id, 'service_charge', 'Service Charge (Alcohol)', NULL,
        v_sc_pretax, 1, 'Service Charge (Alcohol)', 'served', 10, v_sc_vat,
        v_sc_pretax, v_sc_total
      );
    END IF;

    v_products := v_products || jsonb_build_object(
      'feature', '1',
      'seq', v_seq::text,
      'item_code', '',
      'item_name', 'Service Charge (Alcohol)',
      'uom', 'EA',
      'quantity', '1',
      'unit_price', v_sc_pretax::text,
      'dc_rate', '',
      'dc_amt', '',
      'total_amount', v_sc_pretax::text,
      'vat_rate', '10%',
      'vat_amount', v_sc_vat::text,
      'paying_amount', v_sc_total::text
    );
  END IF;

  SELECT ROUND(COALESCE(SUM(COALESCE(paying_amount_inc_tax, unit_price * quantity)), 0), 2)
  INTO v_order_total
  FROM order_items
  WHERE order_id = p_order_id
    AND status <> 'cancelled';

  IF v_order_total <= 0 THEN
    RAISE EXCEPTION 'ORDER_TOTAL_INVALID';
  END IF;

  SELECT COALESCE(SUM(amount_portion), 0)
  INTO v_total_paid_before
  FROM payments
  WHERE order_id = p_order_id;

  IF v_total_paid_before + p_amount > v_order_total + 0.01 THEN
    RAISE EXCEPTION 'PAYMENT_AMOUNT_EXCEEDS_REMAINING';
  END IF;

  v_total_paid_after := ROUND(v_total_paid_before + p_amount, 2);
  v_should_complete := v_total_paid_after >= v_order_total - 0.01;

  INSERT INTO payments (
    order_id,
    restaurant_id,
    amount,
    method,
    processed_by,
    is_revenue,
    amount_portion
  )
  VALUES (
    p_order_id,
    p_store_id,
    p_amount,
    v_payment_method_storage,
    auth.uid(),
    v_is_revenue,
    p_amount
  )
  RETURNING * INTO v_payment;

  IF v_should_complete THEN
    UPDATE orders
    SET status = 'completed', updated_at = now()
    WHERE id = p_order_id
    RETURNING table_id INTO v_table_id;

    IF v_table_id IS NOT NULL THEN
      UPDATE tables
      SET status = 'available', updated_at = now()
      WHERE id = v_table_id;
    END IF;

    FOR v_item IN
      SELECT
        oi.id AS order_item_id,
        oi.menu_item_id,
        oi.quantity AS ordered_qty
      FROM order_items oi
      WHERE oi.order_id = p_order_id
        AND oi.menu_item_id IS NOT NULL
        AND oi.status <> 'cancelled'
        AND oi.item_type = 'menu_item'
    LOOP
      FOR v_recipe IN
        SELECT mr.ingredient_id, mr.quantity_g
        FROM menu_recipes mr
        WHERE mr.menu_item_id = v_item.menu_item_id
          AND mr.restaurant_id = p_store_id
      LOOP
        v_deduct_qty := v_item.ordered_qty * v_recipe.quantity_g;

        UPDATE inventory_items
        SET current_stock = current_stock - v_deduct_qty, updated_at = now()
        WHERE id = v_recipe.ingredient_id
          AND restaurant_id = p_store_id;

        INSERT INTO inventory_transactions (
          restaurant_id, ingredient_id, transaction_type,
          quantity_g, reference_type, reference_id, created_by
        )
        VALUES (
          p_store_id, v_recipe.ingredient_id, 'deduct',
          -v_deduct_qty, 'order_item', v_item.order_item_id, auth.uid()
        );
      END LOOP;
    END LOOP;

    IF v_is_revenue THEN
      SELECT r.tax_entity_id
      INTO v_tax_entity_id
      FROM restaurants r
      WHERE r.id = p_store_id;

      IF v_tax_entity_id IS NOT NULL
         AND NOT EXISTS (
           SELECT 1
           FROM tax_entity
           WHERE id = v_tax_entity_id
             AND tax_code = 'PLACEHOLDER_DEV_000'
         ) THEN
        SELECT id
        INTO v_einvoice_shop_id
        FROM einvoice_shop
        WHERE tax_entity_id = v_tax_entity_id
          AND EXISTS (
            SELECT 1
            FROM jsonb_array_elements(COALESCE(templates, '[]'::jsonb)) AS t
            WHERE t->>'status_code' = '1'
          )
        LIMIT 1;

        IF v_einvoice_shop_id IS NOT NULL THEN
          v_ref_id := generate_uuidv7();

          SELECT jsonb_build_object(
            'ref_id', v_ref_id,
            'cqt_code', '',
            'store_code', COALESCE(es.provider_shop_code, te.tax_code),
            'store_name', COALESCE(es.shop_name, r.name),
            'order_date', v_order_dt,
            'bill_no', v_ref_id,
            'pos_no', '001',
            'trans_type', '1',
            'currency_code', 'VND',
            'exchange_rate', '1.0',
            'payment_method', 'TM/CK',
            'buyer_comp_name', '',
            'buyer_comp_tax_code', '',
            'buyer_comp_address', '',
            'buyer_comp_tel', '',
            'buyer_comp_email', '',
            'buyer_nm', '',
            'buyer_cccd', '',
            'buyer_passport_no', '',
            'buyer_budget_unit_code', '',
            'products', v_products
          )
          INTO v_send_payload
          FROM restaurants r
          JOIN tax_entity te ON te.id = v_tax_entity_id
          JOIN einvoice_shop es ON es.id = v_einvoice_shop_id
          WHERE r.id = p_store_id;

          INSERT INTO einvoice_jobs (
            ref_id, order_id, tax_entity_id, einvoice_shop_id,
            redinvoice_requested, status, send_order_payload
          )
          VALUES (
            v_ref_id, p_order_id, v_tax_entity_id, v_einvoice_shop_id,
            FALSE, 'pending', v_send_payload
          );
        END IF;
      END IF;
    END IF;
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'process_payment',
    'payments',
    v_payment.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', p_order_id,
      'amount', p_amount,
      'input_method', p_method,
      'stored_method', v_payment_method_storage,
      'is_revenue', v_is_revenue,
      'order_total', v_order_total,
      'total_paid_before', v_total_paid_before,
      'total_paid_after', v_total_paid_after,
      'payment_completes_order', v_should_complete,
      'ref_id', v_ref_id,
      'einvoice_job_created', v_ref_id IS NOT NULL
    )
  );

  RETURN v_payment;
END;
$$;


ALTER FUNCTION "public"."process_payment"("p_order_id" "uuid", "p_store_id" "uuid", "p_amount" numeric, "p_method" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recalculate_inventory_purchase_order_totals"("p_purchase_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_supply NUMERIC(12,2);
  v_tax NUMERIC(12,2);
BEGIN
  SELECT
    COALESCE(SUM(supply_amount), 0),
    COALESCE(SUM(tax_amount), 0)
  INTO v_supply, v_tax
  FROM public.inventory_purchase_order_lines
  WHERE purchase_order_id = p_purchase_order_id;

  UPDATE public.inventory_purchase_orders
  SET total_supply_amount = v_supply,
      tax_amount = v_tax,
      total_amount = v_supply + v_tax,
      updated_at = now()
  WHERE id = p_purchase_order_id;
END;
$$;


ALTER FUNCTION "public"."recalculate_inventory_purchase_order_totals"("p_purchase_order_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_attendance_event"("p_store_id" "uuid", "p_user_id" "uuid", "p_type" "text", "p_photo_url" "text" DEFAULT NULL::"text", "p_photo_thumbnail_url" "text" DEFAULT NULL::"text") RETURNS TABLE("attendance_log_id" "uuid", "restaurant_id" "uuid", "user_id" "uuid", "attendance_type" "text", "photo_url" "text", "photo_thumbnail_url" "text", "logged_at" timestamp with time zone, "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_target_user public.users%ROWTYPE;
  v_log public.attendance_logs%ROWTYPE;
  v_photo_url TEXT := NULLIF(btrim(COALESCE(p_photo_url, '')), '');
  v_photo_thumbnail_url TEXT := NULLIF(btrim(COALESCE(p_photo_thumbnail_url, '')), '');
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_FORBIDDEN';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_USER_REQUIRED';
  END IF;

  IF p_type IS NULL OR p_type NOT IN ('clock_in', 'clock_out') THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_TYPE_INVALID';
  END IF;

  SELECT u.*
  INTO v_target_user
  FROM public.users u
  WHERE u.id = p_user_id
    AND u.restaurant_id = p_store_id
    AND u.is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ATTENDANCE_EVENT_USER_NOT_FOUND';
  END IF;

  INSERT INTO public.attendance_logs (
    restaurant_id,
    user_id,
    type,
    photo_url,
    photo_thumbnail_url,
    logged_at
  )
  VALUES (
    p_store_id,
    p_user_id,
    p_type,
    v_photo_url,
    COALESCE(v_photo_thumbnail_url, v_photo_url),
    now()
  )
  RETURNING * INTO v_log;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'attendance_event_recorded',
    'attendance_logs',
    v_log.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'user_id', p_user_id,
      'attendance_type', p_type,
      'logged_at', v_log.logged_at,
      'photo_url', v_log.photo_url,
      'photo_thumbnail_url', v_log.photo_thumbnail_url
    )
  );

  RETURN QUERY
  SELECT
    v_log.id AS attendance_log_id,
    v_log.restaurant_id,
    v_log.user_id,
    v_log.type AS attendance_type,
    v_log.photo_url,
    v_log.photo_thumbnail_url,
    v_log.logged_at,
    v_log.created_at;
END;
$$;


ALTER FUNCTION "public"."record_attendance_event"("p_store_id" "uuid", "p_user_id" "uuid", "p_type" "text", "p_photo_url" "text", "p_photo_thumbnail_url" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_inventory_waste"("p_restaurant_id" "uuid", "p_ingredient_id" "uuid", "p_quantity_g" numeric, "p_note" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor       public.users%ROWTYPE;
  v_ingredient  public.inventory_items%ROWTYPE;
  v_new_stock   DECIMAL(10,3);
BEGIN
  -- Actor validation
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_FORBIDDEN';
  END IF;

  -- Input validation
  IF p_quantity_g IS NULL OR p_quantity_g <= 0 THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_QUANTITY_INVALID';
  END IF;

  -- Lock ingredient row
  SELECT *
  INTO v_ingredient
  FROM public.inventory_items
  WHERE id = p_ingredient_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_INGREDIENT_NOT_FOUND';
  END IF;

  v_new_stock := COALESCE(v_ingredient.current_stock, 0) - p_quantity_g;

  -- Allow negative stock (real-world discrepancy) but warn via audit
  UPDATE public.inventory_items
  SET current_stock = v_new_stock,
      updated_at    = now()
  WHERE id = p_ingredient_id
    AND restaurant_id = p_restaurant_id;

  -- Transaction record (negative quantity for waste)
  INSERT INTO public.inventory_transactions (
    restaurant_id, ingredient_id, transaction_type,
    quantity_g, reference_type, note, created_by
  ) VALUES (
    p_restaurant_id, p_ingredient_id, 'waste',
    -p_quantity_g, 'manual', p_note, v_actor.id
  );

  -- Audit log
  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_waste_recorded',
    'inventory_items',
    p_ingredient_id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'ingredient_name', v_ingredient.name,
      'quantity_g', p_quantity_g,
      'old_stock', COALESCE(v_ingredient.current_stock, 0),
      'new_stock', v_new_stock,
      'note', p_note,
      'went_negative', v_new_stock < 0
    )
  );
END;
$$;


ALTER FUNCTION "public"."record_inventory_waste"("p_restaurant_id" "uuid", "p_ingredient_id" "uuid", "p_quantity_g" numeric, "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_inventory_daily_consumption"("p_store_id" "uuid", "p_from" "date" DEFAULT (CURRENT_DATE - 6), "p_to" "date" DEFAULT CURRENT_DATE) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_store public.restaurants%ROWTYPE;
  v_refreshed_count INTEGER := 0;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_CONSUMPTION_REFRESH_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RAISE EXCEPTION 'INVENTORY_CONSUMPTION_DATE_RANGE_INVALID';
  END IF;

  SELECT * INTO v_store
  FROM public.restaurants
  WHERE id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  WITH aggregated AS (
    SELECT
      p_store_id AS restaurant_id,
      v_store.brand_id AS brand_id,
      ip.id AS product_id,
      o.updated_at::DATE AS consumption_date,
      SUM(oi.quantity)::NUMERIC(12,3) AS sales_quantity,
      SUM(oi.quantity * mr.quantity_g)::NUMERIC(12,3) AS consumed_quantity_base,
      ROUND(
        SUM(oi.quantity * mr.quantity_g * COALESCE(ii.cost_per_unit, 0)),
        2
      ) AS consumed_amount
    FROM public.orders o
    JOIN public.order_items oi
      ON oi.order_id = o.id
     AND oi.restaurant_id = o.restaurant_id
    JOIN public.menu_recipes mr
      ON mr.menu_item_id = oi.menu_item_id
     AND mr.restaurant_id = o.restaurant_id
    JOIN public.inventory_items ii
      ON ii.id = mr.ingredient_id
     AND ii.restaurant_id = o.restaurant_id
    JOIN public.inventory_products ip
      ON ip.inventory_item_id = ii.id
     AND ip.restaurant_id = o.restaurant_id
    WHERE o.restaurant_id = p_store_id
      AND o.status = 'completed'
      AND oi.menu_item_id IS NOT NULL
      AND o.updated_at::DATE BETWEEN p_from AND p_to
    GROUP BY ip.id, o.updated_at::DATE
  ),
  upserted AS (
    INSERT INTO public.inventory_daily_consumption (
      restaurant_id,
      brand_id,
      product_id,
      consumption_date,
      sales_quantity,
      consumed_quantity_base,
      consumed_amount,
      source
    )
    SELECT
      restaurant_id,
      brand_id,
      product_id,
      consumption_date,
      sales_quantity,
      consumed_quantity_base,
      consumed_amount,
      'pos'
    FROM aggregated
    ON CONFLICT (restaurant_id, product_id, consumption_date, source)
    DO UPDATE SET
      sales_quantity = EXCLUDED.sales_quantity,
      consumed_quantity_base = EXCLUDED.consumed_quantity_base,
      consumed_amount = EXCLUDED.consumed_amount
    RETURNING id
  )
  SELECT COUNT(*) INTO v_refreshed_count
  FROM upserted;

  RETURN COALESCE(v_refreshed_count, 0);
END;
$$;


ALTER FUNCTION "public"."refresh_inventory_daily_consumption"("p_store_id" "uuid", "p_from" "date", "p_to" "date") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."qc_checks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "template_id" "uuid" NOT NULL,
    "check_date" "date" NOT NULL,
    "checked_by" "uuid",
    "result" "text" NOT NULL,
    "evidence_photo_url" "text",
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "scheduled_at" timestamp with time zone,
    "due_at" timestamp with time zone,
    "submitted_at" timestamp with time zone,
    "submission_status" "text" DEFAULT 'submitted'::"text" NOT NULL,
    "photo_required_count" integer DEFAULT 0 NOT NULL,
    "photo_uploaded_count" integer DEFAULT 0 NOT NULL,
    "score" numeric(5,2),
    "grade" "text",
    "sv_review_status" "text" DEFAULT 'not_required'::"text" NOT NULL,
    "sv_reviewed_by" "uuid",
    "sv_reviewed_at" timestamp with time zone,
    "sv_score" numeric(5,2),
    "sv_note" "text",
    "visit_session_id" "uuid",
    CONSTRAINT "qc_checks_grade_check" CHECK ((("grade" IS NULL) OR ("grade" = ANY (ARRAY['good'::"text", 'caution'::"text", 'risk'::"text"])))),
    CONSTRAINT "qc_checks_photo_required_count_check" CHECK (("photo_required_count" >= 0)),
    CONSTRAINT "qc_checks_photo_uploaded_count_check" CHECK (("photo_uploaded_count" >= 0)),
    CONSTRAINT "qc_checks_result_check" CHECK (("result" = ANY (ARRAY['pass'::"text", 'fail'::"text", 'na'::"text"]))),
    CONSTRAINT "qc_checks_submission_status_check" CHECK (("submission_status" = ANY (ARRAY['pending'::"text", 'submitted'::"text", 'overdue'::"text"]))),
    CONSTRAINT "qc_checks_sv_review_status_check" CHECK (("sv_review_status" = ANY (ARRAY['not_required'::"text", 'pending'::"text", 'reviewed'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."qc_checks" OWNER TO "postgres";


COMMENT ON COLUMN "public"."qc_checks"."scheduled_at" IS 'Optional scheduled inspection time for QSC v2.';



COMMENT ON COLUMN "public"."qc_checks"."due_at" IS 'Optional due time for QSC completion and overdue calculation.';



COMMENT ON COLUMN "public"."qc_checks"."submitted_at" IS 'Explicit submission timestamp. created_at remains row creation time.';



COMMENT ON COLUMN "public"."qc_checks"."submission_status" IS 'QSC submission lifecycle state: pending, submitted, overdue.';



COMMENT ON COLUMN "public"."qc_checks"."photo_required_count" IS 'Expected number of photos for this check at submission time.';



COMMENT ON COLUMN "public"."qc_checks"."photo_uploaded_count" IS 'Number of photos currently attached to this check.';



COMMENT ON COLUMN "public"."qc_checks"."score" IS 'Operational score recorded for the check.';



COMMENT ON COLUMN "public"."qc_checks"."grade" IS 'Presentation-grade bucket for the check: good, caution, risk.';



COMMENT ON COLUMN "public"."qc_checks"."sv_review_status" IS 'SV review lifecycle state for the check.';



COMMENT ON COLUMN "public"."qc_checks"."sv_reviewed_by" IS 'SV reviewer auth user id.';



COMMENT ON COLUMN "public"."qc_checks"."sv_reviewed_at" IS 'Timestamp when the SV review was completed.';



COMMENT ON COLUMN "public"."qc_checks"."sv_score" IS 'SV-evaluated score for the check.';



COMMENT ON COLUMN "public"."qc_checks"."sv_note" IS 'SV review note or rejection reason.';



COMMENT ON COLUMN "public"."qc_checks"."visit_session_id" IS 'Optional grouping key linking several checks to a single visit/review session.';



CREATE OR REPLACE FUNCTION "public"."refresh_qc_check_photo_summary"("p_check_id" "uuid", "p_sync_legacy_photo" boolean DEFAULT true) RETURNS "public"."qc_checks"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_check public.qc_checks%ROWTYPE;
  v_required_count INTEGER;
  v_uploaded_count INTEGER;
  v_primary_photo_url TEXT;
BEGIN
  SELECT qc.*
  INTO v_check
  FROM public.qc_checks qc
  WHERE qc.id = p_check_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_CHECK_NOT_FOUND';
  END IF;

  SELECT
    CASE
      WHEN COALESCE(qt.requires_photo, TRUE) THEN COALESCE(qt.required_photo_count, 1)
      ELSE 0
    END
  INTO v_required_count
  FROM public.qc_templates qt
  WHERE qt.id = v_check.template_id;

  SELECT COUNT(*)::INTEGER
  INTO v_uploaded_count
  FROM public.qc_check_photos p
  WHERE p.check_id = p_check_id;

  SELECT p.photo_url
  INTO v_primary_photo_url
  FROM public.qc_check_photos p
  WHERE p.check_id = p_check_id
  ORDER BY p.is_primary DESC, p.uploaded_at DESC, p.id DESC
  LIMIT 1;

  UPDATE public.qc_checks qc
  SET
    photo_required_count = COALESCE(qc.photo_required_count, v_required_count),
    photo_uploaded_count = COALESCE(v_uploaded_count, 0),
    evidence_photo_url = CASE
      WHEN p_sync_legacy_photo THEN v_primary_photo_url
      ELSE qc.evidence_photo_url
    END
  WHERE qc.id = p_check_id
  RETURNING * INTO v_check;

  RETURN v_check;
END;
$$;


ALTER FUNCTION "public"."refresh_qc_check_photo_summary"("p_check_id" "uuid", "p_sync_legacy_photo" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."refresh_qc_check_photo_summary"("p_check_id" "uuid", "p_sync_legacy_photo" boolean) IS 'Internal helper that recomputes photo counters and representative photo URL on qc_checks from qc_check_photos.';



CREATE OR REPLACE FUNCTION "public"."refresh_user_claims"("p_auth_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_brand_ids uuid[];
  v_store_ids uuid[];
  v_tax_entity_ids uuid[];
  v_primary_store_id uuid;
  v_claims jsonb;
BEGIN
  SELECT *
  INTO v_user
  FROM public.users
  WHERE auth_id = p_auth_user_id
  LIMIT 1;

  IF NOT FOUND OR v_user.is_active IS NOT TRUE THEN
    v_claims := jsonb_build_object(
      'role', NULL,
      'brand_ids', '[]'::jsonb,
      'accessible_store_ids', '[]'::jsonb,
      'accessible_tax_entity_ids', '[]'::jsonb,
      'primary_store_id', NULL
    );
  ELSE
    v_brand_ids := ARRAY(SELECT * FROM public.user_accessible_brands(p_auth_user_id));
    v_store_ids := ARRAY(SELECT * FROM public.user_accessible_stores(p_auth_user_id));
    v_tax_entity_ids := ARRAY(SELECT * FROM public.user_accessible_tax_entities(p_auth_user_id));
    v_primary_store_id := COALESCE(v_user.primary_store_id, v_user.restaurant_id);

    v_claims := jsonb_build_object(
      'role', v_user.role,
      'brand_ids', to_jsonb(COALESCE(v_brand_ids, ARRAY[]::uuid[])),
      'accessible_store_ids', to_jsonb(COALESCE(v_store_ids, ARRAY[]::uuid[])),
      'accessible_tax_entity_ids', to_jsonb(COALESCE(v_tax_entity_ids, ARRAY[]::uuid[])),
      'primary_store_id', to_jsonb(v_primary_store_id)
    );
  END IF;

  UPDATE auth.users
  SET raw_app_meta_data =
    COALESCE(raw_app_meta_data, '{}'::jsonb)
    - 'role'
    - 'brand_ids'
    - 'accessible_store_ids'
    - 'accessible_tax_entity_ids'
    - 'primary_store_id'
    || v_claims
  WHERE id = p_auth_user_id;

  RETURN v_claims;
END;
$$;


ALTER FUNCTION "public"."refresh_user_claims"("p_auth_user_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."refresh_user_claims"("p_auth_user_id" "uuid") IS 'Recomputes and persists app metadata claims for an auth.users.id after access or role changes.';



CREATE OR REPLACE FUNCTION "public"."request_red_invoice"("p_order_id" "uuid", "p_store_id" "uuid", "p_buyer_tax_code" "text", "p_buyer_name" "text", "p_buyer_address" "text", "p_receiver_email" "text", "p_receiver_email_cc" "text" DEFAULT NULL::"text", "p_buyer_tel" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
  v_job einvoice_jobs%ROWTYPE;
  v_shop einvoice_shop%ROWTYPE;
  v_te tax_entity%ROWTYPE;
  v_restaurant restaurants%ROWTYPE;
  v_ref_id text;
  v_store_code text;
  v_store_name text;
  v_order_date text;
  v_request_payload jsonb;
  v_photo_objet_brand_id constant uuid := '77000000-0000-0000-0000-000000000001';
BEGIN
  SELECT * INTO v_actor
  FROM users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_REQUIRED';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  IF p_receiver_email IS NULL OR trim(p_receiver_email) = '' THEN
    RAISE EXCEPTION 'EMAIL_REQUIRED';
  END IF;

  SELECT * INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  SELECT * INTO v_job
  FROM einvoice_jobs
  WHERE order_id = p_order_id
  ORDER BY created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'JOB_NOT_FOUND';
  END IF;

  IF v_job.status IN ('failed_terminal') THEN
    RAISE EXCEPTION 'JOB_FAILED';
  END IF;

  SELECT * INTO v_shop FROM einvoice_shop WHERE id = v_job.einvoice_shop_id;
  SELECT * INTO v_te FROM tax_entity WHERE id = v_job.tax_entity_id;
  SELECT * INTO v_restaurant FROM restaurants WHERE id = p_store_id;

  IF v_restaurant.brand_id = v_photo_objet_brand_id THEN
    RAISE EXCEPTION 'RED_INVOICE_DISABLED_FOR_PHOTO_OBJET';
  END IF;

  v_store_code := COALESCE(v_shop.provider_shop_code, v_te.tax_code);
  v_store_name := COALESCE(v_shop.shop_name, v_restaurant.name, 'GLOBOSVN');
  v_ref_id := v_job.ref_id;
  v_order_date := to_char(v_order.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh', 'YYYYMMDD');

  SELECT jsonb_build_object(
    'bills', jsonb_build_array(
      jsonb_build_object(
        'ref_id', v_ref_id,
        'tax_id', COALESCE(p_buyer_tax_code, ''),
        'tax_company_name', COALESCE(p_buyer_name, ''),
        'tax_address', COALESCE(p_buyer_address, ''),
        'tax_buyer_name', '',
        'receiver_email', p_receiver_email,
        'receiver_email_cc', COALESCE(p_receiver_email_cc, ''),
        'order_date', v_order_date,
        'store_code', v_store_code,
        'store_name', v_store_name,
        'pos_number', COALESCE(v_job.send_order_payload->>'pos_no', '001'),
        'order_id', COALESCE(v_job.send_order_payload->>'bill_no', v_ref_id)
      )
    )
  ) INTO v_request_payload;

  UPDATE einvoice_jobs
  SET
    redinvoice_requested = TRUE,
    request_einvoice_payload = v_request_payload,
    request_einvoice_retry_count = 0,
    request_einvoice_next_retry_at = NULL,
    error_classification = NULL,
    error_message = NULL,
    updated_at = now()
  WHERE id = v_job.id;

  IF p_buyer_tax_code IS NOT NULL AND p_buyer_tax_code <> '' THEN
    INSERT INTO b2b_buyer_cache (
      store_id, buyer_tax_code, tax_company_name,
      tax_address, receiver_email, receiver_email_cc,
      first_used_at, last_used_at, use_count, tax_entity_id
    ) VALUES (
      p_store_id,
      p_buyer_tax_code,
      COALESCE(p_buyer_name, ''),
      COALESCE(p_buyer_address, ''),
      p_receiver_email,
      p_receiver_email_cc,
      now(), now(), 1,
      v_te.id
    )
    ON CONFLICT (store_id, buyer_tax_code) DO UPDATE SET
      tax_company_name = EXCLUDED.tax_company_name,
      tax_address = EXCLUDED.tax_address,
      receiver_email = EXCLUDED.receiver_email,
      receiver_email_cc = EXCLUDED.receiver_email_cc,
      last_used_at = now(),
      use_count = b2b_buyer_cache.use_count + 1;
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'request_red_invoice',
    'einvoice_jobs',
    v_job.id,
    jsonb_build_object(
      'order_id', p_order_id,
      'store_id', p_store_id,
      'buyer_tax_code', p_buyer_tax_code,
      'receiver_email', p_receiver_email,
      'payload_type', 'requestEinvoiceInfo'
    )
  );

  RETURN jsonb_build_object('ok', true, 'job_id', v_job.id, 'ref_id', v_ref_id);
END;
$$;


ALTER FUNCTION "public"."request_red_invoice"("p_order_id" "uuid", "p_store_id" "uuid", "p_buyer_tax_code" "text", "p_buyer_name" "text", "p_buyer_address" "text", "p_receiver_email" "text", "p_receiver_email_cc" "text", "p_buyer_tel" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."require_admin_actor_for_restaurant"("p_restaurant_id" "uuid") RETURNS "public"."users"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'ADMIN_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'ADMIN_MUTATION_FORBIDDEN';
  END IF;

  RETURN v_actor;
END;
$$;


ALTER FUNCTION "public"."require_admin_actor_for_restaurant"("p_restaurant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."restock_inventory_item"("p_restaurant_id" "uuid", "p_ingredient_id" "uuid", "p_quantity_g" numeric, "p_note" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor       public.users%ROWTYPE;
  v_ingredient  public.inventory_items%ROWTYPE;
  v_new_stock   DECIMAL(10,3);
BEGIN
  -- Actor validation
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_FORBIDDEN';
  END IF;

  -- Input validation
  IF p_quantity_g IS NULL OR p_quantity_g <= 0 THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_QUANTITY_INVALID';
  END IF;

  -- Lock ingredient row
  SELECT *
  INTO v_ingredient
  FROM public.inventory_items
  WHERE id = p_ingredient_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_INGREDIENT_NOT_FOUND';
  END IF;

  v_new_stock := COALESCE(v_ingredient.current_stock, 0) + p_quantity_g;

  -- Atomic stock update
  UPDATE public.inventory_items
  SET current_stock = v_new_stock,
      updated_at    = now()
  WHERE id = p_ingredient_id
    AND restaurant_id = p_restaurant_id;

  -- Transaction record
  INSERT INTO public.inventory_transactions (
    restaurant_id, ingredient_id, transaction_type,
    quantity_g, reference_type, note, created_by
  ) VALUES (
    p_restaurant_id, p_ingredient_id, 'restock',
    p_quantity_g, 'manual', p_note, v_actor.id
  );

  -- Audit log
  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_restocked',
    'inventory_items',
    p_ingredient_id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'ingredient_name', v_ingredient.name,
      'quantity_g', p_quantity_g,
      'old_stock', COALESCE(v_ingredient.current_stock, 0),
      'new_stock', v_new_stock,
      'note', p_note
    )
  );
END;
$$;


ALTER FUNCTION "public"."restock_inventory_item"("p_restaurant_id" "uuid", "p_ingredient_id" "uuid", "p_quantity_g" numeric, "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."run_inventory_purchase_recommendation"("p_store_id" "uuid", "p_target_stock_days" numeric DEFAULT 3, "p_as_of_date" "date" DEFAULT CURRENT_DATE) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_brand_id UUID;
  v_run_id UUID;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;

  IF p_target_stock_days IS NULL OR p_target_stock_days <= 0 THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_TARGET_DAYS_INVALID';
  END IF;

  SELECT brand_id
  INTO v_brand_id
  FROM public.restaurants
  WHERE id = p_store_id;

  INSERT INTO public.inventory_recommendation_runs (
    restaurant_id,
    brand_id,
    run_date,
    target_stock_days,
    created_by
  )
  VALUES (
    p_store_id,
    v_brand_id,
    p_as_of_date,
    p_target_stock_days,
    auth.uid()
  )
  RETURNING id INTO v_run_id;

  INSERT INTO public.inventory_recommendation_lines (
    run_id,
    product_id,
    supplier_id,
    current_stock_base,
    avg_daily_consumption_base,
    target_stock_days,
    recommended_quantity_base,
    recommended_order_units,
    estimated_days_remaining,
    risk_status
  )
  SELECT
    v_run_id,
    status.product_id,
    supplier_pick.supplier_id,
    status.current_stock_base,
    status.avg_daily_consumption_base,
    p_target_stock_days,
    GREATEST(0, ROUND((p_target_stock_days * status.avg_daily_consumption_base) - status.current_stock_base, 3)) AS recommended_quantity_base,
    CASE
      WHEN supplier_pick.order_unit_quantity_base IS NULL THEN 0
      ELSE GREATEST(
        COALESCE(supplier_pick.min_order_quantity, 1),
        CEIL(
          GREATEST(0, (p_target_stock_days * status.avg_daily_consumption_base) - status.current_stock_base)
          / supplier_pick.order_unit_quantity_base
        )
      )
    END AS recommended_order_units,
    status.estimated_days_remaining,
    status.risk_status
  FROM public.get_inventory_stock_status(p_store_id, p_as_of_date) status
  LEFT JOIN LATERAL (
    SELECT
      isi.supplier_id,
      isi.order_unit_quantity_base,
      isi.min_order_quantity
    FROM public.inventory_supplier_items isi
    WHERE isi.product_id = status.product_id
      AND isi.is_active = TRUE
    ORDER BY isi.is_preferred DESC, isi.updated_at DESC
    LIMIT 1
  ) supplier_pick ON TRUE
  WHERE status.avg_daily_consumption_base > 0;

  RETURN v_run_id;
END;
$$;


ALTER FUNCTION "public"."run_inventory_purchase_recommendation"("p_store_id" "uuid", "p_target_stock_days" numeric, "p_as_of_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_inventory_stock_audit"("p_store_id" "uuid", "p_lines" "jsonb", "p_memo" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_brand_id UUID;
  v_session_id UUID;
  v_line JSONB;
  v_product_id UUID;
  v_actual_quantity_base NUMERIC(12,3);
  v_line_memo TEXT;
  v_product public.inventory_products%ROWTYPE;
  v_item public.inventory_items%ROWTYPE;
  v_variance_quantity_base NUMERIC(12,3);
  v_variance_amount NUMERIC(12,2);
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_FORBIDDEN';
  END IF;

  IF p_lines IS NULL
     OR jsonb_typeof(p_lines) <> 'array'
     OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_LINES_REQUIRED';
  END IF;

  SELECT brand_id
  INTO v_brand_id
  FROM public.restaurants
  WHERE id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_STORE_NOT_FOUND';
  END IF;

  INSERT INTO public.inventory_stock_audit_sessions (
    restaurant_id,
    brand_id,
    audit_no,
    audit_type,
    status,
    planned_date,
    started_at,
    completed_at,
    created_by,
    assigned_to,
    memo
  )
  VALUES (
    p_store_id,
    v_brand_id,
    'INV-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || upper(substr(replace(gen_random_uuid()::TEXT, '-', ''), 1, 6)),
    'daily',
    'in_progress',
    CURRENT_DATE,
    now(),
    NULL,
    auth.uid(),
    auth.uid(),
    NULLIF(btrim(COALESCE(p_memo, '')), '')
  )
  RETURNING id INTO v_session_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_product_id := NULLIF(v_line->>'product_id', '')::UUID;
    v_actual_quantity_base := NULLIF(v_line->>'actual_quantity_base', '')::NUMERIC;
    v_line_memo := NULLIF(btrim(COALESCE(v_line->>'memo', '')), '');

    IF v_product_id IS NULL THEN
      RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_PRODUCT_REQUIRED';
    END IF;

    IF v_actual_quantity_base IS NULL OR v_actual_quantity_base < 0 THEN
      RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_ACTUAL_INVALID';
    END IF;

    SELECT *
    INTO v_product
    FROM public.inventory_products
    WHERE id = v_product_id
      AND restaurant_id = p_store_id
      AND is_active = TRUE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_PRODUCT_NOT_FOUND';
    END IF;

    IF v_product.inventory_item_id IS NULL THEN
      RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_ITEM_NOT_LINKED';
    END IF;

    SELECT *
    INTO v_item
    FROM public.inventory_items
    WHERE id = v_product.inventory_item_id
      AND restaurant_id = p_store_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'INVENTORY_STOCK_AUDIT_ITEM_NOT_FOUND';
    END IF;

    v_variance_quantity_base := v_actual_quantity_base - COALESCE(v_item.current_stock, 0);
    v_variance_amount := ROUND(v_variance_quantity_base * COALESCE(v_item.cost_per_unit, 0), 2);

    INSERT INTO public.inventory_stock_audit_lines (
      session_id,
      product_id,
      theoretical_quantity_base,
      actual_quantity_base,
      variance_quantity_base,
      variance_amount,
      status,
      memo
    )
    VALUES (
      v_session_id,
      v_product_id,
      COALESCE(v_item.current_stock, 0),
      v_actual_quantity_base,
      v_variance_quantity_base,
      v_variance_amount,
      'counted',
      v_line_memo
    );

    UPDATE public.inventory_items
    SET current_stock = v_actual_quantity_base,
        quantity = v_actual_quantity_base,
        updated_at = now()
    WHERE id = v_item.id
      AND restaurant_id = p_store_id;

    INSERT INTO public.inventory_transactions (
      restaurant_id,
      ingredient_id,
      transaction_type,
      quantity_g,
      reference_type,
      reference_id,
      note,
      created_by
    )
    VALUES (
      p_store_id,
      v_item.id,
      'adjust',
      v_variance_quantity_base,
      'inventory_stock_audit',
      v_session_id,
      COALESCE(v_line_memo, NULLIF(btrim(COALESCE(p_memo, '')), ''), '실재고 실사'),
      auth.uid()
    );
  END LOOP;

  UPDATE public.inventory_stock_audit_sessions
  SET status = 'completed',
      completed_at = now(),
      updated_at = now()
  WHERE id = v_session_id;

  RETURN v_session_id;
END;
$$;


ALTER FUNCTION "public"."save_inventory_stock_audit"("p_store_id" "uuid", "p_lines" "jsonb", "p_memo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_b2b_buyers"("p_store_id" "uuid", "p_query" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_tax_entity_id uuid;
  v_query text := btrim(COALESCE(p_query, ''));
  v_result jsonb;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_REQUIRED';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  IF length(v_query) < 2 THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT tax_entity_id
  INTO v_tax_entity_id
  FROM restaurants
  WHERE id = p_store_id;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'buyer_tax_code', ranked.buyer_tax_code,
        'tax_company_name', ranked.tax_company_name,
        'tax_address', ranked.tax_address,
        'receiver_email', ranked.receiver_email,
        'receiver_email_cc', ranked.receiver_email_cc
      )
      ORDER BY ranked.store_priority DESC, ranked.last_used_at DESC
    ),
    '[]'::jsonb
  )
  INTO v_result
  FROM (
    SELECT
      buyer_tax_code,
      tax_company_name,
      tax_address,
      receiver_email,
      receiver_email_cc,
      last_used_at,
      (store_id = p_store_id) AS store_priority
    FROM b2b_buyer_cache
    WHERE (
        store_id = p_store_id
        OR (v_tax_entity_id IS NOT NULL AND tax_entity_id = v_tax_entity_id)
      )
      AND (
        buyer_tax_code ILIKE v_query || '%'
        OR tax_company_name ILIKE '%' || v_query || '%'
      )
    ORDER BY (store_id = p_store_id) DESC, last_used_at DESC
    LIMIT 5
  ) ranked;

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."search_b2b_buyers"("p_store_id" "uuid", "p_query" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_products" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "brand_id" "uuid",
    "inventory_item_id" "uuid",
    "product_code" "text",
    "name" "text" NOT NULL,
    "category" "text",
    "stock_unit" "text" DEFAULT 'kg'::"text" NOT NULL,
    "base_unit" "text" DEFAULT 'g'::"text" NOT NULL,
    "base_unit_factor" numeric(12,3) DEFAULT 1000 NOT NULL,
    "image_url" "text",
    "storage_type" "text",
    "shelf_life_days" integer,
    "is_orderable" boolean DEFAULT true NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "inventory_products_base_unit_check" CHECK (("base_unit" = ANY (ARRAY['g'::"text", 'ml'::"text", 'ea'::"text"]))),
    CONSTRAINT "inventory_products_base_unit_factor_check" CHECK (("base_unit_factor" > (0)::numeric)),
    CONSTRAINT "inventory_products_shelf_life_days_check" CHECK ((("shelf_life_days" IS NULL) OR ("shelf_life_days" >= 0)))
);


ALTER TABLE "public"."inventory_products" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_inventory_product_active"("p_store_id" "uuid", "p_product_id" "uuid", "p_is_active" boolean) RETURNS "public"."inventory_products"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_product public.inventory_products%ROWTYPE;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_PRODUCT_FORBIDDEN';
  END IF;

  UPDATE public.inventory_products
  SET is_active = COALESCE(p_is_active, FALSE),
      is_orderable = CASE WHEN COALESCE(p_is_active, FALSE) THEN is_orderable ELSE FALSE END,
      updated_at = now()
  WHERE id = p_product_id
    AND restaurant_id = p_store_id
  RETURNING * INTO v_product;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRODUCT_NOT_FOUND';
  END IF;

  IF v_product.inventory_item_id IS NOT NULL THEN
    UPDATE public.inventory_items
    SET is_active = COALESCE(p_is_active, FALSE)
    WHERE id = v_product.inventory_item_id
      AND restaurant_id = p_store_id;
  END IF;

  RETURN v_product;
END;
$$;


ALTER FUNCTION "public"."set_inventory_product_active"("p_store_id" "uuid", "p_product_id" "uuid", "p_is_active" boolean) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_supplier_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "supplier_id" "uuid" NOT NULL,
    "product_id" "uuid" NOT NULL,
    "supplier_sku" "text",
    "order_unit" "text" NOT NULL,
    "order_unit_quantity_base" numeric(12,3) NOT NULL,
    "min_order_quantity" numeric(12,3) DEFAULT 1 NOT NULL,
    "unit_price" numeric(12,2) DEFAULT 0 NOT NULL,
    "tax_rate" numeric(5,2) DEFAULT 0 NOT NULL,
    "lead_time_days" integer DEFAULT 1 NOT NULL,
    "is_preferred" boolean DEFAULT false NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "inventory_supplier_items_lead_time_days_check" CHECK (("lead_time_days" >= 0)),
    CONSTRAINT "inventory_supplier_items_min_order_quantity_check" CHECK (("min_order_quantity" > (0)::numeric)),
    CONSTRAINT "inventory_supplier_items_order_unit_quantity_base_check" CHECK (("order_unit_quantity_base" > (0)::numeric)),
    CONSTRAINT "inventory_supplier_items_tax_rate_check" CHECK (("tax_rate" >= (0)::numeric)),
    CONSTRAINT "inventory_supplier_items_unit_price_check" CHECK (("unit_price" >= (0)::numeric))
);


ALTER TABLE "public"."inventory_supplier_items" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_inventory_supplier_item_active"("p_store_id" "uuid", "p_supplier_item_id" "uuid", "p_is_active" boolean) RETURNS "public"."inventory_supplier_items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_item public.inventory_supplier_items%ROWTYPE;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_SUPPLIER_ITEM_FORBIDDEN';
  END IF;

  UPDATE public.inventory_supplier_items si
  SET is_active = COALESCE(p_is_active, FALSE),
      updated_at = now()
  FROM public.inventory_products p
  WHERE si.id = p_supplier_item_id
    AND si.product_id = p.id
    AND p.restaurant_id = p_store_id
  RETURNING si.* INTO v_item;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SUPPLIER_ITEM_NOT_FOUND';
  END IF;

  RETURN v_item;
END;
$$;


ALTER FUNCTION "public"."set_inventory_supplier_item_active"("p_store_id" "uuid", "p_supplier_item_id" "uuid", "p_is_active" boolean) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_suppliers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "brand_id" "uuid",
    "supplier_name" "text" NOT NULL,
    "supplier_type" "text",
    "contact_name" "text",
    "phone" "text",
    "email" "text",
    "address" "text",
    "business_registration_no" "text",
    "payment_terms" "text",
    "contract_start_date" "date",
    "contract_end_date" "date",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "memo" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "inventory_suppliers_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'inactive'::"text", 'suspended'::"text"])))
);


ALTER TABLE "public"."inventory_suppliers" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_inventory_supplier_status"("p_store_id" "uuid", "p_supplier_id" "uuid", "p_status" "text") RETURNS "public"."inventory_suppliers"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_store public.restaurants%ROWTYPE;
  v_supplier public.inventory_suppliers%ROWTYPE;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_SUPPLIER_FORBIDDEN';
  END IF;

  IF p_status NOT IN ('active', 'inactive', 'suspended') THEN
    RAISE EXCEPTION 'SUPPLIER_STATUS_INVALID';
  END IF;

  SELECT * INTO v_store
  FROM public.restaurants
  WHERE id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  UPDATE public.inventory_suppliers
  SET status = p_status,
      updated_at = now()
  WHERE id = p_supplier_id
    AND (brand_id IS NULL OR brand_id = v_store.brand_id)
  RETURNING * INTO v_supplier;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SUPPLIER_NOT_FOUND';
  END IF;

  RETURN v_supplier;
END;
$$;


ALTER FUNCTION "public"."set_inventory_supplier_status"("p_store_id" "uuid", "p_supplier_id" "uuid", "p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_qc_visit_review"("p_store_id" "uuid", "p_check_ids" "uuid"[], "p_sv_review_status" "text", "p_sv_score" numeric DEFAULT NULL::numeric, "p_sv_note" "text" DEFAULT NULL::"text", "p_visit_session_id" "uuid" DEFAULT NULL::"uuid", "p_reviewed_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_reviewed_by" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("check_id" "uuid", "sv_review_status" "text", "sv_reviewed_by" "uuid", "sv_reviewed_at" timestamp with time zone, "sv_score" numeric, "visit_session_id" "uuid")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_can_review BOOLEAN;
  v_reviewed_by UUID := COALESCE(p_reviewed_by, auth.uid());
  v_note TEXT := NULLIF(btrim(COALESCE(p_sv_note, '')), '');
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_VISIT_REVIEW_FORBIDDEN';
  END IF;

  v_can_review := v_actor.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
    OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check'];

  IF NOT v_can_review THEN
    RAISE EXCEPTION 'QC_VISIT_REVIEW_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'QC_VISIT_REVIEW_FORBIDDEN';
  END IF;

  IF p_check_ids IS NULL OR cardinality(p_check_ids) = 0 THEN
    RAISE EXCEPTION 'QC_VISIT_REVIEW_CHECKS_REQUIRED';
  END IF;

  IF p_sv_review_status NOT IN ('pending', 'reviewed', 'rejected') THEN
    RAISE EXCEPTION 'QC_VISIT_REVIEW_STATUS_INVALID';
  END IF;

  IF v_reviewed_by <> auth.uid() THEN
    RAISE EXCEPTION 'QC_VISIT_REVIEW_ACTOR_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(p_check_ids) cid
    LEFT JOIN public.qc_checks qc
      ON qc.id = cid
     AND qc.restaurant_id = p_store_id
    WHERE qc.id IS NULL
  ) THEN
    RAISE EXCEPTION 'QC_VISIT_REVIEW_CHECK_NOT_FOUND';
  END IF;

  RETURN QUERY
  UPDATE public.qc_checks qc
  SET
    sv_review_status = p_sv_review_status,
    sv_reviewed_by = CASE
      WHEN p_sv_review_status IN ('reviewed', 'rejected') THEN v_reviewed_by
      ELSE qc.sv_reviewed_by
    END,
    sv_reviewed_at = CASE
      WHEN p_sv_review_status IN ('reviewed', 'rejected') THEN COALESCE(p_reviewed_at, now())
      ELSE p_reviewed_at
    END,
    sv_score = COALESCE(p_sv_score, qc.sv_score),
    sv_note = COALESCE(v_note, qc.sv_note),
    visit_session_id = COALESCE(p_visit_session_id, qc.visit_session_id)
  WHERE qc.restaurant_id = p_store_id
    AND qc.id = ANY(p_check_ids)
  RETURNING
    qc.id,
    qc.sv_review_status,
    qc.sv_reviewed_by,
    qc.sv_reviewed_at,
    qc.sv_score,
    qc.visit_session_id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_visit_review_submitted',
    'qc_checks',
    COALESCE(p_check_ids[1], gen_random_uuid()),
    jsonb_build_object(
      'store_id', p_store_id,
      'check_ids', p_check_ids,
      'sv_review_status', p_sv_review_status,
      'sv_score', p_sv_score,
      'sv_note', v_note,
      'visit_session_id', p_visit_session_id
    )
  );
END;
$$;


ALTER FUNCTION "public"."submit_qc_visit_review"("p_store_id" "uuid", "p_check_ids" "uuid"[], "p_sv_review_status" "text", "p_sv_score" numeric, "p_sv_note" "text", "p_visit_session_id" "uuid", "p_reviewed_at" timestamp with time zone, "p_reviewed_by" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_all_store_access"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_user_id uuid;
BEGIN
  FOR v_user_id IN
    SELECT id
    FROM public.users
  LOOP
    PERFORM public.sync_user_store_access(v_user_id);
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."sync_all_store_access"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."sync_all_store_access"() IS 'Recomputes inherited store access for all users. Intended for backfill and operator recovery flows.';



CREATE OR REPLACE FUNCTION "public"."sync_brand_store_access"("p_brand_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_user_id uuid;
BEGIN
  FOR v_user_id IN
    SELECT DISTINCT u.id
    FROM public.users u
    JOIN public.user_brand_access uba
      ON uba.user_id = u.id
    WHERE uba.brand_id = p_brand_id
  LOOP
    PERFORM public.sync_user_store_access(v_user_id);
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."sync_brand_store_access"("p_brand_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."sync_brand_store_access"("p_brand_id" "uuid") IS 'Recomputes inherited store access for all users connected to a brand.';



CREATE OR REPLACE FUNCTION "public"."sync_user_store_access"("p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_user public.users%ROWTYPE;
BEGIN
  SELECT *
  INTO v_user
  FROM public.users
  WHERE id = p_user_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_user.is_active IS NOT TRUE THEN
    UPDATE public.user_store_access
    SET
      is_active = false,
      updated_at = now()
    WHERE user_id = p_user_id
      AND source_type = 'brand_inherited'
      AND is_active = true;
    RETURN;
  END IF;

  INSERT INTO public.user_store_access (
    user_id,
    store_id,
    is_primary,
    is_active,
    source_type,
    source_brand_access_id,
    granted_by
  )
  SELECT
    v_user.id,
    r.id,
    false,
    true,
    'brand_inherited',
    uba.id,
    NULL
  FROM public.user_brand_access uba
  JOIN public.restaurants r
    ON r.brand_id = uba.brand_id
  WHERE uba.user_id = v_user.id
    AND uba.is_active = true
    AND r.is_active = true
    AND v_user.role <> 'super_admin'
  ON CONFLICT (user_id, store_id, source_type)
  DO UPDATE SET
    is_active = true,
    is_primary = false,
    source_brand_access_id = EXCLUDED.source_brand_access_id,
    updated_at = now();

  UPDATE public.user_store_access usa
  SET
    is_active = false,
    updated_at = now()
  WHERE usa.user_id = v_user.id
    AND usa.source_type = 'brand_inherited'
    AND usa.is_active = true
    AND NOT EXISTS (
      SELECT 1
      FROM public.user_brand_access uba
      JOIN public.restaurants r
        ON r.brand_id = uba.brand_id
      WHERE uba.user_id = v_user.id
        AND uba.is_active = true
        AND r.is_active = true
        AND r.id = usa.store_id
        AND v_user.role <> 'super_admin'
    );
END;
$$;


ALTER FUNCTION "public"."sync_user_store_access"("p_user_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."sync_user_store_access"("p_user_id" "uuid") IS 'Recomputes brand-inherited store access rows for a single public.users.id. direct rows are preserved.';



CREATE OR REPLACE FUNCTION "public"."transfer_order_table"("p_order_id" "uuid", "p_restaurant_id" "uuid", "p_new_table_id" "uuid") RETURNS "public"."orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
  v_old_table_id UUID;
  v_new_table tables%ROWTYPE;
BEGIN
  -- Actor validation
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  -- Lock order
  SELECT *
  INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  v_old_table_id := v_order.table_id;

  -- Cannot transfer to same table
  IF v_old_table_id = p_new_table_id THEN
    RAISE EXCEPTION 'TRANSFER_SAME_TABLE';
  END IF;

  -- Lock and validate new table
  SELECT *
  INTO v_new_table
  FROM tables
  WHERE id = p_new_table_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  IF v_new_table.status <> 'available' THEN
    RAISE EXCEPTION 'TABLE_ALREADY_OCCUPIED';
  END IF;

  -- Move order to new table
  UPDATE orders
  SET table_id = p_new_table_id,
      updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  -- Occupy new table
  UPDATE tables
  SET status = 'occupied',
      updated_at = now()
  WHERE id = p_new_table_id;

  -- Release old table (if it had one)
  IF v_old_table_id IS NOT NULL THEN
    UPDATE tables
    SET status = 'available',
        updated_at = now()
    WHERE id = v_old_table_id;
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'transfer_order_table',
    'orders',
    p_order_id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'old_table_id', v_old_table_id,
      'new_table_id', p_new_table_id,
      'new_table_number', v_new_table.table_number
    )
  );

  RETURN v_order;
END;
$$;


ALTER FUNCTION "public"."transfer_order_table"("p_order_id" "uuid", "p_restaurant_id" "uuid", "p_new_table_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_inventory_item"("p_item_id" "uuid", "p_restaurant_id" "uuid", "p_patch" "jsonb") RETURNS "public"."inventory_items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_existing public.inventory_items%ROWTYPE;
  v_updated public.inventory_items%ROWTYPE;
  v_supported_keys CONSTANT TEXT[] := ARRAY[
    'name',
    'unit',
    'current_stock',
    'reorder_point',
    'cost_per_unit',
    'supplier_name'
  ];
  v_key TEXT;
  v_name TEXT;
  v_unit TEXT;
  v_current_stock DECIMAL(12,3);
  v_reorder_point DECIMAL(12,3);
  v_cost_per_unit DECIMAL(12,2);
  v_supplier_name TEXT;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_WRITE_FORBIDDEN';
  END IF;

  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_PATCH_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM jsonb_object_keys(p_patch) AS k(key)
    WHERE k.key = ANY(v_supported_keys)
  ) THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_PATCH_EMPTY';
  END IF;

  FOR v_key IN
    SELECT key
    FROM jsonb_object_keys(p_patch) AS k(key)
  LOOP
    IF NOT (v_key = ANY(v_supported_keys)) THEN
      RAISE EXCEPTION 'INVENTORY_ITEM_PATCH_UNSUPPORTED';
    END IF;
  END LOOP;

  SELECT *
  INTO v_existing
  FROM public.inventory_items
  WHERE id = p_item_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_NOT_FOUND';
  END IF;

  v_name := v_existing.name;
  v_unit := v_existing.unit;
  v_current_stock := v_existing.current_stock;
  v_reorder_point := v_existing.reorder_point;
  v_cost_per_unit := v_existing.cost_per_unit;
  v_supplier_name := v_existing.supplier_name;

  IF p_patch ? 'name' THEN
    v_name := btrim(COALESCE(p_patch->>'name', ''));
    IF v_name = '' THEN
      RAISE EXCEPTION 'INVENTORY_ITEM_NAME_REQUIRED';
    END IF;
  END IF;

  IF p_patch ? 'unit' THEN
    v_unit := btrim(COALESCE(p_patch->>'unit', ''));
    IF v_unit NOT IN ('g', 'ml', 'ea') THEN
      RAISE EXCEPTION 'INVENTORY_ITEM_UNIT_INVALID';
    END IF;
  END IF;

  IF p_patch ? 'current_stock' THEN
    IF jsonb_typeof(p_patch->'current_stock') = 'null' THEN
      RAISE EXCEPTION 'INVENTORY_ITEM_CURRENT_STOCK_REQUIRED';
    END IF;
    v_current_stock := (p_patch->>'current_stock')::DECIMAL(12,3);
    IF v_current_stock < 0 THEN
      RAISE EXCEPTION 'INVENTORY_ITEM_CURRENT_STOCK_INVALID';
    END IF;
  END IF;

  IF p_patch ? 'reorder_point' THEN
    IF jsonb_typeof(p_patch->'reorder_point') = 'null' THEN
      v_reorder_point := NULL;
    ELSE
      v_reorder_point := (p_patch->>'reorder_point')::DECIMAL(12,3);
      IF v_reorder_point < 0 THEN
        RAISE EXCEPTION 'INVENTORY_ITEM_REORDER_POINT_INVALID';
      END IF;
    END IF;
  END IF;

  IF p_patch ? 'cost_per_unit' THEN
    IF jsonb_typeof(p_patch->'cost_per_unit') = 'null' THEN
      v_cost_per_unit := NULL;
    ELSE
      v_cost_per_unit := (p_patch->>'cost_per_unit')::DECIMAL(12,2);
      IF v_cost_per_unit < 0 THEN
        RAISE EXCEPTION 'INVENTORY_ITEM_COST_INVALID';
      END IF;
    END IF;
  END IF;

  IF p_patch ? 'supplier_name' THEN
    IF jsonb_typeof(p_patch->'supplier_name') = 'null' THEN
      v_supplier_name := NULL;
    ELSE
      v_supplier_name := NULLIF(btrim(p_patch->>'supplier_name'), '');
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_items ii
    WHERE ii.restaurant_id = p_restaurant_id
      AND ii.id <> p_item_id
      AND lower(btrim(ii.name)) = lower(v_name)
  ) THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_NAME_DUPLICATE';
  END IF;

  IF v_existing.name IS DISTINCT FROM v_name THEN
    v_changed_fields := array_append(v_changed_fields, 'name');
    v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
    v_new_values := v_new_values || jsonb_build_object('name', v_name);
  END IF;
  IF v_existing.unit IS DISTINCT FROM v_unit THEN
    v_changed_fields := array_append(v_changed_fields, 'unit');
    v_old_values := v_old_values || jsonb_build_object('unit', v_existing.unit);
    v_new_values := v_new_values || jsonb_build_object('unit', v_unit);
  END IF;
  IF v_existing.current_stock IS DISTINCT FROM v_current_stock THEN
    v_changed_fields := array_append(v_changed_fields, 'current_stock');
    v_old_values := v_old_values || jsonb_build_object('current_stock', v_existing.current_stock);
    v_new_values := v_new_values || jsonb_build_object('current_stock', v_current_stock);
  END IF;
  IF v_existing.reorder_point IS DISTINCT FROM v_reorder_point THEN
    v_changed_fields := array_append(v_changed_fields, 'reorder_point');
    v_old_values := v_old_values || jsonb_build_object('reorder_point', v_existing.reorder_point);
    v_new_values := v_new_values || jsonb_build_object('reorder_point', v_reorder_point);
  END IF;
  IF v_existing.cost_per_unit IS DISTINCT FROM v_cost_per_unit THEN
    v_changed_fields := array_append(v_changed_fields, 'cost_per_unit');
    v_old_values := v_old_values || jsonb_build_object('cost_per_unit', v_existing.cost_per_unit);
    v_new_values := v_new_values || jsonb_build_object('cost_per_unit', v_cost_per_unit);
  END IF;
  IF v_existing.supplier_name IS DISTINCT FROM v_supplier_name THEN
    v_changed_fields := array_append(v_changed_fields, 'supplier_name');
    v_old_values := v_old_values || jsonb_build_object('supplier_name', v_existing.supplier_name);
    v_new_values := v_new_values || jsonb_build_object('supplier_name', v_supplier_name);
  END IF;

  IF coalesce(array_length(v_changed_fields, 1), 0) = 0 THEN
    RETURN v_existing;
  END IF;

  UPDATE public.inventory_items
  SET name = v_name,
      unit = v_unit,
      current_stock = v_current_stock,
      reorder_point = v_reorder_point,
      cost_per_unit = v_cost_per_unit,
      supplier_name = v_supplier_name,
      updated_at = now()
  WHERE id = p_item_id
    AND restaurant_id = p_restaurant_id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_item_updated',
    'inventory_items',
    v_updated.id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'changed_fields', to_jsonb(v_changed_fields),
      'old_values', v_old_values,
      'new_values', v_new_values
    )
  );

  RETURN v_updated;
END;
$$;


ALTER FUNCTION "public"."update_inventory_item"("p_item_id" "uuid", "p_restaurant_id" "uuid", "p_patch" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_my_profile_full_name"("p_full_name" "text") RETURNS "public"."users"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_updated public.users%ROWTYPE;
  v_full_name TEXT := NULLIF(btrim(COALESCE(p_full_name, '')), '');
BEGIN
  IF v_full_name IS NULL THEN
    RAISE EXCEPTION 'USER_FULL_NAME_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'USER_PROFILE_UPDATE_FORBIDDEN';
  END IF;

  UPDATE public.users
  SET full_name = v_full_name
  WHERE id = v_actor.id
  RETURNING * INTO v_updated;

  RETURN v_updated;
END;
$$;


ALTER FUNCTION "public"."update_my_profile_full_name"("p_full_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_order_item_status"("p_item_id" "uuid", "p_store_id" "uuid", "p_new_status" "text") RETURNS "public"."order_items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_item order_items%ROWTYPE;
  v_order_status text;
  v_from_status text;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'super_admin', 'kitchen') THEN
    RAISE EXCEPTION 'ORDER_ITEM_STATUS_FORBIDDEN';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_ITEM_STATUS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_item
  FROM order_items
  WHERE id = p_item_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  SELECT status
  INTO v_order_status
  FROM orders
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF v_item.status = 'cancelled' THEN
    RAISE EXCEPTION 'ITEM_IS_CANCELLED';
  END IF;

  IF NOT (
    (v_item.status = 'pending' AND p_new_status = 'preparing')
    OR (v_item.status = 'preparing' AND p_new_status = 'ready')
    OR (v_item.status = 'ready' AND p_new_status = 'served')
    OR v_item.status = p_new_status
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_STATUS_TRANSITION';
  END IF;

  v_from_status := v_item.status;

  UPDATE order_items
  SET status = p_new_status
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'update_order_item_status',
    'order_items',
    p_item_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'from_status', v_from_status,
      'to_status', p_new_status
    )
  );

  RETURN v_item;
END;
$$;


ALTER FUNCTION "public"."update_order_item_status"("p_item_id" "uuid", "p_store_id" "uuid", "p_new_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_qc_followup_status"("p_followup_id" "uuid", "p_restaurant_id" "uuid", "p_status" "text", "p_resolution_notes" "text" DEFAULT NULL::"text") RETURNS "public"."qc_followups"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor    public.users%ROWTYPE;
  v_existing public.qc_followups%ROWTYPE;
  v_updated  public.qc_followups%ROWTYPE;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN';
  END IF;

  IF p_status NOT IN ('open', 'in_progress', 'resolved') THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_STATUS_INVALID';
  END IF;

  SELECT * INTO v_existing
  FROM public.qc_followups
  WHERE id = p_followup_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_NOT_FOUND';
  END IF;

  UPDATE public.qc_followups
  SET status = p_status,
      resolution_notes = CASE
        WHEN p_resolution_notes IS NOT NULL
        THEN NULLIF(btrim(p_resolution_notes), '')
        ELSE resolution_notes
      END,
      updated_at = now(),
      resolved_at = CASE
        WHEN p_status = 'resolved' THEN now()
        ELSE NULL
      END
  WHERE id = p_followup_id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_followup_status_updated',
    'qc_followups',
    v_updated.id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'old_status', v_existing.status,
      'new_status', p_status,
      'resolution_notes', v_updated.resolution_notes
    )
  );

  RETURN v_updated;
END;
$$;


ALTER FUNCTION "public"."update_qc_followup_status"("p_followup_id" "uuid", "p_restaurant_id" "uuid", "p_status" "text", "p_resolution_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_qc_template"("p_template_id" "uuid", "p_patch" "jsonb") RETURNS "public"."qc_templates"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_existing public.qc_templates%ROWTYPE;
  v_updated public.qc_templates%ROWTYPE;
  v_patch JSONB := COALESCE(p_patch, '{}'::JSONB);
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_key TEXT;
  v_value JSONB;
  v_category TEXT;
  v_text TEXT;
  v_photo TEXT;
  v_sort_order INT;
  v_qsc_domain TEXT;
  v_requires_photo BOOLEAN;
  v_required_photo_count INT;
  v_weight NUMERIC(5,2);
  v_sort_group TEXT;
  v_is_sv_required BOOLEAN;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  IF jsonb_typeof(v_patch) <> 'object' THEN
    RAISE EXCEPTION 'QC_TEMPLATE_PATCH_INVALID';
  END IF;

  IF v_patch = '{}'::JSONB THEN
    RAISE EXCEPTION 'QC_TEMPLATE_PATCH_EMPTY';
  END IF;

  SELECT qt.*
  INTO v_existing
  FROM public.qc_templates qt
  WHERE qt.id = p_template_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_TEMPLATE_NOT_FOUND';
  END IF;

  IF v_existing.is_global AND v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  IF NOT v_existing.is_global
     AND v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = v_existing.restaurant_id
     ) THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  FOR v_key, v_value IN
    SELECT key, value FROM jsonb_each(v_patch)
  LOOP
    IF v_key NOT IN (
      'category',
      'criteria_text',
      'criteria_photo_url',
      'sort_order',
      'qsc_domain',
      'requires_photo',
      'required_photo_count',
      'weight',
      'sort_group',
      'is_sv_required'
    ) THEN
      RAISE EXCEPTION 'QC_TEMPLATE_PATCH_UNSUPPORTED';
    END IF;
  END LOOP;

  v_category := v_existing.category;
  v_text := v_existing.criteria_text;
  v_photo := v_existing.criteria_photo_url;
  v_sort_order := v_existing.sort_order;
  v_qsc_domain := v_existing.qsc_domain;
  v_requires_photo := COALESCE(v_existing.requires_photo, TRUE);
  v_required_photo_count := COALESCE(v_existing.required_photo_count, 1);
  v_weight := COALESCE(v_existing.weight, 1);
  v_sort_group := v_existing.sort_group;
  v_is_sv_required := COALESCE(v_existing.is_sv_required, FALSE);

  IF v_patch ? 'category' THEN
    v_category := NULLIF(btrim(v_patch->>'category'), '');
    IF v_category IS NULL THEN
      RAISE EXCEPTION 'QC_TEMPLATE_CATEGORY_REQUIRED';
    END IF;
    IF v_category IS DISTINCT FROM v_existing.category THEN
      v_changed_fields := array_append(v_changed_fields, 'category');
      v_old_values := v_old_values || jsonb_build_object('category', v_existing.category);
      v_new_values := v_new_values || jsonb_build_object('category', v_category);
    END IF;
  END IF;

  IF v_patch ? 'criteria_text' THEN
    v_text := NULLIF(btrim(v_patch->>'criteria_text'), '');
    IF v_text IS NULL THEN
      RAISE EXCEPTION 'QC_TEMPLATE_TEXT_REQUIRED';
    END IF;
    IF v_text IS DISTINCT FROM v_existing.criteria_text THEN
      v_changed_fields := array_append(v_changed_fields, 'criteria_text');
      v_old_values := v_old_values || jsonb_build_object('criteria_text', v_existing.criteria_text);
      v_new_values := v_new_values || jsonb_build_object('criteria_text', v_text);
    END IF;
  END IF;

  IF v_patch ? 'criteria_photo_url' THEN
    v_photo := NULLIF(btrim(COALESCE(v_patch->>'criteria_photo_url', '')), '');
    IF v_photo IS DISTINCT FROM v_existing.criteria_photo_url THEN
      v_changed_fields := array_append(v_changed_fields, 'criteria_photo_url');
      v_old_values := v_old_values || jsonb_build_object('criteria_photo_url', v_existing.criteria_photo_url);
      v_new_values := v_new_values || jsonb_build_object('criteria_photo_url', v_photo);
    END IF;
  END IF;

  IF v_patch ? 'sort_order' THEN
    BEGIN
      v_sort_order := (v_patch->>'sort_order')::INT;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'QC_TEMPLATE_SORT_INVALID';
    END;
    IF v_sort_order < 0 THEN
      RAISE EXCEPTION 'QC_TEMPLATE_SORT_INVALID';
    END IF;
    IF v_sort_order IS DISTINCT FROM v_existing.sort_order THEN
      v_changed_fields := array_append(v_changed_fields, 'sort_order');
      v_old_values := v_old_values || jsonb_build_object('sort_order', v_existing.sort_order);
      v_new_values := v_new_values || jsonb_build_object('sort_order', v_sort_order);
    END IF;
  END IF;

  IF v_patch ? 'qsc_domain' THEN
    v_qsc_domain := NULLIF(lower(btrim(COALESCE(v_patch->>'qsc_domain', ''))), '');
    IF v_qsc_domain IS NOT NULL
       AND v_qsc_domain NOT IN ('quality', 'service', 'cleanliness') THEN
      RAISE EXCEPTION 'QC_TEMPLATE_QSC_DOMAIN_INVALID';
    END IF;
    IF v_qsc_domain IS DISTINCT FROM v_existing.qsc_domain THEN
      v_changed_fields := array_append(v_changed_fields, 'qsc_domain');
      v_old_values := v_old_values || jsonb_build_object('qsc_domain', v_existing.qsc_domain);
      v_new_values := v_new_values || jsonb_build_object('qsc_domain', v_qsc_domain);
    END IF;
  END IF;

  IF v_patch ? 'requires_photo' THEN
    BEGIN
      v_requires_photo := (v_patch->>'requires_photo')::BOOLEAN;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'QC_TEMPLATE_REQUIRES_PHOTO_INVALID';
    END;
    IF v_requires_photo IS DISTINCT FROM v_existing.requires_photo THEN
      v_changed_fields := array_append(v_changed_fields, 'requires_photo');
      v_old_values := v_old_values || jsonb_build_object('requires_photo', v_existing.requires_photo);
      v_new_values := v_new_values || jsonb_build_object('requires_photo', v_requires_photo);
    END IF;
  END IF;

  IF v_patch ? 'required_photo_count' THEN
    BEGIN
      v_required_photo_count := (v_patch->>'required_photo_count')::INT;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'QC_TEMPLATE_REQUIRED_PHOTO_COUNT_INVALID';
    END;
    IF v_required_photo_count < 0 THEN
      RAISE EXCEPTION 'QC_TEMPLATE_REQUIRED_PHOTO_COUNT_INVALID';
    END IF;
    IF v_required_photo_count IS DISTINCT FROM v_existing.required_photo_count THEN
      v_changed_fields := array_append(v_changed_fields, 'required_photo_count');
      v_old_values := v_old_values || jsonb_build_object('required_photo_count', v_existing.required_photo_count);
      v_new_values := v_new_values || jsonb_build_object('required_photo_count', v_required_photo_count);
    END IF;
  END IF;

  IF v_patch ? 'weight' THEN
    BEGIN
      v_weight := (v_patch->>'weight')::NUMERIC(5,2);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'QC_TEMPLATE_WEIGHT_INVALID';
    END;
    IF v_weight <= 0 THEN
      RAISE EXCEPTION 'QC_TEMPLATE_WEIGHT_INVALID';
    END IF;
    IF v_weight IS DISTINCT FROM v_existing.weight THEN
      v_changed_fields := array_append(v_changed_fields, 'weight');
      v_old_values := v_old_values || jsonb_build_object('weight', v_existing.weight);
      v_new_values := v_new_values || jsonb_build_object('weight', v_weight);
    END IF;
  END IF;

  IF v_patch ? 'sort_group' THEN
    v_sort_group := NULLIF(btrim(COALESCE(v_patch->>'sort_group', '')), '');
    IF v_sort_group IS DISTINCT FROM v_existing.sort_group THEN
      v_changed_fields := array_append(v_changed_fields, 'sort_group');
      v_old_values := v_old_values || jsonb_build_object('sort_group', v_existing.sort_group);
      v_new_values := v_new_values || jsonb_build_object('sort_group', v_sort_group);
    END IF;
  END IF;

  IF v_patch ? 'is_sv_required' THEN
    BEGIN
      v_is_sv_required := (v_patch->>'is_sv_required')::BOOLEAN;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'QC_TEMPLATE_SV_REQUIRED_INVALID';
    END;
    IF v_is_sv_required IS DISTINCT FROM v_existing.is_sv_required THEN
      v_changed_fields := array_append(v_changed_fields, 'is_sv_required');
      v_old_values := v_old_values || jsonb_build_object('is_sv_required', v_existing.is_sv_required);
      v_new_values := v_new_values || jsonb_build_object('is_sv_required', v_is_sv_required);
    END IF;
  END IF;

  UPDATE public.qc_templates
  SET category = v_category,
      criteria_text = v_text,
      criteria_photo_url = v_photo,
      sort_order = v_sort_order,
      qsc_domain = v_qsc_domain,
      requires_photo = v_requires_photo,
      required_photo_count = v_required_photo_count,
      weight = v_weight,
      sort_group = v_sort_group,
      is_sv_required = v_is_sv_required,
      updated_at = now()
  WHERE id = p_template_id
  RETURNING * INTO v_updated;

  IF array_length(v_changed_fields, 1) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'qc_template_updated',
      'qc_templates',
      v_updated.id,
      jsonb_build_object(
        'restaurant_id', v_updated.restaurant_id,
        'is_global', v_updated.is_global,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values
      )
    );
  END IF;

  RETURN v_updated;
END;
$$;


ALTER FUNCTION "public"."update_qc_template"("p_template_id" "uuid", "p_patch" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_inventory_product"("p_store_id" "uuid", "p_product_id" "uuid" DEFAULT NULL::"uuid", "p_product_code" "text" DEFAULT NULL::"text", "p_name" "text" DEFAULT NULL::"text", "p_category" "text" DEFAULT NULL::"text", "p_stock_unit" "text" DEFAULT NULL::"text", "p_base_unit" "text" DEFAULT 'g'::"text", "p_base_unit_factor" numeric DEFAULT 1000, "p_image_url" "text" DEFAULT NULL::"text", "p_storage_type" "text" DEFAULT NULL::"text", "p_shelf_life_days" integer DEFAULT NULL::integer, "p_is_orderable" boolean DEFAULT true) RETURNS "public"."inventory_products"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_store public.restaurants%ROWTYPE;
  v_product public.inventory_products%ROWTYPE;
  v_inventory_item_id UUID;
  v_name TEXT := NULLIF(BTRIM(COALESCE(p_name, '')), '');
  v_stock_unit TEXT := NULLIF(BTRIM(COALESCE(p_stock_unit, '')), '');
  v_base_unit TEXT := LOWER(NULLIF(BTRIM(COALESCE(p_base_unit, '')), ''));
BEGIN
  -- CHECK: base unit and factor are validated here before product mutation.
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_PRODUCT_FORBIDDEN';
  END IF;

  SELECT * INTO v_store
  FROM public.restaurants
  WHERE id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'PRODUCT_NAME_REQUIRED';
  END IF;

  IF v_stock_unit IS NULL THEN
    RAISE EXCEPTION 'STOCK_UNIT_REQUIRED';
  END IF;

  IF v_base_unit NOT IN ('g', 'ml', 'ea') THEN
    RAISE EXCEPTION 'BASE_UNIT_INVALID';
  END IF;

  IF COALESCE(p_base_unit_factor, 0) <= 0 THEN
    RAISE EXCEPTION 'BASE_UNIT_FACTOR_INVALID';
  END IF;

  IF p_shelf_life_days IS NOT NULL AND p_shelf_life_days < 0 THEN
    RAISE EXCEPTION 'SHELF_LIFE_INVALID';
  END IF;

  IF p_product_id IS NOT NULL THEN
    SELECT *
    INTO v_product
    FROM public.inventory_products
    WHERE id = p_product_id
      AND restaurant_id = p_store_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'PRODUCT_NOT_FOUND';
    END IF;

    v_inventory_item_id := v_product.inventory_item_id;
  END IF;

  IF v_inventory_item_id IS NULL THEN
    INSERT INTO public.inventory_items (
      restaurant_id,
      name,
      quantity,
      unit,
      current_stock,
      reorder_point,
      cost_per_unit,
      supplier_name,
      is_active
    ) VALUES (
      p_store_id,
      v_name,
      0,
      v_base_unit,
      0,
      0,
      0,
      NULL,
      TRUE
    )
    RETURNING id INTO v_inventory_item_id;
  ELSE
    UPDATE public.inventory_items
    SET name = v_name,
        unit = v_base_unit,
        is_active = TRUE
    WHERE id = v_inventory_item_id
      AND restaurant_id = p_store_id;
  END IF;

  IF p_product_id IS NULL THEN
    INSERT INTO public.inventory_products (
      restaurant_id,
      brand_id,
      inventory_item_id,
      product_code,
      name,
      category,
      stock_unit,
      base_unit,
      base_unit_factor,
      image_url,
      storage_type,
      shelf_life_days,
      is_orderable,
      is_active
    ) VALUES (
      p_store_id,
      v_store.brand_id,
      v_inventory_item_id,
      NULLIF(BTRIM(COALESCE(p_product_code, '')), ''),
      v_name,
      NULLIF(BTRIM(COALESCE(p_category, '')), ''),
      v_stock_unit,
      v_base_unit,
      p_base_unit_factor,
      NULLIF(BTRIM(COALESCE(p_image_url, '')), ''),
      NULLIF(BTRIM(COALESCE(p_storage_type, '')), ''),
      p_shelf_life_days,
      COALESCE(p_is_orderable, TRUE),
      TRUE
    )
    RETURNING * INTO v_product;
  ELSE
    UPDATE public.inventory_products
    SET inventory_item_id = v_inventory_item_id,
        product_code = NULLIF(BTRIM(COALESCE(p_product_code, '')), ''),
        name = v_name,
        category = NULLIF(BTRIM(COALESCE(p_category, '')), ''),
        stock_unit = v_stock_unit,
        base_unit = v_base_unit,
        base_unit_factor = p_base_unit_factor,
        image_url = NULLIF(BTRIM(COALESCE(p_image_url, '')), ''),
        storage_type = NULLIF(BTRIM(COALESCE(p_storage_type, '')), ''),
        shelf_life_days = p_shelf_life_days,
        is_orderable = COALESCE(p_is_orderable, TRUE),
        is_active = TRUE,
        updated_at = now()
    WHERE id = p_product_id
      AND restaurant_id = p_store_id
    RETURNING * INTO v_product;
  END IF;

  RETURN v_product;
END;
$$;


ALTER FUNCTION "public"."upsert_inventory_product"("p_store_id" "uuid", "p_product_id" "uuid", "p_product_code" "text", "p_name" "text", "p_category" "text", "p_stock_unit" "text", "p_base_unit" "text", "p_base_unit_factor" numeric, "p_image_url" "text", "p_storage_type" "text", "p_shelf_life_days" integer, "p_is_orderable" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_inventory_recipe_line"("p_restaurant_id" "uuid", "p_menu_item_id" "uuid", "p_ingredient_id" "uuid", "p_quantity_g" numeric) RETURNS TABLE("recipe_id" "uuid", "restaurant_id" "uuid", "menu_item_id" "uuid", "menu_item_name" "text", "ingredient_id" "uuid", "ingredient_name" "text", "ingredient_unit" "text", "quantity_g" numeric, "last_updated" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_menu_item public.menu_items%ROWTYPE;
  v_ingredient public.inventory_items%ROWTYPE;
  v_existing public.menu_recipes%ROWTYPE;
  v_recipe public.menu_recipes%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_WRITE_FORBIDDEN';
  END IF;

  IF p_menu_item_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_MENU_ITEM_REQUIRED';
  END IF;

  IF p_ingredient_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_REQUIRED';
  END IF;

  IF p_quantity_g IS NULL OR p_quantity_g <= 0 THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_QUANTITY_INVALID';
  END IF;

  SELECT mi.*
  INTO v_menu_item
  FROM public.menu_items mi
  WHERE mi.id = p_menu_item_id
    AND mi.restaurant_id = p_restaurant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_MENU_ITEM_NOT_FOUND';
  END IF;

  SELECT ii.*
  INTO v_ingredient
  FROM public.inventory_items ii
  WHERE ii.id = p_ingredient_id
    AND ii.restaurant_id = p_restaurant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_NOT_FOUND';
  END IF;

  IF v_ingredient.unit <> 'g' THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_UNIT_UNSUPPORTED';
  END IF;

  SELECT mr.*
  INTO v_existing
  FROM public.menu_recipes mr
  WHERE mr.restaurant_id = p_restaurant_id
    AND mr.menu_item_id = p_menu_item_id
    AND mr.ingredient_id = p_ingredient_id
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing.quantity_g IS DISTINCT FROM p_quantity_g THEN
      v_changed_fields := ARRAY['quantity_g'];
      v_old_values := jsonb_build_object('quantity_g', v_existing.quantity_g);
      v_new_values := jsonb_build_object('quantity_g', p_quantity_g);

      UPDATE public.menu_recipes mr
      SET quantity_g = p_quantity_g,
          updated_at = now()
      WHERE mr.id = v_existing.id
      RETURNING mr.* INTO v_recipe;

      INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
      VALUES (
        auth.uid(),
        'inventory_recipe_upserted',
        'menu_recipes',
        v_recipe.id,
        jsonb_build_object(
          'operation', 'update',
          'restaurant_id', p_restaurant_id,
          'menu_item_id', p_menu_item_id,
          'ingredient_id', p_ingredient_id,
          'changed_fields', to_jsonb(v_changed_fields),
          'old_values', v_old_values,
          'new_values', v_new_values
        )
      );
    ELSE
      v_recipe := v_existing;
    END IF;
  ELSE
    INSERT INTO public.menu_recipes (
      restaurant_id,
      menu_item_id,
      ingredient_id,
      quantity_g,
      updated_at
    )
    VALUES (
      p_restaurant_id,
      p_menu_item_id,
      p_ingredient_id,
      p_quantity_g,
      now()
    )
    RETURNING * INTO v_recipe;

    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'inventory_recipe_upserted',
      'menu_recipes',
      v_recipe.id,
      jsonb_build_object(
        'operation', 'create',
        'restaurant_id', p_restaurant_id,
        'menu_item_id', p_menu_item_id,
        'ingredient_id', p_ingredient_id,
        'new_values', jsonb_build_object(
          'quantity_g', v_recipe.quantity_g
        )
      )
    );
  END IF;

  RETURN QUERY
  SELECT
    v_recipe.id AS recipe_id,
    v_recipe.restaurant_id,
    v_recipe.menu_item_id,
    v_menu_item.name AS menu_item_name,
    v_recipe.ingredient_id,
    v_ingredient.name AS ingredient_name,
    v_ingredient.unit AS ingredient_unit,
    v_recipe.quantity_g,
    v_recipe.updated_at AS last_updated;
END;
$$;


ALTER FUNCTION "public"."upsert_inventory_recipe_line"("p_restaurant_id" "uuid", "p_menu_item_id" "uuid", "p_ingredient_id" "uuid", "p_quantity_g" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_inventory_supplier"("p_store_id" "uuid", "p_supplier_id" "uuid" DEFAULT NULL::"uuid", "p_supplier_name" "text" DEFAULT NULL::"text", "p_supplier_type" "text" DEFAULT NULL::"text", "p_contact_name" "text" DEFAULT NULL::"text", "p_phone" "text" DEFAULT NULL::"text", "p_email" "text" DEFAULT NULL::"text", "p_address" "text" DEFAULT NULL::"text", "p_business_registration_no" "text" DEFAULT NULL::"text", "p_payment_terms" "text" DEFAULT NULL::"text", "p_contract_start_date" "date" DEFAULT NULL::"date", "p_contract_end_date" "date" DEFAULT NULL::"date", "p_memo" "text" DEFAULT NULL::"text") RETURNS "public"."inventory_suppliers"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_store public.restaurants%ROWTYPE;
  v_supplier public.inventory_suppliers%ROWTYPE;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_SUPPLIER_FORBIDDEN';
  END IF;

  SELECT * INTO v_store
  FROM public.restaurants
  WHERE id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_supplier_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'SUPPLIER_NAME_REQUIRED';
  END IF;

  IF p_supplier_id IS NULL THEN
    INSERT INTO public.inventory_suppliers (
      brand_id,
      supplier_name,
      supplier_type,
      contact_name,
      phone,
      email,
      address,
      business_registration_no,
      payment_terms,
      contract_start_date,
      contract_end_date,
      status,
      memo
    ) VALUES (
      v_store.brand_id,
      BTRIM(p_supplier_name),
      NULLIF(BTRIM(COALESCE(p_supplier_type, '')), ''),
      NULLIF(BTRIM(COALESCE(p_contact_name, '')), ''),
      NULLIF(BTRIM(COALESCE(p_phone, '')), ''),
      NULLIF(BTRIM(COALESCE(p_email, '')), ''),
      NULLIF(BTRIM(COALESCE(p_address, '')), ''),
      NULLIF(BTRIM(COALESCE(p_business_registration_no, '')), ''),
      NULLIF(BTRIM(COALESCE(p_payment_terms, '')), ''),
      p_contract_start_date,
      p_contract_end_date,
      'active',
      NULLIF(BTRIM(COALESCE(p_memo, '')), '')
    )
    RETURNING * INTO v_supplier;
  ELSE
    UPDATE public.inventory_suppliers
    SET supplier_name = BTRIM(p_supplier_name),
        supplier_type = NULLIF(BTRIM(COALESCE(p_supplier_type, '')), ''),
        contact_name = NULLIF(BTRIM(COALESCE(p_contact_name, '')), ''),
        phone = NULLIF(BTRIM(COALESCE(p_phone, '')), ''),
        email = NULLIF(BTRIM(COALESCE(p_email, '')), ''),
        address = NULLIF(BTRIM(COALESCE(p_address, '')), ''),
        business_registration_no = NULLIF(BTRIM(COALESCE(p_business_registration_no, '')), ''),
        payment_terms = NULLIF(BTRIM(COALESCE(p_payment_terms, '')), ''),
        contract_start_date = p_contract_start_date,
        contract_end_date = p_contract_end_date,
        memo = NULLIF(BTRIM(COALESCE(p_memo, '')), ''),
        updated_at = now()
    WHERE id = p_supplier_id
      AND (brand_id IS NULL OR brand_id = v_store.brand_id)
    RETURNING * INTO v_supplier;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'SUPPLIER_NOT_FOUND';
    END IF;
  END IF;

  RETURN v_supplier;
END;
$$;


ALTER FUNCTION "public"."upsert_inventory_supplier"("p_store_id" "uuid", "p_supplier_id" "uuid", "p_supplier_name" "text", "p_supplier_type" "text", "p_contact_name" "text", "p_phone" "text", "p_email" "text", "p_address" "text", "p_business_registration_no" "text", "p_payment_terms" "text", "p_contract_start_date" "date", "p_contract_end_date" "date", "p_memo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_inventory_supplier_item"("p_store_id" "uuid", "p_supplier_item_id" "uuid" DEFAULT NULL::"uuid", "p_supplier_id" "uuid" DEFAULT NULL::"uuid", "p_product_id" "uuid" DEFAULT NULL::"uuid", "p_supplier_sku" "text" DEFAULT NULL::"text", "p_order_unit" "text" DEFAULT NULL::"text", "p_order_unit_quantity_base" numeric DEFAULT NULL::numeric, "p_min_order_quantity" numeric DEFAULT 1, "p_unit_price" numeric DEFAULT 0, "p_tax_rate" numeric DEFAULT 0, "p_lead_time_days" integer DEFAULT 1, "p_is_preferred" boolean DEFAULT false) RETURNS "public"."inventory_supplier_items"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_store public.restaurants%ROWTYPE;
  v_supplier public.inventory_suppliers%ROWTYPE;
  v_product public.inventory_products%ROWTYPE;
  v_item public.inventory_supplier_items%ROWTYPE;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_SUPPLIER_ITEM_FORBIDDEN';
  END IF;

  SELECT * INTO v_store
  FROM public.restaurants
  WHERE id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  SELECT * INTO v_supplier
  FROM public.inventory_suppliers
  WHERE id = p_supplier_id
    AND status = 'active'
    AND (brand_id IS NULL OR brand_id = v_store.brand_id);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SUPPLIER_NOT_FOUND';
  END IF;

  SELECT * INTO v_product
  FROM public.inventory_products
  WHERE id = p_product_id
    AND restaurant_id = p_store_id
    AND is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRODUCT_NOT_FOUND';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_order_unit, '')), '') IS NULL THEN
    RAISE EXCEPTION 'ORDER_UNIT_REQUIRED';
  END IF;

  IF COALESCE(p_order_unit_quantity_base, 0) <= 0 THEN
    RAISE EXCEPTION 'ORDER_UNIT_QUANTITY_INVALID';
  END IF;

  IF COALESCE(p_min_order_quantity, 0) <= 0 THEN
    RAISE EXCEPTION 'MIN_ORDER_QUANTITY_INVALID';
  END IF;

  IF COALESCE(p_unit_price, 0) < 0 THEN
    RAISE EXCEPTION 'UNIT_PRICE_INVALID';
  END IF;

  IF COALESCE(p_tax_rate, 0) < 0 THEN
    RAISE EXCEPTION 'TAX_RATE_INVALID';
  END IF;

  IF COALESCE(p_lead_time_days, 0) < 0 THEN
    RAISE EXCEPTION 'LEAD_TIME_INVALID';
  END IF;

  IF p_is_preferred THEN
    UPDATE public.inventory_supplier_items
    SET is_preferred = FALSE,
        updated_at = now()
    WHERE product_id = p_product_id
      AND supplier_id <> p_supplier_id;
  END IF;

  IF p_supplier_item_id IS NULL THEN
    INSERT INTO public.inventory_supplier_items (
      supplier_id,
      product_id,
      supplier_sku,
      order_unit,
      order_unit_quantity_base,
      min_order_quantity,
      unit_price,
      tax_rate,
      lead_time_days,
      is_preferred,
      is_active
    ) VALUES (
      p_supplier_id,
      p_product_id,
      NULLIF(BTRIM(COALESCE(p_supplier_sku, '')), ''),
      BTRIM(p_order_unit),
      p_order_unit_quantity_base,
      p_min_order_quantity,
      p_unit_price,
      COALESCE(p_tax_rate, 0),
      COALESCE(p_lead_time_days, 1),
      COALESCE(p_is_preferred, FALSE),
      TRUE
    )
    ON CONFLICT (supplier_id, product_id, order_unit)
    DO UPDATE SET supplier_sku = EXCLUDED.supplier_sku,
                  order_unit_quantity_base = EXCLUDED.order_unit_quantity_base,
                  min_order_quantity = EXCLUDED.min_order_quantity,
                  unit_price = EXCLUDED.unit_price,
                  tax_rate = EXCLUDED.tax_rate,
                  lead_time_days = EXCLUDED.lead_time_days,
                  is_preferred = EXCLUDED.is_preferred,
                  is_active = TRUE,
                  updated_at = now()
    RETURNING * INTO v_item;
  ELSE
    UPDATE public.inventory_supplier_items
    SET supplier_sku = NULLIF(BTRIM(COALESCE(p_supplier_sku, '')), ''),
        order_unit = BTRIM(p_order_unit),
        order_unit_quantity_base = p_order_unit_quantity_base,
        min_order_quantity = p_min_order_quantity,
        unit_price = p_unit_price,
        tax_rate = COALESCE(p_tax_rate, 0),
        lead_time_days = COALESCE(p_lead_time_days, 1),
        is_preferred = COALESCE(p_is_preferred, FALSE),
        is_active = TRUE,
        updated_at = now()
    WHERE id = p_supplier_item_id
      AND supplier_id = p_supplier_id
      AND product_id = p_product_id
    RETURNING * INTO v_item;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'SUPPLIER_ITEM_NOT_FOUND';
    END IF;
  END IF;

  RETURN v_item;
END;
$$;


ALTER FUNCTION "public"."upsert_inventory_supplier_item"("p_store_id" "uuid", "p_supplier_item_id" "uuid", "p_supplier_id" "uuid", "p_product_id" "uuid", "p_supplier_sku" "text", "p_order_unit" "text", "p_order_unit_quantity_base" numeric, "p_min_order_quantity" numeric, "p_unit_price" numeric, "p_tax_rate" numeric, "p_lead_time_days" integer, "p_is_preferred" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_qc_check"("p_store_id" "uuid", "p_template_id" "uuid", "p_check_date" "date", "p_result" "text", "p_evidence_photo_url" "text" DEFAULT NULL::"text", "p_note" "text" DEFAULT NULL::"text", "p_checked_by" "uuid" DEFAULT NULL::"uuid", "p_submitted_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_submission_status" "text" DEFAULT NULL::"text", "p_photo_required_count" integer DEFAULT NULL::integer, "p_photo_uploaded_count" integer DEFAULT NULL::integer, "p_score" numeric DEFAULT NULL::numeric, "p_grade" "text" DEFAULT NULL::"text", "p_sv_review_status" "text" DEFAULT NULL::"text", "p_sv_reviewed_by" "uuid" DEFAULT NULL::"uuid", "p_sv_reviewed_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_sv_score" numeric DEFAULT NULL::numeric, "p_sv_note" "text" DEFAULT NULL::"text", "p_visit_session_id" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."qc_checks"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_can_check BOOLEAN;
  v_template public.qc_templates%ROWTYPE;
  v_existing public.qc_checks%ROWTYPE;
  v_saved public.qc_checks%ROWTYPE;
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_photo TEXT := NULLIF(btrim(COALESCE(p_evidence_photo_url, '')), '');
  v_checked_by UUID := COALESCE(p_checked_by, auth.uid());
  v_submission_status TEXT;
  v_submitted_at TIMESTAMPTZ;
  v_photo_required_count INTEGER;
  v_photo_uploaded_count INTEGER;
  v_grade TEXT := NULLIF(btrim(COALESCE(p_grade, '')), '');
  v_sv_review_status TEXT;
  v_sv_reviewed_by UUID;
  v_sv_reviewed_at TIMESTAMPTZ;
  v_sv_note TEXT := NULLIF(btrim(COALESCE(p_sv_note, '')), '');
  v_score NUMERIC;
  v_sv_score NUMERIC;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_CHECK_WRITE_FORBIDDEN';
  END IF;

  v_can_check := v_actor.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
    OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check'];

  IF NOT v_can_check THEN
    RAISE EXCEPTION 'QC_CHECK_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'QC_CHECK_WRITE_FORBIDDEN';
  END IF;

  IF p_template_id IS NULL THEN
    RAISE EXCEPTION 'QC_CHECK_TEMPLATE_REQUIRED';
  END IF;

  IF p_check_date IS NULL THEN
    RAISE EXCEPTION 'QC_CHECK_DATE_REQUIRED';
  END IF;

  IF p_result NOT IN ('pass', 'fail', 'na') THEN
    RAISE EXCEPTION 'QC_CHECK_RESULT_INVALID';
  END IF;

  IF v_checked_by <> auth.uid() THEN
    RAISE EXCEPTION 'QC_CHECK_ACTOR_INVALID';
  END IF;

  SELECT qt.*
  INTO v_template
  FROM public.qc_templates qt
  WHERE qt.id = p_template_id
    AND qt.is_active = TRUE
    AND (
      qt.is_global = TRUE
      OR qt.restaurant_id = p_store_id
    );

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_CHECK_TEMPLATE_NOT_FOUND';
  END IF;

  SELECT qc.*
  INTO v_existing
  FROM public.qc_checks qc
  WHERE qc.template_id = p_template_id
    AND qc.restaurant_id = p_store_id
    AND qc.check_date = p_check_date
  FOR UPDATE;

  v_submission_status := COALESCE(
    NULLIF(btrim(COALESCE(p_submission_status, '')), ''),
    v_existing.submission_status,
    'submitted'
  );

  IF v_submission_status NOT IN ('pending', 'submitted', 'overdue') THEN
    RAISE EXCEPTION 'QC_CHECK_SUBMISSION_STATUS_INVALID';
  END IF;

  v_submitted_at := CASE
    WHEN v_submission_status = 'submitted' THEN COALESCE(
      p_submitted_at,
      v_existing.submitted_at,
      now()
    )
    ELSE p_submitted_at
  END;

  v_photo_required_count := COALESCE(
    p_photo_required_count,
    v_existing.photo_required_count,
    CASE
      WHEN COALESCE(v_template.requires_photo, TRUE) THEN COALESCE(v_template.required_photo_count, 1)
      ELSE 0
    END
  );

  IF v_photo_required_count < 0 THEN
    RAISE EXCEPTION 'QC_CHECK_PHOTO_REQUIRED_COUNT_INVALID';
  END IF;

  v_photo_uploaded_count := COALESCE(
    p_photo_uploaded_count,
    v_existing.photo_uploaded_count,
    CASE
      WHEN v_photo IS NOT NULL THEN 1
      ELSE 0
    END
  );

  IF v_photo_uploaded_count < 0 THEN
    RAISE EXCEPTION 'QC_CHECK_PHOTO_UPLOADED_COUNT_INVALID';
  END IF;

  v_score := COALESCE(p_score, v_existing.score);
  v_sv_score := COALESCE(p_sv_score, v_existing.sv_score);

  IF v_grade IS NOT NULL
     AND v_grade NOT IN ('good', 'caution', 'risk') THEN
    RAISE EXCEPTION 'QC_CHECK_GRADE_INVALID';
  END IF;

  v_grade := COALESCE(v_grade, v_existing.grade);

  v_sv_review_status := COALESCE(
    NULLIF(btrim(COALESCE(p_sv_review_status, '')), ''),
    v_existing.sv_review_status,
    CASE
      WHEN COALESCE(v_template.is_sv_required, FALSE) THEN 'pending'
      ELSE 'not_required'
    END
  );

  IF v_sv_review_status NOT IN ('not_required', 'pending', 'reviewed', 'rejected') THEN
    RAISE EXCEPTION 'QC_CHECK_SV_REVIEW_STATUS_INVALID';
  END IF;

  v_sv_reviewed_by := COALESCE(
    p_sv_reviewed_by,
    v_existing.sv_reviewed_by,
    CASE
      WHEN v_sv_review_status IN ('reviewed', 'rejected') THEN auth.uid()
      ELSE NULL
    END
  );

  IF v_sv_reviewed_by IS NOT NULL
     AND v_sv_reviewed_by <> auth.uid() THEN
    RAISE EXCEPTION 'QC_CHECK_SV_ACTOR_INVALID';
  END IF;

  v_sv_reviewed_at := CASE
    WHEN v_sv_review_status IN ('reviewed', 'rejected') THEN COALESCE(
      p_sv_reviewed_at,
      v_existing.sv_reviewed_at,
      now()
    )
    WHEN p_sv_reviewed_at IS NOT NULL THEN p_sv_reviewed_at
    ELSE v_existing.sv_reviewed_at
  END;

  INSERT INTO public.qc_checks (
    restaurant_id,
    template_id,
    check_date,
    checked_by,
    result,
    evidence_photo_url,
    note,
    submitted_at,
    submission_status,
    photo_required_count,
    photo_uploaded_count,
    score,
    grade,
    sv_review_status,
    sv_reviewed_by,
    sv_reviewed_at,
    sv_score,
    sv_note,
    visit_session_id
  )
  VALUES (
    p_store_id,
    p_template_id,
    p_check_date,
    v_checked_by,
    p_result,
    v_photo,
    v_note,
    v_submitted_at,
    v_submission_status,
    v_photo_required_count,
    v_photo_uploaded_count,
    v_score,
    v_grade,
    v_sv_review_status,
    v_sv_reviewed_by,
    v_sv_reviewed_at,
    v_sv_score,
    v_sv_note,
    COALESCE(p_visit_session_id, v_existing.visit_session_id)
  )
  ON CONFLICT (restaurant_id, template_id, check_date)
  DO UPDATE SET
    restaurant_id = EXCLUDED.restaurant_id,
    checked_by = EXCLUDED.checked_by,
    result = EXCLUDED.result,
    evidence_photo_url = EXCLUDED.evidence_photo_url,
    note = EXCLUDED.note,
    submitted_at = EXCLUDED.submitted_at,
    submission_status = EXCLUDED.submission_status,
    photo_required_count = EXCLUDED.photo_required_count,
    photo_uploaded_count = EXCLUDED.photo_uploaded_count,
    score = EXCLUDED.score,
    grade = EXCLUDED.grade,
    sv_review_status = EXCLUDED.sv_review_status,
    sv_reviewed_by = EXCLUDED.sv_reviewed_by,
    sv_reviewed_at = EXCLUDED.sv_reviewed_at,
    sv_score = EXCLUDED.sv_score,
    sv_note = EXCLUDED.sv_note,
    visit_session_id = EXCLUDED.visit_session_id
  RETURNING * INTO v_saved;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_check_upserted',
    'qc_checks',
    v_saved.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'template_id', p_template_id,
      'check_date', p_check_date,
      'result', p_result,
      'evidence_photo_url', v_photo,
      'note', v_note,
      'submitted_at', v_submitted_at,
      'submission_status', v_submission_status,
      'photo_required_count', v_photo_required_count,
      'photo_uploaded_count', v_photo_uploaded_count,
      'score', v_score,
      'grade', v_grade,
      'sv_review_status', v_sv_review_status,
      'sv_reviewed_by', v_sv_reviewed_by,
      'sv_reviewed_at', v_sv_reviewed_at,
      'sv_score', v_sv_score,
      'sv_note', v_sv_note,
      'visit_session_id', COALESCE(p_visit_session_id, v_existing.visit_session_id),
      'previous_check', CASE
        WHEN v_existing.id IS NULL THEN NULL
        ELSE jsonb_build_object(
          'result', v_existing.result,
          'evidence_photo_url', v_existing.evidence_photo_url,
          'note', v_existing.note,
          'checked_by', v_existing.checked_by,
          'submitted_at', v_existing.submitted_at,
          'submission_status', v_existing.submission_status,
          'photo_required_count', v_existing.photo_required_count,
          'photo_uploaded_count', v_existing.photo_uploaded_count,
          'score', v_existing.score,
          'grade', v_existing.grade,
          'sv_review_status', v_existing.sv_review_status,
          'sv_reviewed_by', v_existing.sv_reviewed_by,
          'sv_reviewed_at', v_existing.sv_reviewed_at,
          'sv_score', v_existing.sv_score,
          'sv_note', v_existing.sv_note,
          'visit_session_id', v_existing.visit_session_id
        )
      END
    )
  );

  RETURN v_saved;
END;
$$;


ALTER FUNCTION "public"."upsert_qc_check"("p_store_id" "uuid", "p_template_id" "uuid", "p_check_date" "date", "p_result" "text", "p_evidence_photo_url" "text", "p_note" "text", "p_checked_by" "uuid", "p_submitted_at" timestamp with time zone, "p_submission_status" "text", "p_photo_required_count" integer, "p_photo_uploaded_count" integer, "p_score" numeric, "p_grade" "text", "p_sv_review_status" "text", "p_sv_reviewed_by" "uuid", "p_sv_reviewed_at" timestamp with time zone, "p_sv_score" numeric, "p_sv_note" "text", "p_visit_session_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."upsert_qc_check"("p_store_id" "uuid", "p_template_id" "uuid", "p_check_date" "date", "p_result" "text", "p_evidence_photo_url" "text", "p_note" "text", "p_checked_by" "uuid", "p_submitted_at" timestamp with time zone, "p_submission_status" "text", "p_photo_required_count" integer, "p_photo_uploaded_count" integer, "p_score" numeric, "p_grade" "text", "p_sv_review_status" "text", "p_sv_reviewed_by" "uuid", "p_sv_reviewed_at" timestamp with time zone, "p_sv_score" numeric, "p_sv_note" "text", "p_visit_session_id" "uuid") IS 'Backward-compatible QSC write anchor. Old callers can keep sending the original 7 params; QSC v2 callers may send the optional trailing fields.';



CREATE TABLE IF NOT EXISTS "public"."qc_check_photos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "check_id" "uuid" NOT NULL,
    "template_id" "uuid" NOT NULL,
    "photo_url" "text" NOT NULL,
    "storage_path" "text" NOT NULL,
    "photo_role" "text" DEFAULT 'staff'::"text" NOT NULL,
    "uploaded_by" "uuid",
    "uploaded_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "taken_at" timestamp with time zone,
    "is_primary" boolean DEFAULT false NOT NULL,
    "caption" "text",
    CONSTRAINT "qc_check_photos_photo_role_check" CHECK (("photo_role" = ANY (ARRAY['staff'::"text", 'sv'::"text", 'reference'::"text"]))),
    CONSTRAINT "qc_check_photos_photo_url_nonempty_check" CHECK (("btrim"("photo_url") <> ''::"text")),
    CONSTRAINT "qc_check_photos_storage_path_nonempty_check" CHECK (("btrim"("storage_path") <> ''::"text"))
);


ALTER TABLE "public"."qc_check_photos" OWNER TO "postgres";


COMMENT ON TABLE "public"."qc_check_photos" IS 'Normalized evidence photo table for QSC v2. Keeps multiple staff/SV/reference photos per QC check.';



COMMENT ON COLUMN "public"."qc_check_photos"."photo_url" IS 'Resolved photo URL used by clients. Legacy evidence_photo_url on qc_checks remains for backward compatibility.';



COMMENT ON COLUMN "public"."qc_check_photos"."storage_path" IS 'Storage object path inside qc-photos bucket. First folder segment must be restaurant_id text.';



COMMENT ON COLUMN "public"."qc_check_photos"."photo_role" IS 'Origin/purpose of the photo: staff, sv, or reference.';



COMMENT ON COLUMN "public"."qc_check_photos"."is_primary" IS 'Whether this photo is the representative photo for the check.';



CREATE OR REPLACE FUNCTION "public"."upsert_qc_check_photo"("p_store_id" "uuid", "p_check_id" "uuid", "p_template_id" "uuid", "p_photo_url" "text", "p_storage_path" "text", "p_photo_role" "text" DEFAULT 'staff'::"text", "p_uploaded_by" "uuid" DEFAULT NULL::"uuid", "p_taken_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_is_primary" boolean DEFAULT false, "p_caption" "text" DEFAULT NULL::"text", "p_sync_legacy_photo" boolean DEFAULT true) RETURNS "public"."qc_check_photos"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_can_check BOOLEAN;
  v_check public.qc_checks%ROWTYPE;
  v_saved public.qc_check_photos%ROWTYPE;
  v_uploaded_by UUID := COALESCE(p_uploaded_by, auth.uid());
  v_caption TEXT := NULLIF(btrim(COALESCE(p_caption, '')), '');
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_CHECK_PHOTO_WRITE_FORBIDDEN';
  END IF;

  v_can_check := v_actor.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
    OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check'];

  IF NOT v_can_check THEN
    RAISE EXCEPTION 'QC_CHECK_PHOTO_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'QC_CHECK_PHOTO_WRITE_FORBIDDEN';
  END IF;

  IF v_uploaded_by <> auth.uid() THEN
    RAISE EXCEPTION 'QC_CHECK_PHOTO_ACTOR_INVALID';
  END IF;

  IF p_photo_role NOT IN ('staff', 'sv', 'reference') THEN
    RAISE EXCEPTION 'QC_CHECK_PHOTO_ROLE_INVALID';
  END IF;

  SELECT qc.*
  INTO v_check
  FROM public.qc_checks qc
  WHERE qc.id = p_check_id
    AND qc.restaurant_id = p_store_id
    AND qc.template_id = p_template_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_CHECK_PHOTO_CHECK_NOT_FOUND';
  END IF;

  IF p_is_primary THEN
    UPDATE public.qc_check_photos
    SET is_primary = FALSE
    WHERE check_id = p_check_id;
  END IF;

  INSERT INTO public.qc_check_photos (
    restaurant_id,
    check_id,
    template_id,
    photo_url,
    storage_path,
    photo_role,
    uploaded_by,
    taken_at,
    is_primary,
    caption
  )
  VALUES (
    p_store_id,
    p_check_id,
    p_template_id,
    NULLIF(btrim(COALESCE(p_photo_url, '')), ''),
    NULLIF(btrim(COALESCE(p_storage_path, '')), ''),
    p_photo_role,
    v_uploaded_by,
    p_taken_at,
    p_is_primary,
    v_caption
  )
  ON CONFLICT (check_id, storage_path)
  DO UPDATE SET
    photo_url = EXCLUDED.photo_url,
    photo_role = EXCLUDED.photo_role,
    uploaded_by = EXCLUDED.uploaded_by,
    uploaded_at = now(),
    taken_at = EXCLUDED.taken_at,
    is_primary = EXCLUDED.is_primary,
    caption = EXCLUDED.caption
  RETURNING * INTO v_saved;

  PERFORM public.refresh_qc_check_photo_summary(p_check_id, p_sync_legacy_photo);

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_check_photo_upserted',
    'qc_check_photos',
    v_saved.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'check_id', p_check_id,
      'template_id', p_template_id,
      'photo_role', p_photo_role,
      'storage_path', p_storage_path,
      'is_primary', p_is_primary
    )
  );

  RETURN v_saved;
END;
$$;


ALTER FUNCTION "public"."upsert_qc_check_photo"("p_store_id" "uuid", "p_check_id" "uuid", "p_template_id" "uuid", "p_photo_url" "text", "p_storage_path" "text", "p_photo_role" "text", "p_uploaded_by" "uuid", "p_taken_at" timestamp with time zone, "p_is_primary" boolean, "p_caption" "text", "p_sync_legacy_photo" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_accessible_brands"("uid" "uuid") RETURNS SETOF "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  WITH explicit_brands AS (
    SELECT uba.brand_id
    FROM public.user_brand_access uba
    JOIN public.users u
      ON u.id = uba.user_id
    WHERE u.auth_id = uid
      AND u.is_active = true
      AND uba.is_active = true
  ),
  fallback_brand AS (
    SELECT u.brand_id
    FROM public.users u
    WHERE u.auth_id = uid
      AND u.is_active = true
      AND u.brand_id IS NOT NULL
  )
  SELECT DISTINCT brand_id
  FROM (
    SELECT brand_id FROM explicit_brands
    UNION
    SELECT brand_id FROM fallback_brand
  ) brand_scope
  WHERE brand_id IS NOT NULL;
$$;


ALTER FUNCTION "public"."user_accessible_brands"("uid" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."user_accessible_brands"("uid" "uuid") IS 'Returns all active brand ids accessible to an auth user via user_brand_access plus the user''s fallback brand_id.';



CREATE OR REPLACE FUNCTION "public"."user_accessible_stores"("uid" "uuid") RETURNS SETOF "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  WITH explicit_store_access AS (
    SELECT usa.store_id
    FROM public.user_store_access usa
    JOIN public.users u
      ON u.id = usa.user_id
    WHERE u.auth_id = uid
      AND u.is_active = true
      AND usa.is_active = true
  ),
  fallback_store AS (
    SELECT COALESCE(u.primary_store_id, u.restaurant_id) AS store_id
    FROM public.users u
    WHERE u.auth_id = uid
      AND u.is_active = true
      AND COALESCE(u.primary_store_id, u.restaurant_id) IS NOT NULL
  )
  SELECT DISTINCT store_id
  FROM (
    SELECT store_id FROM explicit_store_access
    UNION
    SELECT store_id FROM fallback_store
  ) store_scope
  WHERE store_id IS NOT NULL;
$$;


ALTER FUNCTION "public"."user_accessible_stores"("uid" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."user_accessible_stores"("uid" "uuid") IS 'Returns all active store ids accessible to an auth user via user_store_access plus the fallback primary/restaurant store during transition.';



CREATE OR REPLACE FUNCTION "public"."user_accessible_tax_entities"("uid" "uuid") RETURNS SETOF "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  SELECT DISTINCT r.tax_entity_id
  FROM public.user_accessible_stores(uid) s(store_id)
  JOIN public.restaurants r
    ON r.id = s.store_id
  WHERE r.tax_entity_id IS NOT NULL;
$$;


ALTER FUNCTION "public"."user_accessible_tax_entities"("uid" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."user_accessible_tax_entities"("uid" "uuid") IS 'Returns all tax_entity ids reachable through the auth user''s accessible stores.';



CREATE TABLE IF NOT EXISTS "public"."attendance_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "type" "text" NOT NULL,
    "logged_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "photo_url" "text",
    "photo_thumbnail_url" "text",
    CONSTRAINT "attendance_logs_type_check" CHECK (("type" = ANY (ARRAY['clock_in'::"text", 'clock_out'::"text"])))
);


ALTER TABLE "public"."attendance_logs" OWNER TO "postgres";


COMMENT ON TABLE "public"."attendance_logs" IS '스태프 근태 기록';



CREATE TABLE IF NOT EXISTS "public"."audit_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "actor_id" "uuid",
    "action" "text" NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "uuid",
    "details" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."audit_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."b2b_buyer_cache" (
    "store_id" "uuid" NOT NULL,
    "buyer_tax_code" "text" NOT NULL,
    "tax_id" "text" GENERATED ALWAYS AS ("buyer_tax_code") STORED NOT NULL,
    "tax_company_name" "text",
    "tax_address" "text",
    "tax_buyer_name" "text",
    "receiver_email" "text" NOT NULL,
    "receiver_email_cc" "text",
    "first_used_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_used_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "use_count" integer DEFAULT 1 NOT NULL,
    "email_bounce_count" integer DEFAULT 0 NOT NULL,
    "last_verified_at" timestamp with time zone,
    "tax_entity_id" "uuid"
);


ALTER TABLE "public"."b2b_buyer_cache" OWNER TO "postgres";


COMMENT ON TABLE "public"."b2b_buyer_cache" IS 'POS-local B2B buyer cache. Drives 2-tier autocomplete: Tier A (current store), Tier B (same tax_entity). Populated from form entries and WT09 auto-fill.';



COMMENT ON COLUMN "public"."b2b_buyer_cache"."store_id" IS 'FK to restaurants.id. Column named store_id (new vocabulary) — no legacy code reads this table.';



COMMENT ON COLUMN "public"."b2b_buyer_cache"."buyer_tax_code" IS 'Buyer Vietnamese tax code. Part of composite PK.';



COMMENT ON COLUMN "public"."b2b_buyer_cache"."tax_id" IS 'Generated alias for buyer_tax_code. Kept for field-name alignment with requestEinvoiceInfo payload schema.';



COMMENT ON COLUMN "public"."b2b_buyer_cache"."tax_company_name" IS 'Legal company name. Auto-filled from WT09 on first entry.';



COMMENT ON COLUMN "public"."b2b_buyer_cache"."tax_address" IS 'Registered address. Auto-filled from WT09.';



COMMENT ON COLUMN "public"."b2b_buyer_cache"."tax_buyer_name" IS 'Contact person name. Optional.';



COMMENT ON COLUMN "public"."b2b_buyer_cache"."receiver_email" IS 'Primary email for red invoice delivery. Required — requestEinvoiceInfo will not proceed without this.';



COMMENT ON COLUMN "public"."b2b_buyer_cache"."receiver_email_cc" IS 'Optional CC email for red invoice delivery.';



COMMENT ON COLUMN "public"."b2b_buyer_cache"."first_used_at" IS 'When this buyer was first registered at this store.';



COMMENT ON COLUMN "public"."b2b_buyer_cache"."last_used_at" IS 'Last red invoice request for this buyer at this store.';



COMMENT ON COLUMN "public"."b2b_buyer_cache"."use_count" IS 'Total red invoice requests for this buyer at this store.';



COMMENT ON COLUMN "public"."b2b_buyer_cache"."email_bounce_count" IS 'Email delivery failures from WT06 email_status feedback.';



COMMENT ON COLUMN "public"."b2b_buyer_cache"."last_verified_at" IS 'Last time buyer data was confirmed against WT09 or manually.';



COMMENT ON COLUMN "public"."b2b_buyer_cache"."tax_entity_id" IS 'Denormalized from store at insert time. Enables Tier B cross-store lookup within same tax_entity.';



CREATE TABLE IF NOT EXISTS "public"."brand_master" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "type" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "brand_master_type_check" CHECK (("type" = ANY (ARRAY['internal'::"text", 'external'::"text"])))
);


ALTER TABLE "public"."brand_master" OWNER TO "postgres";


COMMENT ON TABLE "public"."brand_master" IS 'Logical grouping of brands by ownership type. Sits between hq (companies) and brands in the operational hierarchy.';



COMMENT ON COLUMN "public"."brand_master"."id" IS 'Primary key.';



COMMENT ON COLUMN "public"."brand_master"."company_id" IS 'FK to companies (hq). One brand_master belongs to one hq.';



COMMENT ON COLUMN "public"."brand_master"."name" IS 'Human-readable label for this brand group.';



COMMENT ON COLUMN "public"."brand_master"."type" IS 'internal = GLOBOSVN directly operated; external = SaaS client company.';



COMMENT ON COLUMN "public"."brand_master"."created_at" IS 'Row creation timestamp.';



COMMENT ON COLUMN "public"."brand_master"."updated_at" IS 'Last update timestamp.';



CREATE TABLE IF NOT EXISTS "public"."brands" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_id" "uuid",
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "logo_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "brand_master_id" "uuid" NOT NULL,
    "suggested_tax_entity_id" "uuid",
    "service_charge_enabled" boolean DEFAULT false NOT NULL,
    "service_charge_rate" numeric(5,2) DEFAULT 0 NOT NULL,
    CONSTRAINT "brands_service_charge_rate_check" CHECK ((("service_charge_rate" >= (0)::numeric) AND ("service_charge_rate" <= (20)::numeric)))
);


ALTER TABLE "public"."brands" OWNER TO "postgres";


COMMENT ON COLUMN "public"."brands"."brand_master_id" IS 'FK to brand_master. Dev rows use placeholder — update during onboarding.';



COMMENT ON COLUMN "public"."brands"."suggested_tax_entity_id" IS 'UI default tax_entity for new stores under this brand. NOT authoritative — store.tax_entity_id is authoritative (Invariant I1).';



COMMENT ON COLUMN "public"."brands"."service_charge_enabled" IS 'Whether this brand applies a service charge to all orders.';



COMMENT ON COLUMN "public"."brands"."service_charge_rate" IS 'Service charge percentage 0–20. Ignored when service_charge_enabled = false.';



CREATE TABLE IF NOT EXISTS "public"."companies" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."companies" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."daily_closings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "closing_date" "date" NOT NULL,
    "closed_by" "uuid" NOT NULL,
    "orders_total" integer DEFAULT 0 NOT NULL,
    "orders_completed" integer DEFAULT 0 NOT NULL,
    "orders_cancelled" integer DEFAULT 0 NOT NULL,
    "items_cancelled" integer DEFAULT 0 NOT NULL,
    "payments_count" integer DEFAULT 0 NOT NULL,
    "payments_total" numeric(12,2) DEFAULT 0 NOT NULL,
    "payments_cash" numeric(12,2) DEFAULT 0 NOT NULL,
    "payments_card" numeric(12,2) DEFAULT 0 NOT NULL,
    "payments_pay" numeric(12,2) DEFAULT 0 NOT NULL,
    "service_count" integer DEFAULT 0 NOT NULL,
    "service_total" numeric(12,2) DEFAULT 0 NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "low_stock_count" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."daily_closings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."delivery_settlement_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "settlement_id" "uuid" NOT NULL,
    "item_type" "text" NOT NULL,
    "amount" numeric(12,2) NOT NULL,
    "description" "text",
    "reference_rate" numeric(5,4),
    "reference_base" numeric(12,2),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_reference_rate_range" CHECK ((("reference_rate" IS NULL) OR (("reference_rate" >= (0)::numeric) AND ("reference_rate" <= (1)::numeric)))),
    CONSTRAINT "delivery_settlement_items_amount_check" CHECK (("amount" >= (0)::numeric))
);


ALTER TABLE "public"."delivery_settlement_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."einvoice_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid",
    "event_type" "text" NOT NULL,
    "description" "text",
    "retry_count" integer,
    "raw_request" "jsonb",
    "raw_response" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."einvoice_events" OWNER TO "postgres";


COMMENT ON TABLE "public"."einvoice_events" IS 'Append-only audit log of all state changes and API calls for einvoice_jobs. No updates or deletes.';



COMMENT ON COLUMN "public"."einvoice_events"."id" IS 'Primary key.';



COMMENT ON COLUMN "public"."einvoice_events"."job_id" IS 'FK to einvoice_jobs. NULL for system-level events (e.g. polling_activated) not tied to a specific job.';



COMMENT ON COLUMN "public"."einvoice_events"."event_type" IS 'Event type (e.g. send_order_attempt, poll_result, request_einvoice_attempt, polling_activated, status_transition).';



COMMENT ON COLUMN "public"."einvoice_events"."description" IS 'Human-readable description. Includes error details for failed events.';



COMMENT ON COLUMN "public"."einvoice_events"."retry_count" IS 'Retry count at event time. Relevant for requestEinvoiceInfo backoff events.';



COMMENT ON COLUMN "public"."einvoice_events"."raw_request" IS 'JSONB of API request payload. Redacted of credentials.';



COMMENT ON COLUMN "public"."einvoice_events"."raw_response" IS 'JSONB of API response payload. NULL for non-API events.';



COMMENT ON COLUMN "public"."einvoice_events"."created_at" IS 'Event timestamp.';



CREATE TABLE IF NOT EXISTS "public"."einvoice_jobs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ref_id" "text" NOT NULL,
    "order_id" "uuid" NOT NULL,
    "tax_entity_id" "uuid" NOT NULL,
    "einvoice_shop_id" "uuid" NOT NULL,
    "redinvoice_requested" boolean DEFAULT false NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "send_order_payload" "jsonb" NOT NULL,
    "request_einvoice_payload" "jsonb",
    "sid" "text",
    "cqt_report_status" "text",
    "issuance_status" "text",
    "lookup_url" "text",
    "error_classification" "text",
    "error_message" "text",
    "dispatch_attempts" integer DEFAULT 0 NOT NULL,
    "last_dispatch_at" timestamp with time zone,
    "dispatched_at" timestamp with time zone,
    "polling_next_at" timestamp with time zone,
    "request_einvoice_retry_count" integer DEFAULT 0 NOT NULL,
    "request_einvoice_next_retry_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "einvoice_jobs_ref_id_check" CHECK (("ref_id" ~ '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'::"text")),
    CONSTRAINT "einvoice_jobs_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'dispatched'::"text", 'dispatched_polling_disabled'::"text", 'reported'::"text", 'issued_by_portal'::"text", 'failed_terminal'::"text", 'stale'::"text"])))
);


ALTER TABLE "public"."einvoice_jobs" OWNER TO "postgres";


COMMENT ON TABLE "public"."einvoice_jobs" IS 'Per-order WeTax dispatch tracking. Created when order reaches completed status. Two-phase dispatch: sendOrderInfo always; requestEinvoiceInfo only when redinvoice_requested=true.';



COMMENT ON COLUMN "public"."einvoice_jobs"."id" IS 'Primary key.';



COMMENT ON COLUMN "public"."einvoice_jobs"."ref_id" IS 'Immutable UUIDv7 job identifier (Invariant I8). CHECK enforces version nibble=7 and variant bits. Used as WeTax order reference across all API calls.';



COMMENT ON COLUMN "public"."einvoice_jobs"."order_id" IS 'FK to orders. The POS order being reported to WeTax.';



COMMENT ON COLUMN "public"."einvoice_jobs"."tax_entity_id" IS 'Snapshot of store.tax_entity_id at job creation (Invariant I2). Immutable after creation.';



COMMENT ON COLUMN "public"."einvoice_jobs"."einvoice_shop_id" IS 'Snapshot of active einvoice_shop at job creation. Immutable after creation.';



COMMENT ON COLUMN "public"."einvoice_jobs"."redinvoice_requested" IS 'Customer requested a red invoice at checkout. Triggers requestEinvoiceInfo sub-flow when true.';



COMMENT ON COLUMN "public"."einvoice_jobs"."status" IS 'Dispatch lifecycle state. dispatched_polling_disabled = sendOrderInfo done but WT06 globally off via system_config.';



COMMENT ON COLUMN "public"."einvoice_jobs"."send_order_payload" IS 'JSONB snapshot of sendOrderInfo payload as transmitted. Preserved for audit and manual reprocessing.';



COMMENT ON COLUMN "public"."einvoice_jobs"."request_einvoice_payload" IS 'JSONB snapshot of requestEinvoiceInfo payload including buyer data. NULL if redinvoice_requested=false.';



COMMENT ON COLUMN "public"."einvoice_jobs"."sid" IS 'WeTax session identifier. NULLABLE (adaptation point 1): from sendOrderInfo response if present, otherwise from WT06 polling.';



COMMENT ON COLUMN "public"."einvoice_jobs"."cqt_report_status" IS 'CQT tax authority report status from WT06. NULL until polled.';



COMMENT ON COLUMN "public"."einvoice_jobs"."issuance_status" IS 'Invoice issuance status from WT06. NULL until polled.';



COMMENT ON COLUMN "public"."einvoice_jobs"."lookup_url" IS 'WeTax portal URL from WT06. Used by Open in WeTax Portal button.';



COMMENT ON COLUMN "public"."einvoice_jobs"."error_classification" IS 'Classified error type for failed_terminal/stale jobs. Drives admin dashboard filtering.';



COMMENT ON COLUMN "public"."einvoice_jobs"."error_message" IS 'Human-readable error from API or dispatcher.';



COMMENT ON COLUMN "public"."einvoice_jobs"."dispatch_attempts" IS 'Total sendOrderInfo attempt count including retries.';



COMMENT ON COLUMN "public"."einvoice_jobs"."last_dispatch_at" IS 'Most recent sendOrderInfo attempt timestamp.';



COMMENT ON COLUMN "public"."einvoice_jobs"."dispatched_at" IS 'When job first reached dispatched/dispatched_polling_disabled. Used for FIFO polling order and stale detection (>24h → stale).';



COMMENT ON COLUMN "public"."einvoice_jobs"."polling_next_at" IS 'Scheduled next WT06 poll time. NULL when polling globally disabled.';



COMMENT ON COLUMN "public"."einvoice_jobs"."request_einvoice_retry_count" IS 'Retry count for requestEinvoiceInfo. Drives exponential backoff (adaptation point 3). Reset on manual retry.';



COMMENT ON COLUMN "public"."einvoice_jobs"."request_einvoice_next_retry_at" IS 'Scheduled next requestEinvoiceInfo retry. NULL when not in backoff state.';



COMMENT ON COLUMN "public"."einvoice_jobs"."created_at" IS 'Row creation timestamp.';



COMMENT ON COLUMN "public"."einvoice_jobs"."updated_at" IS 'Last update timestamp.';



CREATE TABLE IF NOT EXISTS "public"."einvoice_shop" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tax_entity_id" "uuid" NOT NULL,
    "provider_shop_code" "text" NOT NULL,
    "shop_name" "text" NOT NULL,
    "templates" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."einvoice_shop" OWNER TO "postgres";


COMMENT ON TABLE "public"."einvoice_shop" IS 'WeTax-registered shop under a tax_entity. Represents one physical sales point in WeTax. Populated from WT01 seller-info.';



COMMENT ON COLUMN "public"."einvoice_shop"."id" IS 'Primary key.';



COMMENT ON COLUMN "public"."einvoice_shop"."tax_entity_id" IS 'FK to tax_entity. The legal seller this shop belongs to.';



COMMENT ON COLUMN "public"."einvoice_shop"."provider_shop_code" IS 'Shop code assigned by WeTax from WT01.';



COMMENT ON COLUMN "public"."einvoice_shop"."shop_name" IS 'Human-readable shop name as registered with WeTax.';



COMMENT ON COLUMN "public"."einvoice_shop"."templates" IS 'JSONB array of {form_no, serial_no, status_code} from WT01. Only status_code=1 (Using) eligible for dispatch (Invariant I9).';



COMMENT ON COLUMN "public"."einvoice_shop"."created_at" IS 'Row creation timestamp.';



COMMENT ON COLUMN "public"."einvoice_shop"."updated_at" IS 'Last update timestamp.';



CREATE TABLE IF NOT EXISTS "public"."external_sales" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "source_system" "text" NOT NULL,
    "external_order_id" "text" NOT NULL,
    "sales_channel" "text" DEFAULT 'delivery'::"text" NOT NULL,
    "gross_amount" numeric(12,2) NOT NULL,
    "discount_amount" numeric(12,2) DEFAULT 0 NOT NULL,
    "delivery_fee" numeric(12,2) DEFAULT 0 NOT NULL,
    "net_amount" numeric(12,2) NOT NULL,
    "currency" "text" DEFAULT 'VND'::"text" NOT NULL,
    "order_status" "text" NOT NULL,
    "is_revenue" boolean DEFAULT true NOT NULL,
    "completed_at" timestamp with time zone,
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "settlement_id" "uuid",
    CONSTRAINT "external_sales_delivery_fee_check" CHECK (("delivery_fee" >= (0)::numeric)),
    CONSTRAINT "external_sales_discount_amount_check" CHECK (("discount_amount" >= (0)::numeric)),
    CONSTRAINT "external_sales_gross_amount_check" CHECK (("gross_amount" >= (0)::numeric)),
    CONSTRAINT "external_sales_net_amount_check" CHECK (("net_amount" >= (0)::numeric)),
    CONSTRAINT "external_sales_order_status_check" CHECK (("order_status" = ANY (ARRAY['completed'::"text", 'cancelled'::"text", 'refunded'::"text", 'partially_refunded'::"text"]))),
    CONSTRAINT "external_sales_sales_channel_check" CHECK (("sales_channel" = 'delivery'::"text")),
    CONSTRAINT "external_sales_source_system_check" CHECK (("source_system" = 'deliberry'::"text"))
);


ALTER TABLE "public"."external_sales" OWNER TO "postgres";


COMMENT ON TABLE "public"."external_sales" IS 'Deliberry 배달 매출 연동';



CREATE TABLE IF NOT EXISTS "public"."fingerprint_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "template_data" "text" NOT NULL,
    "finger_index" integer DEFAULT 0 NOT NULL,
    "enrolled_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."fingerprint_templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_daily_consumption" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "brand_id" "uuid",
    "product_id" "uuid" NOT NULL,
    "consumption_date" "date" NOT NULL,
    "sales_quantity" numeric(12,3) DEFAULT 0 NOT NULL,
    "consumed_quantity_base" numeric(12,3) DEFAULT 0 NOT NULL,
    "consumed_amount" numeric(12,2) DEFAULT 0 NOT NULL,
    "source" "text" DEFAULT 'pos'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "inventory_daily_consumption_source_check" CHECK (("source" = ANY (ARRAY['pos'::"text", 'daily_close'::"text", 'manual_adjustment'::"text"])))
);


ALTER TABLE "public"."inventory_daily_consumption" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_physical_counts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "ingredient_id" "uuid" NOT NULL,
    "count_date" "date" NOT NULL,
    "actual_quantity_g" numeric(12,3) NOT NULL,
    "theoretical_quantity_g" numeric(12,3),
    "variance_g" numeric(12,3),
    "counted_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."inventory_physical_counts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_purchase_order_lines" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "purchase_order_id" "uuid" NOT NULL,
    "product_id" "uuid" NOT NULL,
    "supplier_item_id" "uuid",
    "recommended_quantity_base" numeric(12,3) DEFAULT 0 NOT NULL,
    "ordered_quantity_base" numeric(12,3) DEFAULT 0 NOT NULL,
    "ordered_quantity_unit" numeric(12,3) DEFAULT 0 NOT NULL,
    "order_unit" "text" NOT NULL,
    "unit_price" numeric(12,2) DEFAULT 0 NOT NULL,
    "supply_amount" numeric(12,2) DEFAULT 0 NOT NULL,
    "tax_amount" numeric(12,2) DEFAULT 0 NOT NULL,
    "memo" "text",
    "recommendation_snapshot" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "inventory_purchase_order_lines_ordered_quantity_base_check" CHECK (("ordered_quantity_base" >= (0)::numeric)),
    CONSTRAINT "inventory_purchase_order_lines_ordered_quantity_unit_check" CHECK (("ordered_quantity_unit" >= (0)::numeric)),
    CONSTRAINT "inventory_purchase_order_lines_recommended_quantity_base_check" CHECK (("recommended_quantity_base" >= (0)::numeric)),
    CONSTRAINT "inventory_purchase_order_lines_supply_amount_check" CHECK (("supply_amount" >= (0)::numeric)),
    CONSTRAINT "inventory_purchase_order_lines_tax_amount_check" CHECK (("tax_amount" >= (0)::numeric)),
    CONSTRAINT "inventory_purchase_order_lines_unit_price_check" CHECK (("unit_price" >= (0)::numeric))
);


ALTER TABLE "public"."inventory_purchase_order_lines" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_receipt_lines" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "receipt_id" "uuid" NOT NULL,
    "purchase_order_line_id" "uuid",
    "product_id" "uuid" NOT NULL,
    "received_quantity_base" numeric(12,3) DEFAULT 0 NOT NULL,
    "accepted_quantity_base" numeric(12,3) DEFAULT 0 NOT NULL,
    "rejected_quantity_base" numeric(12,3) DEFAULT 0 NOT NULL,
    "memo" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "inventory_receipt_lines_accepted_quantity_base_check" CHECK (("accepted_quantity_base" >= (0)::numeric)),
    CONSTRAINT "inventory_receipt_lines_received_quantity_base_check" CHECK (("received_quantity_base" >= (0)::numeric)),
    CONSTRAINT "inventory_receipt_lines_rejected_quantity_base_check" CHECK (("rejected_quantity_base" >= (0)::numeric))
);


ALTER TABLE "public"."inventory_receipt_lines" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_receipts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "purchase_order_id" "uuid" NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "supplier_id" "uuid" NOT NULL,
    "received_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "received_by" "uuid",
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "memo" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "inventory_receipts_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'confirmed'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."inventory_receipts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_recommendation_lines" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "run_id" "uuid" NOT NULL,
    "product_id" "uuid" NOT NULL,
    "supplier_id" "uuid",
    "current_stock_base" numeric(12,3) DEFAULT 0 NOT NULL,
    "avg_daily_consumption_base" numeric(12,3) DEFAULT 0 NOT NULL,
    "target_stock_days" numeric(8,2) DEFAULT 3 NOT NULL,
    "recommended_quantity_base" numeric(12,3) DEFAULT 0 NOT NULL,
    "recommended_order_units" numeric(12,3) DEFAULT 0 NOT NULL,
    "estimated_days_remaining" numeric(8,2),
    "risk_status" "text" DEFAULT 'stable'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "inventory_recommendation_lines_risk_status_check" CHECK (("risk_status" = ANY (ARRAY['danger'::"text", 'warning'::"text", 'normal'::"text", 'stable'::"text"])))
);


ALTER TABLE "public"."inventory_recommendation_lines" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_recommendation_runs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "brand_id" "uuid",
    "run_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "target_stock_days" numeric(8,2) DEFAULT 3 NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "inventory_recommendation_runs_target_stock_days_check" CHECK (("target_stock_days" > (0)::numeric))
);


ALTER TABLE "public"."inventory_recommendation_runs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_stock_audit_lines" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "product_id" "uuid" NOT NULL,
    "theoretical_quantity_base" numeric(12,3) DEFAULT 0 NOT NULL,
    "actual_quantity_base" numeric(12,3),
    "variance_quantity_base" numeric(12,3),
    "variance_amount" numeric(12,2),
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "photo_url" "text",
    "memo" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "inventory_stock_audit_lines_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'counted'::"text", 'skipped'::"text"])))
);


ALTER TABLE "public"."inventory_stock_audit_lines" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_stock_audit_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "brand_id" "uuid",
    "audit_no" "text" NOT NULL,
    "audit_type" "text" DEFAULT 'daily'::"text" NOT NULL,
    "status" "text" DEFAULT 'planned'::"text" NOT NULL,
    "planned_date" "date",
    "started_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "created_by" "uuid",
    "assigned_to" "uuid",
    "memo" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "inventory_stock_audit_sessions_audit_type_check" CHECK (("audit_type" = ANY (ARRAY['daily'::"text", 'weekly'::"text", 'monthly'::"text", 'ad_hoc'::"text"]))),
    CONSTRAINT "inventory_stock_audit_sessions_status_check" CHECK (("status" = ANY (ARRAY['planned'::"text", 'in_progress'::"text", 'completed'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."inventory_stock_audit_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventory_transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "ingredient_id" "uuid" NOT NULL,
    "transaction_type" "text" NOT NULL,
    "quantity_g" numeric(12,3) NOT NULL,
    "reference_type" "text",
    "reference_id" "uuid",
    "note" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "inventory_transactions_transaction_type_check" CHECK (("transaction_type" = ANY (ARRAY['deduct'::"text", 'restock'::"text", 'adjust'::"text", 'waste'::"text"])))
);


ALTER TABLE "public"."inventory_transactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."menu_recipes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "menu_item_id" "uuid" NOT NULL,
    "ingredient_id" "uuid" NOT NULL,
    "quantity_g" numeric(10,3) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "menu_recipes_quantity_g_check" CHECK (("quantity_g" > (0)::numeric))
);


ALTER TABLE "public"."menu_recipes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."office_payroll_reviews" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_payroll_id" "uuid" NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "brand_id" "uuid",
    "period_start" "date" NOT NULL,
    "period_end" "date" NOT NULL,
    "status" "text" DEFAULT 'pending_review'::"text" NOT NULL,
    "reviewed_by" "uuid",
    "confirmed_by" "uuid",
    "review_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "office_payroll_reviews_status_check" CHECK (("status" = ANY (ARRAY['pending_review'::"text", 'in_review'::"text", 'confirmed'::"text", 'rejected'::"text", 'returned'::"text"])))
);


ALTER TABLE "public"."office_payroll_reviews" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."partner_credential_access_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "credential_id" "uuid" NOT NULL,
    "accessed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "access_reason" "text" NOT NULL,
    "accessed_by_function" "text" NOT NULL,
    "success" boolean NOT NULL
);


ALTER TABLE "public"."partner_credential_access_log" OWNER TO "postgres";


COMMENT ON TABLE "public"."partner_credential_access_log" IS 'Append-only log of every decrypt or read of partner_credentials. Required by L4 envelope encryption discipline (Invariant I6). No updates or deletes — enforced by RLS in Step 6.';



COMMENT ON COLUMN "public"."partner_credential_access_log"."id" IS 'Primary key.';



COMMENT ON COLUMN "public"."partner_credential_access_log"."credential_id" IS 'FK to partner_credentials. The credential that was accessed.';



COMMENT ON COLUMN "public"."partner_credential_access_log"."accessed_at" IS 'Access event timestamp.';



COMMENT ON COLUMN "public"."partner_credential_access_log"."access_reason" IS 'Reason for access (e.g. token_refresh, initial_auth, dispatcher_startup).';



COMMENT ON COLUMN "public"."partner_credential_access_log"."accessed_by_function" IS 'Edge function or process identifier (e.g. wetax-dispatcher).';



COMMENT ON COLUMN "public"."partner_credential_access_log"."success" IS 'Whether the access and subsequent operation succeeded.';



CREATE TABLE IF NOT EXISTS "public"."partner_credentials" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "data_source" "text" DEFAULT 'VNPT_EPAY'::"text" NOT NULL,
    "auth_mode" "text" DEFAULT 'password_jwt'::"text" NOT NULL,
    "user_id" "text" NOT NULL,
    "password_value" "bytea" NOT NULL,
    "password_format" "text" DEFAULT 'plaintext'::"text" NOT NULL,
    "kek_version" integer DEFAULT 1 NOT NULL,
    "last_verified_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "current_token" "text",
    "token_expires_at" timestamp with time zone,
    CONSTRAINT "partner_credentials_auth_mode_check" CHECK (("auth_mode" = ANY (ARRAY['password_jwt'::"text", 'api_key'::"text"]))),
    CONSTRAINT "partner_credentials_password_format_check" CHECK (("password_format" = ANY (ARRAY['plaintext'::"text", 'aes256_ciphertext'::"text"])))
);


ALTER TABLE "public"."partner_credentials" OWNER TO "postgres";


COMMENT ON TABLE "public"."partner_credentials" IS 'Single Agency master credential for WeTax. L4 envelope encryption. Singleton per data_source (I4). Only wetax-dispatcher edge function may read (enforced by RLS in Step 6).';



COMMENT ON COLUMN "public"."partner_credentials"."id" IS 'Primary key.';



COMMENT ON COLUMN "public"."partner_credentials"."data_source" IS 'Data source identifier. VNPT_EPAY only in Stage 1. UNIQUE — at most one credential per provider.';



COMMENT ON COLUMN "public"."partner_credentials"."auth_mode" IS 'Auth mode. password_jwt in Stage 1. api_key reserved for future migration without schema change.';



COMMENT ON COLUMN "public"."partner_credentials"."user_id" IS 'WeTax partner login username. Plaintext (low sensitivity).';



COMMENT ON COLUMN "public"."partner_credentials"."password_value" IS 'Envelope-encrypted credential bytes. Inner plaintext is raw password or AES256 ciphertext depending on password_format.';



COMMENT ON COLUMN "public"."partner_credentials"."password_format" IS 'plaintext = raw password forwarded to WT00; aes256_ciphertext = pre-encrypted string forwarded verbatim. Envelope encryption (L1) applies in both modes.';



COMMENT ON COLUMN "public"."partner_credentials"."kek_version" IS 'Key Encryption Key version. Tracks KEK rotations via Supabase Vault.';



COMMENT ON COLUMN "public"."partner_credentials"."last_verified_at" IS 'Last successful WT00 authentication with this credential.';



COMMENT ON COLUMN "public"."partner_credentials"."created_at" IS 'Row creation timestamp.';



COMMENT ON COLUMN "public"."partner_credentials"."updated_at" IS 'Last update timestamp.';



COMMENT ON COLUMN "public"."partner_credentials"."current_token" IS 'Cached WeTax JWT from WT00 login. Read by dispatcher before each API call. Refreshed when NULL or within 15 minutes of token_expires_at.';



COMMENT ON COLUMN "public"."partner_credentials"."token_expires_at" IS 'Expiry timestamp of current_token. Proactive refresh triggers at token_expires_at - 15 minutes. Set from WT00 response expires_in.';



CREATE TABLE IF NOT EXISTS "public"."photo_objet_sales" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "store_id" "uuid" NOT NULL,
    "sale_date" "date" NOT NULL,
    "device_name" "text" NOT NULL,
    "device_id" "text",
    "gross_sales" bigint DEFAULT 0 NOT NULL,
    "service_amount" bigint DEFAULT 0 NOT NULL,
    "transaction_count" integer DEFAULT 0 NOT NULL,
    "service_count" integer DEFAULT 0 NOT NULL,
    "raw_rows" "jsonb",
    "pulled_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "pull_source" "text" DEFAULT 'scheduled'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "photo_objet_sales_gross_non_negative" CHECK (("gross_sales" >= 0)),
    CONSTRAINT "photo_objet_sales_pull_source_check" CHECK (("pull_source" = ANY (ARRAY['scheduled'::"text", 'manual'::"text"]))),
    CONSTRAINT "photo_objet_sales_service_count_non_negative" CHECK (("service_count" >= 0)),
    CONSTRAINT "photo_objet_sales_service_non_negative" CHECK (("service_amount" >= 0)),
    CONSTRAINT "photo_objet_sales_transactions_non_negative" CHECK (("transaction_count" >= 0))
);


ALTER TABLE "public"."photo_objet_sales" OWNER TO "postgres";


COMMENT ON TABLE "public"."photo_objet_sales" IS 'Photo Objet daily sales ingestion table. POS contract uses restaurants.id as store_id.';



CREATE OR REPLACE VIEW "public"."public_menu_items" AS
 SELECT "mi"."id" AS "external_menu_item_id",
    "mi"."restaurant_id",
    "r"."slug" AS "restaurant_slug",
    "r"."store_type",
    "mc"."name" AS "category_name",
    "mi"."name",
    "mi"."description",
    "mi"."price",
    "r"."operation_mode"
   FROM (("public"."menu_items" "mi"
     JOIN "public"."stores" "r" ON (("r"."id" = "mi"."restaurant_id")))
     LEFT JOIN "public"."menu_categories" "mc" ON (("mc"."id" = "mi"."category_id")))
  WHERE (("mi"."is_available" = true) AND ("mi"."is_visible_public" = true));


ALTER VIEW "public"."public_menu_items" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."public_restaurant_profiles" AS
 SELECT "r"."id",
    "r"."slug",
    "r"."name",
    "r"."address",
    "r"."operation_mode",
    "r"."per_person_charge",
    "r"."is_active",
    "r"."store_type",
    "r"."brand_id",
    "b"."name" AS "brand_name",
    "r"."created_at"
   FROM ("public"."stores" "r"
     LEFT JOIN "public"."brands" "b" ON (("b"."id" = "r"."brand_id")))
  WHERE ("r"."is_active" = true);


ALTER VIEW "public"."public_restaurant_profiles" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."public_store_profiles" AS
 SELECT "id",
    "slug",
    "name",
    "address",
    "operation_mode",
    "per_person_charge",
    "is_active",
    "store_type",
    "brand_id",
    "brand_name",
    "created_at"
   FROM "public"."public_restaurant_profiles";


ALTER VIEW "public"."public_store_profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."restaurant_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "payroll_pin" "text",
    "settings_json" "jsonb" DEFAULT '{}'::"jsonb",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."restaurant_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."staff_wage_configs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "wage_type" "text" NOT NULL,
    "hourly_rate" numeric(12,2),
    "shift_rates" "jsonb",
    "effective_from" "date" DEFAULT CURRENT_DATE NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_hourly_rate" CHECK ((("hourly_rate" IS NULL) OR ("hourly_rate" > (0)::numeric))),
    CONSTRAINT "staff_wage_configs_wage_type_check" CHECK (("wage_type" = ANY (ARRAY['hourly'::"text", 'shift'::"text"])))
);


ALTER TABLE "public"."staff_wage_configs" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."store_settings" AS
 SELECT "id",
    "restaurant_id" AS "store_id",
    "payroll_pin",
    "settings_json",
    "updated_at"
   FROM "public"."restaurant_settings";


ALTER VIEW "public"."store_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."store_tax_entity_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "store_id" "uuid" NOT NULL,
    "tax_entity_id" "uuid" NOT NULL,
    "effective_from" timestamp with time zone DEFAULT "now"() NOT NULL,
    "effective_to" timestamp with time zone,
    "reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid"
);


ALTER TABLE "public"."store_tax_entity_history" OWNER TO "postgres";


COMMENT ON TABLE "public"."store_tax_entity_history" IS 'Append-only history of store-to-tax_entity associations. Invariant I5: new associations are new rows; only effective_to is updated on prior rows.';



COMMENT ON COLUMN "public"."store_tax_entity_history"."id" IS 'Primary key.';



COMMENT ON COLUMN "public"."store_tax_entity_history"."store_id" IS 'FK to restaurants.id. Column named store_id (new vocabulary).';



COMMENT ON COLUMN "public"."store_tax_entity_history"."tax_entity_id" IS 'FK to tax_entity. The legal seller associated with this store during this period.';



COMMENT ON COLUMN "public"."store_tax_entity_history"."effective_from" IS 'Start of this association.';



COMMENT ON COLUMN "public"."store_tax_entity_history"."effective_to" IS 'End of this association. NULL = currently active.';



COMMENT ON COLUMN "public"."store_tax_entity_history"."reason" IS 'Reason for the change (e.g. initial_setup, store_sale, restructure).';



COMMENT ON COLUMN "public"."store_tax_entity_history"."created_at" IS 'Row creation timestamp.';



COMMENT ON COLUMN "public"."store_tax_entity_history"."created_by" IS 'FK to users. Admin who recorded the change.';



CREATE TABLE IF NOT EXISTS "public"."system_config" (
    "key" "text" NOT NULL,
    "value" "text" NOT NULL,
    "description" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_by" "uuid"
);


ALTER TABLE "public"."system_config" OWNER TO "postgres";


COMMENT ON TABLE "public"."system_config" IS 'Key-value runtime configuration for WeTax dispatcher. Flags change dispatcher behavior without code deployment. Update via SQL by super admin. See scope v1.3 Section 3.1 and Appendix B.';



COMMENT ON COLUMN "public"."system_config"."key" IS 'Configuration key. Primary key.';



COMMENT ON COLUMN "public"."system_config"."value" IS 'Configuration value (text; parse on read in application code).';



COMMENT ON COLUMN "public"."system_config"."description" IS 'Human-readable explanation of what this flag controls and its valid values.';



COMMENT ON COLUMN "public"."system_config"."updated_at" IS 'Timestamp of last update.';



COMMENT ON COLUMN "public"."system_config"."updated_by" IS 'FK to users. NULL for system-seeded rows. Tracks which super admin changed the value.';



CREATE TABLE IF NOT EXISTS "public"."tax_entity" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tax_code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "owner_type" "text" NOT NULL,
    "einvoice_provider" "text" DEFAULT 'wetax'::"text" NOT NULL,
    "pos_key" "text",
    "declaration_status" "text",
    "res_key" "text",
    "wetax_end_point" "text",
    "data_source" "text" DEFAULT 'VNPT_EPAY'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "tax_entity_einvoice_provider_check" CHECK (("einvoice_provider" = 'wetax'::"text")),
    CONSTRAINT "tax_entity_owner_type_check" CHECK (("owner_type" = ANY (ARRAY['internal'::"text", 'external'::"text"])))
);


ALTER TABLE "public"."tax_entity" OWNER TO "postgres";


COMMENT ON TABLE "public"."tax_entity" IS 'Legal seller entity registered with Vietnamese tax authority. Tax axis anchor: store.tax_entity_id points here. Invariants I1, I2, I10.';



COMMENT ON COLUMN "public"."tax_entity"."id" IS 'Primary key.';



COMMENT ON COLUMN "public"."tax_entity"."tax_code" IS 'Vietnamese tax code (mã số thuế). Unique.';



COMMENT ON COLUMN "public"."tax_entity"."name" IS 'Legal company name as registered with tax authority.';



COMMENT ON COLUMN "public"."tax_entity"."owner_type" IS 'internal = GLOBOSVN own entity; external = SaaS client entity.';



COMMENT ON COLUMN "public"."tax_entity"."einvoice_provider" IS 'E-invoice provider. Only wetax in Stage 1.';



COMMENT ON COLUMN "public"."tax_entity"."pos_key" IS 'POS key from WT01 seller-info. Used in CQT code composition.';



COMMENT ON COLUMN "public"."tax_entity"."declaration_status" IS 'Declaration status from WT01. Must be 5 (Accepted) before dispatch proceeds (Invariant I10).';



COMMENT ON COLUMN "public"."tax_entity"."res_key" IS 'Returned by agency/sellers registration. Identifies the seller in WeTax.';



COMMENT ON COLUMN "public"."tax_entity"."wetax_end_point" IS 'WeTax endpoint URL for this entity. Used for portal lookup_url composition.';



COMMENT ON COLUMN "public"."tax_entity"."data_source" IS 'Data source identifier. Fixed to VNPT_EPAY in Stage 1.';



COMMENT ON COLUMN "public"."tax_entity"."created_at" IS 'Row creation timestamp.';



COMMENT ON COLUMN "public"."tax_entity"."updated_at" IS 'Last update timestamp.';



CREATE TABLE IF NOT EXISTS "public"."user_brand_access" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "brand_id" "uuid" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "granted_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."user_brand_access" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_brand_access" IS 'Authoritative brand-scope access table. Defines which brands a user can access in the multi-access model.';



COMMENT ON COLUMN "public"."user_brand_access"."is_active" IS 'Soft-disable flag for brand access grants. Rows are preserved for auditability.';



CREATE TABLE IF NOT EXISTS "public"."user_store_access" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "store_id" "uuid" NOT NULL,
    "is_primary" boolean DEFAULT false NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "source_type" "text" NOT NULL,
    "source_brand_access_id" "uuid",
    "granted_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "user_store_access_source_type_check" CHECK (("source_type" = ANY (ARRAY['direct'::"text", 'brand_inherited'::"text"])))
);


ALTER TABLE "public"."user_store_access" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_store_access" IS 'Authoritative final store-scope access table. RLS and Flutter consumers will ultimately resolve access at the store level from this table.';



COMMENT ON COLUMN "public"."user_store_access"."is_primary" IS 'Marks the user''s primary working store access row. Distinct from broader multi-store visibility.';



COMMENT ON COLUMN "public"."user_store_access"."source_type" IS 'direct = explicitly granted store access; brand_inherited = derived from an active brand access grant.';



CREATE OR REPLACE VIEW "public"."v_brand_kpi" AS
 SELECT "b"."id" AS "brand_id",
    "b"."code" AS "brand_code",
    "b"."name" AS "brand_name",
    "count"(DISTINCT "r"."id") AS "store_count",
    "count"(DISTINCT "u"."id") FILTER (WHERE ("u"."is_active" = true)) AS "active_staff_count",
    ( SELECT COALESCE("sum"("p"."amount"), (0)::numeric) AS "coalesce"
           FROM ("public"."payments" "p"
             JOIN "public"."stores" "r2" ON (("r2"."id" = "p"."restaurant_id")))
          WHERE (("r2"."brand_id" = "b"."id") AND ("r2"."store_type" = 'direct'::"text") AND ("p"."is_revenue" = true) AND ("p"."created_at" >= "date_trunc"('month'::"text", ("now"() AT TIME ZONE 'Asia/Ho_Chi_Minh'::"text"))))) AS "mtd_revenue",
    ( SELECT "count"(DISTINCT "p"."order_id") AS "count"
           FROM ("public"."payments" "p"
             JOIN "public"."stores" "r2" ON (("r2"."id" = "p"."restaurant_id")))
          WHERE (("r2"."brand_id" = "b"."id") AND ("r2"."store_type" = 'direct'::"text") AND ("p"."is_revenue" = true) AND ("p"."created_at" >= "date_trunc"('month'::"text", ("now"() AT TIME ZONE 'Asia/Ho_Chi_Minh'::"text"))))) AS "mtd_order_count"
   FROM (("public"."brands" "b"
     LEFT JOIN "public"."stores" "r" ON ((("r"."brand_id" = "b"."id") AND ("r"."store_type" = 'direct'::"text"))))
     LEFT JOIN "public"."users" "u" ON (("u"."restaurant_id" = "r"."id")))
  GROUP BY "b"."id", "b"."code", "b"."name";


ALTER VIEW "public"."v_brand_kpi" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_daily_revenue_by_channel" AS
 SELECT COALESCE("pos"."restaurant_id", "del"."restaurant_id") AS "restaurant_id",
    COALESCE("pos"."sale_date", "del"."sale_date") AS "sale_date",
    COALESCE("pos"."dine_in_revenue", (0)::numeric) AS "dine_in_revenue",
    COALESCE("pos"."dine_in_orders", (0)::bigint) AS "dine_in_orders",
    COALESCE("pos"."takeaway_revenue", (0)::numeric) AS "takeaway_revenue",
    COALESCE("pos"."takeaway_orders", (0)::bigint) AS "takeaway_orders",
    COALESCE("del"."delivery_revenue", (0)::numeric) AS "delivery_revenue",
    COALESCE("del"."delivery_orders", (0)::bigint) AS "delivery_orders",
    ((COALESCE("pos"."dine_in_revenue", (0)::numeric) + COALESCE("pos"."takeaway_revenue", (0)::numeric)) + COALESCE("del"."delivery_revenue", (0)::numeric)) AS "total_revenue"
   FROM (( SELECT "o"."restaurant_id",
            (("p"."created_at" AT TIME ZONE 'Asia/Ho_Chi_Minh'::"text"))::"date" AS "sale_date",
            "sum"(
                CASE
                    WHEN ("o"."sales_channel" = 'dine_in'::"text") THEN "p"."amount"
                    ELSE (0)::numeric
                END) AS "dine_in_revenue",
            "count"(
                CASE
                    WHEN ("o"."sales_channel" = 'dine_in'::"text") THEN 1
                    ELSE NULL::integer
                END) AS "dine_in_orders",
            "sum"(
                CASE
                    WHEN ("o"."sales_channel" = 'takeaway'::"text") THEN "p"."amount"
                    ELSE (0)::numeric
                END) AS "takeaway_revenue",
            "count"(
                CASE
                    WHEN ("o"."sales_channel" = 'takeaway'::"text") THEN 1
                    ELSE NULL::integer
                END) AS "takeaway_orders"
           FROM ("public"."orders" "o"
             JOIN "public"."payments" "p" ON (("p"."order_id" = "o"."id")))
          WHERE (("o"."status" = 'completed'::"text") AND ("p"."is_revenue" = true))
          GROUP BY "o"."restaurant_id", ((("p"."created_at" AT TIME ZONE 'Asia/Ho_Chi_Minh'::"text"))::"date")) "pos"
     FULL JOIN ( SELECT "external_sales"."restaurant_id",
            (("external_sales"."completed_at" AT TIME ZONE 'Asia/Ho_Chi_Minh'::"text"))::"date" AS "sale_date",
            "sum"("external_sales"."gross_amount") AS "delivery_revenue",
            "count"(*) AS "delivery_orders"
           FROM "public"."external_sales"
          WHERE (("external_sales"."is_revenue" = true) AND ("external_sales"."order_status" = 'completed'::"text"))
          GROUP BY "external_sales"."restaurant_id", ((("external_sales"."completed_at" AT TIME ZONE 'Asia/Ho_Chi_Minh'::"text"))::"date")) "del" ON ((("pos"."restaurant_id" = "del"."restaurant_id") AND ("pos"."sale_date" = "del"."sale_date"))));


ALTER VIEW "public"."v_daily_revenue_by_channel" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_external_store_overview" WITH ("security_invoker"='true') AS
 SELECT "r"."id" AS "store_id",
    "r"."name" AS "store_name",
    "b"."name" AS "brand_name",
    "r"."brand_id",
    "r"."is_active",
    "r"."created_at" AS "registered_at",
    ( SELECT "count"(*) AS "count"
           FROM "public"."users" "u"
          WHERE (("u"."restaurant_id" = "r"."id") AND ("u"."is_active" = true))) AS "active_staff",
    ( SELECT COALESCE("sum"("p"."amount"), (0)::numeric) AS "coalesce"
           FROM "public"."payments" "p"
          WHERE (("p"."restaurant_id" = "r"."id") AND ("p"."is_revenue" = true) AND ("p"."created_at" >= "date_trunc"('month'::"text", "now"())))) AS "mtd_sales",
    ( SELECT "count"(DISTINCT "o"."id") AS "count"
           FROM "public"."orders" "o"
          WHERE (("o"."restaurant_id" = "r"."id") AND ("o"."created_at" >= "date_trunc"('month'::"text", "now"())))) AS "mtd_order_count"
   FROM ("public"."stores" "r"
     LEFT JOIN "public"."brands" "b" ON (("b"."id" = "r"."brand_id")))
  WHERE (("r"."store_type" = 'external'::"text") AND "public"."is_super_admin"());


ALTER VIEW "public"."v_external_store_overview" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_external_store_sales" WITH ("security_invoker"='true') AS
 SELECT "r"."id" AS "store_id",
    "r"."brand_id",
    "b"."name" AS "brand_name",
    "r"."name" AS "store_name",
    "date"(("p"."created_at" AT TIME ZONE 'Asia/Ho_Chi_Minh'::"text")) AS "sale_date",
    "count"(DISTINCT "p"."order_id") AS "order_count",
    "sum"(
        CASE
            WHEN "p"."is_revenue" THEN "p"."amount"
            ELSE (0)::numeric
        END) AS "revenue",
    "sum"(
        CASE
            WHEN (NOT "p"."is_revenue") THEN "p"."amount"
            ELSE (0)::numeric
        END) AS "service_amount"
   FROM (("public"."payments" "p"
     JOIN "public"."stores" "r" ON (("r"."id" = "p"."restaurant_id")))
     LEFT JOIN "public"."brands" "b" ON (("b"."id" = "r"."brand_id")))
  WHERE (("r"."store_type" = 'external'::"text") AND "public"."is_super_admin"())
  GROUP BY "r"."id", "r"."brand_id", "b"."name", "r"."name", ("date"(("p"."created_at" AT TIME ZONE 'Asia/Ho_Chi_Minh'::"text")));


ALTER VIEW "public"."v_external_store_sales" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_inventory_status" AS
 SELECT "ii"."id" AS "item_id",
    "ii"."restaurant_id" AS "store_id",
    "r"."brand_id",
    "r"."name" AS "store_name",
    "ii"."name" AS "item_name",
    "ii"."current_stock",
    "ii"."unit",
    "ii"."reorder_point",
    "ii"."cost_per_unit",
    "ii"."supplier_name",
        CASE
            WHEN (("ii"."reorder_point" IS NOT NULL) AND ("ii"."current_stock" <= "ii"."reorder_point")) THEN true
            ELSE false
        END AS "needs_reorder",
    "ii"."updated_at" AS "last_updated"
   FROM ("public"."inventory_items" "ii"
     JOIN "public"."stores" "r" ON (("r"."id" = "ii"."restaurant_id")))
  WHERE ("r"."store_type" = 'direct'::"text");


ALTER VIEW "public"."v_inventory_status" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_quality_monitoring" AS
 WITH "qsc_source" AS (
         SELECT "qc"."id" AS "check_id",
            "qc"."restaurant_id" AS "store_id",
            "r"."brand_id",
            "r"."name" AS "store_name",
            "qt"."category",
            "qt"."criteria_text",
            "qc"."check_date",
            "qc"."result",
            "qc"."evidence_photo_url",
            "qc"."note",
            "qc"."checked_by",
            "qc"."created_at",
            "qt"."qsc_domain",
            COALESCE("qt"."requires_photo", true) AS "requires_photo",
            COALESCE("qc"."photo_required_count", "qt"."required_photo_count", 0) AS "required_photo_count",
            COALESCE("qc"."photo_uploaded_count", 0) AS "photo_uploaded_count",
            "qc"."submission_status",
            "qc"."submitted_at",
            "qc"."score",
            "qc"."grade",
            "qc"."sv_review_status",
            "qc"."sv_reviewed_by",
            "qc"."sv_reviewed_at",
            "qc"."sv_score",
            "qc"."visit_session_id",
            "qf"."id" AS "followup_id",
            "qf"."status" AS "followup_status",
            "qf"."assigned_to_name" AS "followup_assigned_to_name",
            "qf"."resolved_at" AS "followup_resolved_at"
           FROM ((("public"."qc_checks" "qc"
             JOIN "public"."qc_templates" "qt" ON (("qt"."id" = "qc"."template_id")))
             JOIN "public"."restaurants" "r" ON (("r"."id" = "qc"."restaurant_id")))
             LEFT JOIN "public"."qc_followups" "qf" ON (("qf"."source_check_id" = "qc"."id")))
          WHERE ("r"."store_type" = 'direct'::"text")
        )
 SELECT "check_id",
    "store_id",
    "brand_id",
    "store_name",
    "category",
    "criteria_text",
    "check_date",
    "result",
    "evidence_photo_url",
    "note",
    "checked_by",
    "created_at",
    "qsc_domain",
    "requires_photo",
    "required_photo_count",
    "photo_uploaded_count",
        CASE
            WHEN ((NOT "requires_photo") OR ("required_photo_count" = 0)) THEN 'not_required'::"text"
            WHEN ("photo_uploaded_count" <= 0) THEN 'missing'::"text"
            WHEN ("photo_uploaded_count" < "required_photo_count") THEN 'partial'::"text"
            ELSE 'complete'::"text"
        END AS "photo_status",
    "submission_status",
    "submitted_at",
    "score",
    "grade",
    "sv_review_status",
    "sv_reviewed_by",
    "sv_reviewed_at",
    "sv_score",
    ("result" = 'fail'::"text") AS "improvement_required",
    COALESCE("followup_status", 'none'::"text") AS "followup_status",
    "followup_id",
    "followup_assigned_to_name",
    "followup_resolved_at",
    "visit_session_id"
   FROM "qsc_source" "src";


ALTER VIEW "public"."v_quality_monitoring" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_quality_monitoring" IS 'POS-side monitoring snapshot for Office and admin quality review. Legacy columns are preserved and QSC v2 fields are appended.';



CREATE OR REPLACE VIEW "public"."v_qsc_dashboard_summary" AS
 WITH "per_check" AS (
         SELECT "v_quality_monitoring"."check_id",
            "v_quality_monitoring"."store_id",
            "v_quality_monitoring"."brand_id",
            "v_quality_monitoring"."store_name",
            "v_quality_monitoring"."category",
            "v_quality_monitoring"."criteria_text",
            "v_quality_monitoring"."check_date",
            "v_quality_monitoring"."result",
            "v_quality_monitoring"."evidence_photo_url",
            "v_quality_monitoring"."note",
            "v_quality_monitoring"."checked_by",
            "v_quality_monitoring"."created_at",
            "v_quality_monitoring"."qsc_domain",
            "v_quality_monitoring"."requires_photo",
            "v_quality_monitoring"."required_photo_count",
            "v_quality_monitoring"."photo_uploaded_count",
            "v_quality_monitoring"."photo_status",
            "v_quality_monitoring"."submission_status",
            "v_quality_monitoring"."submitted_at",
            "v_quality_monitoring"."score",
            "v_quality_monitoring"."grade",
            "v_quality_monitoring"."sv_review_status",
            "v_quality_monitoring"."sv_reviewed_by",
            "v_quality_monitoring"."sv_reviewed_at",
            "v_quality_monitoring"."sv_score",
            "v_quality_monitoring"."improvement_required",
            "v_quality_monitoring"."followup_status",
            "v_quality_monitoring"."followup_id",
            "v_quality_monitoring"."followup_assigned_to_name",
            "v_quality_monitoring"."followup_resolved_at",
            "v_quality_monitoring"."visit_session_id"
           FROM "public"."v_quality_monitoring"
        ), "latest_check_date" AS (
         SELECT "per_check"."store_id",
            "max"("per_check"."check_date") AS "latest_check_date"
           FROM "per_check"
          GROUP BY "per_check"."store_id"
        )
 SELECT "r"."id" AS "store_id",
    "r"."brand_id",
    "r"."name" AS "store_name",
    "lcd"."latest_check_date",
    "count"("pc"."check_id") FILTER (WHERE ("pc"."check_date" = "lcd"."latest_check_date")) AS "total_checks",
    "count"("pc"."check_id") FILTER (WHERE (("pc"."check_date" = "lcd"."latest_check_date") AND ("pc"."submission_status" = 'submitted'::"text"))) AS "submitted_checks",
    "count"("pc"."check_id") FILTER (WHERE (("pc"."check_date" = "lcd"."latest_check_date") AND ("pc"."submission_status" = 'pending'::"text"))) AS "pending_checks",
    "count"("pc"."check_id") FILTER (WHERE (("pc"."check_date" = "lcd"."latest_check_date") AND ("pc"."submission_status" = 'overdue'::"text"))) AS "overdue_checks",
    "count"("pc"."check_id") FILTER (WHERE (("pc"."check_date" = "lcd"."latest_check_date") AND ("pc"."result" = 'fail'::"text"))) AS "failed_checks",
    "count"("pc"."check_id") FILTER (WHERE (("pc"."check_date" = "lcd"."latest_check_date") AND ("pc"."photo_status" = 'missing'::"text"))) AS "missing_photo_checks",
    "count"("pc"."check_id") FILTER (WHERE (("pc"."check_date" = "lcd"."latest_check_date") AND ("pc"."sv_review_status" = 'pending'::"text"))) AS "pending_sv_reviews",
    "count"("pc"."check_id") FILTER (WHERE (("pc"."check_date" = "lcd"."latest_check_date") AND ("pc"."followup_status" = ANY (ARRAY['open'::"text", 'in_progress'::"text"])))) AS "open_followups",
    "round"("avg"("pc"."score") FILTER (WHERE (("pc"."check_date" = "lcd"."latest_check_date") AND ("pc"."score" IS NOT NULL))), 2) AS "average_score",
        CASE
            WHEN ("count"("pc"."check_id") FILTER (WHERE ("pc"."check_date" = "lcd"."latest_check_date")) = 0) THEN NULL::numeric
            ELSE "round"(((100.0 * ("count"("pc"."check_id") FILTER (WHERE (("pc"."check_date" = "lcd"."latest_check_date") AND ("pc"."submission_status" = 'submitted'::"text"))))::numeric) / ("count"("pc"."check_id") FILTER (WHERE ("pc"."check_date" = "lcd"."latest_check_date")))::numeric), 2)
        END AS "completion_rate"
   FROM (("public"."restaurants" "r"
     LEFT JOIN "latest_check_date" "lcd" ON (("lcd"."store_id" = "r"."id")))
     LEFT JOIN "per_check" "pc" ON (("pc"."store_id" = "r"."id")))
  WHERE ("r"."store_type" = 'direct'::"text")
  GROUP BY "r"."id", "r"."brand_id", "r"."name", "lcd"."latest_check_date";


ALTER VIEW "public"."v_qsc_dashboard_summary" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_qsc_dashboard_summary" IS 'Store-level latest-day QSC snapshot for dashboard KPI cards and summary widgets.';



CREATE OR REPLACE VIEW "public"."v_office_qsc_dashboard" AS
 SELECT "store_id" AS "restaurant_id",
    "store_id",
    "brand_id",
    "store_name",
    "latest_check_date",
    "total_checks",
    "submitted_checks",
    "pending_checks",
    "overdue_checks",
    "failed_checks",
    "missing_photo_checks",
    "pending_sv_reviews",
    "open_followups",
    "average_score",
    "completion_rate",
        CASE
            WHEN ("latest_check_date" IS NULL) THEN 'no_data'::"text"
            WHEN ((COALESCE("overdue_checks", (0)::bigint) > 0) OR (COALESCE("failed_checks", (0)::bigint) > 0) OR (COALESCE("open_followups", (0)::bigint) > 0)) THEN 'risk'::"text"
            WHEN ((COALESCE("pending_checks", (0)::bigint) > 0) OR (COALESCE("missing_photo_checks", (0)::bigint) > 0) OR (COALESCE("pending_sv_reviews", (0)::bigint) > 0)) THEN 'caution'::"text"
            ELSE 'good'::"text"
        END AS "store_status"
   FROM "public"."v_qsc_dashboard_summary" "ds";


ALTER VIEW "public"."v_office_qsc_dashboard" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_office_qsc_dashboard" IS 'Office-facing wrapper over v_qsc_dashboard_summary with both restaurant_id and store_id aliases.';



CREATE OR REPLACE VIEW "public"."v_office_qsc_issue_queue" AS
 SELECT "check_id",
    "store_id" AS "restaurant_id",
    "store_id",
    "brand_id",
    "store_name",
    "category",
    "qsc_domain",
    "criteria_text",
    "check_date",
    "result",
    "photo_status",
    "submission_status",
    "sv_review_status",
    "followup_status",
        CASE
            WHEN (("submission_status" = 'overdue'::"text") OR (("result" = 'fail'::"text") AND ("photo_status" = 'missing'::"text"))) THEN 'critical'::"text"
            WHEN (("result" = 'fail'::"text") OR ("sv_review_status" = 'rejected'::"text")) THEN 'high'::"text"
            WHEN (("sv_review_status" = 'pending'::"text") OR ("photo_status" = ANY (ARRAY['missing'::"text", 'partial'::"text"]))) THEN 'medium'::"text"
            WHEN (("submission_status" = 'pending'::"text") OR ("followup_status" = ANY (ARRAY['open'::"text", 'in_progress'::"text"]))) THEN 'low'::"text"
            ELSE 'info'::"text"
        END AS "severity",
    "evidence_photo_url",
    "note",
    "checked_by",
    "created_at",
    "submitted_at",
    "score",
    "grade"
   FROM "public"."v_quality_monitoring" "vm"
  WHERE (("submission_status" = ANY (ARRAY['pending'::"text", 'overdue'::"text"])) OR ("result" = 'fail'::"text") OR ("photo_status" = ANY (ARRAY['missing'::"text", 'partial'::"text"])) OR ("sv_review_status" = ANY (ARRAY['pending'::"text", 'rejected'::"text"])) OR ("followup_status" = ANY (ARRAY['open'::"text", 'in_progress'::"text"])));


ALTER VIEW "public"."v_office_qsc_issue_queue" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_office_qsc_issue_queue" IS 'Office-facing issue queue wrapper over v_quality_monitoring for evidence review and follow-up creation.';



CREATE OR REPLACE VIEW "public"."v_qsc_store_status" AS
 SELECT "store_id",
    "brand_id",
    "store_name",
    "check_date",
    "count"("check_id") AS "total_checks",
    "count"("check_id") FILTER (WHERE ("submission_status" = 'submitted'::"text")) AS "submitted_checks",
    "count"("check_id") FILTER (WHERE ("submission_status" = 'pending'::"text")) AS "pending_checks",
    "count"("check_id") FILTER (WHERE ("submission_status" = 'overdue'::"text")) AS "overdue_checks",
    "count"("check_id") FILTER (WHERE ("result" = 'pass'::"text")) AS "pass_checks",
    "count"("check_id") FILTER (WHERE ("result" = 'fail'::"text")) AS "fail_checks",
    "count"("check_id") FILTER (WHERE ("result" = 'na'::"text")) AS "na_checks",
    "count"("check_id") FILTER (WHERE ("photo_status" = 'missing'::"text")) AS "missing_photo_checks",
    "count"("check_id") FILTER (WHERE ("photo_status" = 'partial'::"text")) AS "partial_photo_checks",
    "count"("check_id") FILTER (WHERE ("sv_review_status" = 'pending'::"text")) AS "pending_sv_reviews",
    "count"("check_id") FILTER (WHERE ("followup_status" = ANY (ARRAY['open'::"text", 'in_progress'::"text"]))) AS "active_followups",
    "round"("avg"("score") FILTER (WHERE ("score" IS NOT NULL)), 2) AS "average_score",
    "round"("avg"("sv_score") FILTER (WHERE ("sv_score" IS NOT NULL)), 2) AS "average_sv_score",
        CASE
            WHEN ("count"("check_id") = 0) THEN NULL::numeric
            ELSE "round"(((100.0 * ("count"("check_id") FILTER (WHERE ("submission_status" = 'submitted'::"text")))::numeric) / ("count"("check_id"))::numeric), 2)
        END AS "completion_rate",
        CASE
            WHEN ("count"("check_id") = 0) THEN 'no_data'::"text"
            WHEN ("count"("check_id") FILTER (WHERE (("submission_status" = 'overdue'::"text") OR ("result" = 'fail'::"text"))) > 0) THEN 'risk'::"text"
            WHEN ("count"("check_id") FILTER (WHERE (("submission_status" = 'pending'::"text") OR ("photo_status" = ANY (ARRAY['missing'::"text", 'partial'::"text"])) OR ("sv_review_status" = 'pending'::"text"))) > 0) THEN 'caution'::"text"
            ELSE 'good'::"text"
        END AS "store_status"
   FROM "public"."v_quality_monitoring" "vm"
  GROUP BY "store_id", "brand_id", "store_name", "check_date";


ALTER VIEW "public"."v_qsc_store_status" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_qsc_store_status" IS 'Daily store-level QSC rollup for management tables, charts, and mobile summary.';



CREATE OR REPLACE VIEW "public"."v_office_qsc_store_latest" AS
 WITH "latest_dates" AS (
         SELECT "v_qsc_store_status"."store_id",
            "max"("v_qsc_store_status"."check_date") AS "latest_check_date"
           FROM "public"."v_qsc_store_status"
          GROUP BY "v_qsc_store_status"."store_id"
        )
 SELECT "ss"."store_id" AS "restaurant_id",
    "ss"."store_id",
    "ss"."brand_id",
    "ss"."store_name",
    "ss"."check_date",
    "ss"."total_checks",
    "ss"."submitted_checks",
    "ss"."pending_checks",
    "ss"."overdue_checks",
    "ss"."pass_checks",
    "ss"."fail_checks",
    "ss"."na_checks",
    "ss"."missing_photo_checks",
    "ss"."partial_photo_checks",
    "ss"."pending_sv_reviews",
    "ss"."active_followups",
    "ss"."average_score",
    "ss"."average_sv_score",
    "ss"."completion_rate",
    "ss"."store_status"
   FROM ("public"."v_qsc_store_status" "ss"
     JOIN "latest_dates" "ld" ON ((("ld"."store_id" = "ss"."store_id") AND ("ld"."latest_check_date" = "ss"."check_date"))));


ALTER VIEW "public"."v_office_qsc_store_latest" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_office_qsc_store_latest" IS 'Office-facing latest daily store rollup for QSC monitoring and problem-store lists.';



CREATE OR REPLACE VIEW "public"."v_photo_objet_daily_summary" WITH ("security_invoker"='true') AS
 SELECT "pos"."store_id",
    "r"."name" AS "store_name",
    "pos"."sale_date",
    "sum"("pos"."gross_sales") AS "total_gross_sales",
    "sum"("pos"."transaction_count") AS "total_transactions",
    "sum"("pos"."service_amount") AS "total_service_amount",
    "count"(DISTINCT "pos"."device_name") AS "active_machines",
    "max"("pos"."pulled_at") AS "last_pulled_at"
   FROM ("public"."photo_objet_sales" "pos"
     JOIN "public"."restaurants" "r" ON (("r"."id" = "pos"."store_id")))
  GROUP BY "pos"."store_id", "r"."name", "pos"."sale_date";


ALTER VIEW "public"."v_photo_objet_daily_summary" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_photo_objet_daily_summary" IS 'Photo Objet daily sales rollup joined to restaurants for POS Photo Ops workspace.';



CREATE OR REPLACE VIEW "public"."v_qsc_item_status" AS
 SELECT "store_id",
    "brand_id",
    "store_name",
    "check_date",
    "category",
    "qsc_domain",
    "criteria_text",
    "count"("check_id") AS "total_checks",
    "count"("check_id") FILTER (WHERE ("result" = 'pass'::"text")) AS "pass_checks",
    "count"("check_id") FILTER (WHERE ("result" = 'fail'::"text")) AS "fail_checks",
    "count"("check_id") FILTER (WHERE ("result" = 'na'::"text")) AS "na_checks",
    "count"("check_id") FILTER (WHERE ("photo_status" = 'missing'::"text")) AS "missing_photo_checks",
    "count"("check_id") FILTER (WHERE ("sv_review_status" = 'pending'::"text")) AS "pending_sv_reviews",
    "count"("check_id") FILTER (WHERE ("followup_status" = ANY (ARRAY['open'::"text", 'in_progress'::"text"]))) AS "active_followups",
    "round"("avg"("score") FILTER (WHERE ("score" IS NOT NULL)), 2) AS "average_score",
    "round"("avg"("sv_score") FILTER (WHERE ("sv_score" IS NOT NULL)), 2) AS "average_sv_score",
        CASE
            WHEN ("count"("check_id") = 0) THEN 'no_data'::"text"
            WHEN ("count"("check_id") FILTER (WHERE ("result" = 'fail'::"text")) > 0) THEN 'risk'::"text"
            WHEN ("count"("check_id") FILTER (WHERE (("photo_status" = ANY (ARRAY['missing'::"text", 'partial'::"text"])) OR ("sv_review_status" = 'pending'::"text"))) > 0) THEN 'caution'::"text"
            ELSE 'good'::"text"
        END AS "item_status"
   FROM "public"."v_quality_monitoring" "vm"
  GROUP BY "store_id", "brand_id", "store_name", "check_date", "category", "qsc_domain", "criteria_text";


ALTER VIEW "public"."v_qsc_item_status" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_qsc_item_status" IS 'Daily item-level QSC rollup for category analysis, item pages, and weak-point review.';



CREATE OR REPLACE VIEW "public"."v_settlement_summary" AS
 SELECT "id",
    "restaurant_id",
    "period_label",
    "period_start",
    "period_end",
    "gross_total",
    "total_deductions",
    "net_settlement",
    "status",
    "received_at",
    COALESCE(( SELECT "jsonb_agg"("jsonb_build_object"('item_type', "dsi"."item_type", 'amount', "dsi"."amount", 'description', "dsi"."description", 'reference_rate', "dsi"."reference_rate") ORDER BY "dsi"."item_type") AS "jsonb_agg"
           FROM "public"."delivery_settlement_items" "dsi"
          WHERE ("dsi"."settlement_id" = "ds"."id")), '[]'::"jsonb") AS "items",
    ( SELECT "count"(*) AS "count"
           FROM "public"."external_sales" "es"
          WHERE (("es"."settlement_id" = "ds"."id") AND ("es"."is_revenue" = true))) AS "order_count"
   FROM "public"."delivery_settlements" "ds";


ALTER VIEW "public"."v_settlement_summary" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_store_attendance_summary" AS
 SELECT "al"."restaurant_id" AS "store_id",
    "r"."brand_id",
    "al"."user_id",
    COALESCE("u"."full_name", "u"."role") AS "employee_name",
    "u"."role" AS "employee_role",
    "date"(("al"."logged_at" AT TIME ZONE 'Asia/Ho_Chi_Minh'::"text")) AS "work_date",
    "min"(
        CASE
            WHEN ("al"."type" = 'clock_in'::"text") THEN "al"."logged_at"
            ELSE NULL::timestamp with time zone
        END) AS "first_clock_in",
    "max"(
        CASE
            WHEN ("al"."type" = 'clock_out'::"text") THEN "al"."logged_at"
            ELSE NULL::timestamp with time zone
        END) AS "last_clock_out",
    "count"(
        CASE
            WHEN ("al"."type" = 'clock_in'::"text") THEN 1
            ELSE NULL::integer
        END) AS "clock_in_count",
    "count"(
        CASE
            WHEN ("al"."type" = 'clock_out'::"text") THEN 1
            ELSE NULL::integer
        END) AS "clock_out_count"
   FROM (("public"."attendance_logs" "al"
     JOIN "public"."stores" "r" ON (("r"."id" = "al"."restaurant_id")))
     JOIN "public"."users" "u" ON (("u"."id" = "al"."user_id")))
  WHERE ("r"."store_type" = 'direct'::"text")
  GROUP BY "al"."restaurant_id", "r"."brand_id", "al"."user_id", COALESCE("u"."full_name", "u"."role"), "u"."role", ("date"(("al"."logged_at" AT TIME ZONE 'Asia/Ho_Chi_Minh'::"text")));


ALTER VIEW "public"."v_store_attendance_summary" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_store_daily_sales" AS
 SELECT "r"."id" AS "store_id",
    "r"."brand_id",
    "b"."name" AS "brand_name",
    "r"."name" AS "store_name",
    "date"(("p"."created_at" AT TIME ZONE 'Asia/Ho_Chi_Minh'::"text")) AS "sale_date",
    "count"(DISTINCT "p"."order_id") AS "order_count",
    "sum"(
        CASE
            WHEN "p"."is_revenue" THEN "p"."amount"
            ELSE (0)::numeric
        END) AS "revenue",
    "sum"(
        CASE
            WHEN (NOT "p"."is_revenue") THEN "p"."amount"
            ELSE (0)::numeric
        END) AS "service_amount"
   FROM (("public"."payments" "p"
     JOIN "public"."stores" "r" ON (("r"."id" = "p"."restaurant_id")))
     LEFT JOIN "public"."brands" "b" ON (("b"."id" = "r"."brand_id")))
  WHERE ("r"."store_type" = 'direct'::"text")
  GROUP BY "r"."id", "r"."brand_id", "b"."name", "r"."name", ("date"(("p"."created_at" AT TIME ZONE 'Asia/Ho_Chi_Minh'::"text")));


ALTER VIEW "public"."v_store_daily_sales" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."wetax_reference_values" (
    "category" "text" NOT NULL,
    "code" "text" NOT NULL,
    "label" "text" NOT NULL,
    "extra_data" "jsonb",
    "fetched_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "wetax_reference_values_category_check" CHECK (("category" = ANY (ARRAY['payment-methods'::"text", 'tax-rates'::"text", 'currency'::"text"])))
);


ALTER TABLE "public"."wetax_reference_values" OWNER TO "postgres";


COMMENT ON TABLE "public"."wetax_reference_values" IS 'Cached WeTax commons reference data. Fetched at onboarding from commons/payment-methods, commons/tax-rates, commons/currency. Drives POS UI dropdowns. Refreshed weekly.';



COMMENT ON COLUMN "public"."wetax_reference_values"."category" IS 'Reference data category matching the WeTax commons/* endpoint path.';



COMMENT ON COLUMN "public"."wetax_reference_values"."code" IS 'Reference code value from WeTax.';



COMMENT ON COLUMN "public"."wetax_reference_values"."label" IS 'Human-readable display label (e.g. TM/CK for cash/transfer).';



COMMENT ON COLUMN "public"."wetax_reference_values"."extra_data" IS 'Additional fields from WeTax response for specific integration needs.';



COMMENT ON COLUMN "public"."wetax_reference_values"."fetched_at" IS 'Timestamp when this value was last fetched from WeTax.';



ALTER TABLE ONLY "public"."attendance_logs"
    ADD CONSTRAINT "attendance_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."b2b_buyer_cache"
    ADD CONSTRAINT "b2b_buyer_cache_pkey" PRIMARY KEY ("store_id", "buyer_tax_code");



ALTER TABLE ONLY "public"."brand_master"
    ADD CONSTRAINT "brand_master_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."brands"
    ADD CONSTRAINT "brands_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."brands"
    ADD CONSTRAINT "brands_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."companies"
    ADD CONSTRAINT "companies_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_closings"
    ADD CONSTRAINT "daily_closings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."delivery_settlement_items"
    ADD CONSTRAINT "delivery_settlement_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."delivery_settlements"
    ADD CONSTRAINT "delivery_settlements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."einvoice_events"
    ADD CONSTRAINT "einvoice_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."einvoice_jobs"
    ADD CONSTRAINT "einvoice_jobs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."einvoice_jobs"
    ADD CONSTRAINT "einvoice_jobs_ref_id_key" UNIQUE ("ref_id");



ALTER TABLE ONLY "public"."einvoice_shop"
    ADD CONSTRAINT "einvoice_shop_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."einvoice_shop"
    ADD CONSTRAINT "einvoice_shop_tax_entity_id_provider_shop_code_key" UNIQUE ("tax_entity_id", "provider_shop_code");



ALTER TABLE ONLY "public"."external_sales"
    ADD CONSTRAINT "external_sales_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fingerprint_templates"
    ADD CONSTRAINT "fingerprint_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fingerprint_templates"
    ADD CONSTRAINT "fingerprint_templates_user_id_finger_index_key" UNIQUE ("user_id", "finger_index");



ALTER TABLE ONLY "public"."inventory_daily_consumption"
    ADD CONSTRAINT "inventory_daily_consumption_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_daily_consumption"
    ADD CONSTRAINT "inventory_daily_consumption_restaurant_id_product_id_consum_key" UNIQUE ("restaurant_id", "product_id", "consumption_date", "source");



ALTER TABLE ONLY "public"."inventory_items"
    ADD CONSTRAINT "inventory_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_physical_counts"
    ADD CONSTRAINT "inventory_physical_counts_ingredient_id_count_date_key" UNIQUE ("ingredient_id", "count_date");



ALTER TABLE ONLY "public"."inventory_physical_counts"
    ADD CONSTRAINT "inventory_physical_counts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_products"
    ADD CONSTRAINT "inventory_products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_products"
    ADD CONSTRAINT "inventory_products_restaurant_id_product_code_key" UNIQUE ("restaurant_id", "product_code");



ALTER TABLE ONLY "public"."inventory_purchase_order_lines"
    ADD CONSTRAINT "inventory_purchase_order_lines_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_purchase_orders"
    ADD CONSTRAINT "inventory_purchase_orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_purchase_orders"
    ADD CONSTRAINT "inventory_purchase_orders_purchase_order_no_key" UNIQUE ("purchase_order_no");



ALTER TABLE ONLY "public"."inventory_receipt_lines"
    ADD CONSTRAINT "inventory_receipt_lines_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_receipts"
    ADD CONSTRAINT "inventory_receipts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_recommendation_lines"
    ADD CONSTRAINT "inventory_recommendation_lines_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_recommendation_runs"
    ADD CONSTRAINT "inventory_recommendation_runs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_stock_audit_lines"
    ADD CONSTRAINT "inventory_stock_audit_lines_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_stock_audit_sessions"
    ADD CONSTRAINT "inventory_stock_audit_sessions_audit_no_key" UNIQUE ("audit_no");



ALTER TABLE ONLY "public"."inventory_stock_audit_sessions"
    ADD CONSTRAINT "inventory_stock_audit_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_supplier_items"
    ADD CONSTRAINT "inventory_supplier_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_supplier_items"
    ADD CONSTRAINT "inventory_supplier_items_supplier_id_product_id_order_unit_key" UNIQUE ("supplier_id", "product_id", "order_unit");



ALTER TABLE ONLY "public"."inventory_suppliers"
    ADD CONSTRAINT "inventory_suppliers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory_transactions"
    ADD CONSTRAINT "inventory_transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."menu_categories"
    ADD CONSTRAINT "menu_categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."menu_items"
    ADD CONSTRAINT "menu_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."menu_recipes"
    ADD CONSTRAINT "menu_recipes_menu_item_id_ingredient_id_key" UNIQUE ("menu_item_id", "ingredient_id");



ALTER TABLE ONLY "public"."menu_recipes"
    ADD CONSTRAINT "menu_recipes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."office_payroll_reviews"
    ADD CONSTRAINT "office_payroll_reviews_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_items"
    ADD CONSTRAINT "order_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."partner_credential_access_log"
    ADD CONSTRAINT "partner_credential_access_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."partner_credentials"
    ADD CONSTRAINT "partner_credentials_data_source_key" UNIQUE ("data_source");



ALTER TABLE ONLY "public"."partner_credentials"
    ADD CONSTRAINT "partner_credentials_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payroll_records"
    ADD CONSTRAINT "payroll_records_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."photo_objet_sales"
    ADD CONSTRAINT "photo_objet_sales_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."photo_objet_sales"
    ADD CONSTRAINT "photo_objet_sales_store_id_sale_date_device_name_key" UNIQUE ("store_id", "sale_date", "device_name");



ALTER TABLE ONLY "public"."qc_check_photos"
    ADD CONSTRAINT "qc_check_photos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."qc_check_photos"
    ADD CONSTRAINT "qc_check_photos_unique_storage_per_check" UNIQUE ("check_id", "storage_path");



ALTER TABLE ONLY "public"."qc_checks"
    ADD CONSTRAINT "qc_checks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."qc_checks"
    ADD CONSTRAINT "qc_checks_restaurant_template_check_date_key" UNIQUE ("restaurant_id", "template_id", "check_date");



COMMENT ON CONSTRAINT "qc_checks_restaurant_template_check_date_key" ON "public"."qc_checks" IS 'Ensures one QC/QSC result per store, template, and date while allowing global templates to be reused across stores.';



ALTER TABLE ONLY "public"."qc_followups"
    ADD CONSTRAINT "qc_followups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."qc_followups"
    ADD CONSTRAINT "qc_followups_source_check_id_key" UNIQUE ("source_check_id");



ALTER TABLE ONLY "public"."qc_templates"
    ADD CONSTRAINT "qc_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."restaurant_settings"
    ADD CONSTRAINT "restaurant_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."restaurant_settings"
    ADD CONSTRAINT "restaurant_settings_restaurant_id_key" UNIQUE ("restaurant_id");



ALTER TABLE ONLY "public"."restaurants"
    ADD CONSTRAINT "restaurants_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."restaurants"
    ADD CONSTRAINT "restaurants_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."staff_wage_configs"
    ADD CONSTRAINT "staff_wage_configs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."staff_wage_configs"
    ADD CONSTRAINT "staff_wage_configs_user_id_effective_from_key" UNIQUE ("user_id", "effective_from");



ALTER TABLE ONLY "public"."store_tax_entity_history"
    ADD CONSTRAINT "store_tax_entity_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."system_config"
    ADD CONSTRAINT "system_config_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."tables"
    ADD CONSTRAINT "tables_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tables"
    ADD CONSTRAINT "tables_restaurant_id_table_number_key" UNIQUE ("restaurant_id", "table_number");



ALTER TABLE ONLY "public"."tax_entity"
    ADD CONSTRAINT "tax_entity_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tax_entity"
    ADD CONSTRAINT "tax_entity_tax_code_key" UNIQUE ("tax_code");



ALTER TABLE ONLY "public"."office_payroll_reviews"
    ADD CONSTRAINT "uniq_office_payroll_review" UNIQUE ("source_payroll_id", "period_start", "period_end");



ALTER TABLE ONLY "public"."daily_closings"
    ADD CONSTRAINT "unique_daily_closing" UNIQUE ("restaurant_id", "closing_date");



ALTER TABLE ONLY "public"."external_sales"
    ADD CONSTRAINT "unique_external_order" UNIQUE ("source_system", "external_order_id");



ALTER TABLE ONLY "public"."delivery_settlements"
    ADD CONSTRAINT "unique_settlement_period" UNIQUE ("restaurant_id", "source_system", "period_label");



ALTER TABLE ONLY "public"."user_brand_access"
    ADD CONSTRAINT "user_brand_access_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_brand_access"
    ADD CONSTRAINT "user_brand_access_unique" UNIQUE ("user_id", "brand_id");



ALTER TABLE ONLY "public"."user_store_access"
    ADD CONSTRAINT "user_store_access_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_store_access"
    ADD CONSTRAINT "user_store_access_unique" UNIQUE ("user_id", "store_id", "source_type");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_auth_id_key" UNIQUE ("auth_id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."wetax_reference_values"
    ADD CONSTRAINT "wetax_reference_values_pkey" PRIMARY KEY ("category", "code");



CREATE INDEX "idx_attendance_user" ON "public"."attendance_logs" USING "btree" ("user_id");



CREATE INDEX "idx_audit_logs_created_at" ON "public"."audit_logs" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_audit_logs_entity" ON "public"."audit_logs" USING "btree" ("entity_type", "entity_id");



CREATE INDEX "idx_brands_company_id" ON "public"."brands" USING "btree" ("company_id");



CREATE INDEX "idx_daily_closings_restaurant_date" ON "public"."daily_closings" USING "btree" ("restaurant_id", "closing_date" DESC);



CREATE INDEX "idx_external_sales_restaurant" ON "public"."external_sales" USING "btree" ("restaurant_id", "completed_at");



CREATE INDEX "idx_external_sales_settlement" ON "public"."external_sales" USING "btree" ("settlement_id");



CREATE INDEX "idx_fingerprint_templates_restaurant" ON "public"."fingerprint_templates" USING "btree" ("restaurant_id");



CREATE INDEX "idx_fingerprint_templates_user" ON "public"."fingerprint_templates" USING "btree" ("user_id");



CREATE INDEX "idx_inventory_audit_sessions_store_status" ON "public"."inventory_stock_audit_sessions" USING "btree" ("restaurant_id", "status");



CREATE INDEX "idx_inventory_daily_consumption_product_date" ON "public"."inventory_daily_consumption" USING "btree" ("product_id", "consumption_date");



CREATE INDEX "idx_inventory_daily_consumption_store_date" ON "public"."inventory_daily_consumption" USING "btree" ("restaurant_id", "consumption_date");



CREATE UNIQUE INDEX "idx_inventory_items_restaurant_name_ci" ON "public"."inventory_items" USING "btree" ("restaurant_id", "lower"("btrim"("name")));



CREATE INDEX "idx_inventory_po_brand_status" ON "public"."inventory_purchase_orders" USING "btree" ("brand_id", "status");



CREATE INDEX "idx_inventory_po_lines_order" ON "public"."inventory_purchase_order_lines" USING "btree" ("purchase_order_id");



CREATE INDEX "idx_inventory_po_store_status" ON "public"."inventory_purchase_orders" USING "btree" ("restaurant_id", "status");



CREATE INDEX "idx_inventory_po_supplier" ON "public"."inventory_purchase_orders" USING "btree" ("supplier_id");



CREATE INDEX "idx_inventory_products_brand" ON "public"."inventory_products" USING "btree" ("brand_id");



CREATE INDEX "idx_inventory_products_store" ON "public"."inventory_products" USING "btree" ("restaurant_id");



CREATE INDEX "idx_inventory_receipts_order" ON "public"."inventory_receipts" USING "btree" ("purchase_order_id");



CREATE INDEX "idx_inventory_reco_runs_store_date" ON "public"."inventory_recommendation_runs" USING "btree" ("restaurant_id", "run_date");



CREATE INDEX "idx_inventory_supplier_items_product" ON "public"."inventory_supplier_items" USING "btree" ("product_id");



CREATE INDEX "idx_inventory_supplier_items_supplier" ON "public"."inventory_supplier_items" USING "btree" ("supplier_id");



CREATE INDEX "idx_inventory_suppliers_brand" ON "public"."inventory_suppliers" USING "btree" ("brand_id");



CREATE INDEX "idx_menu_items_category" ON "public"."menu_items" USING "btree" ("category_id");



CREATE INDEX "idx_menu_items_restaurant" ON "public"."menu_items" USING "btree" ("restaurant_id");



CREATE INDEX "idx_office_payroll_reviews_brand" ON "public"."office_payroll_reviews" USING "btree" ("brand_id");



CREATE INDEX "idx_office_payroll_reviews_restaurant" ON "public"."office_payroll_reviews" USING "btree" ("restaurant_id");



CREATE INDEX "idx_office_payroll_reviews_status" ON "public"."office_payroll_reviews" USING "btree" ("status");



CREATE INDEX "idx_order_items_order" ON "public"."order_items" USING "btree" ("order_id");



CREATE INDEX "idx_orders_restaurant" ON "public"."orders" USING "btree" ("restaurant_id");



CREATE INDEX "idx_orders_status" ON "public"."orders" USING "btree" ("restaurant_id", "status");



CREATE INDEX "idx_orders_table" ON "public"."orders" USING "btree" ("table_id");



CREATE INDEX "idx_payments_order" ON "public"."payments" USING "btree" ("order_id");



CREATE INDEX "idx_payments_restaurant" ON "public"."payments" USING "btree" ("restaurant_id");



CREATE INDEX "idx_photo_objet_sales_store_date" ON "public"."photo_objet_sales" USING "btree" ("store_id", "sale_date" DESC);



CREATE INDEX "idx_qc_check_photos_check_uploaded_at" ON "public"."qc_check_photos" USING "btree" ("check_id", "uploaded_at" DESC);



CREATE UNIQUE INDEX "idx_qc_check_photos_primary_per_check" ON "public"."qc_check_photos" USING "btree" ("check_id") WHERE ("is_primary" = true);



CREATE INDEX "idx_qc_check_photos_restaurant_check" ON "public"."qc_check_photos" USING "btree" ("restaurant_id", "check_id");



CREATE INDEX "idx_qc_check_photos_template_uploaded_at" ON "public"."qc_check_photos" USING "btree" ("template_id", "uploaded_at" DESC);



CREATE INDEX "idx_restaurants_brand_id" ON "public"."restaurants" USING "btree" ("brand_id");



CREATE INDEX "idx_restaurants_brand_store_type" ON "public"."restaurants" USING "btree" ("brand_id", "store_type");



CREATE INDEX "idx_restaurants_store_type" ON "public"."restaurants" USING "btree" ("store_type");



CREATE INDEX "idx_settlement_items_settlement" ON "public"."delivery_settlement_items" USING "btree" ("settlement_id");



CREATE INDEX "idx_settlement_items_type" ON "public"."delivery_settlement_items" USING "btree" ("item_type");



CREATE INDEX "idx_tables_restaurant" ON "public"."tables" USING "btree" ("restaurant_id");



CREATE INDEX "idx_user_brand_access_brand_active" ON "public"."user_brand_access" USING "btree" ("brand_id", "is_active");



CREATE INDEX "idx_user_brand_access_user_active" ON "public"."user_brand_access" USING "btree" ("user_id", "is_active");



CREATE INDEX "idx_user_store_access_source_brand_access_id" ON "public"."user_store_access" USING "btree" ("source_brand_access_id");



CREATE INDEX "idx_user_store_access_store_active" ON "public"."user_store_access" USING "btree" ("store_id", "is_active");



CREATE INDEX "idx_user_store_access_user_active" ON "public"."user_store_access" USING "btree" ("user_id", "is_active");



CREATE INDEX "idx_users_auth_id" ON "public"."users" USING "btree" ("auth_id");



CREATE INDEX "idx_users_brand_id" ON "public"."users" USING "btree" ("brand_id");



CREATE INDEX "idx_users_primary_store_id" ON "public"."users" USING "btree" ("primary_store_id");



CREATE INDEX "idx_users_restaurant" ON "public"."users" USING "btree" ("restaurant_id");



CREATE OR REPLACE TRIGGER "trg_payroll_store_submitted" AFTER UPDATE OF "status" ON "public"."payroll_records" FOR EACH ROW WHEN ((("new"."status" = 'store_submitted'::"text") AND ("old"."status" = 'draft'::"text"))) EXECUTE FUNCTION "public"."on_payroll_store_submitted"();



ALTER TABLE ONLY "public"."attendance_logs"
    ADD CONSTRAINT "attendance_logs_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."attendance_logs"
    ADD CONSTRAINT "attendance_logs_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."b2b_buyer_cache"
    ADD CONSTRAINT "b2b_buyer_cache_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."restaurants"("id");



ALTER TABLE ONLY "public"."b2b_buyer_cache"
    ADD CONSTRAINT "b2b_buyer_cache_tax_entity_id_fkey" FOREIGN KEY ("tax_entity_id") REFERENCES "public"."tax_entity"("id");



ALTER TABLE ONLY "public"."brand_master"
    ADD CONSTRAINT "brand_master_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."brands"
    ADD CONSTRAINT "brands_brand_master_id_fkey" FOREIGN KEY ("brand_master_id") REFERENCES "public"."brand_master"("id");



ALTER TABLE ONLY "public"."brands"
    ADD CONSTRAINT "brands_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."brands"
    ADD CONSTRAINT "brands_suggested_tax_entity_id_fkey" FOREIGN KEY ("suggested_tax_entity_id") REFERENCES "public"."tax_entity"("id");



ALTER TABLE ONLY "public"."daily_closings"
    ADD CONSTRAINT "daily_closings_closed_by_fkey" FOREIGN KEY ("closed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."daily_closings"
    ADD CONSTRAINT "daily_closings_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."delivery_settlement_items"
    ADD CONSTRAINT "delivery_settlement_items_settlement_id_fkey" FOREIGN KEY ("settlement_id") REFERENCES "public"."delivery_settlements"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."delivery_settlements"
    ADD CONSTRAINT "delivery_settlements_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."einvoice_events"
    ADD CONSTRAINT "einvoice_events_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."einvoice_jobs"("id");



ALTER TABLE ONLY "public"."einvoice_jobs"
    ADD CONSTRAINT "einvoice_jobs_einvoice_shop_id_fkey" FOREIGN KEY ("einvoice_shop_id") REFERENCES "public"."einvoice_shop"("id");



ALTER TABLE ONLY "public"."einvoice_jobs"
    ADD CONSTRAINT "einvoice_jobs_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."einvoice_jobs"
    ADD CONSTRAINT "einvoice_jobs_tax_entity_id_fkey" FOREIGN KEY ("tax_entity_id") REFERENCES "public"."tax_entity"("id");



ALTER TABLE ONLY "public"."einvoice_shop"
    ADD CONSTRAINT "einvoice_shop_tax_entity_id_fkey" FOREIGN KEY ("tax_entity_id") REFERENCES "public"."tax_entity"("id");



ALTER TABLE ONLY "public"."external_sales"
    ADD CONSTRAINT "external_sales_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fingerprint_templates"
    ADD CONSTRAINT "fingerprint_templates_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fingerprint_templates"
    ADD CONSTRAINT "fingerprint_templates_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."external_sales"
    ADD CONSTRAINT "fk_external_sales_settlement" FOREIGN KEY ("settlement_id") REFERENCES "public"."delivery_settlements"("id");



ALTER TABLE ONLY "public"."inventory_daily_consumption"
    ADD CONSTRAINT "inventory_daily_consumption_brand_id_fkey" FOREIGN KEY ("brand_id") REFERENCES "public"."brands"("id");



ALTER TABLE ONLY "public"."inventory_daily_consumption"
    ADD CONSTRAINT "inventory_daily_consumption_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."inventory_products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_daily_consumption"
    ADD CONSTRAINT "inventory_daily_consumption_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_items"
    ADD CONSTRAINT "inventory_items_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_physical_counts"
    ADD CONSTRAINT "inventory_physical_counts_counted_by_fkey" FOREIGN KEY ("counted_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."inventory_physical_counts"
    ADD CONSTRAINT "inventory_physical_counts_ingredient_id_fkey" FOREIGN KEY ("ingredient_id") REFERENCES "public"."inventory_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_physical_counts"
    ADD CONSTRAINT "inventory_physical_counts_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_products"
    ADD CONSTRAINT "inventory_products_brand_id_fkey" FOREIGN KEY ("brand_id") REFERENCES "public"."brands"("id");



ALTER TABLE ONLY "public"."inventory_products"
    ADD CONSTRAINT "inventory_products_inventory_item_id_fkey" FOREIGN KEY ("inventory_item_id") REFERENCES "public"."inventory_items"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."inventory_products"
    ADD CONSTRAINT "inventory_products_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_purchase_order_lines"
    ADD CONSTRAINT "inventory_purchase_order_lines_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."inventory_products"("id");



ALTER TABLE ONLY "public"."inventory_purchase_order_lines"
    ADD CONSTRAINT "inventory_purchase_order_lines_purchase_order_id_fkey" FOREIGN KEY ("purchase_order_id") REFERENCES "public"."inventory_purchase_orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_purchase_order_lines"
    ADD CONSTRAINT "inventory_purchase_order_lines_supplier_item_id_fkey" FOREIGN KEY ("supplier_item_id") REFERENCES "public"."inventory_supplier_items"("id");



ALTER TABLE ONLY "public"."inventory_purchase_orders"
    ADD CONSTRAINT "inventory_purchase_orders_brand_id_fkey" FOREIGN KEY ("brand_id") REFERENCES "public"."brands"("id");



ALTER TABLE ONLY "public"."inventory_purchase_orders"
    ADD CONSTRAINT "inventory_purchase_orders_office_reviewed_by_fkey" FOREIGN KEY ("office_reviewed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."inventory_purchase_orders"
    ADD CONSTRAINT "inventory_purchase_orders_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_purchase_orders"
    ADD CONSTRAINT "inventory_purchase_orders_submitted_by_fkey" FOREIGN KEY ("submitted_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."inventory_purchase_orders"
    ADD CONSTRAINT "inventory_purchase_orders_supplier_id_fkey" FOREIGN KEY ("supplier_id") REFERENCES "public"."inventory_suppliers"("id");



ALTER TABLE ONLY "public"."inventory_receipt_lines"
    ADD CONSTRAINT "inventory_receipt_lines_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."inventory_products"("id");



ALTER TABLE ONLY "public"."inventory_receipt_lines"
    ADD CONSTRAINT "inventory_receipt_lines_purchase_order_line_id_fkey" FOREIGN KEY ("purchase_order_line_id") REFERENCES "public"."inventory_purchase_order_lines"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."inventory_receipt_lines"
    ADD CONSTRAINT "inventory_receipt_lines_receipt_id_fkey" FOREIGN KEY ("receipt_id") REFERENCES "public"."inventory_receipts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_receipts"
    ADD CONSTRAINT "inventory_receipts_purchase_order_id_fkey" FOREIGN KEY ("purchase_order_id") REFERENCES "public"."inventory_purchase_orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_receipts"
    ADD CONSTRAINT "inventory_receipts_received_by_fkey" FOREIGN KEY ("received_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."inventory_receipts"
    ADD CONSTRAINT "inventory_receipts_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_receipts"
    ADD CONSTRAINT "inventory_receipts_supplier_id_fkey" FOREIGN KEY ("supplier_id") REFERENCES "public"."inventory_suppliers"("id");



ALTER TABLE ONLY "public"."inventory_recommendation_lines"
    ADD CONSTRAINT "inventory_recommendation_lines_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."inventory_products"("id");



ALTER TABLE ONLY "public"."inventory_recommendation_lines"
    ADD CONSTRAINT "inventory_recommendation_lines_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "public"."inventory_recommendation_runs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_recommendation_lines"
    ADD CONSTRAINT "inventory_recommendation_lines_supplier_id_fkey" FOREIGN KEY ("supplier_id") REFERENCES "public"."inventory_suppliers"("id");



ALTER TABLE ONLY "public"."inventory_recommendation_runs"
    ADD CONSTRAINT "inventory_recommendation_runs_brand_id_fkey" FOREIGN KEY ("brand_id") REFERENCES "public"."brands"("id");



ALTER TABLE ONLY "public"."inventory_recommendation_runs"
    ADD CONSTRAINT "inventory_recommendation_runs_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."inventory_recommendation_runs"
    ADD CONSTRAINT "inventory_recommendation_runs_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_stock_audit_lines"
    ADD CONSTRAINT "inventory_stock_audit_lines_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."inventory_products"("id");



ALTER TABLE ONLY "public"."inventory_stock_audit_lines"
    ADD CONSTRAINT "inventory_stock_audit_lines_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."inventory_stock_audit_sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_stock_audit_sessions"
    ADD CONSTRAINT "inventory_stock_audit_sessions_assigned_to_fkey" FOREIGN KEY ("assigned_to") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."inventory_stock_audit_sessions"
    ADD CONSTRAINT "inventory_stock_audit_sessions_brand_id_fkey" FOREIGN KEY ("brand_id") REFERENCES "public"."brands"("id");



ALTER TABLE ONLY "public"."inventory_stock_audit_sessions"
    ADD CONSTRAINT "inventory_stock_audit_sessions_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."inventory_stock_audit_sessions"
    ADD CONSTRAINT "inventory_stock_audit_sessions_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_supplier_items"
    ADD CONSTRAINT "inventory_supplier_items_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."inventory_products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_supplier_items"
    ADD CONSTRAINT "inventory_supplier_items_supplier_id_fkey" FOREIGN KEY ("supplier_id") REFERENCES "public"."inventory_suppliers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_suppliers"
    ADD CONSTRAINT "inventory_suppliers_brand_id_fkey" FOREIGN KEY ("brand_id") REFERENCES "public"."brands"("id");



ALTER TABLE ONLY "public"."inventory_transactions"
    ADD CONSTRAINT "inventory_transactions_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."inventory_transactions"
    ADD CONSTRAINT "inventory_transactions_ingredient_id_fkey" FOREIGN KEY ("ingredient_id") REFERENCES "public"."inventory_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inventory_transactions"
    ADD CONSTRAINT "inventory_transactions_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."menu_categories"
    ADD CONSTRAINT "menu_categories_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."menu_items"
    ADD CONSTRAINT "menu_items_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."menu_categories"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."menu_items"
    ADD CONSTRAINT "menu_items_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."menu_recipes"
    ADD CONSTRAINT "menu_recipes_ingredient_id_fkey" FOREIGN KEY ("ingredient_id") REFERENCES "public"."inventory_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."menu_recipes"
    ADD CONSTRAINT "menu_recipes_menu_item_id_fkey" FOREIGN KEY ("menu_item_id") REFERENCES "public"."menu_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."menu_recipes"
    ADD CONSTRAINT "menu_recipes_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."office_payroll_reviews"
    ADD CONSTRAINT "office_payroll_reviews_brand_id_fkey" FOREIGN KEY ("brand_id") REFERENCES "public"."brands"("id");



ALTER TABLE ONLY "public"."office_payroll_reviews"
    ADD CONSTRAINT "office_payroll_reviews_confirmed_by_fkey" FOREIGN KEY ("confirmed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."office_payroll_reviews"
    ADD CONSTRAINT "office_payroll_reviews_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id");



ALTER TABLE ONLY "public"."office_payroll_reviews"
    ADD CONSTRAINT "office_payroll_reviews_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."office_payroll_reviews"
    ADD CONSTRAINT "office_payroll_reviews_source_payroll_id_fkey" FOREIGN KEY ("source_payroll_id") REFERENCES "public"."payroll_records"("id");



ALTER TABLE ONLY "public"."order_items"
    ADD CONSTRAINT "order_items_menu_item_id_fkey" FOREIGN KEY ("menu_item_id") REFERENCES "public"."menu_items"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."order_items"
    ADD CONSTRAINT "order_items_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."order_items"
    ADD CONSTRAINT "order_items_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_table_id_fkey" FOREIGN KEY ("table_id") REFERENCES "public"."tables"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."partner_credential_access_log"
    ADD CONSTRAINT "partner_credential_access_log_credential_id_fkey" FOREIGN KEY ("credential_id") REFERENCES "public"."partner_credentials"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_processed_by_fkey" FOREIGN KEY ("processed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_proof_photo_by_fkey" FOREIGN KEY ("proof_photo_by") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payroll_records"
    ADD CONSTRAINT "payroll_records_confirmed_by_fkey" FOREIGN KEY ("confirmed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."payroll_records"
    ADD CONSTRAINT "payroll_records_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payroll_records"
    ADD CONSTRAINT "payroll_records_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."photo_objet_sales"
    ADD CONSTRAINT "photo_objet_sales_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."qc_check_photos"
    ADD CONSTRAINT "qc_check_photos_check_id_fkey" FOREIGN KEY ("check_id") REFERENCES "public"."qc_checks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."qc_check_photos"
    ADD CONSTRAINT "qc_check_photos_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."qc_check_photos"
    ADD CONSTRAINT "qc_check_photos_template_id_fkey" FOREIGN KEY ("template_id") REFERENCES "public"."qc_templates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."qc_check_photos"
    ADD CONSTRAINT "qc_check_photos_uploaded_by_fkey" FOREIGN KEY ("uploaded_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."qc_checks"
    ADD CONSTRAINT "qc_checks_checked_by_fkey" FOREIGN KEY ("checked_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."qc_checks"
    ADD CONSTRAINT "qc_checks_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."qc_checks"
    ADD CONSTRAINT "qc_checks_sv_reviewed_by_fkey" FOREIGN KEY ("sv_reviewed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."qc_checks"
    ADD CONSTRAINT "qc_checks_template_id_fkey" FOREIGN KEY ("template_id") REFERENCES "public"."qc_templates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."qc_followups"
    ADD CONSTRAINT "qc_followups_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."qc_followups"
    ADD CONSTRAINT "qc_followups_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."qc_followups"
    ADD CONSTRAINT "qc_followups_source_check_id_fkey" FOREIGN KEY ("source_check_id") REFERENCES "public"."qc_checks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."qc_templates"
    ADD CONSTRAINT "qc_templates_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."restaurant_settings"
    ADD CONSTRAINT "restaurant_settings_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."restaurants"
    ADD CONSTRAINT "restaurants_brand_id_fkey" FOREIGN KEY ("brand_id") REFERENCES "public"."brands"("id");



ALTER TABLE ONLY "public"."restaurants"
    ADD CONSTRAINT "restaurants_tax_entity_id_fkey" FOREIGN KEY ("tax_entity_id") REFERENCES "public"."tax_entity"("id");



ALTER TABLE ONLY "public"."staff_wage_configs"
    ADD CONSTRAINT "staff_wage_configs_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."staff_wage_configs"
    ADD CONSTRAINT "staff_wage_configs_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."store_tax_entity_history"
    ADD CONSTRAINT "store_tax_entity_history_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."store_tax_entity_history"
    ADD CONSTRAINT "store_tax_entity_history_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."restaurants"("id");



ALTER TABLE ONLY "public"."store_tax_entity_history"
    ADD CONSTRAINT "store_tax_entity_history_tax_entity_id_fkey" FOREIGN KEY ("tax_entity_id") REFERENCES "public"."tax_entity"("id");



ALTER TABLE ONLY "public"."system_config"
    ADD CONSTRAINT "system_config_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."tables"
    ADD CONSTRAINT "tables_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_brand_access"
    ADD CONSTRAINT "user_brand_access_brand_id_fkey" FOREIGN KEY ("brand_id") REFERENCES "public"."brands"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_brand_access"
    ADD CONSTRAINT "user_brand_access_granted_by_fkey" FOREIGN KEY ("granted_by") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_brand_access"
    ADD CONSTRAINT "user_brand_access_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_store_access"
    ADD CONSTRAINT "user_store_access_granted_by_fkey" FOREIGN KEY ("granted_by") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_store_access"
    ADD CONSTRAINT "user_store_access_source_brand_access_id_fkey" FOREIGN KEY ("source_brand_access_id") REFERENCES "public"."user_brand_access"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_store_access"
    ADD CONSTRAINT "user_store_access_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_store_access"
    ADD CONSTRAINT "user_store_access_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_auth_id_fkey" FOREIGN KEY ("auth_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_brand_id_fkey" FOREIGN KEY ("brand_id") REFERENCES "public"."brands"("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_primary_store_id_fkey" FOREIGN KEY ("primary_store_id") REFERENCES "public"."restaurants"("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_restaurant_id_fkey" FOREIGN KEY ("restaurant_id") REFERENCES "public"."restaurants"("id") ON DELETE CASCADE;



CREATE POLICY "admin_only" ON "public"."restaurant_settings" USING ((("restaurant_id" = "public"."get_user_store_id"()) AND "public"."has_any_role"(ARRAY['admin'::"text", 'super_admin'::"text"]))) WITH CHECK ((("restaurant_id" = "public"."get_user_store_id"()) AND "public"."has_any_role"(ARRAY['admin'::"text", 'super_admin'::"text"])));



ALTER TABLE "public"."attendance_logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "attendance_logs_policy" ON "public"."attendance_logs" TO "authenticated" USING (("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"()))) WITH CHECK (("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"())));



ALTER TABLE "public"."audit_logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "audit_logs_admin_read" ON "public"."audit_logs" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."auth_id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "audit_logs_authenticated_select" ON "public"."audit_logs" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."b2b_buyer_cache" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "b2b_buyer_cache_admin_delete" ON "public"."b2b_buyer_cache" FOR DELETE USING (("public"."is_super_admin"() OR ("public"."has_any_role"(ARRAY['admin'::"text", 'store_admin'::"text", 'brand_admin'::"text"]) AND ("store_id" = "public"."get_user_store_id"()))));



CREATE POLICY "b2b_buyer_cache_store_insert" ON "public"."b2b_buyer_cache" FOR INSERT WITH CHECK (("public"."is_super_admin"() OR ("public"."has_any_role"(ARRAY['cashier'::"text", 'admin'::"text", 'store_admin'::"text", 'brand_admin'::"text"]) AND ("store_id" = "public"."get_user_store_id"()))));



CREATE POLICY "b2b_buyer_cache_store_select" ON "public"."b2b_buyer_cache" FOR SELECT USING (("public"."is_super_admin"() OR ("public"."has_any_role"(ARRAY['cashier'::"text", 'admin'::"text", 'store_admin'::"text", 'brand_admin'::"text"]) AND (("store_id" = "public"."get_user_store_id"()) OR ("tax_entity_id" = "public"."get_user_tax_entity_id"())))));



CREATE POLICY "b2b_buyer_cache_store_update" ON "public"."b2b_buyer_cache" FOR UPDATE USING (("public"."is_super_admin"() OR ("public"."has_any_role"(ARRAY['cashier'::"text", 'admin'::"text", 'store_admin'::"text", 'brand_admin'::"text"]) AND ("store_id" = "public"."get_user_store_id"())))) WITH CHECK (("public"."is_super_admin"() OR ("public"."has_any_role"(ARRAY['cashier'::"text", 'admin'::"text", 'store_admin'::"text", 'brand_admin'::"text"]) AND ("store_id" = "public"."get_user_store_id"()))));



ALTER TABLE "public"."brand_master" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "brand_master_admin_read" ON "public"."brand_master" FOR SELECT USING (("public"."is_super_admin"() OR "public"."has_any_role"(ARRAY['admin'::"text", 'store_admin'::"text", 'brand_admin'::"text"])));



CREATE POLICY "brand_master_superadmin_write" ON "public"."brand_master" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



ALTER TABLE "public"."brands" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "brands_scoped_read" ON "public"."brands" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."auth_id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



ALTER TABLE "public"."companies" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "companies_scoped_read" ON "public"."companies" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."users" "u"
  WHERE (("u"."auth_id" = "auth"."uid"()) AND ("u"."role" = ANY (ARRAY['admin'::"text", 'super_admin'::"text"]))))));



CREATE POLICY "credential_log_superadmin_read" ON "public"."partner_credential_access_log" FOR SELECT USING ("public"."is_super_admin"());



ALTER TABLE "public"."daily_closings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."delivery_settlement_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."delivery_settlements" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "delivery_settlements_confirm" ON "public"."delivery_settlements" FOR UPDATE USING ((("restaurant_id" = "public"."get_user_store_id"()) AND "public"."has_any_role"(ARRAY['admin'::"text", 'super_admin'::"text"]))) WITH CHECK (("restaurant_id" = "public"."get_user_store_id"()));



CREATE POLICY "delivery_settlements_read" ON "public"."delivery_settlements" FOR SELECT USING (("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"())));



ALTER TABLE "public"."einvoice_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "einvoice_events_admin_read" ON "public"."einvoice_events" FOR SELECT USING (("public"."is_super_admin"() OR ("public"."has_any_role"(ARRAY['admin'::"text", 'store_admin'::"text", 'brand_admin'::"text"]) AND (("job_id" IS NULL) OR (EXISTS ( SELECT 1
   FROM "public"."einvoice_jobs" "ej"
  WHERE (("ej"."id" = "einvoice_events"."job_id") AND ((EXISTS ( SELECT 1
           FROM "public"."orders" "o"
          WHERE (("o"."id" = "ej"."order_id") AND ("o"."restaurant_id" = "public"."get_user_store_id"())))) OR ("ej"."tax_entity_id" = "public"."get_user_tax_entity_id"())))))))));



ALTER TABLE "public"."einvoice_jobs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "einvoice_jobs_admin_read" ON "public"."einvoice_jobs" FOR SELECT USING (("public"."is_super_admin"() OR ("public"."has_any_role"(ARRAY['admin'::"text", 'store_admin'::"text", 'brand_admin'::"text"]) AND ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "einvoice_jobs"."order_id") AND ("o"."restaurant_id" = "public"."get_user_store_id"())))) OR ("tax_entity_id" = "public"."get_user_tax_entity_id"())))));



ALTER TABLE "public"."einvoice_shop" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "einvoice_shop_admin_read" ON "public"."einvoice_shop" FOR SELECT USING (("public"."is_super_admin"() OR "public"."has_any_role"(ARRAY['admin'::"text", 'store_admin'::"text", 'brand_admin'::"text"])));



CREATE POLICY "einvoice_shop_superadmin_write" ON "public"."einvoice_shop" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



ALTER TABLE "public"."external_sales" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "external_sales_read" ON "public"."external_sales" FOR SELECT USING (("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"())));



ALTER TABLE "public"."fingerprint_templates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inventory_daily_consumption" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "inventory_daily_consumption_store_read" ON "public"."inventory_daily_consumption" FOR SELECT TO "authenticated" USING ("public"."can_access_inventory_purchase_store"("restaurant_id"));



ALTER TABLE "public"."inventory_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "inventory_items_policy" ON "public"."inventory_items" TO "authenticated" USING (("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"()))) WITH CHECK (("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"())));



ALTER TABLE "public"."inventory_physical_counts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inventory_products" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "inventory_products_store_read" ON "public"."inventory_products" FOR SELECT TO "authenticated" USING ("public"."can_access_inventory_purchase_store"("restaurant_id"));



ALTER TABLE "public"."inventory_purchase_order_lines" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "inventory_purchase_order_lines_store_read" ON "public"."inventory_purchase_order_lines" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."inventory_purchase_orders" "po"
  WHERE (("po"."id" = "inventory_purchase_order_lines"."purchase_order_id") AND "public"."can_access_inventory_purchase_store"("po"."restaurant_id")))));



ALTER TABLE "public"."inventory_purchase_orders" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "inventory_purchase_orders_store_read" ON "public"."inventory_purchase_orders" FOR SELECT TO "authenticated" USING ("public"."can_access_inventory_purchase_store"("restaurant_id"));



ALTER TABLE "public"."inventory_receipt_lines" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "inventory_receipt_lines_store_read" ON "public"."inventory_receipt_lines" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."inventory_receipts" "ir"
  WHERE (("ir"."id" = "inventory_receipt_lines"."receipt_id") AND "public"."can_access_inventory_purchase_store"("ir"."restaurant_id")))));



ALTER TABLE "public"."inventory_receipts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "inventory_receipts_store_read" ON "public"."inventory_receipts" FOR SELECT TO "authenticated" USING ("public"."can_access_inventory_purchase_store"("restaurant_id"));



ALTER TABLE "public"."inventory_recommendation_lines" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "inventory_recommendation_lines_store_read" ON "public"."inventory_recommendation_lines" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."inventory_recommendation_runs" "rr"
  WHERE (("rr"."id" = "inventory_recommendation_lines"."run_id") AND "public"."can_access_inventory_purchase_store"("rr"."restaurant_id")))));



ALTER TABLE "public"."inventory_recommendation_runs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "inventory_recommendation_runs_store_read" ON "public"."inventory_recommendation_runs" FOR SELECT TO "authenticated" USING ("public"."can_access_inventory_purchase_store"("restaurant_id"));



ALTER TABLE "public"."inventory_stock_audit_lines" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "inventory_stock_audit_lines_store_read" ON "public"."inventory_stock_audit_lines" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."inventory_stock_audit_sessions" "s"
  WHERE (("s"."id" = "inventory_stock_audit_lines"."session_id") AND "public"."can_access_inventory_purchase_store"("s"."restaurant_id")))));



ALTER TABLE "public"."inventory_stock_audit_sessions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "inventory_stock_audit_sessions_store_read" ON "public"."inventory_stock_audit_sessions" FOR SELECT TO "authenticated" USING ("public"."can_access_inventory_purchase_store"("restaurant_id"));



ALTER TABLE "public"."inventory_supplier_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "inventory_supplier_items_authenticated_read" ON "public"."inventory_supplier_items" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



ALTER TABLE "public"."inventory_suppliers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "inventory_suppliers_authenticated_read" ON "public"."inventory_suppliers" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



ALTER TABLE "public"."inventory_transactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."menu_categories" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "menu_categories_select_policy" ON "public"."menu_categories" FOR SELECT TO "authenticated" USING (("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"())));



ALTER TABLE "public"."menu_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "menu_items_select_policy" ON "public"."menu_items" FOR SELECT TO "authenticated" USING (("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"())));



ALTER TABLE "public"."menu_recipes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."office_payroll_reviews" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "office_payroll_reviews_pos_update" ON "public"."office_payroll_reviews" FOR UPDATE TO "authenticated" USING (("public"."has_any_role"(ARRAY['admin'::"text", 'super_admin'::"text"]) AND ("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"())))) WITH CHECK (("public"."has_any_role"(ARRAY['admin'::"text", 'super_admin'::"text"]) AND ("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"()))));



CREATE POLICY "office_payroll_reviews_scoped_select" ON "public"."office_payroll_reviews" FOR SELECT TO "authenticated" USING (("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"())));



ALTER TABLE "public"."order_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "order_items_policy" ON "public"."order_items" TO "authenticated" USING (("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"()))) WITH CHECK (("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"())));



ALTER TABLE "public"."orders" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "orders_policy" ON "public"."orders" TO "authenticated" USING (("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"()))) WITH CHECK (("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"())));



ALTER TABLE "public"."partner_credential_access_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."partner_credentials" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "payments_policy" ON "public"."payments" TO "authenticated" USING (("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"()))) WITH CHECK (("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"())));



ALTER TABLE "public"."payroll_records" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."photo_objet_sales" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "photo_objet_sales_select_scope" ON "public"."photo_objet_sales" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_accessible_stores"("auth"."uid"()) "s"("store_id")
  WHERE ("s"."store_id" = "photo_objet_sales"."store_id"))));



ALTER TABLE "public"."qc_check_photos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "qc_check_photos_access" ON "public"."qc_check_photos" TO "authenticated" USING (("public"."has_any_role"(ARRAY['super_admin'::"text"]) OR (EXISTS ( SELECT 1
   FROM "public"."user_accessible_stores"("auth"."uid"()) "s"("store_id")
  WHERE ("s"."store_id" = "qc_check_photos"."restaurant_id"))))) WITH CHECK (("public"."has_any_role"(ARRAY['super_admin'::"text"]) OR (EXISTS ( SELECT 1
   FROM "public"."user_accessible_stores"("auth"."uid"()) "s"("store_id")
  WHERE ("s"."store_id" = "qc_check_photos"."restaurant_id")))));



ALTER TABLE "public"."qc_checks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."qc_followups" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "qc_followups_restaurant_isolation" ON "public"."qc_followups" USING ((("restaurant_id" = "public"."get_user_store_id"()) OR "public"."has_any_role"(ARRAY['super_admin'::"text"])));



ALTER TABLE "public"."qc_templates" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "qc_templates_delete" ON "public"."qc_templates" FOR DELETE USING (("public"."has_any_role"(ARRAY['super_admin'::"text"]) OR ("public"."has_any_role"(ARRAY['admin'::"text"]) AND ("is_global" = false) AND ("restaurant_id" = "public"."get_user_store_id"()))));



CREATE POLICY "qc_templates_insert" ON "public"."qc_templates" FOR INSERT WITH CHECK (("public"."has_any_role"(ARRAY['super_admin'::"text"]) OR ("public"."has_any_role"(ARRAY['admin'::"text"]) AND ("is_global" = false) AND ("restaurant_id" = "public"."get_user_store_id"()))));



CREATE POLICY "qc_templates_select" ON "public"."qc_templates" FOR SELECT USING ((("is_global" = true) OR ("restaurant_id" = "public"."get_user_store_id"()) OR "public"."has_any_role"(ARRAY['super_admin'::"text"])));



CREATE POLICY "qc_templates_update" ON "public"."qc_templates" FOR UPDATE USING (("public"."has_any_role"(ARRAY['super_admin'::"text"]) OR ("public"."has_any_role"(ARRAY['admin'::"text"]) AND ("is_global" = false) AND ("restaurant_id" = "public"."get_user_store_id"()))));



CREATE POLICY "restaurant_isolation" ON "public"."inventory_physical_counts" USING ((("restaurant_id" = "public"."get_user_store_id"()) OR "public"."has_any_role"(ARRAY['super_admin'::"text"]))) WITH CHECK ((("restaurant_id" = "public"."get_user_store_id"()) OR "public"."has_any_role"(ARRAY['super_admin'::"text"])));



CREATE POLICY "restaurant_isolation" ON "public"."inventory_transactions" USING ((("restaurant_id" = "public"."get_user_store_id"()) OR "public"."has_any_role"(ARRAY['super_admin'::"text"]))) WITH CHECK ((("restaurant_id" = "public"."get_user_store_id"()) OR "public"."has_any_role"(ARRAY['super_admin'::"text"])));



CREATE POLICY "restaurant_isolation" ON "public"."menu_recipes" USING ((("restaurant_id" = "public"."get_user_store_id"()) OR "public"."has_any_role"(ARRAY['super_admin'::"text"]))) WITH CHECK ((("restaurant_id" = "public"."get_user_store_id"()) OR "public"."has_any_role"(ARRAY['super_admin'::"text"])));



CREATE POLICY "restaurant_isolation" ON "public"."payroll_records" USING ((("restaurant_id" = "public"."get_user_store_id"()) OR "public"."has_any_role"(ARRAY['super_admin'::"text"])));



CREATE POLICY "restaurant_isolation" ON "public"."qc_checks" USING ((("restaurant_id" = "public"."get_user_store_id"()) OR "public"."has_any_role"(ARRAY['super_admin'::"text"])));



CREATE POLICY "restaurant_isolation" ON "public"."staff_wage_configs" USING ((("restaurant_id" = "public"."get_user_store_id"()) OR "public"."has_any_role"(ARRAY['super_admin'::"text"])));



ALTER TABLE "public"."restaurant_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."restaurants" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "restaurants_select_policy" ON "public"."restaurants" FOR SELECT TO "authenticated" USING (("public"."is_super_admin"() OR ("id" = "public"."get_user_store_id"())));



CREATE POLICY "settlement_items_insert" ON "public"."delivery_settlement_items" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."delivery_settlements" "ds"
  WHERE (("ds"."id" = "delivery_settlement_items"."settlement_id") AND ("ds"."restaurant_id" = "public"."get_user_store_id"())))));



CREATE POLICY "settlement_items_read" ON "public"."delivery_settlement_items" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."delivery_settlements" "ds"
  WHERE (("ds"."id" = "delivery_settlement_items"."settlement_id") AND ("public"."is_super_admin"() OR ("ds"."restaurant_id" = "public"."get_user_store_id"()))))));



ALTER TABLE "public"."staff_wage_configs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."store_tax_entity_history" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "store_tax_history_admin_read" ON "public"."store_tax_entity_history" FOR SELECT USING (("public"."is_super_admin"() OR ("public"."has_any_role"(ARRAY['admin'::"text", 'store_admin'::"text", 'brand_admin'::"text"]) AND ("store_id" = "public"."get_user_store_id"()))));



CREATE POLICY "store_tax_history_superadmin_insert" ON "public"."store_tax_entity_history" FOR INSERT WITH CHECK ("public"."is_super_admin"());



CREATE POLICY "store_tax_history_superadmin_update" ON "public"."store_tax_entity_history" FOR UPDATE USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



ALTER TABLE "public"."system_config" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "system_config_admin_read" ON "public"."system_config" FOR SELECT USING (("public"."is_super_admin"() OR "public"."has_any_role"(ARRAY['admin'::"text", 'store_admin'::"text", 'brand_admin'::"text"])));



CREATE POLICY "system_config_superadmin_write" ON "public"."system_config" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



ALTER TABLE "public"."tables" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tables_select_policy" ON "public"."tables" FOR SELECT TO "authenticated" USING (("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"())));



ALTER TABLE "public"."tax_entity" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tax_entity_admin_read" ON "public"."tax_entity" FOR SELECT USING (("public"."is_super_admin"() OR "public"."has_any_role"(ARRAY['admin'::"text", 'store_admin'::"text", 'brand_admin'::"text"])));



CREATE POLICY "tax_entity_superadmin_write" ON "public"."tax_entity" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



ALTER TABLE "public"."user_brand_access" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_store_access" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "users_select_policy" ON "public"."users" FOR SELECT TO "authenticated" USING (("public"."is_super_admin"() OR ("restaurant_id" = "public"."get_user_store_id"())));



CREATE POLICY "wetax_ref_authenticated_read" ON "public"."wetax_reference_values" FOR SELECT USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "wetax_ref_superadmin_write" ON "public"."wetax_reference_values" USING ("public"."is_super_admin"()) WITH CHECK ("public"."is_super_admin"());



ALTER TABLE "public"."wetax_reference_values" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";
GRANT USAGE ON SCHEMA "public" TO "supabase_auth_admin";



GRANT ALL ON TABLE "public"."order_items" TO "anon";
GRANT ALL ON TABLE "public"."order_items" TO "authenticated";
GRANT ALL ON TABLE "public"."order_items" TO "service_role";



GRANT ALL ON FUNCTION "public"."add_items_to_order"("p_order_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."add_items_to_order"("p_order_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_items_to_order"("p_order_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb") TO "service_role";



GRANT ALL ON TABLE "public"."menu_categories" TO "anon";
GRANT ALL ON TABLE "public"."menu_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."menu_categories" TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_create_menu_category"("p_restaurant_id" "uuid", "p_name" "text", "p_sort_order" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."admin_create_menu_category"("p_restaurant_id" "uuid", "p_name" "text", "p_sort_order" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_create_menu_category"("p_restaurant_id" "uuid", "p_name" "text", "p_sort_order" integer) TO "service_role";



GRANT ALL ON TABLE "public"."menu_items" TO "anon";
GRANT ALL ON TABLE "public"."menu_items" TO "authenticated";
GRANT ALL ON TABLE "public"."menu_items" TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_create_menu_item"("p_restaurant_id" "uuid", "p_category_id" "uuid", "p_name" "text", "p_price" numeric, "p_sort_order" integer, "p_description" "text", "p_is_available" boolean, "p_is_visible_public" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."admin_create_menu_item"("p_restaurant_id" "uuid", "p_category_id" "uuid", "p_name" "text", "p_price" numeric, "p_sort_order" integer, "p_description" "text", "p_is_available" boolean, "p_is_visible_public" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_create_menu_item"("p_restaurant_id" "uuid", "p_category_id" "uuid", "p_name" "text", "p_price" numeric, "p_sort_order" integer, "p_description" "text", "p_is_available" boolean, "p_is_visible_public" boolean) TO "service_role";



GRANT ALL ON TABLE "public"."restaurants" TO "anon";
GRANT ALL ON TABLE "public"."restaurants" TO "authenticated";
GRANT ALL ON TABLE "public"."restaurants" TO "service_role";



GRANT ALL ON TABLE "public"."stores" TO "anon";
GRANT ALL ON TABLE "public"."stores" TO "authenticated";
GRANT ALL ON TABLE "public"."stores" TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_create_restaurant"("p_name" "text", "p_slug" "text", "p_operation_mode" "text", "p_address" "text", "p_per_person_charge" numeric, "p_brand_id" "uuid", "p_store_type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_create_restaurant"("p_name" "text", "p_slug" "text", "p_operation_mode" "text", "p_address" "text", "p_per_person_charge" numeric, "p_brand_id" "uuid", "p_store_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_create_restaurant"("p_name" "text", "p_slug" "text", "p_operation_mode" "text", "p_address" "text", "p_per_person_charge" numeric, "p_brand_id" "uuid", "p_store_type" "text") TO "service_role";



GRANT ALL ON TABLE "public"."tables" TO "anon";
GRANT ALL ON TABLE "public"."tables" TO "authenticated";
GRANT ALL ON TABLE "public"."tables" TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_create_table"("p_restaurant_id" "uuid", "p_table_number" "text", "p_seat_count" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."admin_create_table"("p_restaurant_id" "uuid", "p_table_number" "text", "p_seat_count" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_create_table"("p_restaurant_id" "uuid", "p_table_number" "text", "p_seat_count" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_deactivate_restaurant"("p_restaurant_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_deactivate_restaurant"("p_restaurant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_deactivate_restaurant"("p_restaurant_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_delete_menu_category"("p_category_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_delete_menu_category"("p_category_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_delete_menu_category"("p_category_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_delete_menu_item"("p_item_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_delete_menu_item"("p_item_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_delete_menu_item"("p_item_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_delete_table"("p_table_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_delete_table"("p_table_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_delete_table"("p_table_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_mark_resolved_einvoice_job"("p_job_id" "uuid", "p_store_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_mark_resolved_einvoice_job"("p_job_id" "uuid", "p_store_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_mark_resolved_einvoice_job"("p_job_id" "uuid", "p_store_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_retry_einvoice_job"("p_job_id" "uuid", "p_store_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_retry_einvoice_job"("p_job_id" "uuid", "p_store_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_retry_einvoice_job"("p_job_id" "uuid", "p_store_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_update_menu_category"("p_category_id" "uuid", "p_name" "text", "p_sort_order" integer, "p_is_active" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."admin_update_menu_category"("p_category_id" "uuid", "p_name" "text", "p_sort_order" integer, "p_is_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_update_menu_category"("p_category_id" "uuid", "p_name" "text", "p_sort_order" integer, "p_is_active" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_update_menu_item"("p_item_id" "uuid", "p_category_id" "uuid", "p_name" "text", "p_description" "text", "p_price" numeric, "p_is_available" boolean, "p_is_visible_public" boolean, "p_sort_order" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."admin_update_menu_item"("p_item_id" "uuid", "p_category_id" "uuid", "p_name" "text", "p_description" "text", "p_price" numeric, "p_is_available" boolean, "p_is_visible_public" boolean, "p_sort_order" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_update_menu_item"("p_item_id" "uuid", "p_category_id" "uuid", "p_name" "text", "p_description" "text", "p_price" numeric, "p_is_available" boolean, "p_is_visible_public" boolean, "p_sort_order" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_update_restaurant"("p_restaurant_id" "uuid", "p_name" "text", "p_slug" "text", "p_operation_mode" "text", "p_address" "text", "p_per_person_charge" numeric, "p_brand_id" "uuid", "p_store_type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_update_restaurant"("p_restaurant_id" "uuid", "p_name" "text", "p_slug" "text", "p_operation_mode" "text", "p_address" "text", "p_per_person_charge" numeric, "p_brand_id" "uuid", "p_store_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_update_restaurant"("p_restaurant_id" "uuid", "p_name" "text", "p_slug" "text", "p_operation_mode" "text", "p_address" "text", "p_per_person_charge" numeric, "p_brand_id" "uuid", "p_store_type" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_update_restaurant_settings"("p_store_id" "uuid", "p_name" "text", "p_operation_mode" "text", "p_address" "text", "p_per_person_charge" numeric, "p_vat_pricing_mode" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_update_restaurant_settings"("p_store_id" "uuid", "p_name" "text", "p_operation_mode" "text", "p_address" "text", "p_per_person_charge" numeric, "p_vat_pricing_mode" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_update_restaurant_settings"("p_store_id" "uuid", "p_name" "text", "p_operation_mode" "text", "p_address" "text", "p_per_person_charge" numeric, "p_vat_pricing_mode" "text") TO "service_role";



GRANT ALL ON TABLE "public"."users" TO "anon";
GRANT ALL ON TABLE "public"."users" TO "authenticated";
GRANT ALL ON TABLE "public"."users" TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_update_staff_account"("p_user_id" "uuid", "p_restaurant_id" "uuid", "p_full_name" "text", "p_is_active" boolean, "p_extra_permissions" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."admin_update_staff_account"("p_user_id" "uuid", "p_restaurant_id" "uuid", "p_full_name" "text", "p_is_active" boolean, "p_extra_permissions" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_update_staff_account"("p_user_id" "uuid", "p_restaurant_id" "uuid", "p_full_name" "text", "p_is_active" boolean, "p_extra_permissions" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_update_table"("p_table_id" "uuid", "p_table_number" "text", "p_seat_count" integer, "p_status" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_update_table"("p_table_id" "uuid", "p_table_number" "text", "p_seat_count" integer, "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_update_table"("p_table_id" "uuid", "p_table_number" "text", "p_seat_count" integer, "p_status" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."apply_inventory_physical_count_line"("p_restaurant_id" "uuid", "p_count_date" "date", "p_ingredient_id" "uuid", "p_actual_quantity_g" numeric, "p_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."apply_inventory_physical_count_line"("p_restaurant_id" "uuid", "p_count_date" "date", "p_ingredient_id" "uuid", "p_actual_quantity_g" numeric, "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_inventory_physical_count_line"("p_restaurant_id" "uuid", "p_count_date" "date", "p_ingredient_id" "uuid", "p_actual_quantity_g" numeric, "p_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."attach_payment_proof"("p_payment_id" "uuid", "p_store_id" "uuid", "p_proof_photo_url" "text", "p_taken_at" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."attach_payment_proof"("p_payment_id" "uuid", "p_store_id" "uuid", "p_proof_photo_url" "text", "p_taken_at" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."attach_payment_proof"("p_payment_id" "uuid", "p_store_id" "uuid", "p_proof_photo_url" "text", "p_taken_at" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."can_access_inventory_purchase_store"("p_store_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."can_access_inventory_purchase_store"("p_store_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_access_inventory_purchase_store"("p_store_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."can_office_review_inventory_purchase_store"("p_store_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."can_office_review_inventory_purchase_store"("p_store_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_office_review_inventory_purchase_store"("p_store_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."orders" TO "anon";
GRANT ALL ON TABLE "public"."orders" TO "authenticated";
GRANT ALL ON TABLE "public"."orders" TO "service_role";



GRANT ALL ON FUNCTION "public"."cancel_order"("p_order_id" "uuid", "p_restaurant_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."cancel_order"("p_order_id" "uuid", "p_restaurant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancel_order"("p_order_id" "uuid", "p_restaurant_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."cancel_order_item"("p_item_id" "uuid", "p_restaurant_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."cancel_order_item"("p_item_id" "uuid", "p_restaurant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancel_order_item"("p_item_id" "uuid", "p_restaurant_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."complete_onboarding_account_setup"("p_restaurant_id" "uuid", "p_full_name" "text", "p_role" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."complete_onboarding_account_setup"("p_restaurant_id" "uuid", "p_full_name" "text", "p_role" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."complete_onboarding_account_setup"("p_restaurant_id" "uuid", "p_full_name" "text", "p_role" "text") TO "service_role";



GRANT ALL ON TABLE "public"."delivery_settlements" TO "anon";
GRANT ALL ON TABLE "public"."delivery_settlements" TO "authenticated";
GRANT ALL ON TABLE "public"."delivery_settlements" TO "service_role";



GRANT ALL ON FUNCTION "public"."confirm_delivery_settlement_received"("p_settlement_id" "uuid", "p_restaurant_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."confirm_delivery_settlement_received"("p_settlement_id" "uuid", "p_restaurant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."confirm_delivery_settlement_received"("p_settlement_id" "uuid", "p_restaurant_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."inventory_purchase_orders" TO "anon";
GRANT ALL ON TABLE "public"."inventory_purchase_orders" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_purchase_orders" TO "service_role";



GRANT ALL ON FUNCTION "public"."confirm_inventory_purchase_receipt"("p_purchase_order_id" "uuid", "p_memo" "text", "p_lines" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."confirm_inventory_purchase_receipt"("p_purchase_order_id" "uuid", "p_memo" "text", "p_lines" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."confirm_inventory_purchase_receipt"("p_purchase_order_id" "uuid", "p_memo" "text", "p_lines" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_buffet_order"("p_store_id" "uuid", "p_table_id" "uuid", "p_guest_count" integer, "p_extra_items" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."create_buffet_order"("p_store_id" "uuid", "p_table_id" "uuid", "p_guest_count" integer, "p_extra_items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_buffet_order"("p_store_id" "uuid", "p_table_id" "uuid", "p_guest_count" integer, "p_extra_items" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_daily_closing"("p_restaurant_id" "uuid", "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_daily_closing"("p_restaurant_id" "uuid", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_daily_closing"("p_restaurant_id" "uuid", "p_notes" "text") TO "service_role";



GRANT ALL ON TABLE "public"."inventory_items" TO "anon";
GRANT ALL ON TABLE "public"."inventory_items" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_items" TO "service_role";



GRANT ALL ON FUNCTION "public"."create_inventory_item"("p_restaurant_id" "uuid", "p_name" "text", "p_unit" "text", "p_current_stock" numeric, "p_reorder_point" numeric, "p_cost_per_unit" numeric, "p_supplier_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_inventory_item"("p_restaurant_id" "uuid", "p_name" "text", "p_unit" "text", "p_current_stock" numeric, "p_reorder_point" numeric, "p_cost_per_unit" numeric, "p_supplier_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_inventory_item"("p_restaurant_id" "uuid", "p_name" "text", "p_unit" "text", "p_current_stock" numeric, "p_reorder_point" numeric, "p_cost_per_unit" numeric, "p_supplier_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_inventory_menu_with_recipe"("p_store_id" "uuid", "p_category_id" "uuid", "p_name" "text", "p_price" numeric, "p_description" "text", "p_recipe_lines" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."create_inventory_menu_with_recipe"("p_store_id" "uuid", "p_category_id" "uuid", "p_name" "text", "p_price" numeric, "p_description" "text", "p_recipe_lines" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_inventory_menu_with_recipe"("p_store_id" "uuid", "p_category_id" "uuid", "p_name" "text", "p_price" numeric, "p_description" "text", "p_recipe_lines" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_manual_inventory_purchase_order"("p_store_id" "uuid", "p_supplier_id" "uuid", "p_lines" "jsonb", "p_requested_delivery_date" "date", "p_memo" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_manual_inventory_purchase_order"("p_store_id" "uuid", "p_supplier_id" "uuid", "p_lines" "jsonb", "p_requested_delivery_date" "date", "p_memo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_manual_inventory_purchase_order"("p_store_id" "uuid", "p_supplier_id" "uuid", "p_lines" "jsonb", "p_requested_delivery_date" "date", "p_memo" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_order"("p_store_id" "uuid", "p_table_id" "uuid", "p_items" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."create_order"("p_store_id" "uuid", "p_table_id" "uuid", "p_items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_order"("p_store_id" "uuid", "p_table_id" "uuid", "p_items" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_purchase_orders_from_recommendation"("p_run_id" "uuid", "p_requested_delivery_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."create_purchase_orders_from_recommendation"("p_run_id" "uuid", "p_requested_delivery_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_purchase_orders_from_recommendation"("p_run_id" "uuid", "p_requested_delivery_date" "date") TO "service_role";



GRANT ALL ON TABLE "public"."qc_followups" TO "anon";
GRANT ALL ON TABLE "public"."qc_followups" TO "authenticated";
GRANT ALL ON TABLE "public"."qc_followups" TO "service_role";



GRANT ALL ON FUNCTION "public"."create_qc_followup"("p_restaurant_id" "uuid", "p_source_check_id" "uuid", "p_assigned_to_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_qc_followup"("p_restaurant_id" "uuid", "p_source_check_id" "uuid", "p_assigned_to_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_qc_followup"("p_restaurant_id" "uuid", "p_source_check_id" "uuid", "p_assigned_to_name" "text") TO "service_role";



GRANT ALL ON TABLE "public"."qc_templates" TO "anon";
GRANT ALL ON TABLE "public"."qc_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."qc_templates" TO "service_role";



GRANT ALL ON FUNCTION "public"."create_qc_template"("p_category" "text", "p_criteria_text" "text", "p_store_id" "uuid", "p_criteria_photo_url" "text", "p_sort_order" integer, "p_is_global" boolean, "p_qsc_domain" "text", "p_requires_photo" boolean, "p_required_photo_count" integer, "p_weight" numeric, "p_sort_group" "text", "p_is_sv_required" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."create_qc_template"("p_category" "text", "p_criteria_text" "text", "p_store_id" "uuid", "p_criteria_photo_url" "text", "p_sort_order" integer, "p_is_global" boolean, "p_qsc_domain" "text", "p_requires_photo" boolean, "p_required_photo_count" integer, "p_weight" numeric, "p_sort_group" "text", "p_is_sv_required" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_qc_template"("p_category" "text", "p_criteria_text" "text", "p_store_id" "uuid", "p_criteria_photo_url" "text", "p_sort_order" integer, "p_is_global" boolean, "p_qsc_domain" "text", "p_requires_photo" boolean, "p_required_photo_count" integer, "p_weight" numeric, "p_sort_group" "text", "p_is_sv_required" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."custom_access_token_hook"("event" "jsonb") TO "supabase_auth_admin";



GRANT ALL ON FUNCTION "public"."deactivate_qc_template"("p_template_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."deactivate_qc_template"("p_template_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."deactivate_qc_template"("p_template_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_inventory_recipe_line"("p_store_id" "uuid", "p_recipe_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_inventory_recipe_line"("p_store_id" "uuid", "p_recipe_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_inventory_recipe_line"("p_store_id" "uuid", "p_recipe_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."edit_order_item_quantity"("p_item_id" "uuid", "p_restaurant_id" "uuid", "p_new_quantity" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."edit_order_item_quantity"("p_item_id" "uuid", "p_restaurant_id" "uuid", "p_new_quantity" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."edit_order_item_quantity"("p_item_id" "uuid", "p_restaurant_id" "uuid", "p_new_quantity" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_uuidv7"() TO "anon";
GRANT ALL ON FUNCTION "public"."generate_uuidv7"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_uuidv7"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_admin_mutation_audit_trace"("p_restaurant_id" "uuid", "p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_admin_mutation_audit_trace"("p_restaurant_id" "uuid", "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_mutation_audit_trace"("p_restaurant_id" "uuid", "p_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_admin_today_summary"("p_restaurant_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_admin_today_summary"("p_restaurant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_today_summary"("p_restaurant_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_attendance_log_view"("p_store_id" "uuid", "p_from" timestamp with time zone, "p_to" timestamp with time zone, "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_attendance_log_view"("p_store_id" "uuid", "p_from" timestamp with time zone, "p_to" timestamp with time zone, "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_attendance_log_view"("p_store_id" "uuid", "p_from" timestamp with time zone, "p_to" timestamp with time zone, "p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_attendance_staff_directory"("p_store_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_attendance_staff_directory"("p_store_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_attendance_staff_directory"("p_store_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_cashier_today_summary"("p_restaurant_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_cashier_today_summary"("p_restaurant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_cashier_today_summary"("p_restaurant_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_daily_closings"("p_restaurant_id" "uuid", "p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_daily_closings"("p_restaurant_id" "uuid", "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_daily_closings"("p_restaurant_id" "uuid", "p_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_inventory_cost_analysis"("p_store_id" "uuid", "p_from" "date", "p_to" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."get_inventory_cost_analysis"("p_store_id" "uuid", "p_from" "date", "p_to" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_inventory_cost_analysis"("p_store_id" "uuid", "p_from" "date", "p_to" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_inventory_ingredient_catalog"("p_store_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_inventory_ingredient_catalog"("p_store_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_inventory_ingredient_catalog"("p_store_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_inventory_physical_count_sheet"("p_restaurant_id" "uuid", "p_count_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."get_inventory_physical_count_sheet"("p_restaurant_id" "uuid", "p_count_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_inventory_physical_count_sheet"("p_restaurant_id" "uuid", "p_count_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_inventory_purchase_dashboard"("p_store_id" "uuid", "p_brand_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_inventory_purchase_dashboard"("p_store_id" "uuid", "p_brand_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_inventory_purchase_dashboard"("p_store_id" "uuid", "p_brand_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_inventory_recipe_catalog"("p_restaurant_id" "uuid", "p_menu_item_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_inventory_recipe_catalog"("p_restaurant_id" "uuid", "p_menu_item_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_inventory_recipe_catalog"("p_restaurant_id" "uuid", "p_menu_item_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_inventory_stock_status"("p_store_id" "uuid", "p_as_of_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."get_inventory_stock_status"("p_store_id" "uuid", "p_as_of_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_inventory_stock_status"("p_store_id" "uuid", "p_as_of_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_inventory_transaction_visibility"("p_restaurant_id" "uuid", "p_from" timestamp with time zone, "p_to" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."get_inventory_transaction_visibility"("p_restaurant_id" "uuid", "p_from" timestamp with time zone, "p_to" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_inventory_transaction_visibility"("p_restaurant_id" "uuid", "p_from" timestamp with time zone, "p_to" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_photo_objet_store_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_photo_objet_store_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_photo_objet_store_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_qc_analytics"("p_restaurant_id" "uuid", "p_from" "date", "p_to" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."get_qc_analytics"("p_restaurant_id" "uuid", "p_from" "date", "p_to" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_qc_analytics"("p_restaurant_id" "uuid", "p_from" "date", "p_to" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_qc_checks"("p_store_id" "uuid", "p_from" "date", "p_to" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."get_qc_checks"("p_store_id" "uuid", "p_from" "date", "p_to" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_qc_checks"("p_store_id" "uuid", "p_from" "date", "p_to" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_qc_followups"("p_restaurant_id" "uuid", "p_status_filter" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_qc_followups"("p_restaurant_id" "uuid", "p_status_filter" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_qc_followups"("p_restaurant_id" "uuid", "p_status_filter" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_qc_superadmin_summary"("p_week_start" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."get_qc_superadmin_summary"("p_week_start" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_qc_superadmin_summary"("p_week_start" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_qc_templates"("p_store_id" "uuid", "p_scope" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_qc_templates"("p_store_id" "uuid", "p_scope" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_qc_templates"("p_store_id" "uuid", "p_scope" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_primary_store_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_primary_store_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_primary_store_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_restaurant_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_restaurant_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_restaurant_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_role"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_role"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_store_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_store_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_store_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_tax_entity_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_tax_entity_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_tax_entity_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."has_any_role"("required_roles" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."has_any_role"("required_roles" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_any_role"("required_roles" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."is_photo_objet_master"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_photo_objet_master"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_photo_objet_master"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_super_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_super_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_super_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."lookup_b2b_buyer"("p_store_id" "uuid", "p_tax_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."lookup_b2b_buyer"("p_store_id" "uuid", "p_tax_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."lookup_b2b_buyer"("p_store_id" "uuid", "p_tax_code" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."mark_payment_proof_required"("p_payment_id" "uuid", "p_store_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."mark_payment_proof_required"("p_payment_id" "uuid", "p_store_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."mark_payment_proof_required"("p_payment_id" "uuid", "p_store_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."office_approve_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_review_comment" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."office_approve_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_review_comment" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."office_approve_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_review_comment" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."office_cancel_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_review_comment" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."office_cancel_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_review_comment" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."office_cancel_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_review_comment" "text") TO "service_role";



GRANT ALL ON TABLE "public"."payroll_records" TO "anon";
GRANT ALL ON TABLE "public"."payroll_records" TO "authenticated";
GRANT ALL ON TABLE "public"."payroll_records" TO "service_role";



GRANT ALL ON FUNCTION "public"."office_confirm_payroll"("p_payroll_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."office_confirm_payroll"("p_payroll_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."office_confirm_payroll"("p_payroll_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."office_get_inventory_purchase_order_detail"("p_purchase_order_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."office_get_inventory_purchase_order_detail"("p_purchase_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."office_get_inventory_purchase_order_detail"("p_purchase_order_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."office_get_inventory_purchase_orders"("p_brand_id" "uuid", "p_store_id" "uuid", "p_status" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."office_get_inventory_purchase_orders"("p_brand_id" "uuid", "p_store_id" "uuid", "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."office_get_inventory_purchase_orders"("p_brand_id" "uuid", "p_store_id" "uuid", "p_status" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."office_reject_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_rejection_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."office_reject_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_rejection_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."office_reject_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_rejection_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."office_return_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_review_comment" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."office_return_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_review_comment" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."office_return_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_office_review_comment" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."office_return_payroll"("p_payroll_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."office_return_payroll"("p_payroll_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."office_return_payroll"("p_payroll_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."office_update_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_requested_delivery_date" "date", "p_memo" "text", "p_office_review_comment" "text", "p_lines" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."office_update_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_requested_delivery_date" "date", "p_memo" "text", "p_office_review_comment" "text", "p_lines" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."office_update_inventory_purchase_order"("p_purchase_order_id" "uuid", "p_requested_delivery_date" "date", "p_memo" "text", "p_office_review_comment" "text", "p_lines" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."on_payroll_store_submitted"() TO "anon";
GRANT ALL ON FUNCTION "public"."on_payroll_store_submitted"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."on_payroll_store_submitted"() TO "service_role";



GRANT ALL ON TABLE "public"."payments" TO "anon";
GRANT ALL ON TABLE "public"."payments" TO "authenticated";
GRANT ALL ON TABLE "public"."payments" TO "service_role";



GRANT ALL ON FUNCTION "public"."process_payment"("p_order_id" "uuid", "p_store_id" "uuid", "p_amount" numeric, "p_method" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."process_payment"("p_order_id" "uuid", "p_store_id" "uuid", "p_amount" numeric, "p_method" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_payment"("p_order_id" "uuid", "p_store_id" "uuid", "p_amount" numeric, "p_method" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."recalculate_inventory_purchase_order_totals"("p_purchase_order_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."recalculate_inventory_purchase_order_totals"("p_purchase_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recalculate_inventory_purchase_order_totals"("p_purchase_order_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."record_attendance_event"("p_store_id" "uuid", "p_user_id" "uuid", "p_type" "text", "p_photo_url" "text", "p_photo_thumbnail_url" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."record_attendance_event"("p_store_id" "uuid", "p_user_id" "uuid", "p_type" "text", "p_photo_url" "text", "p_photo_thumbnail_url" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_attendance_event"("p_store_id" "uuid", "p_user_id" "uuid", "p_type" "text", "p_photo_url" "text", "p_photo_thumbnail_url" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."record_inventory_waste"("p_restaurant_id" "uuid", "p_ingredient_id" "uuid", "p_quantity_g" numeric, "p_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."record_inventory_waste"("p_restaurant_id" "uuid", "p_ingredient_id" "uuid", "p_quantity_g" numeric, "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_inventory_waste"("p_restaurant_id" "uuid", "p_ingredient_id" "uuid", "p_quantity_g" numeric, "p_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_inventory_daily_consumption"("p_store_id" "uuid", "p_from" "date", "p_to" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_inventory_daily_consumption"("p_store_id" "uuid", "p_from" "date", "p_to" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_inventory_daily_consumption"("p_store_id" "uuid", "p_from" "date", "p_to" "date") TO "service_role";



GRANT ALL ON TABLE "public"."qc_checks" TO "anon";
GRANT ALL ON TABLE "public"."qc_checks" TO "authenticated";
GRANT ALL ON TABLE "public"."qc_checks" TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_qc_check_photo_summary"("p_check_id" "uuid", "p_sync_legacy_photo" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_qc_check_photo_summary"("p_check_id" "uuid", "p_sync_legacy_photo" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_qc_check_photo_summary"("p_check_id" "uuid", "p_sync_legacy_photo" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_user_claims"("p_auth_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_user_claims"("p_auth_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_user_claims"("p_auth_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."request_red_invoice"("p_order_id" "uuid", "p_store_id" "uuid", "p_buyer_tax_code" "text", "p_buyer_name" "text", "p_buyer_address" "text", "p_receiver_email" "text", "p_receiver_email_cc" "text", "p_buyer_tel" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."request_red_invoice"("p_order_id" "uuid", "p_store_id" "uuid", "p_buyer_tax_code" "text", "p_buyer_name" "text", "p_buyer_address" "text", "p_receiver_email" "text", "p_receiver_email_cc" "text", "p_buyer_tel" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."request_red_invoice"("p_order_id" "uuid", "p_store_id" "uuid", "p_buyer_tax_code" "text", "p_buyer_name" "text", "p_buyer_address" "text", "p_receiver_email" "text", "p_receiver_email_cc" "text", "p_buyer_tel" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."require_admin_actor_for_restaurant"("p_restaurant_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."require_admin_actor_for_restaurant"("p_restaurant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."require_admin_actor_for_restaurant"("p_restaurant_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."restock_inventory_item"("p_restaurant_id" "uuid", "p_ingredient_id" "uuid", "p_quantity_g" numeric, "p_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."restock_inventory_item"("p_restaurant_id" "uuid", "p_ingredient_id" "uuid", "p_quantity_g" numeric, "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."restock_inventory_item"("p_restaurant_id" "uuid", "p_ingredient_id" "uuid", "p_quantity_g" numeric, "p_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."run_inventory_purchase_recommendation"("p_store_id" "uuid", "p_target_stock_days" numeric, "p_as_of_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."run_inventory_purchase_recommendation"("p_store_id" "uuid", "p_target_stock_days" numeric, "p_as_of_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."run_inventory_purchase_recommendation"("p_store_id" "uuid", "p_target_stock_days" numeric, "p_as_of_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."save_inventory_stock_audit"("p_store_id" "uuid", "p_lines" "jsonb", "p_memo" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."save_inventory_stock_audit"("p_store_id" "uuid", "p_lines" "jsonb", "p_memo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_inventory_stock_audit"("p_store_id" "uuid", "p_lines" "jsonb", "p_memo" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."search_b2b_buyers"("p_store_id" "uuid", "p_query" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."search_b2b_buyers"("p_store_id" "uuid", "p_query" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_b2b_buyers"("p_store_id" "uuid", "p_query" "text") TO "service_role";



GRANT ALL ON TABLE "public"."inventory_products" TO "anon";
GRANT ALL ON TABLE "public"."inventory_products" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_products" TO "service_role";



GRANT ALL ON FUNCTION "public"."set_inventory_product_active"("p_store_id" "uuid", "p_product_id" "uuid", "p_is_active" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."set_inventory_product_active"("p_store_id" "uuid", "p_product_id" "uuid", "p_is_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_inventory_product_active"("p_store_id" "uuid", "p_product_id" "uuid", "p_is_active" boolean) TO "service_role";



GRANT ALL ON TABLE "public"."inventory_supplier_items" TO "anon";
GRANT ALL ON TABLE "public"."inventory_supplier_items" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_supplier_items" TO "service_role";



GRANT ALL ON FUNCTION "public"."set_inventory_supplier_item_active"("p_store_id" "uuid", "p_supplier_item_id" "uuid", "p_is_active" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."set_inventory_supplier_item_active"("p_store_id" "uuid", "p_supplier_item_id" "uuid", "p_is_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_inventory_supplier_item_active"("p_store_id" "uuid", "p_supplier_item_id" "uuid", "p_is_active" boolean) TO "service_role";



GRANT ALL ON TABLE "public"."inventory_suppliers" TO "anon";
GRANT ALL ON TABLE "public"."inventory_suppliers" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_suppliers" TO "service_role";



GRANT ALL ON FUNCTION "public"."set_inventory_supplier_status"("p_store_id" "uuid", "p_supplier_id" "uuid", "p_status" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."set_inventory_supplier_status"("p_store_id" "uuid", "p_supplier_id" "uuid", "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_inventory_supplier_status"("p_store_id" "uuid", "p_supplier_id" "uuid", "p_status" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."submit_qc_visit_review"("p_store_id" "uuid", "p_check_ids" "uuid"[], "p_sv_review_status" "text", "p_sv_score" numeric, "p_sv_note" "text", "p_visit_session_id" "uuid", "p_reviewed_at" timestamp with time zone, "p_reviewed_by" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_qc_visit_review"("p_store_id" "uuid", "p_check_ids" "uuid"[], "p_sv_review_status" "text", "p_sv_score" numeric, "p_sv_note" "text", "p_visit_session_id" "uuid", "p_reviewed_at" timestamp with time zone, "p_reviewed_by" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_qc_visit_review"("p_store_id" "uuid", "p_check_ids" "uuid"[], "p_sv_review_status" "text", "p_sv_score" numeric, "p_sv_note" "text", "p_visit_session_id" "uuid", "p_reviewed_at" timestamp with time zone, "p_reviewed_by" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_all_store_access"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_all_store_access"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_all_store_access"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_brand_store_access"("p_brand_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."sync_brand_store_access"("p_brand_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_brand_store_access"("p_brand_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_user_store_access"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."sync_user_store_access"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_user_store_access"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."transfer_order_table"("p_order_id" "uuid", "p_restaurant_id" "uuid", "p_new_table_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."transfer_order_table"("p_order_id" "uuid", "p_restaurant_id" "uuid", "p_new_table_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."transfer_order_table"("p_order_id" "uuid", "p_restaurant_id" "uuid", "p_new_table_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_inventory_item"("p_item_id" "uuid", "p_restaurant_id" "uuid", "p_patch" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."update_inventory_item"("p_item_id" "uuid", "p_restaurant_id" "uuid", "p_patch" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_inventory_item"("p_item_id" "uuid", "p_restaurant_id" "uuid", "p_patch" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_my_profile_full_name"("p_full_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_my_profile_full_name"("p_full_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_my_profile_full_name"("p_full_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_order_item_status"("p_item_id" "uuid", "p_store_id" "uuid", "p_new_status" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_order_item_status"("p_item_id" "uuid", "p_store_id" "uuid", "p_new_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_order_item_status"("p_item_id" "uuid", "p_store_id" "uuid", "p_new_status" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_qc_followup_status"("p_followup_id" "uuid", "p_restaurant_id" "uuid", "p_status" "text", "p_resolution_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_qc_followup_status"("p_followup_id" "uuid", "p_restaurant_id" "uuid", "p_status" "text", "p_resolution_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_qc_followup_status"("p_followup_id" "uuid", "p_restaurant_id" "uuid", "p_status" "text", "p_resolution_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_qc_template"("p_template_id" "uuid", "p_patch" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."update_qc_template"("p_template_id" "uuid", "p_patch" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_qc_template"("p_template_id" "uuid", "p_patch" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_inventory_product"("p_store_id" "uuid", "p_product_id" "uuid", "p_product_code" "text", "p_name" "text", "p_category" "text", "p_stock_unit" "text", "p_base_unit" "text", "p_base_unit_factor" numeric, "p_image_url" "text", "p_storage_type" "text", "p_shelf_life_days" integer, "p_is_orderable" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_inventory_product"("p_store_id" "uuid", "p_product_id" "uuid", "p_product_code" "text", "p_name" "text", "p_category" "text", "p_stock_unit" "text", "p_base_unit" "text", "p_base_unit_factor" numeric, "p_image_url" "text", "p_storage_type" "text", "p_shelf_life_days" integer, "p_is_orderable" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_inventory_product"("p_store_id" "uuid", "p_product_id" "uuid", "p_product_code" "text", "p_name" "text", "p_category" "text", "p_stock_unit" "text", "p_base_unit" "text", "p_base_unit_factor" numeric, "p_image_url" "text", "p_storage_type" "text", "p_shelf_life_days" integer, "p_is_orderable" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_inventory_recipe_line"("p_restaurant_id" "uuid", "p_menu_item_id" "uuid", "p_ingredient_id" "uuid", "p_quantity_g" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_inventory_recipe_line"("p_restaurant_id" "uuid", "p_menu_item_id" "uuid", "p_ingredient_id" "uuid", "p_quantity_g" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_inventory_recipe_line"("p_restaurant_id" "uuid", "p_menu_item_id" "uuid", "p_ingredient_id" "uuid", "p_quantity_g" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_inventory_supplier"("p_store_id" "uuid", "p_supplier_id" "uuid", "p_supplier_name" "text", "p_supplier_type" "text", "p_contact_name" "text", "p_phone" "text", "p_email" "text", "p_address" "text", "p_business_registration_no" "text", "p_payment_terms" "text", "p_contract_start_date" "date", "p_contract_end_date" "date", "p_memo" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_inventory_supplier"("p_store_id" "uuid", "p_supplier_id" "uuid", "p_supplier_name" "text", "p_supplier_type" "text", "p_contact_name" "text", "p_phone" "text", "p_email" "text", "p_address" "text", "p_business_registration_no" "text", "p_payment_terms" "text", "p_contract_start_date" "date", "p_contract_end_date" "date", "p_memo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_inventory_supplier"("p_store_id" "uuid", "p_supplier_id" "uuid", "p_supplier_name" "text", "p_supplier_type" "text", "p_contact_name" "text", "p_phone" "text", "p_email" "text", "p_address" "text", "p_business_registration_no" "text", "p_payment_terms" "text", "p_contract_start_date" "date", "p_contract_end_date" "date", "p_memo" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_inventory_supplier_item"("p_store_id" "uuid", "p_supplier_item_id" "uuid", "p_supplier_id" "uuid", "p_product_id" "uuid", "p_supplier_sku" "text", "p_order_unit" "text", "p_order_unit_quantity_base" numeric, "p_min_order_quantity" numeric, "p_unit_price" numeric, "p_tax_rate" numeric, "p_lead_time_days" integer, "p_is_preferred" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_inventory_supplier_item"("p_store_id" "uuid", "p_supplier_item_id" "uuid", "p_supplier_id" "uuid", "p_product_id" "uuid", "p_supplier_sku" "text", "p_order_unit" "text", "p_order_unit_quantity_base" numeric, "p_min_order_quantity" numeric, "p_unit_price" numeric, "p_tax_rate" numeric, "p_lead_time_days" integer, "p_is_preferred" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_inventory_supplier_item"("p_store_id" "uuid", "p_supplier_item_id" "uuid", "p_supplier_id" "uuid", "p_product_id" "uuid", "p_supplier_sku" "text", "p_order_unit" "text", "p_order_unit_quantity_base" numeric, "p_min_order_quantity" numeric, "p_unit_price" numeric, "p_tax_rate" numeric, "p_lead_time_days" integer, "p_is_preferred" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_qc_check"("p_store_id" "uuid", "p_template_id" "uuid", "p_check_date" "date", "p_result" "text", "p_evidence_photo_url" "text", "p_note" "text", "p_checked_by" "uuid", "p_submitted_at" timestamp with time zone, "p_submission_status" "text", "p_photo_required_count" integer, "p_photo_uploaded_count" integer, "p_score" numeric, "p_grade" "text", "p_sv_review_status" "text", "p_sv_reviewed_by" "uuid", "p_sv_reviewed_at" timestamp with time zone, "p_sv_score" numeric, "p_sv_note" "text", "p_visit_session_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_qc_check"("p_store_id" "uuid", "p_template_id" "uuid", "p_check_date" "date", "p_result" "text", "p_evidence_photo_url" "text", "p_note" "text", "p_checked_by" "uuid", "p_submitted_at" timestamp with time zone, "p_submission_status" "text", "p_photo_required_count" integer, "p_photo_uploaded_count" integer, "p_score" numeric, "p_grade" "text", "p_sv_review_status" "text", "p_sv_reviewed_by" "uuid", "p_sv_reviewed_at" timestamp with time zone, "p_sv_score" numeric, "p_sv_note" "text", "p_visit_session_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_qc_check"("p_store_id" "uuid", "p_template_id" "uuid", "p_check_date" "date", "p_result" "text", "p_evidence_photo_url" "text", "p_note" "text", "p_checked_by" "uuid", "p_submitted_at" timestamp with time zone, "p_submission_status" "text", "p_photo_required_count" integer, "p_photo_uploaded_count" integer, "p_score" numeric, "p_grade" "text", "p_sv_review_status" "text", "p_sv_reviewed_by" "uuid", "p_sv_reviewed_at" timestamp with time zone, "p_sv_score" numeric, "p_sv_note" "text", "p_visit_session_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."qc_check_photos" TO "anon";
GRANT ALL ON TABLE "public"."qc_check_photos" TO "authenticated";
GRANT ALL ON TABLE "public"."qc_check_photos" TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_qc_check_photo"("p_store_id" "uuid", "p_check_id" "uuid", "p_template_id" "uuid", "p_photo_url" "text", "p_storage_path" "text", "p_photo_role" "text", "p_uploaded_by" "uuid", "p_taken_at" timestamp with time zone, "p_is_primary" boolean, "p_caption" "text", "p_sync_legacy_photo" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_qc_check_photo"("p_store_id" "uuid", "p_check_id" "uuid", "p_template_id" "uuid", "p_photo_url" "text", "p_storage_path" "text", "p_photo_role" "text", "p_uploaded_by" "uuid", "p_taken_at" timestamp with time zone, "p_is_primary" boolean, "p_caption" "text", "p_sync_legacy_photo" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_qc_check_photo"("p_store_id" "uuid", "p_check_id" "uuid", "p_template_id" "uuid", "p_photo_url" "text", "p_storage_path" "text", "p_photo_role" "text", "p_uploaded_by" "uuid", "p_taken_at" timestamp with time zone, "p_is_primary" boolean, "p_caption" "text", "p_sync_legacy_photo" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."user_accessible_brands"("uid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."user_accessible_brands"("uid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_accessible_brands"("uid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."user_accessible_stores"("uid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."user_accessible_stores"("uid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_accessible_stores"("uid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."user_accessible_tax_entities"("uid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."user_accessible_tax_entities"("uid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_accessible_tax_entities"("uid" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."attendance_logs" TO "anon";
GRANT ALL ON TABLE "public"."attendance_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."attendance_logs" TO "service_role";



GRANT ALL ON TABLE "public"."audit_logs" TO "anon";
GRANT ALL ON TABLE "public"."audit_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_logs" TO "service_role";



GRANT ALL ON TABLE "public"."b2b_buyer_cache" TO "anon";
GRANT ALL ON TABLE "public"."b2b_buyer_cache" TO "authenticated";
GRANT ALL ON TABLE "public"."b2b_buyer_cache" TO "service_role";



GRANT ALL ON TABLE "public"."brand_master" TO "anon";
GRANT ALL ON TABLE "public"."brand_master" TO "authenticated";
GRANT ALL ON TABLE "public"."brand_master" TO "service_role";



GRANT ALL ON TABLE "public"."brands" TO "anon";
GRANT ALL ON TABLE "public"."brands" TO "authenticated";
GRANT ALL ON TABLE "public"."brands" TO "service_role";



GRANT ALL ON TABLE "public"."companies" TO "anon";
GRANT ALL ON TABLE "public"."companies" TO "authenticated";
GRANT ALL ON TABLE "public"."companies" TO "service_role";



GRANT ALL ON TABLE "public"."daily_closings" TO "anon";
GRANT ALL ON TABLE "public"."daily_closings" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_closings" TO "service_role";



GRANT ALL ON TABLE "public"."delivery_settlement_items" TO "anon";
GRANT ALL ON TABLE "public"."delivery_settlement_items" TO "authenticated";
GRANT ALL ON TABLE "public"."delivery_settlement_items" TO "service_role";



GRANT ALL ON TABLE "public"."einvoice_events" TO "anon";
GRANT ALL ON TABLE "public"."einvoice_events" TO "authenticated";
GRANT ALL ON TABLE "public"."einvoice_events" TO "service_role";



GRANT ALL ON TABLE "public"."einvoice_jobs" TO "anon";
GRANT ALL ON TABLE "public"."einvoice_jobs" TO "authenticated";
GRANT ALL ON TABLE "public"."einvoice_jobs" TO "service_role";



GRANT ALL ON TABLE "public"."einvoice_shop" TO "anon";
GRANT ALL ON TABLE "public"."einvoice_shop" TO "authenticated";
GRANT ALL ON TABLE "public"."einvoice_shop" TO "service_role";



GRANT ALL ON TABLE "public"."external_sales" TO "anon";
GRANT ALL ON TABLE "public"."external_sales" TO "authenticated";
GRANT ALL ON TABLE "public"."external_sales" TO "service_role";



GRANT ALL ON TABLE "public"."fingerprint_templates" TO "anon";
GRANT ALL ON TABLE "public"."fingerprint_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."fingerprint_templates" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_daily_consumption" TO "anon";
GRANT ALL ON TABLE "public"."inventory_daily_consumption" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_daily_consumption" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_physical_counts" TO "anon";
GRANT ALL ON TABLE "public"."inventory_physical_counts" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_physical_counts" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_purchase_order_lines" TO "anon";
GRANT ALL ON TABLE "public"."inventory_purchase_order_lines" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_purchase_order_lines" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_receipt_lines" TO "anon";
GRANT ALL ON TABLE "public"."inventory_receipt_lines" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_receipt_lines" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_receipts" TO "anon";
GRANT ALL ON TABLE "public"."inventory_receipts" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_receipts" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_recommendation_lines" TO "anon";
GRANT ALL ON TABLE "public"."inventory_recommendation_lines" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_recommendation_lines" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_recommendation_runs" TO "anon";
GRANT ALL ON TABLE "public"."inventory_recommendation_runs" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_recommendation_runs" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_stock_audit_lines" TO "anon";
GRANT ALL ON TABLE "public"."inventory_stock_audit_lines" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_stock_audit_lines" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_stock_audit_sessions" TO "anon";
GRANT ALL ON TABLE "public"."inventory_stock_audit_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_stock_audit_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."inventory_transactions" TO "anon";
GRANT ALL ON TABLE "public"."inventory_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory_transactions" TO "service_role";



GRANT ALL ON TABLE "public"."menu_recipes" TO "anon";
GRANT ALL ON TABLE "public"."menu_recipes" TO "authenticated";
GRANT ALL ON TABLE "public"."menu_recipes" TO "service_role";



GRANT ALL ON TABLE "public"."office_payroll_reviews" TO "anon";
GRANT ALL ON TABLE "public"."office_payroll_reviews" TO "authenticated";
GRANT ALL ON TABLE "public"."office_payroll_reviews" TO "service_role";



GRANT ALL ON TABLE "public"."partner_credential_access_log" TO "anon";
GRANT ALL ON TABLE "public"."partner_credential_access_log" TO "authenticated";
GRANT ALL ON TABLE "public"."partner_credential_access_log" TO "service_role";



GRANT ALL ON TABLE "public"."partner_credentials" TO "anon";
GRANT ALL ON TABLE "public"."partner_credentials" TO "authenticated";
GRANT ALL ON TABLE "public"."partner_credentials" TO "service_role";



GRANT ALL ON TABLE "public"."photo_objet_sales" TO "anon";
GRANT ALL ON TABLE "public"."photo_objet_sales" TO "authenticated";
GRANT ALL ON TABLE "public"."photo_objet_sales" TO "service_role";



GRANT ALL ON TABLE "public"."public_menu_items" TO "anon";
GRANT ALL ON TABLE "public"."public_menu_items" TO "authenticated";
GRANT ALL ON TABLE "public"."public_menu_items" TO "service_role";



GRANT ALL ON TABLE "public"."public_restaurant_profiles" TO "anon";
GRANT ALL ON TABLE "public"."public_restaurant_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."public_restaurant_profiles" TO "service_role";



GRANT ALL ON TABLE "public"."public_store_profiles" TO "anon";
GRANT ALL ON TABLE "public"."public_store_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."public_store_profiles" TO "service_role";



GRANT ALL ON TABLE "public"."restaurant_settings" TO "anon";
GRANT ALL ON TABLE "public"."restaurant_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."restaurant_settings" TO "service_role";



GRANT ALL ON TABLE "public"."staff_wage_configs" TO "anon";
GRANT ALL ON TABLE "public"."staff_wage_configs" TO "authenticated";
GRANT ALL ON TABLE "public"."staff_wage_configs" TO "service_role";



GRANT ALL ON TABLE "public"."store_settings" TO "anon";
GRANT ALL ON TABLE "public"."store_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."store_settings" TO "service_role";



GRANT ALL ON TABLE "public"."store_tax_entity_history" TO "anon";
GRANT ALL ON TABLE "public"."store_tax_entity_history" TO "authenticated";
GRANT ALL ON TABLE "public"."store_tax_entity_history" TO "service_role";



GRANT ALL ON TABLE "public"."system_config" TO "anon";
GRANT ALL ON TABLE "public"."system_config" TO "authenticated";
GRANT ALL ON TABLE "public"."system_config" TO "service_role";



GRANT ALL ON TABLE "public"."tax_entity" TO "anon";
GRANT ALL ON TABLE "public"."tax_entity" TO "authenticated";
GRANT ALL ON TABLE "public"."tax_entity" TO "service_role";



GRANT ALL ON TABLE "public"."user_brand_access" TO "anon";
GRANT ALL ON TABLE "public"."user_brand_access" TO "authenticated";
GRANT ALL ON TABLE "public"."user_brand_access" TO "service_role";



GRANT ALL ON TABLE "public"."user_store_access" TO "anon";
GRANT ALL ON TABLE "public"."user_store_access" TO "authenticated";
GRANT ALL ON TABLE "public"."user_store_access" TO "service_role";



GRANT ALL ON TABLE "public"."v_brand_kpi" TO "anon";
GRANT ALL ON TABLE "public"."v_brand_kpi" TO "authenticated";
GRANT ALL ON TABLE "public"."v_brand_kpi" TO "service_role";



GRANT ALL ON TABLE "public"."v_daily_revenue_by_channel" TO "anon";
GRANT ALL ON TABLE "public"."v_daily_revenue_by_channel" TO "authenticated";
GRANT ALL ON TABLE "public"."v_daily_revenue_by_channel" TO "service_role";



GRANT SELECT ON TABLE "public"."v_external_store_overview" TO "authenticated";
GRANT SELECT ON TABLE "public"."v_external_store_overview" TO "service_role";



GRANT SELECT ON TABLE "public"."v_external_store_sales" TO "authenticated";
GRANT SELECT ON TABLE "public"."v_external_store_sales" TO "service_role";



GRANT ALL ON TABLE "public"."v_inventory_status" TO "anon";
GRANT ALL ON TABLE "public"."v_inventory_status" TO "authenticated";
GRANT ALL ON TABLE "public"."v_inventory_status" TO "service_role";



GRANT ALL ON TABLE "public"."v_quality_monitoring" TO "anon";
GRANT ALL ON TABLE "public"."v_quality_monitoring" TO "authenticated";
GRANT ALL ON TABLE "public"."v_quality_monitoring" TO "service_role";



GRANT ALL ON TABLE "public"."v_qsc_dashboard_summary" TO "anon";
GRANT ALL ON TABLE "public"."v_qsc_dashboard_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."v_qsc_dashboard_summary" TO "service_role";



GRANT ALL ON TABLE "public"."v_office_qsc_dashboard" TO "anon";
GRANT ALL ON TABLE "public"."v_office_qsc_dashboard" TO "authenticated";
GRANT ALL ON TABLE "public"."v_office_qsc_dashboard" TO "service_role";



GRANT ALL ON TABLE "public"."v_office_qsc_issue_queue" TO "anon";
GRANT ALL ON TABLE "public"."v_office_qsc_issue_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."v_office_qsc_issue_queue" TO "service_role";



GRANT ALL ON TABLE "public"."v_qsc_store_status" TO "anon";
GRANT ALL ON TABLE "public"."v_qsc_store_status" TO "authenticated";
GRANT ALL ON TABLE "public"."v_qsc_store_status" TO "service_role";



GRANT ALL ON TABLE "public"."v_office_qsc_store_latest" TO "anon";
GRANT ALL ON TABLE "public"."v_office_qsc_store_latest" TO "authenticated";
GRANT ALL ON TABLE "public"."v_office_qsc_store_latest" TO "service_role";



GRANT ALL ON TABLE "public"."v_photo_objet_daily_summary" TO "anon";
GRANT ALL ON TABLE "public"."v_photo_objet_daily_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."v_photo_objet_daily_summary" TO "service_role";



GRANT ALL ON TABLE "public"."v_qsc_item_status" TO "anon";
GRANT ALL ON TABLE "public"."v_qsc_item_status" TO "authenticated";
GRANT ALL ON TABLE "public"."v_qsc_item_status" TO "service_role";



GRANT ALL ON TABLE "public"."v_settlement_summary" TO "anon";
GRANT ALL ON TABLE "public"."v_settlement_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."v_settlement_summary" TO "service_role";



GRANT ALL ON TABLE "public"."v_store_attendance_summary" TO "anon";
GRANT ALL ON TABLE "public"."v_store_attendance_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."v_store_attendance_summary" TO "service_role";



GRANT ALL ON TABLE "public"."v_store_daily_sales" TO "anon";
GRANT ALL ON TABLE "public"."v_store_daily_sales" TO "authenticated";
GRANT ALL ON TABLE "public"."v_store_daily_sales" TO "service_role";



GRANT ALL ON TABLE "public"."wetax_reference_values" TO "anon";
GRANT ALL ON TABLE "public"."wetax_reference_values" TO "authenticated";
GRANT ALL ON TABLE "public"."wetax_reference_values" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";





