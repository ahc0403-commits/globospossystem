CREATE TABLE IF NOT EXISTS "public"."direct_order_financials" (
    "request_id" "uuid" NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "quote_id" "uuid" NOT NULL,
    "order_id" "uuid" NOT NULL,
    "payment_id" "uuid" NOT NULL,
    "delivery_fee_item_id" "uuid",
    "menu_total" numeric(15,2) NOT NULL,
    "service_charge_total" numeric(15,2) NOT NULL,
    "delivery_fee_total" numeric(15,2) NOT NULL,
    "final_total" numeric(15,2) NOT NULL,
    "confirmed_bank_reference" "text",
    "approved_by" "uuid" NOT NULL,
    "approved_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "delivery_payment_mode" "text" DEFAULT 'store_prepaid'::"text" NOT NULL
);

ALTER TABLE ONLY "public"."direct_order_financials"
    ADD CONSTRAINT "direct_order_financials_delivery_fee_item_id_key" UNIQUE ("delivery_fee_item_id");

ALTER TABLE ONLY "public"."direct_order_financials"
    ADD CONSTRAINT "direct_order_financials_order_id_key" UNIQUE ("order_id");

ALTER TABLE ONLY "public"."direct_order_financials"
    ADD CONSTRAINT "direct_order_financials_payment_id_key" UNIQUE ("payment_id");

ALTER TABLE ONLY "public"."direct_order_financials"
    ADD CONSTRAINT "direct_order_financials_pkey" PRIMARY KEY ("request_id");

ALTER TABLE ONLY "public"."direct_order_financials"
    ADD CONSTRAINT "direct_order_financials_quote_id_key" UNIQUE ("quote_id");

CREATE INDEX "direct_order_financials_store_approved" ON "public"."direct_order_financials" USING "btree" ("restaurant_id", "approved_at" DESC);

CREATE TABLE IF NOT EXISTS "public"."direct_order_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "session_id" "uuid" NOT NULL,
    "client_request_id" "uuid" NOT NULL,
    "reference_code" "text" NOT NULL,
    "state" "text" DEFAULT 'awaiting_quote'::"text" NOT NULL,
    "locale" "text" DEFAULT 'vi'::"text" NOT NULL,
    "customer_note" "text",
    "approved_at" timestamp with time zone,
    "rejected_at" timestamp with time zone,
    "cancelled_at" timestamp with time zone,
    "pii_purged_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "fulfillment_type" "text" DEFAULT 'delivery'::"text" NOT NULL,
    "diner_count" integer,
    "fulfillment_method" "text" DEFAULT 'delivery'::"text" NOT NULL,
    "fulfillment_version" integer DEFAULT 1 NOT NULL,
    "invoice_details" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "support_closed_at" timestamp with time zone,
    "support_version" integer DEFAULT 1 NOT NULL,
    "delivery_fee_deferred" boolean DEFAULT false NOT NULL,
    "delivery_fee_finalized" boolean DEFAULT true NOT NULL,
    "refund_details" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "utensils_requested" boolean DEFAULT true NOT NULL,
    "delivery_policy_version" integer DEFAULT 2 NOT NULL,
    "submission_hash" "text",
    "operating_release_id" "uuid"
);

ALTER TABLE ONLY "public"."direct_order_requests"
    ADD CONSTRAINT "direct_order_requests_client_request_id_key" UNIQUE ("client_request_id");

ALTER TABLE ONLY "public"."direct_order_requests"
    ADD CONSTRAINT "direct_order_requests_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."direct_order_requests"
    ADD CONSTRAINT "direct_order_requests_reference_code_key" UNIQUE ("reference_code");

CREATE INDEX "direct_order_requests_session_created" ON "public"."direct_order_requests" USING "btree" ("session_id", "created_at" DESC);

CREATE INDEX "direct_order_requests_store_state_created" ON "public"."direct_order_requests" USING "btree" ("restaurant_id", "state", "created_at" DESC, "id" DESC);

CREATE INDEX "direct_requests_operating_release" ON "public"."direct_order_requests" USING "btree" ("operating_release_id") WHERE ("operating_release_id" IS NOT NULL);

CREATE TABLE IF NOT EXISTS "public"."direct_order_customer_requirements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "request_id" "uuid" NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "source_kind" "text" NOT NULL,
    "source_id" "uuid" NOT NULL,
    "request_text" "text" NOT NULL,
    "item_label_vi" "text",
    "source_locale" "text" NOT NULL,
    "customer_context_text" "text",
    "status" "text" DEFAULT 'awaiting_reply'::"text" NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "reply_text" "text",
    "reply_locale" "text",
    "reply_message_id" "uuid",
    "followup_text" "text",
    "print_request_vi" "text",
    "print_reply_vi" "text",
    "print_scope" "text" DEFAULT 'both'::"text" NOT NULL,
    "needs_confirmation" boolean DEFAULT true NOT NULL,
    "confirmed_at" timestamp with time zone,
    "confirmation_message_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE ONLY "public"."direct_order_customer_requirements"
    ADD CONSTRAINT "direct_order_customer_require_request_id_source_kind_source_key" UNIQUE ("request_id", "source_kind", "source_id");

ALTER TABLE ONLY "public"."direct_order_customer_requirements"
    ADD CONSTRAINT "direct_order_customer_requirements_pkey" PRIMARY KEY ("id");

CREATE INDEX "direct_order_requirements_scope" ON "public"."direct_order_customer_requirements" USING "btree" ("request_id", "status");

CREATE TABLE IF NOT EXISTS "public"."emergency_floor_ready_lots" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "session_id" "uuid" NOT NULL,
    "queue_id" "uuid" NOT NULL,
    "order_id" "uuid" NOT NULL,
    "order_item_id" "uuid" NOT NULL,
    "source_kind" "text" NOT NULL,
    "source_id" "uuid" NOT NULL,
    "ready_action_id" "uuid" NOT NULL,
    "ready_sequence" bigint NOT NULL,
    "ready_quantity" integer NOT NULL,
    "served_quantity" integer DEFAULT 0 NOT NULL,
    "voided_quantity" integer DEFAULT 0 NOT NULL,
    "ready_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE ONLY "public"."emergency_floor_ready_lots"
    ADD CONSTRAINT "emergency_floor_ready_lots_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."emergency_floor_ready_lots"
    ADD CONSTRAINT "emergency_floor_ready_lots_ready_action_id_source_kind_sour_key" UNIQUE ("ready_action_id", "source_kind", "source_id");

CREATE INDEX "emergency_floor_ready_lots_line_pending" ON "public"."emergency_floor_ready_lots" USING "btree" ("source_kind", "source_id", "ready_sequence", "id") WHERE (("served_quantity" + "voided_quantity") < "ready_quantity");

CREATE INDEX "emergency_floor_ready_lots_queue_pending" ON "public"."emergency_floor_ready_lots" USING "btree" ("restaurant_id", "queue_id", "ready_sequence", "id") WHERE (("served_quantity" + "voided_quantity") < "ready_quantity");

