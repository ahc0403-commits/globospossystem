-- 251: Photo Objet — stores, staff, sales, inventory, attendance, storage, views
-- All tables in public schema (office DB).
-- Auth checks via office_user_profiles, NOT POS users table.

-- ============================================================
-- 1. Photo Objet stores (7 fixed)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.photo_objet_stores (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE,
  location TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT now()
);
INSERT INTO public.photo_objet_stores (name, location) VALUES
  ('D7', 'Ho Chi Minh City - District 7'),
  ('BIEN HOA', 'Bien Hoa City'),
  ('THAO DIEN', 'Ho Chi Minh City - Thao Dien'),
  ('QUANG TRUNG', 'Ho Chi Minh City - Quang Trung'),
  ('DI AN', 'Binh Duong - Di An'),
  ('LONG THANH', 'Dong Nai - Long Thanh'),
  ('NOW ZONE', 'Ho Chi Minh City - Now Zone')
ON CONFLICT (name) DO NOTHING;
-- ============================================================
-- 2. Photo Objet staff (per-store employee list)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.photo_objet_staff (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id UUID NOT NULL REFERENCES public.photo_objet_stores(id) ON DELETE CASCADE,
  full_name TEXT NOT NULL,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(store_id, full_name)
);
CREATE INDEX IF NOT EXISTS idx_po_staff_store ON public.photo_objet_staff(store_id, is_active);
-- ============================================================
-- 3. Daily sales from moersinc.com
-- ============================================================
CREATE TABLE IF NOT EXISTS public.photo_objet_sales (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id UUID NOT NULL REFERENCES public.photo_objet_stores(id),
  sale_date DATE NOT NULL,
  device_name TEXT NOT NULL,
  device_id TEXT,
  gross_sales BIGINT DEFAULT 0,
  service_amount BIGINT DEFAULT 0,
  transaction_count INTEGER DEFAULT 0,
  service_count INTEGER DEFAULT 0,
  raw_rows JSONB,
  pulled_at TIMESTAMPTZ DEFAULT now(),
  pull_source TEXT DEFAULT 'scheduled',
  UNIQUE(store_id, sale_date, device_name)
);
CREATE INDEX IF NOT EXISTS idx_pos_store_date ON public.photo_objet_sales(store_id, sale_date);
-- ============================================================
-- 4. Inventory (9 fixed item types)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.photo_objet_inventory (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id UUID NOT NULL REFERENCES public.photo_objet_stores(id),
  item_type TEXT NOT NULL CHECK (item_type IN (
    'film','dry_tissue','wet_tissue','pen',
    'small_sleeve','large_sleeve','sticker','tape','garbage_bag'
  )),
  quantity INTEGER NOT NULL DEFAULT 0,
  note TEXT,
  updated_at TIMESTAMPTZ DEFAULT now(),
  updated_by UUID,
  UNIQUE(store_id, item_type)
);
-- ============================================================
-- 5. Attendance (photo-based, with staff_id)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.photo_objet_attendance (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id UUID NOT NULL REFERENCES public.photo_objet_stores(id),
  staff_id UUID REFERENCES public.photo_objet_staff(id),
  staff_name TEXT NOT NULL,
  check_type TEXT NOT NULL CHECK (check_type IN ('clock_in', 'clock_out')),
  photo_url TEXT,
  checked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  note TEXT,
  created_by UUID
);
CREATE INDEX IF NOT EXISTS idx_poa_store_date ON public.photo_objet_attendance(store_id, checked_at);
-- ============================================================
-- 6. Helper functions (based on office_user_profiles)
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_photo_objet_master()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS(
    SELECT 1 FROM public.office_user_profiles
    WHERE auth_id = auth.uid()
      AND account_level IN ('super_admin', 'platform_admin', 'office_admin', 'photo_objet_master')
  );
$$;
CREATE OR REPLACE FUNCTION public.get_photo_objet_store_id()
RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT (scope_ids[1])::uuid
  FROM public.office_user_profiles
  WHERE auth_id = auth.uid()
    AND scope_type = 'po_store'
  LIMIT 1;
$$;
-- ============================================================
-- 7. RLS policies
-- ============================================================
ALTER TABLE public.photo_objet_stores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_objet_sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_objet_inventory ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_objet_attendance ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.photo_objet_staff ENABLE ROW LEVEL SECURITY;
-- Stores: all authenticated can read
CREATE POLICY "po_stores_read" ON public.photo_objet_stores
  FOR SELECT TO authenticated USING (true);
-- Sales
CREATE POLICY "po_sales_master" ON public.photo_objet_sales
  FOR ALL TO authenticated USING (is_photo_objet_master());
CREATE POLICY "po_sales_store" ON public.photo_objet_sales
  FOR SELECT TO authenticated
  USING (store_id = get_photo_objet_store_id());
-- Inventory
CREATE POLICY "po_inventory_master" ON public.photo_objet_inventory
  FOR ALL TO authenticated USING (is_photo_objet_master());
CREATE POLICY "po_inventory_store" ON public.photo_objet_inventory
  FOR ALL TO authenticated
  USING (store_id = get_photo_objet_store_id());
-- Attendance
CREATE POLICY "po_attendance_master" ON public.photo_objet_attendance
  FOR ALL TO authenticated USING (is_photo_objet_master());
CREATE POLICY "po_attendance_store" ON public.photo_objet_attendance
  FOR ALL TO authenticated
  USING (store_id = get_photo_objet_store_id());
-- Staff
CREATE POLICY "po_staff_master" ON public.photo_objet_staff
  FOR ALL TO authenticated USING (is_photo_objet_master());
CREATE POLICY "po_staff_store_read" ON public.photo_objet_staff
  FOR SELECT TO authenticated
  USING (store_id = get_photo_objet_store_id());
CREATE POLICY "po_staff_store_write" ON public.photo_objet_staff
  FOR ALL TO authenticated
  USING (store_id = get_photo_objet_store_id());
-- ============================================================
-- 8. Storage bucket for attendance photos
-- ============================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'po-attendance', 'po-attendance', false,
  5242880,
  ARRAY['image/jpeg', 'image/png']
) ON CONFLICT (id) DO NOTHING;
CREATE POLICY "po_attendance_upload" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'po-attendance');
CREATE POLICY "po_attendance_read" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'po-attendance');
-- ============================================================
-- 9. Dashboard view: daily summary per store
-- ============================================================
CREATE OR REPLACE VIEW public.v_photo_objet_daily_summary AS
SELECT
  pos.store_id,
  s.name AS store_name,
  pos.sale_date,
  SUM(pos.gross_sales) AS total_gross_sales,
  SUM(pos.transaction_count) AS total_transactions,
  SUM(pos.service_amount) AS total_service_amount,
  COUNT(DISTINCT pos.device_name) AS active_machines,
  MAX(pos.pulled_at) AS last_pulled_at
FROM public.photo_objet_sales pos
JOIN public.photo_objet_stores s ON s.id = pos.store_id
GROUP BY pos.store_id, s.name, pos.sale_date;
GRANT SELECT ON public.v_photo_objet_daily_summary TO authenticated;
