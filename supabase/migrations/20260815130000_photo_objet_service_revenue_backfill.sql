-- production-gate: self-verifying
BEGIN;

-- Moers gross sales include both ordinary sales and coin-service rows. The
-- collector stores the source classification in raw_type (and in raw_payload
-- for older rows), so rebuild the service subset without changing gross sales.
WITH classified_raw AS (
  SELECT
    raw.store_id,
    raw.sale_date,
    raw.device_name,
    raw.amount,
    regexp_replace(
      lower(
        btrim(
          coalesce(
            nullif(btrim(raw.raw_type), ''),
            raw.raw_payload #>> '{row,Type}',
            ''
          )
        )
      ),
      '[^a-z0-9]+',
      ' ',
      'g'
    ) AS normalized_type
  FROM public.photo_objet_sales_raw raw
),
service_totals AS (
  SELECT
    classified_raw.store_id,
    classified_raw.sale_date,
    classified_raw.device_name,
    coalesce(
      sum(classified_raw.amount) FILTER (
        WHERE classified_raw.amount > 0
          AND classified_raw.normalized_type ~ '(^| )(service|coin)( |$)'
      ),
      0
    )::bigint AS service_amount,
    count(*) FILTER (
      WHERE classified_raw.amount > 0
        AND classified_raw.normalized_type ~ '(^| )(service|coin)( |$)'
    )::integer AS service_count
  FROM classified_raw
  GROUP BY
    classified_raw.store_id,
    classified_raw.sale_date,
    classified_raw.device_name
)
UPDATE public.photo_objet_sales sales
SET
  service_amount = totals.service_amount,
  service_count = totals.service_count
FROM service_totals totals
WHERE sales.store_id = totals.store_id
  AND sales.sale_date = totals.sale_date
  AND sales.device_name = totals.device_name
  AND (
    sales.service_amount IS DISTINCT FROM totals.service_amount
    OR sales.service_count IS DISTINCT FROM totals.service_count
  );

DO $$
BEGIN
  IF EXISTS (
    WITH classified_raw AS (
      SELECT
        raw.store_id,
        raw.sale_date,
        raw.device_name,
        raw.amount,
        regexp_replace(
          lower(
            btrim(
              coalesce(
                nullif(btrim(raw.raw_type), ''),
                raw.raw_payload #>> '{row,Type}',
                ''
              )
            )
          ),
          '[^a-z0-9]+',
          ' ',
          'g'
        ) AS normalized_type
      FROM public.photo_objet_sales_raw raw
    ),
    service_totals AS (
      SELECT
        classified_raw.store_id,
        classified_raw.sale_date,
        classified_raw.device_name,
        coalesce(
          sum(classified_raw.amount) FILTER (
            WHERE classified_raw.amount > 0
              AND classified_raw.normalized_type ~ '(^| )(service|coin)( |$)'
          ),
          0
        )::bigint AS service_amount,
        count(*) FILTER (
          WHERE classified_raw.amount > 0
            AND classified_raw.normalized_type ~ '(^| )(service|coin)( |$)'
        )::integer AS service_count
      FROM classified_raw
      GROUP BY
        classified_raw.store_id,
        classified_raw.sale_date,
        classified_raw.device_name
    )
    SELECT 1
    FROM public.photo_objet_sales sales
    JOIN service_totals totals
      ON totals.store_id = sales.store_id
     AND totals.sale_date = sales.sale_date
     AND totals.device_name = sales.device_name
    WHERE sales.service_amount IS DISTINCT FROM totals.service_amount
       OR sales.service_count IS DISTINCT FROM totals.service_count
  ) THEN
    RAISE EXCEPTION 'Photo Objet service revenue backfill verification failed';
  END IF;
END;
$$;

COMMIT;