CREATE TABLE IF NOT EXISTS "public"."emergency_tray_ready_lots" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "session_id" "uuid" NOT NULL,
    "queue_id" "uuid" NOT NULL,
    "order_id" "uuid" NOT NULL,
    "order_item_id" "uuid" NOT NULL,
    "source_kind" "text" NOT NULL,
    "source_id" "uuid" NOT NULL,
    "kitchen_event_id" "uuid" NOT NULL,
    "ready_sequence" bigint NOT NULL,
    "ready_quantity" integer NOT NULL,
    "handed_quantity" integer DEFAULT 0 NOT NULL,
    "voided_quantity" integer DEFAULT 0 NOT NULL,
    "ready_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE ONLY "public"."emergency_tray_ready_lots"
    ADD CONSTRAINT "emergency_tray_ready_lots_kitchen_event_id_source_kind_sour_key" UNIQUE ("kitchen_event_id", "source_kind", "source_id");

ALTER TABLE ONLY "public"."emergency_tray_ready_lots"
    ADD CONSTRAINT "emergency_tray_ready_lots_pkey" PRIMARY KEY ("id");

CREATE INDEX "emergency_tray_ready_lots_line_pending" ON "public"."emergency_tray_ready_lots" USING "btree" ("source_kind", "source_id", "ready_sequence", "id") WHERE (("handed_quantity" + "voided_quantity") < "ready_quantity");

CREATE INDEX "emergency_tray_ready_lots_queue_pending" ON "public"."emergency_tray_ready_lots" USING "btree" ("restaurant_id", "queue_id", "ready_sequence", "id") WHERE (("handed_quantity" + "voided_quantity") < "ready_quantity");

CREATE TABLE IF NOT EXISTS "public"."leftover_packaging_requests" (
    "id" "uuid" NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "order_id" "uuid" NOT NULL,
    "session_id" "uuid" NOT NULL,
    "queue_id" "uuid" NOT NULL,
    "table_number" "text" NOT NULL,
    "floor_label" "text" NOT NULL,
    "source" "text" NOT NULL,
    "status" "text" DEFAULT 'awaiting_floor_pickup'::"text" NOT NULL,
    "requested_by" "uuid",
    "requested_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "completed_at" timestamp with time zone
);

ALTER TABLE ONLY "public"."leftover_packaging_requests"
    ADD CONSTRAINT "leftover_packaging_requests_order_id_key" UNIQUE ("order_id");

ALTER TABLE ONLY "public"."leftover_packaging_requests"
    ADD CONSTRAINT "leftover_packaging_requests_pkey" PRIMARY KEY ("id");

CREATE INDEX "leftover_packaging_station_queue_idx" ON "public"."leftover_packaging_requests" USING "btree" ("session_id", "status", "floor_label", "requested_at");

CREATE TABLE IF NOT EXISTS "public"."store_workflow_releases" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "definition" "jsonb" NOT NULL,
    "source_hash" "text" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE ONLY "public"."store_workflow_releases"
    ADD CONSTRAINT "store_workflow_releases_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."store_workflow_releases"
    ADD CONSTRAINT "store_workflow_releases_restaurant_id_id_key" UNIQUE ("restaurant_id", "id");

-- Reduced schema-only fixture from production 2026-10-23. No production rows.
-- KDS checks/defaults/indexes retained; unrelated catalog checks, FKs/triggers excluded.
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;

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
    "short_code" "text",
    "qr_takeout_enabled" boolean DEFAULT true NOT NULL,
    "qr_takeout_resume_at" timestamp with time zone,
    CONSTRAINT "restaurants_check" CHECK (((("operation_mode" = 'standard'::"text") AND ("per_person_charge" IS NULL)) OR (("operation_mode" = ANY (ARRAY['buffet'::"text", 'hybrid'::"text"])) AND ("per_person_charge" IS NOT NULL) AND ("per_person_charge" > (0)::numeric)))),
    CONSTRAINT "restaurants_operation_mode_check" CHECK (("operation_mode" = ANY (ARRAY['standard'::"text", 'buffet'::"text", 'hybrid'::"text"]))),
    CONSTRAINT "restaurants_short_code_check" CHECK ((("short_code" IS NULL) OR ("short_code" ~ '^[A-Z0-9]{2,6}$'::"text"))),
    CONSTRAINT "restaurants_store_type_check" CHECK (("store_type" = ANY (ARRAY['direct'::"text", 'external'::"text"]))),
    CONSTRAINT "restaurants_vat_pricing_mode_check" CHECK (("vat_pricing_mode" = ANY (ARRAY['exclusive'::"text", 'inclusive'::"text"])))
);

ALTER TABLE ONLY "public"."restaurants"
    ADD CONSTRAINT "restaurants_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."restaurants"
    ADD CONSTRAINT "restaurants_slug_key" UNIQUE ("slug");

CREATE INDEX "idx_restaurants_brand_id" ON "public"."restaurants" USING "btree" ("brand_id");

CREATE INDEX "idx_restaurants_brand_store_type" ON "public"."restaurants" USING "btree" ("brand_id", "store_type");

CREATE INDEX "idx_restaurants_store_type" ON "public"."restaurants" USING "btree" ("store_type");

CREATE INDEX "idx_restaurants_tax_entity_brand" ON "public"."restaurants" USING "btree" ("tax_entity_id", "brand_id");

CREATE UNIQUE INDEX "restaurants_short_code_unique" ON "public"."restaurants" USING "btree" ("upper"("short_code")) WHERE ("short_code" IS NOT NULL);

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
    "account_type" "text" DEFAULT 'legacy_user'::"text" NOT NULL,
    "fixed_account_code" "text",
    "must_change_password" boolean DEFAULT true NOT NULL,
    "password_change_required_at" timestamp with time zone DEFAULT "clock_timestamp"(),
    "password_changed_at" timestamp with time zone,
    "password_change_generation" bigint DEFAULT 0 NOT NULL,
    CONSTRAINT "users_account_type_check" CHECK (("account_type" = ANY (ARRAY['legacy_user'::"text", 'master'::"text", 'brand_manager'::"text", 'store_manager'::"text", 'inventory_orderer'::"text", 'inventory_accounting'::"text", 'device_pos'::"text", 'device_tablet'::"text", 'device_kitchen'::"text", 'device_print_station'::"text", 'device_customer_display'::"text", 'device_emergency_station'::"text", 'store_operator'::"text"]))),
    CONSTRAINT "users_fixed_account_code_check" CHECK (((("account_type" = 'legacy_user'::"text") AND ("fixed_account_code" IS NULL)) OR (("account_type" <> 'legacy_user'::"text") AND ("fixed_account_code" IS NOT NULL) AND ("fixed_account_code" ~ '^[a-z][a-z0-9_]{1,31}$'::"text")))),
    CONSTRAINT "users_role_check" CHECK (("role" = ANY (ARRAY['super_admin'::"text", 'master_admin'::"text", 'brand_admin'::"text", 'store_admin'::"text", 'admin'::"text", 'inventory_orderer'::"text", 'inventory_accounting'::"text", 'waiter'::"text", 'kitchen'::"text", 'cashier'::"text", 'print_station'::"text", 'customer_display'::"text", 'emergency_station'::"text", 'photo_objet_master'::"text", 'photo_objet_store_admin'::"text", 'photo_objet_store_operator'::"text"])))
);

ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_auth_id_key" UNIQUE ("auth_id");

ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");

CREATE INDEX "idx_users_auth_id" ON "public"."users" USING "btree" ("auth_id");

CREATE INDEX "idx_users_brand_id" ON "public"."users" USING "btree" ("brand_id");

CREATE INDEX "idx_users_primary_store_id" ON "public"."users" USING "btree" ("primary_store_id");

CREATE INDEX "idx_users_restaurant" ON "public"."users" USING "btree" ("restaurant_id");

