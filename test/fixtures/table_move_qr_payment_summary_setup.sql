-- Additional fixture schema for the latest workflow and QR function definitions.
ALTER TABLE restaurants ADD COLUMN is_active boolean DEFAULT true;
ALTER TABLE order_items ADD COLUMN is_takeout boolean DEFAULT false;
CREATE TABLE leftover_packaging_requests(order_id uuid,status text);
ALTER TABLE order_items DROP CONSTRAINT order_items_wet_tissue_charge_check;
ALTER TABLE order_items ADD CONSTRAINT order_items_wet_tissue_charge_check CHECK(item_type<>'wet_tissue_charge' OR vat_rate=8);
ALTER TABLE orders ADD COLUMN created_at timestamptz DEFAULT now(),ADD COLUMN operating_release_id uuid,ADD COLUMN operational_closed_at timestamptz;
CREATE FUNCTION table_order_is_current(o public.orders) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT o.operational_closed_at IS NULL $$;
CREATE TABLE table_qr_tokens(token text,restaurant_id uuid,table_id uuid,is_active boolean DEFAULT true);
CREATE TABLE store_preparation_tasks(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid,release_id uuid,order_id uuid,order_item_id uuid,source_kind text,source_id uuid,menu_item_id uuid,ticket_id uuid,created_at timestamptz DEFAULT now());
CREATE TABLE store_preparation_steps(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),restaurant_id uuid,task_id uuid,station_id uuid,position int,started int DEFAULT 0,done int DEFAULT 0,revision int DEFAULT 0,started_at timestamptz,done_at timestamptz,updated_by uuid);
CREATE FUNCTION store_workflow_notify(uuid) RETURNS void LANGUAGE sql AS $$ SELECT NULL::void $$;
CREATE FUNCTION qr_get_active_order(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r jsonb; BEGIN
 r:=public.qr_get_active_order_pre_display_reset(p_token);
 RETURN r||jsonb_build_object('order_id',(SELECT id FROM orders o JOIN table_qr_tokens q ON q.restaurant_id=o.restaurant_id AND q.table_id=o.table_id WHERE q.token=p_token AND o.status IN ('pending','confirmed','serving') ORDER BY o.created_at DESC LIMIT 1));
END $$;
REVOKE ALL ON FUNCTION qr_get_active_order(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION qr_get_active_order(text) TO anon,authenticated;
-- Narrow fixture projection used by the real statement reconciliation trigger.
CREATE VIEW store_preparation_sources AS
 SELECT id source_id,'base'::text source_kind,ordered_quantity-excused_quantity quantity,is_cancelled OR needs_review blocked FROM emergency_fulfillment_items
 UNION ALL SELECT id,'combo_component',ordered_quantity-excused_quantity,is_cancelled OR needs_review FROM emergency_combo_component_items
 UNION ALL SELECT id,'floor_direct',ordered_quantity-excused_quantity,is_cancelled OR needs_review FROM emergency_floor_direct_items;
