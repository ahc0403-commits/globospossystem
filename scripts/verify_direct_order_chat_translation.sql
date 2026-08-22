\set ON_ERROR_STOP on

-- Production-only, read-only verification for direct-order chat translation.
-- This script intentionally does not create, update, or delete application data.
DO $verify$
DECLARE
  v_function regprocedure;
  v_function_name text;
  v_translation_constraint text;
BEGIN
  IF to_regclass('public.direct_order_messages') IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CHAT_TRANSLATION_TABLE_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (VALUES
      ('source_locale', 'text', 'YES'),
      ('body_ko', 'text', 'YES'),
      ('body_vi', 'text', 'YES'),
      ('body_en', 'text', 'YES'),
      ('translation_status', 'text', 'NO'),
      ('translation_provider', 'text', 'YES')
    ) AS required_column(column_name, data_type, is_nullable)
    WHERE NOT EXISTS (
      SELECT 1
      FROM information_schema.columns column_row
      WHERE column_row.table_schema = 'public'
        AND column_row.table_name = 'direct_order_messages'
        AND column_row.column_name = required_column.column_name
        AND column_row.data_type = required_column.data_type
        AND column_row.is_nullable = required_column.is_nullable
    )
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CHAT_TRANSLATION_COLUMN_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns column_row
    WHERE column_row.table_schema = 'public'
      AND column_row.table_name = 'direct_order_messages'
      AND column_row.column_name = 'translation_status'
      AND column_row.column_default = '''not_requested''::text'
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CHAT_TRANSLATION_DEFAULT_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (VALUES
      ('direct_order_messages_source_locale_valid'),
      ('direct_order_messages_translation_status_valid'),
      ('direct_order_messages_translations_valid')
    ) AS required_constraint(constraint_name)
    WHERE NOT EXISTS (
      SELECT 1
      FROM pg_constraint constraint_row
      WHERE constraint_row.conrelid = 'public.direct_order_messages'::regclass
        AND constraint_row.conname = required_constraint.constraint_name
        AND constraint_row.contype = 'c'
        AND constraint_row.convalidated
    )
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CHAT_TRANSLATION_CONSTRAINT_INVALID';
  END IF;

  SELECT lower(pg_get_constraintdef(constraint_row.oid))
  INTO v_translation_constraint
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid = 'public.direct_order_messages'::regclass
    AND constraint_row.conname = 'direct_order_messages_translations_valid';
  IF v_translation_constraint NOT LIKE '%source_locale is not null%'
     OR v_translation_constraint NOT LIKE '%body_ko is not null%'
     OR v_translation_constraint NOT LIKE '%body_vi is not null%'
     OR v_translation_constraint NOT LIKE '%body_en is not null%'
     OR v_translation_constraint NOT LIKE '%translation_provider is not null%'
     OR v_translation_constraint NOT LIKE '%google_cloud_translation_v2%' THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CHAT_TRANSLATION_ATOMICITY_INVALID';
  END IF;

  FOR v_function_name IN
    SELECT unnest(ARRAY[
      'public.direct_order_public_message_translated(uuid,text,uuid,text,text,text,text,text)',
      'public.direct_order_staff_message_translated(uuid,uuid,uuid,text,text,text,text,text)',
      'public.direct_order_public_message_translations(uuid,text,uuid,text,uuid[])'
    ])
  LOOP
    v_function := to_regprocedure(v_function_name);
    IF v_function IS NULL THEN
      RAISE EXCEPTION 'DIRECT_ORDER_CHAT_TRANSLATION_RPC_MISSING:%',
        v_function_name;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM pg_proc procedure_row
      WHERE procedure_row.oid = v_function
        AND procedure_row.prosecdef
        AND EXISTS (
          SELECT 1
          FROM unnest(COALESCE(procedure_row.proconfig, ARRAY[]::text[]))
            AS config(setting)
          WHERE lower(replace(config.setting, ' ', '')) IN (
            'search_path=public,pg_catalog',
            'search_path=public,auth,pg_catalog'
          )
        )
    )
       OR has_function_privilege('anon', v_function, 'EXECUTE')
       OR has_function_privilege('authenticated', v_function, 'EXECUTE')
       OR NOT has_function_privilege('service_role', v_function, 'EXECUTE') THEN
      RAISE EXCEPTION 'DIRECT_ORDER_CHAT_TRANSLATION_RPC_SECURITY_INVALID:%',
        v_function_name;
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1
    FROM public.direct_order_messages message_row
    WHERE message_row.translation_status NOT IN ('not_requested', 'complete')
       OR (
         message_row.translation_status = 'not_requested'
         AND (
           message_row.source_locale IS NOT NULL
           OR message_row.body_ko IS NOT NULL
           OR message_row.body_vi IS NOT NULL
           OR message_row.body_en IS NOT NULL
           OR message_row.translation_provider IS NOT NULL
         )
       )
       OR (
         message_row.translation_status = 'complete'
         AND (
           message_row.message_type <> 'text'
           OR message_row.source_locale IS NULL
           OR message_row.source_locale NOT IN ('ko', 'vi', 'en')
           OR message_row.body_ko IS NULL
           OR char_length(message_row.body_ko) NOT BETWEEN 1 AND 6000
           OR message_row.body_vi IS NULL
           OR char_length(message_row.body_vi) NOT BETWEEN 1 AND 6000
           OR message_row.body_en IS NULL
           OR char_length(message_row.body_en) NOT BETWEEN 1 AND 6000
           OR message_row.translation_provider IS NULL
           OR message_row.translation_provider
             <> 'google_cloud_translation_v2'
           OR CASE message_row.source_locale
             WHEN 'ko' THEN message_row.body_ko IS DISTINCT FROM message_row.body
             WHEN 'vi' THEN message_row.body_vi IS DISTINCT FROM message_row.body
             WHEN 'en' THEN message_row.body_en IS DISTINCT FROM message_row.body
             ELSE true
           END
         )
       )
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CHAT_TRANSLATION_DATA_INVALID';
  END IF;
END;
$verify$;

SELECT 'DIRECT_ORDER_CHAT_TRANSLATION_VERIFY_PASS' AS result;