CREATE UNIQUE INDEX "users_fixed_account_code_unique" ON "public"."users" USING "btree" ("lower"("fixed_account_code")) WHERE ("fixed_account_code" IS NOT NULL);

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
    "order_purpose" "text" DEFAULT 'customer'::"text" NOT NULL,
    "order_source" "text" DEFAULT 'staff'::"text" NOT NULL,
    "non_revenue_type" "text",
    "non_revenue_reason" "text",
    "non_revenue_staff_name" "text",
    "non_revenue_classified_by" "uuid",
    "non_revenue_classified_at" timestamp with time zone,
    "fulfillment_mode_snapshot" "text" DEFAULT 'pos_print'::"text" NOT NULL,
    "operational_closed_at" timestamp with time zone,
    "operational_close_reason" "text",
    "operating_release_id" "uuid",
    CONSTRAINT "orders_fulfillment_mode_snapshot_check" CHECK (("fulfillment_mode_snapshot" = ANY (ARRAY['pos_print'::"text", 'paperless'::"text"]))),
    CONSTRAINT "orders_guest_count_check" CHECK ((("guest_count" IS NULL) OR ("guest_count" > 0))),
    CONSTRAINT "orders_non_revenue_type_check" CHECK ((("non_revenue_type" IS NULL) OR ("non_revenue_type" = ANY (ARRAY['staff_meal'::"text", 'influencer_invite'::"text", 'customer_recovery'::"text", 'tasting'::"text", 'other'::"text"])))),
    CONSTRAINT "orders_operational_close_pair" CHECK (((("operational_closed_at" IS NULL) AND ("operational_close_reason" IS NULL)) OR (("operational_closed_at" IS NOT NULL) AND ("operational_close_reason" IS NOT NULL) AND ("operational_close_reason" = 'business_day_expired'::"text")))),
    CONSTRAINT "orders_order_purpose_check" CHECK (("order_purpose" = ANY (ARRAY['customer'::"text", 'staff_meal'::"text"]))),
    CONSTRAINT "orders_order_source_check" CHECK (("order_source" = ANY (ARRAY['staff'::"text", 'qr'::"text"]))),
    CONSTRAINT "orders_sales_channel_check" CHECK (("sales_channel" = ANY (ARRAY['dine_in'::"text", 'takeaway'::"text", 'delivery'::"text"]))),
    CONSTRAINT "orders_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'confirmed'::"text", 'serving'::"text", 'completed'::"text", 'cancelled'::"text"])))
);

ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_pkey" PRIMARY KEY ("id");

CREATE INDEX "idx_orders_restaurant" ON "public"."orders" USING "btree" ("restaurant_id");

CREATE INDEX "idx_orders_status" ON "public"."orders" USING "btree" ("restaurant_id", "status");

CREATE INDEX "idx_orders_table" ON "public"."orders" USING "btree" ("table_id");

CREATE INDEX "orders_bm_staff_meal_history_idx" ON "public"."orders" USING "btree" ("restaurant_id", "created_at" DESC) WHERE ("order_purpose" = 'staff_meal'::"text");

CREATE INDEX "orders_operating_release" ON "public"."orders" USING "btree" ("operating_release_id") WHERE ("operating_release_id" IS NOT NULL);

CREATE INDEX "orders_stale_table_operations" ON "public"."orders" USING "btree" ("restaurant_id", "created_at", "id") WHERE (("operational_closed_at" IS NULL) AND ("table_id" IS NOT NULL) AND ("sales_channel" = 'dine_in'::"text") AND ("status" = ANY (ARRAY['pending'::"text", 'confirmed'::"text", 'serving'::"text"])));

CREATE INDEX "orders_store_status_created_id" ON "public"."orders" USING "btree" ("restaurant_id", "status", "created_at", "id");

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
    "is_service_item" boolean DEFAULT false NOT NULL,
    "service_reason" "text",
    "service_marked_by" "uuid",
    "service_marked_at" timestamp with time zone,
    "combo_components" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "fulfillment_mode_snapshot" "text" DEFAULT 'pos_print'::"text" NOT NULL,
    "fulfillment_route_snapshot" "text" DEFAULT 'kitchen_tray_floor'::"text" NOT NULL,
    "menu_item_id_snapshot" "uuid",
    "is_takeout" boolean DEFAULT false NOT NULL,
    "vat_profile_snapshot" "jsonb",
    "vat_breakdown" "jsonb",
    "billing_cancelled_quantity" integer DEFAULT 0 NOT NULL,
    "cancelled_consumed_quantity" integer DEFAULT 0 NOT NULL,
    "menu_option_snapshot" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "order_items_billing_cancelled_quantity_check" CHECK (("billing_cancelled_quantity" >= 0)),
    CONSTRAINT "order_items_cancelled_consumed_quantity_check" CHECK (("cancelled_consumed_quantity" >= 0)),
    CONSTRAINT "order_items_combo_components_array_check" CHECK (("jsonb_typeof"("combo_components") = 'array'::"text")),
    CONSTRAINT "order_items_fulfillment_mode_snapshot_check" CHECK (("fulfillment_mode_snapshot" = ANY (ARRAY['pos_print'::"text", 'paperless'::"text"]))),
    CONSTRAINT "order_items_fulfillment_route_snapshot_check" CHECK (("fulfillment_route_snapshot" = ANY (ARRAY['kitchen_tray_floor'::"text", 'floor_direct'::"text"]))),
    CONSTRAINT "order_items_item_type_check" CHECK (("item_type" = ANY (ARRAY['menu_item'::"text", 'service_charge'::"text", 'wet_tissue_charge'::"text"]))),
    CONSTRAINT "order_items_item_type_menu_item_check" CHECK (((("item_type" = 'menu_item'::"text") AND ("menu_item_id" IS NOT NULL)) OR (("item_type" = ANY (ARRAY['service_charge'::"text", 'wet_tissue_charge'::"text"])) AND ("menu_item_id" IS NULL)))),
    CONSTRAINT "order_items_quantity_check" CHECK (("quantity" > 0)),
    CONSTRAINT "order_items_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'preparing'::"text", 'ready'::"text", 'served'::"text", 'cancelled'::"text"]))),
    CONSTRAINT "order_items_unit_price_check" CHECK (("unit_price" >= (0)::numeric))
);

ALTER TABLE ONLY "public"."order_items"
    ADD CONSTRAINT "order_items_pkey" PRIMARY KEY ("id");

CREATE INDEX "idx_order_items_order" ON "public"."order_items" USING "btree" ("order_id");

CREATE INDEX "order_items_invoice_order" ON "public"."order_items" USING "btree" ("order_id") WHERE (("status" <> 'cancelled'::"text") AND (COALESCE("is_service_item", false) = false));

CREATE UNIQUE INDEX "order_items_one_wet_tissue_charge_per_order_idx" ON "public"."order_items" USING "btree" ("order_id") WHERE ("item_type" = 'wet_tissue_charge'::"text");

CREATE OR REPLACE FUNCTION "public"."menu_effective_vat_rate"("p_category" "text", "p_sugar_class" "text") RETURNS numeric
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'pg_catalog'
    AS $$
  SELECT CASE WHEN p_category = 'alcohol' OR p_sugar_class = 'gt_5' THEN 10::numeric ELSE 8::numeric END
