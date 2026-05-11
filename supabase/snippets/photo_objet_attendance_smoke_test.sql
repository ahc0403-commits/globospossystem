CREATE TEMP TABLE photo_objet_attendance_seed (
  store_id uuid PRIMARY KEY,
  store_name text NOT NULL,
  email text NOT NULL,
  full_name text NOT NULL,
  role text NOT NULL DEFAULT 'waiter'
) ON COMMIT DROP;

INSERT INTO photo_objet_attendance_seed (store_id, store_name, email, full_name, role)
VALUES
  (
    '77000000-0000-0000-0000-000000000101',
    'PHOTO OBJET D7',
    'photoobjet.attendance.d7@globosvn.test',
    'PHOTO OBJET D7 Attendance',
    'waiter'
  ),
  (
    '77000000-0000-0000-0000-000000000102',
    'PHOTO OBJET BIEN HOA',
    'photoobjet.attendance.bienhoa@globosvn.test',
    'PHOTO OBJET BIEN HOA Attendance',
    'waiter'
  ),
  (
    '77000000-0000-0000-0000-000000000103',
    'PHOTO OBJET DI AN',
    'photoobjet.attendance.dian@globosvn.test',
    'PHOTO OBJET DI AN Attendance',
    'waiter'
  ),
  (
    '77000000-0000-0000-0000-000000000104',
    'PHOTO OBJET LONG THANH',
    'photoobjet.attendance.longthanh@globosvn.test',
    'PHOTO OBJET LONG THANH Attendance',
    'waiter'
  ),
  (
    '77000000-0000-0000-0000-000000000105',
    'PHOTO OBJET THAO DIEN',
    'photoobjet.attendance.thaodien@globosvn.test',
    'PHOTO OBJET THAO DIEN Attendance',
    'waiter'
  ),
  (
    '77000000-0000-0000-0000-000000000106',
    'PHOTO OBJET QUANG TRUNG',
    'photoobjet.attendance.quangtrung@globosvn.test',
    'PHOTO OBJET QUANG TRUNG Attendance',
    'waiter'
  ),
  (
    '77000000-0000-0000-0000-000000000107',
    'PHOTO OBJET NOW ZONE',
    'photoobjet.attendance.nowzone@globosvn.test',
    'PHOTO OBJET NOW ZONE Attendance',
    'waiter'
  );

CREATE TEMP TABLE photo_objet_attendance_users (
  store_id uuid PRIMARY KEY,
  store_name text NOT NULL,
  email text NOT NULL,
  full_name text NOT NULL,
  auth_user_id uuid NOT NULL,
  public_user_id uuid NOT NULL
) ON COMMIT DROP;

DO $$
DECLARE
  v_super_admin_user_id constant uuid := 'ebf1bb72-9e2a-4348-9597-6c4f5efb5400';
  v_brand_id constant uuid := '77000000-0000-0000-0000-000000000001';
  v_password constant text := 'PhotoObjet123!';
  v_instance_id constant uuid := '00000000-0000-0000-0000-000000000000';
  v_seed record;
  v_auth_user_id uuid;
  v_public_user_id uuid;
BEGIN
  FOR v_seed IN
    SELECT *
    FROM photo_objet_attendance_seed
    ORDER BY store_name
  LOOP
    SELECT u.id
    INTO v_auth_user_id
    FROM auth.users u
    WHERE lower(u.email) = lower(v_seed.email)
      AND u.deleted_at IS NULL
    LIMIT 1;

    IF v_auth_user_id IS NULL THEN
      v_auth_user_id := gen_random_uuid();

      INSERT INTO auth.users (
        instance_id,
        id,
        aud,
        role,
        email,
        encrypted_password,
        email_confirmed_at,
        raw_app_meta_data,
        raw_user_meta_data,
        created_at,
        updated_at,
        confirmation_token,
        email_change,
        email_change_token_new,
        recovery_token
      )
      VALUES (
        v_instance_id,
        v_auth_user_id,
        'authenticated',
        'authenticated',
        lower(v_seed.email),
        crypt(v_password, gen_salt('bf')),
        now(),
        jsonb_build_object('provider', 'email', 'providers', ARRAY['email']),
        jsonb_build_object('display_name', v_seed.full_name, 'full_name', v_seed.full_name),
        now(),
        now(),
        '',
        '',
        '',
        ''
      );
    ELSE
      UPDATE auth.users
      SET
        email = lower(v_seed.email),
        encrypted_password = crypt(v_password, gen_salt('bf')),
        email_confirmed_at = COALESCE(email_confirmed_at, now()),
        raw_app_meta_data = jsonb_build_object('provider', 'email', 'providers', ARRAY['email']),
        raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) ||
          jsonb_build_object('display_name', v_seed.full_name, 'full_name', v_seed.full_name),
        updated_at = now(),
        deleted_at = NULL
      WHERE id = v_auth_user_id;
    END IF;

    INSERT INTO auth.identities (
      id,
      user_id,
      provider_id,
      identity_data,
      provider,
      last_sign_in_at,
      created_at,
      updated_at
    )
    SELECT
      gen_random_uuid(),
      v_auth_user_id,
      v_auth_user_id::text,
      jsonb_build_object(
        'sub', v_auth_user_id::text,
        'email', lower(v_seed.email),
        'email_verified', true
      ),
      'email',
      now(),
      now(),
      now()
    WHERE NOT EXISTS (
      SELECT 1
      FROM auth.identities i
      WHERE i.user_id = v_auth_user_id
        AND i.provider = 'email'
    );

    SELECT u.id
    INTO v_public_user_id
    FROM public.users u
    WHERE u.auth_id = v_auth_user_id
    LIMIT 1;

    IF v_public_user_id IS NULL THEN
      INSERT INTO public.users (
        auth_id,
        restaurant_id,
        brand_id,
        primary_store_id,
        role,
        full_name,
        is_active
      )
      VALUES (
        v_auth_user_id,
        v_seed.store_id,
        v_brand_id,
        v_seed.store_id,
        v_seed.role,
        v_seed.full_name,
        true
      )
      RETURNING id INTO v_public_user_id;
    ELSE
      UPDATE public.users
      SET
        restaurant_id = v_seed.store_id,
        brand_id = v_brand_id,
        primary_store_id = v_seed.store_id,
        role = v_seed.role,
        full_name = v_seed.full_name,
        is_active = true
      WHERE id = v_public_user_id;
    END IF;

    INSERT INTO public.user_store_access (
      user_id,
      store_id,
      is_primary,
      is_active,
      source_type,
      granted_by
    )
    VALUES (
      v_public_user_id,
      v_seed.store_id,
      true,
      true,
      'direct',
      v_super_admin_user_id
    )
    ON CONFLICT (user_id, store_id, source_type) DO UPDATE
    SET
      is_primary = true,
      is_active = true,
      granted_by = EXCLUDED.granted_by,
      updated_at = now();

    INSERT INTO photo_objet_attendance_users (
      store_id,
      store_name,
      email,
      full_name,
      auth_user_id,
      public_user_id
    )
    VALUES (
      v_seed.store_id,
      v_seed.store_name,
      v_seed.email,
      v_seed.full_name,
      v_auth_user_id,
      v_public_user_id
    );
  END LOOP;
