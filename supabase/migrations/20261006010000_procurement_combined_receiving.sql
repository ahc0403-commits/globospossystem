BEGIN;
-- production-gate: self-verifying
-- One shared account may receive and confirm only after the native administrator
-- explicitly assigns both receiving stages for the same accessible store.
CREATE FUNCTION public.can_receive_and_confirm_inventory_receipt(p_store_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT auth.role()='authenticated'
  AND public.can_access_inventory_workflow(p_store_id)
  AND EXISTS(SELECT 1 FROM public.users u
    JOIN public.procurement_role_roster receiver ON receiver.subject_id=u.auth_id
      AND receiver.restaurant_id=p_store_id AND receiver.system='pos'
      AND receiver.stage='receiver' AND receiver.account_kind='shared_role'
      AND receiver.valid_from<=now() AND receiver.valid_until>now()
    JOIN public.procurement_role_roster verifier ON verifier.subject_id=u.auth_id
      AND verifier.restaurant_id=p_store_id AND verifier.system='pos'
      AND verifier.stage='verifier' AND verifier.account_kind='shared_role'
      AND verifier.valid_from<=now() AND verifier.valid_until>now()
    WHERE u.auth_id=auth.uid() AND u.is_active AND u.role='inventory_orderer');
$$;
REVOKE ALL ON FUNCTION public.can_receive_and_confirm_inventory_receipt(uuid)
 FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.can_receive_and_confirm_inventory_receipt(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.can_verify_inventory_receipt(p_store_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
 SELECT public.can_access_inventory_workflow(p_store_id)
  AND (COALESCE(public.inventory_purchase_actor_role(),'')='inventory_accounting'
    OR public.can_receive_and_confirm_inventory_receipt(p_store_id));
$$;

-- Retain the reviewed native command, idempotency and confirmation bodies.
-- Fail closed if their expected contracts have changed.
DO $patch$
DECLARE definition text;needle text;replacement text;
BEGIN
 definition:=pg_get_functiondef('public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb)'::regprocedure);
 needle:=$old$WHEN 'verifier' THEN principal.role IN ('inventory_accounting','super_admin')$old$;
 replacement:=$new$WHEN 'verifier' THEN principal.role IN ('inventory_accounting','super_admin')
    OR (kind='shared_role' AND principal.role='inventory_orderer' AND EXISTS(
      SELECT 1 FROM public.procurement_role_roster receiver
      WHERE receiver.restaurant_id=p_store_id AND receiver.system='pos'
        AND receiver.subject_id=subject AND receiver.stage='receiver'
        AND receiver.account_kind='shared_role'
        AND receiver.valid_from<=now() AND receiver.valid_until>now()))$new$;
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'PROCUREMENT_COMBINED_ROSTER_PATCH_MISMATCH';END IF;
 EXECUTE replace(definition,needle,replacement);

 definition:=pg_get_functiondef('public.verify_inventory_receipt_p1(uuid,integer,text,jsonb,text)'::regprocedure);
 needle:=$old$IF v_receipt.received_by IS NOT DISTINCT FROM auth.uid() OR EXISTS (
    SELECT 1 FROM public.inventory_receipt_submission_attempts a
    WHERE a.receipt_id=v_receipt.id AND a.actor_id=auth.uid()) THEN$old$;
 replacement:=$new$IF NOT public.can_receive_and_confirm_inventory_receipt(v_receipt.restaurant_id)
    AND (v_receipt.received_by IS NOT DISTINCT FROM auth.uid() OR EXISTS (
      SELECT 1 FROM public.inventory_receipt_submission_attempts a
      WHERE a.receipt_id=v_receipt.id AND a.actor_id=auth.uid())) THEN$new$;
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'PROCUREMENT_COMBINED_CONFIRM_PATCH_MISMATCH';END IF;
 EXECUTE replace(definition,needle,replacement);

 definition:=pg_get_functiondef('public.submit_inventory_receipt_batch(uuid,uuid,integer,integer,text,jsonb,text,text,text,date,text)'::regprocedure);
 needle:=$old$  RETURN v_result;
END$old$;
 replacement:=$new$  IF public.can_receive_and_confirm_inventory_receipt(v_order.restaurant_id) THEN
    -- Submission and final confirmation share this database transaction. A failed
    -- inspection/stock mapping rolls both back; a replay returns the saved result.
    PERFORM public.verify_inventory_receipt(p_receipt_id,v_receipt.row_version,
      'receive-confirm:'||p_idempotency_key,'[]'::jsonb,'combined_receiving_inspection');
    SELECT * INTO v_receipt FROM public.inventory_receipts WHERE id=p_receipt_id;
    v_result:=jsonb_build_object('receipt_id',p_receipt_id,'row_version',v_receipt.row_version,
      'status',v_receipt.status,'combined_receiving',true);
    UPDATE public.inventory_receipt_submission_attempts SET result=v_result
      WHERE receipt_id=p_receipt_id AND attempt_key=p_idempotency_key;
  END IF;
  RETURN v_result;
END$new$;
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'PROCUREMENT_COMBINED_SUBMIT_PATCH_MISMATCH';END IF;
 EXECUTE replace(definition,needle,replacement);

 definition:=pg_get_functiondef('public.get_inventory_workflow_detail(uuid)'::regprocedure);
 needle:=$old$'can_urgent_approve',public.can_urgent_approve_inventory_order(v_order.restaurant_id),$old$;
 replacement:=needle||$new$
    'can_receive_and_confirm',public.can_receive_and_confirm_inventory_receipt(v_order.restaurant_id),$new$;
 IF position(needle IN definition)=0 THEN RAISE EXCEPTION 'PROCUREMENT_COMBINED_DETAIL_PATCH_MISMATCH';END IF;
 EXECUTE replace(definition,needle,replacement);
END $patch$;

DO $verify$
BEGIN
 IF position('combined_receiving_inspection' IN pg_get_functiondef(
   'public.submit_inventory_receipt_batch(uuid,uuid,integer,integer,text,jsonb,text,text,text,date,text)'::regprocedure))=0
  OR position('NOT public.can_receive_and_confirm_inventory_receipt' IN pg_get_functiondef(
   'public.verify_inventory_receipt_p1(uuid,integer,text,jsonb,text)'::regprocedure))=0
  OR position('can_receive_and_confirm' IN pg_get_functiondef(
   'public.get_inventory_workflow_detail(uuid)'::regprocedure))=0
  OR has_function_privilege('anon','public.can_receive_and_confirm_inventory_receipt(uuid)','EXECUTE')
  OR NOT has_function_privilege('authenticated','public.can_receive_and_confirm_inventory_receipt(uuid)','EXECUTE')
 THEN RAISE EXCEPTION 'PROCUREMENT_COMBINED_RECEIVING_CONTRACT_FAILED';END IF;
END $verify$;
COMMIT;