$$;


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
    "image_url" "text",
    "image_storage_path" "text",
    "name_ko" "text",
    "name_vi" "text",
    "name_en" "text",
    "is_combo" boolean DEFAULT false NOT NULL,
    "is_archived" boolean DEFAULT false NOT NULL,
    "combo_drink_choice_count" smallint DEFAULT 0 NOT NULL,
    "fulfillment_route" "text" DEFAULT 'kitchen_tray_floor'::"text" NOT NULL,
    "paperless_name_vi" "text",
    "beverage_sugar_tax_class" "text" DEFAULT 'not_applicable'::"text" NOT NULL,
    "sugar_g_per_100ml" numeric,
    "tax_basis_note" "text",
    "effective_vat_rate" numeric(5,2),
    "invoice_name_vi" "text",
    "invoice_unit_name" "text",
    "invoice_sale_unit" "text",
    "portion_code" "text" DEFAULT ''::"text" NOT NULL,
    "spice_level" "text" DEFAULT 'unknown'::"text" NOT NULL,
    "spice_choice" "text" DEFAULT ''::"text" NOT NULL,
    "option_base_names" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "menu_option_key" "text",
    "size_prices" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "size_parent_id" "uuid",
    "meal_choices" boolean DEFAULT false NOT NULL,
    "meal_choice" "text" DEFAULT ''::"text" NOT NULL,
    "choice_definition" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);

ALTER TABLE ONLY "public"."menu_items"
    ADD CONSTRAINT "menu_items_pkey" PRIMARY KEY ("id");

CREATE INDEX "direct_order_public_menu_page" ON "public"."menu_items" USING "btree" ("restaurant_id", "sort_order", "id") WHERE ("is_available" AND "is_visible_public" AND (NOT "is_archived"));

CREATE INDEX "idx_menu_items_category" ON "public"."menu_items" USING "btree" ("category_id");

CREATE INDEX "idx_menu_items_restaurant" ON "public"."menu_items" USING "btree" ("restaurant_id");

CREATE INDEX "menu_items_active_store_category_idx" ON "public"."menu_items" USING "btree" ("restaurant_id", "category_id", "sort_order") WHERE ("is_archived" = false);

CREATE UNIQUE INDEX "menu_items_id_restaurant_unique" ON "public"."menu_items" USING "btree" ("id", "restaurant_id");

CREATE INDEX "menu_items_size_parent_idx" ON "public"."menu_items" USING "btree" ("size_parent_id") WHERE ("size_parent_id" IS NOT NULL);

CREATE UNIQUE INDEX "menu_items_size_projection_idx" ON "public"."menu_items" USING "btree" ("size_parent_id", "portion_code", "meal_choice") WHERE ("size_parent_id" IS NOT NULL);

CREATE INDEX "menu_items_store_export_id_idx" ON "public"."menu_items" USING "btree" ("restaurant_id", "id");

CREATE TABLE IF NOT EXISTS "public"."restaurant_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "payroll_pin" "text",
    "settings_json" "jsonb" DEFAULT '{}'::"jsonb",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "fulfillment_mode" "text" DEFAULT 'pos_print'::"text" NOT NULL,
    "floor_direct_beverages_enabled" boolean DEFAULT false NOT NULL,
    "kds_workflow" "text" DEFAULT 'kitchen_tray_floor'::"text" NOT NULL,
    CONSTRAINT "restaurant_settings_fulfillment_mode_check" CHECK (("fulfillment_mode" = ANY (ARRAY['pos_print'::"text", 'paperless'::"text"]))),
    CONSTRAINT "restaurant_settings_kds_workflow_check" CHECK (("kds_workflow" = ANY (ARRAY['kitchen_tray_floor'::"text", 'kitchen_floor'::"text"])))
);

ALTER TABLE ONLY "public"."restaurant_settings"
    ADD CONSTRAINT "restaurant_settings_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."restaurant_settings"
    ADD CONSTRAINT "restaurant_settings_restaurant_id_key" UNIQUE ("restaurant_id");

CREATE TABLE IF NOT EXISTS "public"."emergency_order_queue" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "order_id" "uuid" NOT NULL,
    "queue_no" integer NOT NULL,
    "table_number" "text" NOT NULL,
    "floor_label" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "workflow_version" smallint DEFAULT 2 NOT NULL,
    "physical_floor_label" "text",
    "physical_floor_inferred" boolean DEFAULT true NOT NULL,
    "kitchen_direct_to_floor" boolean DEFAULT false NOT NULL,
    CONSTRAINT "emergency_order_queue_floor_label_check" CHECK (("floor_label" ~ '^[A-Z0-9][A-Z0-9_-]{0,15}$'::"text")),
    CONSTRAINT "emergency_order_queue_queue_no_check" CHECK (("queue_no" > 0)),
    CONSTRAINT "emergency_order_queue_workflow_version_check" CHECK (("workflow_version" = ANY (ARRAY[1, 2])))
);

ALTER TABLE ONLY "public"."emergency_order_queue"
    ADD CONSTRAINT "emergency_order_queue_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."emergency_order_queue"
    ADD CONSTRAINT "emergency_order_queue_session_id_order_id_key" UNIQUE ("session_id", "order_id");

ALTER TABLE ONLY "public"."emergency_order_queue"
    ADD CONSTRAINT "emergency_order_queue_session_id_queue_no_key" UNIQUE ("session_id", "queue_no");

CREATE INDEX "emergency_queue_session_created_queue" ON "public"."emergency_order_queue" USING "btree" ("session_id", "created_at", "queue_no");

CREATE INDEX "emergency_queue_store_created_order" ON "public"."emergency_order_queue" USING "btree" ("restaurant_id", "created_at", "order_id");

CREATE INDEX "emergency_queue_store_session" ON "public"."emergency_order_queue" USING "btree" ("restaurant_id", "session_id", "queue_no");

CREATE TABLE IF NOT EXISTS "public"."emergency_fulfillment_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "reason" "text" NOT NULL,
    "activated_by" "uuid",
    "activated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "closed_by" "uuid",
    "closed_at" timestamp with time zone,
    "close_reason" "text",
    "close_resolution" "text",
    "force_closed" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "emergency_fulfillment_sessions_close_resolution_check" CHECK ((("close_resolution" IS NULL) OR ("close_resolution" = ANY (ARRAY['digital_completed'::"text", 'reprint'::"text", 'dismiss'::"text"])))),
    CONSTRAINT "emergency_fulfillment_sessions_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'closed'::"text"]))),
    CONSTRAINT "emergency_session_closed_state" CHECK (((("status" = 'active'::"text") AND ("closed_at" IS NULL) AND ("closed_by" IS NULL)) OR (("status" = 'closed'::"text") AND ("closed_at" IS NOT NULL) AND ("closed_by" IS NOT NULL) AND ("close_resolution" IS NOT NULL)))),
    CONSTRAINT "emergency_session_reason_present" CHECK (("btrim"("reason") <> ''::"text"))
);

ALTER TABLE ONLY "public"."emergency_fulfillment_sessions"
    ADD CONSTRAINT "emergency_fulfillment_sessions_pkey" PRIMARY KEY ("id");

CREATE UNIQUE INDEX "emergency_one_active_session_per_store" ON "public"."emergency_fulfillment_sessions" USING "btree" ("restaurant_id") WHERE ("status" = 'active'::"text");

