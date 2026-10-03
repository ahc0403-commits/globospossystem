DO $$ BEGIN
 IF current_database()<>'codex_direct_photo' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF;
END $$;
ALTER TABLE public.emergency_fulfillment_items
 ADD COLUMN kitchen_started_quantity integer NOT NULL DEFAULT 0,
 ADD COLUMN excused_quantity integer NOT NULL DEFAULT 0;
UPDATE public.emergency_fulfillment_items SET kitchen_started_quantity=kitchen_done_quantity;
ALTER TABLE public.emergency_fulfillment_items
 ADD CONSTRAINT emergency_fulfillment_quantity_chain CHECK (
 floor_served_quantity >= 0 AND floor_served_quantity <= tray_dispatched_quantity
 AND tray_dispatched_quantity <= tray_received_quantity
 AND tray_received_quantity <= kitchen_done_quantity
 AND kitchen_done_quantity <= kitchen_started_quantity
 AND excused_quantity >= 0 AND kitchen_started_quantity + excused_quantity <= ordered_quantity);
