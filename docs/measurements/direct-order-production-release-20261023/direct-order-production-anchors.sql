WITH checks(signature,needle,expected) AS (VALUES
 ('public.direct_order_public_submit(uuid,text,uuid,jsonb)',$n$btrim(v_address->>'detail_address')$n$,1),
 ('public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)',$n$btrim(v_address->>'detail_address')$n$,1),
 ('public.enqueue_direct_delivery_driver_receipt(uuid,uuid,boolean)',$n$OR NULLIF(btrim(v_address.detail_address), '') IS NULL$n$,1),
 ('public.guard_direct_delivery_driver_receipt_job()',$n$OR NULLIF(btrim(NEW.payload->>'detail_address'), '') IS NULL$n$,1),
 ('public.direct_order_capture_requirements()',$n$request_text,source_locale)$n$,1),
 ('public.direct_order_capture_requirements()',$n$'order',id,btrim(customer_note),locale FROM$n$,1),
 ('public.direct_order_capture_requirements()',$n$source_locale,item_label_vi)$n$,1),
 ('public.direct_order_staff_reply_requirement(uuid,uuid,uuid,integer,uuid,text,text,boolean,text,text,text)',$n$NOT IN ('preparation','delivery','both')$n$,1),
 ('public.direct_order_staff_reply_requirement(uuid,uuid,uuid,integer,uuid,text,text,boolean,text,text,text)',$n$OR $10 !~ '^[ -~ÀÁÂÃÈÉÊÌÍÒÓÔÕÙÚÝàáâãèéêìíòóôõùúýĂăĐđĨĩŨũƠơƯưẠ-ỹ]+$' THEN$n$,1),
 ('public.direct_order_requirement_print_snapshot(uuid,text)',$n$AND ($2='receipt' OR print_scope='both' OR print_scope=$2)$n$,1),
 ('public.direct_order_emit_requirement_addendum(uuid)',$n$IF NOT FOUND THEN RETURN; END IF;$n$,1)
), definitions AS MATERIALIZED (SELECT signature,needle,expected,pg_get_functiondef(signature::regprocedure) AS definition FROM checks)
SELECT signature,((length(definition)-length(replace(definition,needle,'')))/length(needle))=expected AS expected_anchor_matches
FROM definitions;