CREATE TABLE IF NOT EXISTS "public"."emergency_fulfillment_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "queue_id" "uuid" NOT NULL,
    "order_id" "uuid" NOT NULL,
    "order_item_id" "uuid" NOT NULL,
    "source_quantity" integer NOT NULL,
    "ordered_quantity" integer NOT NULL,
    "kitchen_done_quantity" integer DEFAULT 0 NOT NULL,
    "tray_received_quantity" integer DEFAULT 0 NOT NULL,
    "tray_dispatched_quantity" integer DEFAULT 0 NOT NULL,
    "floor_served_quantity" integer DEFAULT 0 NOT NULL,
    "is_cancelled" boolean DEFAULT false NOT NULL,
    "needs_review" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "kitchen_started_quantity" integer DEFAULT 0 NOT NULL,
    "excused_quantity" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "emergency_fulfillment_items_ordered_quantity_check" CHECK (("ordered_quantity" > 0)),
    CONSTRAINT "emergency_fulfillment_items_source_quantity_check" CHECK (("source_quantity" > 0)),
    CONSTRAINT "emergency_fulfillment_quantity_chain" CHECK ((("floor_served_quantity" >= 0) AND ("floor_served_quantity" <= "tray_dispatched_quantity") AND ("tray_dispatched_quantity" <= "tray_received_quantity") AND ("tray_received_quantity" <= "kitchen_done_quantity") AND ("kitchen_done_quantity" <= "kitchen_started_quantity") AND ("excused_quantity" >= 0) AND (("kitchen_started_quantity" + "excused_quantity") <= "ordered_quantity")))
);

ALTER TABLE ONLY "public"."emergency_fulfillment_items"
    ADD CONSTRAINT "emergency_fulfillment_items_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."emergency_fulfillment_items"
    ADD CONSTRAINT "emergency_fulfillment_items_session_id_order_item_id_key" UNIQUE ("session_id", "order_item_id");

CREATE INDEX "emergency_items_order" ON "public"."emergency_fulfillment_items" USING "btree" ("session_id", "order_id");

CREATE INDEX "emergency_items_queue_open_created" ON "public"."emergency_fulfillment_items" USING "btree" ("queue_id", "created_at", "order_item_id") WHERE ("is_cancelled" = false);

CREATE TABLE IF NOT EXISTS "public"."emergency_floor_direct_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "queue_id" "uuid" NOT NULL,
    "order_id" "uuid" NOT NULL,
    "order_item_id" "uuid" NOT NULL,
    "line_key" "text" NOT NULL,
    "source_kind" "text" NOT NULL,
    "component_menu_item_id" "uuid",
    "name_ko" "text" NOT NULL,
    "name_vi" "text" NOT NULL,
    "name_en" "text" NOT NULL,
    "source_quantity" integer NOT NULL,
    "ordered_quantity" integer NOT NULL,
    "floor_served_quantity" integer DEFAULT 0 NOT NULL,
    "is_cancelled" boolean DEFAULT false NOT NULL,
    "needs_review" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "excused_quantity" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "emergency_floor_direct_items_ordered_quantity_check" CHECK (("ordered_quantity" > 0)),
    CONSTRAINT "emergency_floor_direct_items_source_kind_check" CHECK (("source_kind" = ANY (ARRAY['order_item'::"text", 'combo_component'::"text"]))),
    CONSTRAINT "emergency_floor_direct_items_source_quantity_check" CHECK (("source_quantity" > 0)),
    CONSTRAINT "emergency_floor_direct_line_key_present" CHECK (("btrim"("line_key") <> ''::"text")),
    CONSTRAINT "emergency_floor_direct_quantity_check" CHECK ((("floor_served_quantity" >= 0) AND ("excused_quantity" >= 0) AND (("floor_served_quantity" + "excused_quantity") <= "ordered_quantity")))
);

ALTER TABLE ONLY "public"."emergency_floor_direct_items"
    ADD CONSTRAINT "emergency_floor_direct_items_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."emergency_floor_direct_items"
    ADD CONSTRAINT "emergency_floor_direct_items_session_id_order_item_id_line__key" UNIQUE ("session_id", "order_item_id", "line_key");

CREATE INDEX "emergency_floor_direct_order" ON "public"."emergency_floor_direct_items" USING "btree" ("session_id", "order_id", "queue_id");

CREATE INDEX "emergency_floor_direct_store_open" ON "public"."emergency_floor_direct_items" USING "btree" ("restaurant_id", "created_at") WHERE ("is_cancelled" = false);

CREATE TABLE IF NOT EXISTS "public"."emergency_combo_component_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "queue_id" "uuid" NOT NULL,
    "order_id" "uuid" NOT NULL,
    "order_item_id" "uuid" NOT NULL,
    "line_key" "text" NOT NULL,
    "component_menu_item_id" "uuid",
    "name_ko" "text" NOT NULL,
    "name_vi" "text" NOT NULL,
    "name_en" "text" NOT NULL,
    "source_quantity" integer NOT NULL,
    "ordered_quantity" integer NOT NULL,
    "kitchen_done_quantity" integer DEFAULT 0 NOT NULL,
    "tray_received_quantity" integer DEFAULT 0 NOT NULL,
    "tray_dispatched_quantity" integer DEFAULT 0 NOT NULL,
    "floor_served_quantity" integer DEFAULT 0 NOT NULL,
    "is_cancelled" boolean DEFAULT false NOT NULL,
    "needs_review" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "kitchen_started_quantity" integer DEFAULT 0 NOT NULL,
    "excused_quantity" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "emergency_combo_component_items_ordered_quantity_check" CHECK (("ordered_quantity" > 0)),
    CONSTRAINT "emergency_combo_component_items_source_quantity_check" CHECK (("source_quantity" > 0)),
    CONSTRAINT "emergency_combo_component_line_key_present" CHECK (("btrim"("line_key") <> ''::"text")),
    CONSTRAINT "emergency_combo_component_quantity_chain" CHECK ((("floor_served_quantity" >= 0) AND ("floor_served_quantity" <= "tray_dispatched_quantity") AND ("tray_dispatched_quantity" <= "tray_received_quantity") AND ("tray_received_quantity" <= "kitchen_done_quantity") AND ("kitchen_done_quantity" <= "kitchen_started_quantity") AND ("excused_quantity" >= 0) AND (("kitchen_started_quantity" + "excused_quantity") <= "ordered_quantity")))
);

ALTER TABLE ONLY "public"."emergency_combo_component_items"
    ADD CONSTRAINT "emergency_combo_component_ite_session_id_order_item_id_line_key" UNIQUE ("session_id", "order_item_id", "line_key");

ALTER TABLE ONLY "public"."emergency_combo_component_items"
    ADD CONSTRAINT "emergency_combo_component_items_pkey" PRIMARY KEY ("id");

CREATE INDEX "emergency_combo_component_order" ON "public"."emergency_combo_component_items" USING "btree" ("session_id", "order_id", "queue_id");

CREATE INDEX "emergency_combo_component_store_open" ON "public"."emergency_combo_component_items" USING "btree" ("restaurant_id", "created_at") WHERE ("is_cancelled" = false);

CREATE TABLE IF NOT EXISTS "public"."emergency_station_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "station_type" "text" NOT NULL,
    "floor_label" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "service_area_codes" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    CONSTRAINT "emergency_station_assignments_station_type_check" CHECK (("station_type" = ANY (ARRAY['kitchen'::"text", 'tray'::"text", 'floor'::"text"]))),
    CONSTRAINT "emergency_station_floor_contract" CHECK (((("station_type" = 'floor'::"text") AND ("floor_label" IS NOT NULL) AND ("floor_label" ~ '^[A-Z0-9][A-Z0-9_-]{0,15}$'::"text")) OR (("station_type" <> 'floor'::"text") AND ("floor_label" IS NULL)))),
    CONSTRAINT "station_service_areas_bound" CHECK ((("cardinality"("service_area_codes") <= 16) AND (("cardinality"("service_area_codes") = 0) OR (("station_type" = 'floor'::"text") AND ("floor_label" = ANY ("service_area_codes"))))))
);

