-- Moers occasionally emits zero-amount rows alongside real sales. Preserve
-- those immutable source rows for audit, while the collector excludes them
-- from revenue, transaction counts, and invoice dispatch.

ALTER TABLE public.photo_objet_sales_raw
  DROP CONSTRAINT photo_objet_sales_raw_amount_check;

ALTER TABLE public.photo_objet_sales_raw
  ADD CONSTRAINT photo_objet_sales_raw_amount_check
  CHECK (amount >= 0);

COMMENT ON COLUMN public.photo_objet_sales_raw.amount IS
  'Immutable Moers row amount in VND. Zero is retained as a non-revenue audit row; negative values are invalid.';
