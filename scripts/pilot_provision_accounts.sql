-- pilot_provision_accounts.sql
-- Gate 0 provisioning: minimum pilot staff accounts (Test Plan 2026-07-03).
-- Creates 5 accounts against the seed store from 20260402000001_seed_data.sql:
--   superadmin@globos.test  super_admin
--   admin@globos.test       admin
--   waiter@globos.test      waiter
--   kitchen@globos.test     kitchen
--   cashier@globos.test     cashier
-- Each account gets: auth.users row (confirmed), auth.identities row,
-- public.users profile, user_store_access (is_primary), refresh_user_claims.
--
-- Idempotent: existing emails are left untouched (reported via NOTICE).
-- Requires service-level access (local supabase db or service connection).
--
-- Usage (password is NEVER stored in this file):
--   psql "$DB_URL" -v pilot_password="$PILOT_SMOKE_PASSWORD" \
--        -f scripts/pilot_provision_accounts.sql
--
-- The same password is applied to all 5 accounts (matches the shared
-- PILOT_SMOKE_PASSWORD convention in integration_test).

\set ON_ERROR_STOP on

BEGIN;

-- psql variables do not interpolate inside dollar-quoted DO blocks;
-- pass the password through a transaction-local GUC instead.
SELECT set_config('pilot.password', :'pilot_password', true);

DO $provision$
DECLARE
  v_store_id uuid;
  v_password text := current_setting('pilot.password', true);
  v_auth_id uuid;
  v_user_id uuid;
  v_account record;
BEGIN
  IF v_password IS NULL OR length(v_password) < 8 THEN
    RAISE EXCEPTION 'pilot_password psql variable missing or too short (min 8 chars)';
  END IF;

  -- Seed store from 20260402000001_seed_data.sql; fall back to first active store.
  SELECT id INTO v_store_id
  FROM restaurants
  WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
  IF v_store_id IS NULL THEN
    SELECT id INTO v_store_id FROM restaurants WHERE is_active LIMIT 1;
  END IF;
  IF v_store_id IS NULL THEN
    RAISE EXCEPTION 'No restaurant found — run seed (20260402000001) first';
  END IF;

  FOR v_account IN
    SELECT * FROM (VALUES
      ('superadmin@globos.test', 'super_admin', 'Pilot Super Admin'),
      ('admin@globos.test',      'admin',       'Pilot Store Admin'),
      ('waiter@globos.test',     'waiter',      'Pilot Waiter'),
      ('kitchen@globos.test',    'kitchen',     'Pilot Kitchen'),
      ('cashier@globos.test',    'cashier',     'Pilot Cashier')
    ) AS t(email, staff_role, full_name)
  LOOP
    IF EXISTS (SELECT 1 FROM auth.users WHERE email = v_account.email) THEN
      RAISE NOTICE 'SKIP % — auth user already exists', v_account.email;
      SELECT id INTO v_auth_id FROM auth.users WHERE email = v_account.email;
    ELSE
      v_auth_id := gen_random_uuid();
      INSERT INTO auth.users (
        instance_id, id, aud, role, email, encrypted_password,
        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
        created_at, updated_at,
        confirmation_token, recovery_token, email_change, email_change_token_new
      ) VALUES (
        '00000000-0000-0000-0000-000000000000', v_auth_id,
        'authenticated', 'authenticated', v_account.email,
        crypt(v_password, gen_salt('bf')),
        now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
        now(), now(), '', '', '', ''
      );
      INSERT INTO auth.identities (
        id, user_id, provider_id, provider, identity_data,
        last_sign_in_at, created_at, updated_at
      ) VALUES (
        gen_random_uuid(), v_auth_id, v_auth_id::text, 'email',
        jsonb_build_object('sub', v_auth_id::text, 'email', v_account.email,
                           'email_verified', true),
        now(), now(), now()
      );
      RAISE NOTICE 'CREATED auth user %', v_account.email;
    END IF;

    -- POS profile
    SELECT id INTO v_user_id FROM public.users WHERE auth_id = v_auth_id;
    IF v_user_id IS NULL THEN
      INSERT INTO public.users (auth_id, restaurant_id, role, full_name, is_active)
      VALUES (v_auth_id, v_store_id, v_account.staff_role, v_account.full_name, true)
      RETURNING id INTO v_user_id;
      RAISE NOTICE 'CREATED profile % (role=%)', v_account.email, v_account.staff_role;
    ELSE
      RAISE NOTICE 'SKIP profile % — already exists', v_account.email;
    END IF;

    -- Store scope
    INSERT INTO public.user_store_access
      (user_id, store_id, is_primary, is_active, source_type)
    VALUES (v_user_id, v_store_id, true, true, 'direct')
    ON CONFLICT (user_id, store_id, source_type) DO UPDATE
      SET is_active = true, is_primary = true, updated_at = now();

    -- JWT claims (login gate contract P0-2 depends on this being populated)
    PERFORM public.refresh_user_claims(v_auth_id);
    RAISE NOTICE 'CLAIMS refreshed for %', v_account.email;
  END LOOP;
END;
$provision$;

-- Post-provision assertion: every pilot account must have non-empty
-- accessible_store_ids in app metadata (Gate 0 check 0.4). Fails the
-- transaction loudly instead of leaving half-provisioned accounts.
DO $verify$
DECLARE
  v_bad text;
BEGIN
  SELECT string_agg(u.email, ', ') INTO v_bad
  FROM auth.users u
  WHERE u.email IN (
    'superadmin@globos.test','admin@globos.test','waiter@globos.test',
    'kitchen@globos.test','cashier@globos.test'
  )
  AND (
    u.raw_app_meta_data->'accessible_store_ids' IS NULL
    OR jsonb_array_length(u.raw_app_meta_data->'accessible_store_ids') = 0
  );
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'CLAIMS EMPTY after provision for: % (C3 — refresh_user_claims did not populate)', v_bad;
  END IF;
  RAISE NOTICE 'Gate 0 provision verify PASS — all 5 accounts have store claims';
END;
$verify$;

COMMIT;
