DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.restaurants
    WHERE id='273b057e-3b69-46e3-93c1-6194c2802849' AND name='JeonGabok Binh Thanh' AND is_active) THEN
    RAISE EXCEPTION 'JEONGABOK_STORE_IDENTITY_CHANGED';
  END IF;
  IF EXISTS (SELECT 1 FROM public.emergency_order_queue q
    JOIN public.emergency_fulfillment_sessions s ON s.id=q.session_id AND s.status='active'
    WHERE q.restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849'
      AND (EXISTS (SELECT 1 FROM public.emergency_fulfillment_items i WHERE i.queue_id=q.id
        AND NOT i.is_cancelled AND i.floor_served_quantity<i.ordered_quantity-i.excused_quantity)
      OR EXISTS (SELECT 1 FROM public.emergency_floor_direct_items i WHERE i.queue_id=q.id
        AND NOT i.is_cancelled AND i.floor_served_quantity<i.ordered_quantity-i.excused_quantity))) THEN
    RAISE EXCEPTION 'JEONGABOK_CUTOVER_REQUIRES_DRAINED_ORDERS';
  END IF;
  IF EXISTS (SELECT 1 FROM public.leftover_packaging_requests
    WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849' AND status NOT IN ('completed','cancelled')) THEN
    RAISE EXCEPTION 'JEONGABOK_CUTOVER_REQUIRES_DRAINED_PACKAGING';
  END IF;
END;
$$;
SELECT 'JEONGABOK_KITCHEN_FLOOR_PREFLIGHT=PASS';
