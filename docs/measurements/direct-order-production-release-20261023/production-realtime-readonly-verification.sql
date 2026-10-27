SELECT EXISTS(SELECT 1 FROM pg_publication_tables WHERE schemaname='public' AND tablename='pos_live_events' AND pubname='supabase_realtime') AS staff_signal_published,
 (SELECT count(*)=3 AND bool_and(tgenabled='O' AND pg_get_triggerdef(oid) LIKE '%direct_order_chat%')
 FROM pg_trigger WHERE (tgrelid='public.direct_order_messages'::regclass AND tgname IN('direct_order_chat_live_event','direct_order_translation_message_live'))
 OR (tgrelid='public.direct_order_requests'::regclass AND tgname='direct_order_translation_note_live')) AS staff_chat_emitters_ready;