ALTER TABLE ONLY "public"."emergency_station_assignments"
    ADD CONSTRAINT "emergency_station_assignments_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."emergency_station_assignments"
    ADD CONSTRAINT "emergency_station_assignments_restaurant_id_user_id_key" UNIQUE ("restaurant_id", "user_id");

CREATE TABLE IF NOT EXISTS "public"."emergency_fulfillment_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "session_id" "uuid" NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "order_id" "uuid" NOT NULL,
    "order_item_id" "uuid",
    "stage" "text" NOT NULL,
    "delta" integer NOT NULL,
    "actor_user_id" "uuid",
    "details" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "action_id" "uuid",
    "floor_direct_item_id" "uuid",
    "combo_component_item_id" "uuid",
    "leftover_packaging_request_id" "uuid",
    CONSTRAINT "emergency_fulfillment_events_delta_check" CHECK (("delta" <> 0)),
    CONSTRAINT "emergency_fulfillment_events_stage_check" CHECK (("stage" = ANY (ARRAY['order_received'::"text", 'kitchen_started'::"text", 'kitchen_done'::"text", 'tray_ready'::"text", 'tray_received'::"text", 'tray_dispatched'::"text", 'floor_served'::"text", 'fulfillment_cancelled'::"text", 'floor_direct_ready'::"text", 'leftover_floor_to_kitchen'::"text", 'leftover_kitchen_to_floor'::"text", 'leftover_requested'::"text", 'leftover_floor_to_tray'::"text", 'leftover_tray_to_kitchen'::"text", 'leftover_kitchen_packaged'::"text", 'leftover_tray_to_floor'::"text", 'leftover_floor_delivered'::"text"])))
);

ALTER TABLE ONLY "public"."emergency_fulfillment_events"
    ADD CONSTRAINT "emergency_fulfillment_events_event_id_key" UNIQUE ("event_id");

ALTER TABLE ONLY "public"."emergency_fulfillment_events"
    ADD CONSTRAINT "emergency_fulfillment_events_pkey" PRIMARY KEY ("id");

CREATE INDEX "emergency_events_action" ON "public"."emergency_fulfillment_events" USING "btree" ("action_id") WHERE ("action_id" IS NOT NULL);

CREATE INDEX "emergency_events_analytics" ON "public"."emergency_fulfillment_events" USING "btree" ("restaurant_id", "order_id", "stage", "created_at") WHERE ("delta" > 0);

CREATE INDEX "emergency_events_combo_component_created" ON "public"."emergency_fulfillment_events" USING "btree" ("combo_component_item_id", "created_at") WHERE ("combo_component_item_id" IS NOT NULL);

CREATE INDEX "emergency_events_direct_item_created" ON "public"."emergency_fulfillment_events" USING "btree" ("floor_direct_item_id", "created_at") WHERE ("floor_direct_item_id" IS NOT NULL);

CREATE INDEX "emergency_events_leftover_request_idx" ON "public"."emergency_fulfillment_events" USING "btree" ("leftover_packaging_request_id") WHERE ("leftover_packaging_request_id" IS NOT NULL);

CREATE INDEX "emergency_events_order_item_stage_created" ON "public"."emergency_fulfillment_events" USING "btree" ("order_item_id", "stage", "created_at") WHERE (("order_item_id" IS NOT NULL) AND ("delta" > 0));

CREATE INDEX "emergency_events_store_created" ON "public"."emergency_fulfillment_events" USING "btree" ("restaurant_id", "created_at");

CREATE TABLE IF NOT EXISTS "public"."emergency_fulfillment_actions" (
    "action_id" "uuid" NOT NULL,
    "session_id" "uuid" NOT NULL,
    "restaurant_id" "uuid" NOT NULL,
    "queue_id" "uuid" NOT NULL,
    "order_id" "uuid" NOT NULL,
    "station_type" "text" NOT NULL,
    "floor_label" "text",
    "action_kind" "text" NOT NULL,
    "stage" "text" NOT NULL,
    "original_action_id" "uuid",
    "actor_user_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "emergency_action_revert_contract" CHECK (((("action_kind" = 'complete'::"text") AND ("original_action_id" IS NULL)) OR (("action_kind" = 'revert'::"text") AND ("original_action_id" IS NOT NULL)))),
    CONSTRAINT "emergency_fulfillment_actions_action_kind_check" CHECK (("action_kind" = ANY (ARRAY['complete'::"text", 'revert'::"text"]))),
    CONSTRAINT "emergency_fulfillment_actions_stage_check" CHECK (("stage" = ANY (ARRAY['kitchen_done'::"text", 'tray_handoff'::"text", 'floor_served'::"text"]))),
    CONSTRAINT "emergency_fulfillment_actions_station_type_check" CHECK (("station_type" = ANY (ARRAY['kitchen'::"text", 'tray'::"text", 'floor'::"text"])))
);

ALTER TABLE ONLY "public"."emergency_fulfillment_actions"
    ADD CONSTRAINT "emergency_fulfillment_actions_pkey" PRIMARY KEY ("action_id");

CREATE INDEX "emergency_actions_queue_station_recent" ON "public"."emergency_fulfillment_actions" USING "btree" ("queue_id", "station_type", "created_at" DESC);

CREATE UNIQUE INDEX "emergency_one_revert_per_action" ON "public"."emergency_fulfillment_actions" USING "btree" ("original_action_id") WHERE ("action_kind" = 'revert'::"text");

