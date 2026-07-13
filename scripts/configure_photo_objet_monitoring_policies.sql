\set ON_ERROR_STOP on

-- The fail-fast production runner supplies these non-secret values with psql
-- -v flags. An unset or malformed value aborts the surrounding transaction.

CREATE TEMP TABLE approved_photo_objet_monitoring_stores (
  deployment_key text PRIMARY KEY,
  store_id uuid NOT NULL UNIQUE
) ON COMMIT DROP;

CREATE TEMP TABLE photo_objet_monitoring_rollout (
  effective_from timestamptz NOT NULL
) ON COMMIT DROP;

INSERT INTO photo_objet_monitoring_rollout (effective_from)
VALUES (:'photo_policy_effective_from'::timestamptz);

INSERT INTO approved_photo_objet_monitoring_stores (deployment_key, store_id)
VALUES
  ('BIENHOA', :'photo_store_bienhoa'::uuid),
  ('DIAN', :'photo_store_dian'::uuid),
  ('LONGTHANH', :'photo_store_longthanh'::uuid),
  ('THAODIEN', :'photo_store_thaodien'::uuid),
  ('QUANGTRUNG', :'photo_store_quangtrung'::uuid),
  ('NOWZONE', :'photo_store_nowzone'::uuid);

DO $$
DECLARE v_invalid integer;
BEGIN
  SELECT count(*) INTO v_invalid
  FROM approved_photo_objet_monitoring_stores approved
  LEFT JOIN public.restaurants store ON store.id = approved.store_id
  WHERE store.id IS NULL OR store.is_active IS DISTINCT FROM true;
  IF v_invalid <> 0 THEN
    RAISE EXCEPTION 'PHOTO_MONITORING_APPROVED_STORE_INVALID: %', v_invalid;
  END IF;
END $$;

INSERT INTO public.photo_objet_monitoring_policies (
  store_id,
  effective_from,
  timezone,
  schedule_version,
  grace_minutes,
  final_slot_grace_minutes,
  is_enabled
)
SELECT
  approved.store_id,
  rollout.effective_from,
  'Asia/Ho_Chi_Minh',
  'hcm-hourly-v1',
  15,
  15,
  true
FROM approved_photo_objet_monitoring_stores approved
CROSS JOIN photo_objet_monitoring_rollout rollout
ON CONFLICT (store_id, effective_from) DO NOTHING;

DO $$
DECLARE
  v_effective_from timestamptz;
  v_invalid integer;
BEGIN
  SELECT effective_from INTO STRICT v_effective_from
  FROM photo_objet_monitoring_rollout;
  SELECT count(*) INTO v_invalid
  FROM approved_photo_objet_monitoring_stores approved
  LEFT JOIN public.photo_objet_monitoring_policies policy
    ON policy.store_id = approved.store_id
   AND policy.effective_from = v_effective_from
   AND policy.effective_to IS NULL
   AND policy.is_enabled = true
  WHERE policy.id IS NULL;
  IF v_invalid <> 0 THEN
    RAISE EXCEPTION 'PHOTO_MONITORING_POLICY_CONFIGURATION_FAILED: %', v_invalid;
  END IF;

  PERFORM public.photo_objet_ensure_expected_slots(
    (v_effective_from AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
    (v_effective_from AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
  );
END $$;

SELECT 'PHOTO_OBJET_MONITORING_POLICY_CONFIGURATION_PASS' AS result;
