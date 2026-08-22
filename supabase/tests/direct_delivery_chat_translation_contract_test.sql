-- Direct-order translated chat contract. Disposable DB or rollback-only live run.
\set ON_ERROR_STOP on
BEGIN;
\ir fixtures/direct_delivery_test_fixture.sql

CREATE TEMP TABLE _direct_chat_translation_results (
  scenario text PRIMARY KEY,
  ok boolean NOT NULL,
  detail text
);

DO $contract$
DECLARE
  v_chat jsonb;
  v_message jsonb;
  v_translations jsonb;
  v_invalid_blocked boolean := false;
  v_null_translation_blocked boolean := false;
BEGIN
  v_chat := direct_delivery_test.create_request('awaiting_quote');
  v_message := public.direct_order_public_message_translated(
    (v_chat->>'session_id')::uuid,
    v_chat->>'secret_hash',
    (v_chat->>'request_id')::uuid,
    'Please call when you arrive.',
    'en',
    '도착하면 전화해 주세요.',
    'Vui lòng gọi khi đến.',
    'Please call when you arrive.'
  );
  v_translations := public.direct_order_public_message_translations(
    (v_chat->>'session_id')::uuid,
    v_chat->>'secret_hash',
    (v_chat->>'request_id')::uuid,
    'vi',
    ARRAY[(v_message->>'message_id')::uuid]
  );
  INSERT INTO _direct_chat_translation_results VALUES (
    'customer original and three viewer copies are atomic',
    EXISTS (
      SELECT 1 FROM public.direct_order_messages message
      WHERE message.id=(v_message->>'message_id')::uuid
        AND message.body='Please call when you arrive.'
        AND message.source_locale='en'
        AND message.body_ko='도착하면 전화해 주세요.'
        AND message.body_vi='Vui lòng gọi khi đến.'
        AND message.body_en=message.body
        AND message.translation_status='complete'
        AND message.translation_provider='google_cloud_translation_v2'
    ) AND v_translations->'translations'->0->>'body'=
      'Vui lòng gọi khi đến.',
    'the original remains immutable and customer reads the target locale'
  );

  v_message := public.direct_order_staff_message_translated(
    (v_chat->>'auth_id')::uuid,
    (v_chat->>'store_id')::uuid,
    (v_chat->>'request_id')::uuid,
    'Tài xế sẽ đến trong 10 phút.',
    'vi',
    '기사가 10분 안에 도착합니다.',
    'Tài xế sẽ đến trong 10 phút.',
    'The driver will arrive in 10 minutes.'
  );
  INSERT INTO _direct_chat_translation_results VALUES (
    'staff message is actor scoped and fully translated',
    EXISTS (
      SELECT 1 FROM public.direct_order_messages message
      WHERE message.id=(v_message->>'message_id')::uuid
        AND message.sender_type='cashier'
        AND message.sender_auth_id=(v_chat->>'auth_id')::uuid
        AND message.body='Tài xế sẽ đến trong 10 phút.'
        AND message.body_en='The driver will arrive in 10 minutes.'
        AND message.translation_status='complete'
    ),
    'only the trusted service function can persist generated translations'
  );

  BEGIN
    PERFORM public.direct_order_public_message_translated(
      (v_chat->>'session_id')::uuid,
      v_chat->>'secret_hash',
      (v_chat->>'request_id')::uuid,
      'original', 'en', '한국어', 'Tiếng Việt', 'changed source'
    );
  EXCEPTION WHEN OTHERS THEN
    v_invalid_blocked := SQLERRM LIKE '%DIRECT_ORDER_TRANSLATION_INVALID%';
  END;
  INSERT INTO _direct_chat_translation_results VALUES (
    'source translation mismatch is rejected before insert',
    v_invalid_blocked AND NOT EXISTS (
      SELECT 1 FROM public.direct_order_messages message
      WHERE message.request_id=(v_chat->>'request_id')::uuid
        AND message.body='original'
    ),
    'the selected source locale must exactly preserve the original body'
  );

  BEGIN
    INSERT INTO public.direct_order_messages(
      request_id, restaurant_id, sender_type, message_type, body,
      source_locale, body_en, translation_status, translation_provider
    ) VALUES (
      (v_chat->>'request_id')::uuid,
      (v_chat->>'store_id')::uuid,
      'customer',
      'text',
      'must remain atomic',
      'en',
      'must remain atomic',
      'complete',
      'google_cloud_translation_v2'
    );
  EXCEPTION WHEN check_violation THEN
    v_null_translation_blocked := true;
  END;
  INSERT INTO _direct_chat_translation_results VALUES (
    'complete translation cannot contain null viewer copies',
    v_null_translation_blocked,
    'all three viewer-language copies must be stored atomically'
  );

  INSERT INTO _direct_chat_translation_results VALUES (
    'browser roles cannot call trusted translation writers',
    NOT has_function_privilege(
      'anon',
      'public.direct_order_public_message_translated(uuid,text,uuid,text,text,text,text,text)',
      'EXECUTE'
    ) AND NOT has_function_privilege(
      'authenticated',
      'public.direct_order_staff_message_translated(uuid,uuid,uuid,text,text,text,text,text)',
      'EXECUTE'
    ),
    'generated translations cross only the server-side Edge boundary'
  );
END;
$contract$;

DO $assert$
DECLARE v_failures text;
BEGIN
  SELECT string_agg(scenario || ': ' || detail, E'\n' ORDER BY scenario)
  INTO v_failures
  FROM _direct_chat_translation_results WHERE NOT ok;
  IF v_failures IS NOT NULL THEN
    RAISE EXCEPTION E'DIRECT_DELIVERY_CHAT_TRANSLATION_FAILED:\n%', v_failures;
  END IF;
END;
$assert$;

SELECT 'DIRECT_DELIVERY_CHAT_TRANSLATION_PASS' AS result,
       count(*) AS scenarios
FROM _direct_chat_translation_results;

ROLLBACK;