CREATE OR REPLACE FUNCTION "public"."get_emergency_station_today_completed_base"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_orders jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_user
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;

  SELECT * INTO v_assignment
  FROM public.emergency_station_assignments
  WHERE user_id = v_user.id
    AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND THEN RETURN '[]'::jsonb; END IF;

  v_day_start := (
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp
    AT TIME ZONE 'Asia/Ho_Chi_Minh'
  );
  v_day_end := v_day_start + interval '1 day';

  SELECT COALESCE(
    jsonb_agg(order_payload ORDER BY completed_at DESC, queue_no DESC),
    '[]'::jsonb
  )
  INTO v_orders
  FROM (
    SELECT queue.queue_no, completion.completed_at,
      jsonb_build_object(
        'queue_id', queue.id,
        'order_id', queue.order_id,
        'queue_no', queue.queue_no,
        'table_number', queue.table_number,
        'floor_label', queue.floor_label,
        'created_at', queue.created_at,
        'last_action_id', recent.action_id,
        'last_action_at', completion.completed_at,
        'items', COALESCE((
          SELECT jsonb_agg(item_payload ORDER BY created_at, order_item_id, line_key)
          FROM (
            SELECT fulfillment.created_at, fulfillment.order_item_id,
              'base'::text AS line_key,
              jsonb_build_object(
                'id', fulfillment.id,
                'order_item_id', fulfillment.order_item_id,
                'line_key', 'base',
                'source_kind', 'order_item',
                'fulfillment_route', 'kitchen_tray_floor',
                'name_ko', COALESCE(NULLIF(item.label, ''),
                  NULLIF(item.display_name, ''), menu.name_ko, menu.name, '메뉴'),
                'name_vi', COALESCE(NULLIF(menu.name_vi, ''),
                  NULLIF(item.display_name, ''), menu.name, 'Món'),
                'name_en', COALESCE(NULLIF(menu.name_en, ''),
                  NULLIF(item.display_name, ''), menu.name, 'Item'),
                'combo_components', COALESCE(item.combo_components, '[]'::jsonb),
                'ordered_quantity', fulfillment.ordered_quantity,
                'kitchen_done_quantity', fulfillment.kitchen_done_quantity,
                'tray_received_quantity', fulfillment.tray_received_quantity,
                'tray_dispatched_quantity', fulfillment.tray_dispatched_quantity,
                'floor_served_quantity', fulfillment.floor_served_quantity,
                'needs_review', fulfillment.needs_review
              ) AS item_payload
            FROM public.emergency_fulfillment_items fulfillment
            JOIN public.order_items item ON item.id = fulfillment.order_item_id
            LEFT JOIN public.menu_items menu ON menu.id = item.menu_item_id
            WHERE fulfillment.queue_id = queue.id
              AND fulfillment.is_cancelled = false

            UNION ALL

            SELECT direct.created_at, direct.order_item_id, direct.line_key,
              jsonb_build_object(
                'id', direct.id,
                'order_item_id', direct.order_item_id,
                'line_key', direct.line_key,
                'source_kind', direct.source_kind,
                'fulfillment_route', 'floor_direct',
                'name_ko', direct.name_ko,
                'name_vi', direct.name_vi,
                'name_en', direct.name_en,
                'combo_components', '[]'::jsonb,
                'ordered_quantity', direct.ordered_quantity,
                'kitchen_done_quantity', 0,
                'tray_received_quantity', 0,
                'tray_dispatched_quantity', 0,
                'floor_served_quantity', direct.floor_served_quantity,
                'needs_review', direct.needs_review
              ) AS item_payload
            FROM public.emergency_floor_direct_items direct
            WHERE direct.queue_id = queue.id
              AND direct.is_cancelled = false
          ) completed_items
        ), '[]'::jsonb)
      ) AS order_payload
    FROM public.emergency_order_queue queue
    JOIN public.emergency_fulfillment_sessions session
      ON session.id = queue.session_id
    JOIN LATERAL (
      SELECT max(event.created_at) AS completed_at
      FROM public.emergency_fulfillment_events event
      WHERE event.session_id = queue.session_id
        AND event.order_id = queue.order_id
        AND event.created_at >= v_day_start
        AND event.created_at < v_day_end
        AND event.delta > 0
        AND event.stage = CASE v_assignment.station_type
          WHEN 'kitchen' THEN 'kitchen_done'
          WHEN 'tray' THEN 'tray_dispatched'
          ELSE 'floor_served'
        END
    ) completion ON completion.completed_at IS NOT NULL
    LEFT JOIN LATERAL (
      SELECT action.action_id
      FROM public.emergency_fulfillment_actions action
      WHERE action.queue_id = queue.id
        AND action.station_type = v_assignment.station_type
        AND action.action_kind = 'complete'
        AND NOT EXISTS (
          SELECT 1
          FROM public.emergency_fulfillment_actions reversal
          WHERE reversal.original_action_id = action.action_id
            AND reversal.action_kind = 'revert'
        )
      ORDER BY action.created_at DESC, action.action_id DESC
      LIMIT 1
    ) recent ON true
    WHERE queue.restaurant_id = v_assignment.restaurant_id
      AND (
        v_assignment.station_type <> 'floor'
        OR queue.floor_label=ANY(public.store_assignment_area_codes_v1(v_assignment))
      )
      AND CASE v_assignment.station_type
        WHEN 'kitchen' THEN
          EXISTS (
            SELECT 1 FROM public.emergency_fulfillment_items item
            WHERE item.queue_id = queue.id AND item.is_cancelled = false
          )
          AND NOT EXISTS (
            SELECT 1 FROM public.emergency_fulfillment_items item
            WHERE item.queue_id = queue.id AND item.is_cancelled = false
              AND item.kitchen_done_quantity < item.ordered_quantity
          )
        WHEN 'tray' THEN
          EXISTS (
            SELECT 1 FROM public.emergency_fulfillment_items item
            WHERE item.queue_id = queue.id AND item.is_cancelled = false
          )
          AND NOT EXISTS (
            SELECT 1 FROM public.emergency_fulfillment_items item
            WHERE item.queue_id = queue.id AND item.is_cancelled = false
              AND (
                item.tray_received_quantity < item.ordered_quantity
                OR item.tray_dispatched_quantity < item.ordered_quantity
              )
          )
        ELSE
          (
            EXISTS (
              SELECT 1 FROM public.emergency_fulfillment_items item
              WHERE item.queue_id = queue.id AND item.is_cancelled = false
            )
            OR EXISTS (
              SELECT 1 FROM public.emergency_floor_direct_items item
              WHERE item.queue_id = queue.id AND item.is_cancelled = false
            )
          )
          AND NOT EXISTS (
            SELECT 1 FROM public.emergency_fulfillment_items item
            WHERE item.queue_id = queue.id AND item.is_cancelled = false
              AND item.floor_served_quantity < item.ordered_quantity
          )
          AND NOT EXISTS (
            SELECT 1 FROM public.emergency_floor_direct_items item
            WHERE item.queue_id = queue.id AND item.is_cancelled = false
              AND item.floor_served_quantity < item.ordered_quantity
          )
      END
  ) completed_rows;

  RETURN v_orders;
END;
$$;



CREATE FUNCTION kds_direct_floor_store_ids() RETURNS uuid[] LANGUAGE sql AS $$ SELECT ARRAY['273b057e-3b69-46e3-93c1-6194c2802849'::uuid] $$;

