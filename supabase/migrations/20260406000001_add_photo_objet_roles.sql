-- Add master_admin and photo_objet roles to POS users constraint
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE public.users ADD CONSTRAINT users_role_check
CHECK (role IN (
  'super_admin', 'master_admin',
  'admin', 'waiter', 'kitchen', 'cashier',
  'photo_objet_master', 'photo_objet_store_admin'
));