END;
$$;

DELETE FROM public.attendance_logs
WHERE user_id IN (
  SELECT public_user_id
  FROM photo_objet_attendance_users
);

CREATE TEMP TABLE photo_objet_attendance_smoke_results (
  store_id uuid PRIMARY KEY,
  store_name text NOT NULL,
  email text NOT NULL,
  public_user_id uuid NOT NULL,
  auth_user_id uuid NOT NULL,
  directory_contains_user boolean NOT NULL,
  clock_in_log_id uuid,
  clock_out_log_id uuid,
  today_log_count bigint NOT NULL,
  recorded_types text[] NOT NULL
) ON COMMIT DROP;

DO $$
DECLARE
  v_super_admin_auth_id constant uuid := 'd65a610a-ec27-4d4e-9179-62bddc750f49';
  v_row record;
  v_directory_contains_user boolean;
  v_clock_in_log_id uuid;
  v_clock_out_log_id uuid;
  v_today_log_count bigint;
  v_recorded_types text[];
BEGIN
  FOR v_row IN
    SELECT *
    FROM photo_objet_attendance_users
    ORDER BY store_name
  LOOP
    PERFORM set_config('request.jwt.claim.sub', v_row.auth_user_id::text, true);

    SELECT EXISTS (
      SELECT 1
      FROM public.get_attendance_staff_directory(v_row.store_id)
      WHERE user_id = v_row.public_user_id
    )
    INTO v_directory_contains_user;

    SELECT attendance_log_id
    INTO v_clock_in_log_id
    FROM public.record_attendance_event(
      v_row.store_id,
      v_row.public_user_id,
      'clock_in',
      NULL,
      NULL
    )
    LIMIT 1;

    SELECT attendance_log_id
    INTO v_clock_out_log_id
    FROM public.record_attendance_event(
      v_row.store_id,
      v_row.public_user_id,
      'clock_out',
      NULL,
      NULL
    )
    LIMIT 1;

    PERFORM set_config('request.jwt.claim.sub', v_super_admin_auth_id::text, true);

    SELECT
      COUNT(*),
      COALESCE(array_agg(attendance_type ORDER BY logged_at ASC, created_at ASC), ARRAY[]::text[])
    INTO
      v_today_log_count,
      v_recorded_types
    FROM public.get_attendance_log_view(
      v_row.store_id,
      now() - interval '1 day',
      now() + interval '1 day',
      v_row.public_user_id
    );

    INSERT INTO photo_objet_attendance_smoke_results (
      store_id,
      store_name,
      email,
      public_user_id,
      auth_user_id,
      directory_contains_user,
      clock_in_log_id,
      clock_out_log_id,
      today_log_count,
      recorded_types
    )
    VALUES (
      v_row.store_id,
      v_row.store_name,
      v_row.email,
      v_row.public_user_id,
      v_row.auth_user_id,
      v_directory_contains_user,
      v_clock_in_log_id,
      v_clock_out_log_id,
      v_today_log_count,
      v_recorded_types
    );
  END LOOP;
END;
$$;

SELECT
  store_id,
  store_name,
  email,
  public_user_id,
  auth_user_id,
  directory_contains_user,
  clock_in_log_id,
  clock_out_log_id,
  today_log_count,
  recorded_types,
  (
    directory_contains_user
    AND clock_in_log_id IS NOT NULL
    AND clock_out_log_id IS NOT NULL
    AND today_log_count = 2
    AND recorded_types = ARRAY['clock_in', 'clock_out']
  ) AS smoke_passed
FROM photo_objet_attendance_smoke_results
ORDER BY store_name;