CREATE OR REPLACE FUNCTION "public"."emergency_add_order_batch_timings"("p_orders" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
  SELECT COALESCE(jsonb_agg(
    order_row.raw || jsonb_build_object(
      'items', COALESCE((
        SELECT jsonb_agg(
          item_row.raw || jsonb_strip_nulls(jsonb_build_object(
            'batch_received_at', order_item.created_at,
            'kitchen_first_done_at', event_times.kitchen_first_done_at,
            'kitchen_last_done_at', event_times.kitchen_last_done_at,
            'tray_first_dispatched_at', event_times.tray_first_dispatched_at,
            'tray_last_dispatched_at', event_times.tray_last_dispatched_at,
            'floor_first_served_at', event_times.floor_first_served_at,
            'floor_last_served_at', event_times.floor_last_served_at
          ))
          ORDER BY item_row.ord
        )
        FROM jsonb_array_elements(COALESCE(order_row.raw->'items', '[]'::jsonb))
          WITH ORDINALITY item_row(raw, ord)
        LEFT JOIN public.order_items order_item
          ON order_item.id = CASE
            WHEN item_row.raw->>'order_item_id' ~*
              '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            THEN (item_row.raw->>'order_item_id')::uuid
            ELSE NULL
          END
        LEFT JOIN LATERAL (
          SELECT
            min(event.created_at) FILTER (
              WHERE event.stage = 'kitchen_done'
            ) AS kitchen_first_done_at,
            max(event.created_at) FILTER (
              WHERE event.stage = 'kitchen_done'
            ) AS kitchen_last_done_at,
            min(event.created_at) FILTER (
              WHERE (event.stage = 'tray_dispatched' OR (COALESCE(event.restaurant_id = ANY((SELECT public.kds_direct_floor_store_ids())::uuid[]), false) AND event.stage = 'kitchen_done'))
            ) AS tray_first_dispatched_at,
            max(event.created_at) FILTER (
              WHERE (event.stage = 'tray_dispatched' OR (COALESCE(event.restaurant_id = ANY((SELECT public.kds_direct_floor_store_ids())::uuid[]), false) AND event.stage = 'kitchen_done'))
            ) AS tray_last_dispatched_at,
            min(event.created_at) FILTER (
              WHERE event.stage = 'floor_served'
            ) AS floor_first_served_at,
            max(event.created_at) FILTER (
              WHERE event.stage = 'floor_served'
            ) AS floor_last_served_at
          FROM public.emergency_fulfillment_events event
          WHERE event.delta > 0
            AND (
              (
                item_row.raw->>'source_kind' = 'combo_component'
                AND event.combo_component_item_id = CASE
                  WHEN item_row.raw->>'id' ~*
                    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  THEN (item_row.raw->>'id')::uuid
                  ELSE NULL
                END
              )
              OR (
                item_row.raw->>'fulfillment_route' = 'floor_direct'
                AND event.floor_direct_item_id = CASE
                  WHEN item_row.raw->>'id' ~*
                    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                  THEN (item_row.raw->>'id')::uuid
                  ELSE NULL
                END
              )
              OR (
                COALESCE(item_row.raw->>'source_kind', 'order_item')
                  <> 'combo_component'
                AND COALESCE(item_row.raw->>'fulfillment_route',
                  'kitchen_tray_floor') <> 'floor_direct'
                AND event.order_item_id = order_item.id
                AND event.combo_component_item_id IS NULL
                AND event.floor_direct_item_id IS NULL
              )
            )
        ) event_times ON true
      ), '[]'::jsonb)
    )
    ORDER BY order_row.ord
  ), '[]'::jsonb)
  FROM jsonb_array_elements(COALESCE(p_orders, '[]'::jsonb))
    WITH ORDINALITY order_row(raw, ord);
$_$;



CREATE OR REPLACE FUNCTION "public"."store_assignment_area_codes_v1"("a" "public"."emergency_station_assignments") RETURNS "text"[]
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'pg_catalog'
    AS $$ SELECT coalesce(nullif(a.service_area_codes,'{}'::text[]),ARRAY[a.floor_label]); $$;





CREATE OR REPLACE FUNCTION "public"."emergency_localize_paperless_orders"("p_orders" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
 WITH orders AS MATERIALIZED (
  SELECT value,ordinality ord FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_orders)='array' THEN p_orders ELSE '[]'::jsonb END) WITH ORDINALITY
 ), items AS MATERIALIZED (
  SELECT o.ord,i.ordinality item_ord,i.value item FROM orders o
  CROSS JOIN LATERAL jsonb_array_elements(coalesce(o.value->'items','[]')) WITH ORDINALITY i(value,ordinality)
 ), components AS (
  SELECT i.ord,i.item_ord,jsonb_agg(c.value||jsonb_build_object('name_vi',coalesce(nullif(btrim(m.paperless_name_vi),''),nullif(c.value->>'name_vi',''),'Món')) ORDER BY c.ordinality) value
  FROM items i CROSS JOIN LATERAL jsonb_array_elements(coalesce(i.item->'combo_components','[]')) WITH ORDINALITY c(value,ordinality)
  LEFT JOIN public.menu_items m ON m.id=nullif(c.value->>'menu_item_id','')::uuid GROUP BY i.ord,i.item_ord
 ), localized AS (
  SELECT i.ord,i.item_ord,i.item||jsonb_build_object('name_vi',coalesce(nullif(btrim(m.paperless_name_vi),''),nullif(i.item->>'name_vi',''),'Món'),
   'combo_components',coalesce(c.value,'[]')) value
  FROM items i LEFT JOIN public.order_items oi ON i.item->>'fulfillment_route' IS DISTINCT FROM 'floor_direct' AND oi.id=nullif(i.item->>'order_item_id','')::uuid
  LEFT JOIN public.emergency_floor_direct_items d ON i.item->>'fulfillment_route'='floor_direct' AND d.id=nullif(i.item->>'id','')::uuid
  LEFT JOIN public.menu_items m ON m.id=CASE WHEN i.item->>'fulfillment_route'='floor_direct' THEN d.component_menu_item_id ELSE oi.menu_item_id END
  LEFT JOIN components c ON c.ord=i.ord AND c.item_ord=i.item_ord
 ), grouped AS (SELECT ord,jsonb_agg(value ORDER BY item_ord) items FROM localized GROUP BY ord)
 SELECT coalesce(jsonb_agg(jsonb_set(o.value,'{items}',coalesce(g.items,'[]'),true) ORDER BY o.ord),'[]') FROM orders o LEFT JOIN grouped g USING(ord);
$$;



CREATE OR REPLACE FUNCTION "public"."emergency_add_combo_component_progress"("p_orders" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
 WITH orders AS MATERIALIZED (
  SELECT value,ordinality ord FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_orders)='array' THEN p_orders ELSE '[]'::jsonb END) WITH ORDINALITY
 ), queues AS MATERIALIZED (SELECT DISTINCT nullif(value->>'queue_id','')::uuid id FROM orders),
 components AS (
  SELECT c.queue_id,jsonb_agg(jsonb_build_object('id',c.id,'order_item_id',c.order_item_id,'line_key',c.line_key,'source_kind','combo_component',
   'fulfillment_route','kitchen_tray_floor','name_ko',c.name_ko,'name_vi',coalesce(nullif(btrim(m.paperless_name_vi),''),c.name_vi,'Món'),'name_en',c.name_en,
   'combo_components','[]'::jsonb,'ordered_quantity',c.ordered_quantity,'kitchen_done_quantity',c.kitchen_done_quantity,
   'tray_received_quantity',c.tray_received_quantity,'tray_dispatched_quantity',c.tray_dispatched_quantity,'floor_served_quantity',c.floor_served_quantity,'needs_review',c.needs_review)
   ORDER BY c.created_at,c.order_item_id,c.line_key) items
  FROM queues q JOIN public.emergency_combo_component_items c ON c.queue_id=q.id AND NOT c.is_cancelled
  LEFT JOIN public.menu_items m ON m.id=c.component_menu_item_id GROUP BY c.queue_id
 )
 SELECT coalesce(jsonb_agg(jsonb_set(o.value,'{items}',coalesce(o.value->'items','[]')||coalesce(c.items,'[]'),true) ORDER BY o.ord),'[]')
 FROM orders o LEFT JOIN components c ON c.queue_id=nullif(o.value->>'queue_id','')::uuid;
$$;



CREATE FUNCTION emergency_add_takeout_flags(p jsonb) RETURNS jsonb LANGUAGE sql AS $$ SELECT p $$;

CREATE FUNCTION emergency_enrich_start_ready_orders(p jsonb) RETURNS jsonb LANGUAGE sql AS $$ SELECT p $$;

CREATE FUNCTION emergency_add_order_sales_channels(p jsonb,station text) RETURNS jsonb LANGUAGE sql AS $$ SELECT p $$;

-- Non-target snapshot/workflow adapters are exercised against the complete
-- production schema in the separate load/parity run, not reimplemented here.
CREATE FUNCTION get_emergency_station_snapshot() RETURNS jsonb LANGUAGE sql AS $$ SELECT '{}'::jsonb $$;
CREATE FUNCTION get_emergency_station_today_completed() RETURNS jsonb LANGUAGE sql AS $$ SELECT '[]'::jsonb $$;
