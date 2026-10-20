-- Owner decision 2026-10-20: the existing PR ID also receives and posts stock.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';

-- Extend the existing, set-based onboarding path. Auth IDs, store-access
-- validation, historical accounts and all approval/stock bodies are preserved.
DO $patch$
DECLARE definition text; needle text; replacement text;
BEGIN
 definition:=pg_get_functiondef('public.connect_procurement_stores(uuid[])'::regprocedure);
 needle:=$old$CROSS JOIN LATERAL(SELECT CASE WHEN q.role='store_admin' THEN 'store'
   WHEN q.role='inventory_orderer' AND q.account_code LIKE '%\_pr1' ESCAPE '\' THEN 'requester'
   WHEN q.role='inventory_orderer' AND q.account_code LIKE '%\_order' ESCAPE '\' THEN 'receiver' END stage) x$old$;
 replacement:=$new$CROSS JOIN LATERAL(SELECT unnest(CASE
   WHEN q.role='store_admin' THEN ARRAY['store']
   WHEN q.role='inventory_orderer' AND q.account_code LIKE '%\_pr1' ESCAPE '\'
     THEN ARRAY['requester','receiver','verifier']
   WHEN q.role='inventory_orderer' AND q.account_code LIKE '%\_order' ESCAPE '\'
     THEN ARRAY['receiver'] ELSE ARRAY[]::text[] END) stage) x$new$;
 IF position(needle IN definition)=0 THEN
   RAISE EXCEPTION 'UNIFIED_REQUESTER_ONBOARDING_PREDECESSOR_CHANGED';
 END IF;
 EXECUTE replace(definition,needle,replacement);
END $patch$;

CREATE TEMP TABLE requester_receiving_before ON COMMIT DROP AS
 SELECT rr.restaurant_id,rr.system,rr.subject_id,rr.stage
 FROM public.procurement_role_roster rr
 JOIN public.users u ON u.auth_id=rr.subject_id AND u.is_active
 JOIN public.store_fixed_account_requirements q ON q.provisioned_user_id=u.id
   AND q.store_id=rr.restaurant_id AND q.is_active AND q.scope='store'
 WHERE rr.system='pos' AND q.role='inventory_orderer'
   AND q.account_code LIKE '%\_pr1' ESCAPE '\';

DO $backfill$
BEGIN
 PERFORM public.connect_procurement_stores(batch.ids)
 FROM (
   SELECT array_agg(id) ids FROM (
     SELECT r.id,row_number() OVER(ORDER BY r.id) n
     FROM public.restaurants r WHERE r.is_active AND EXISTS(
       SELECT 1 FROM public.store_fixed_account_requirements q
       WHERE q.store_id=r.id AND q.is_active AND q.role='inventory_orderer'
         AND q.account_code LIKE '%\_pr1' ESCAPE '\'
     )
   ) stores GROUP BY (n-1)/100
 ) batch;
END $backfill$;

INSERT INTO public.procurement_events(restaurant_id,record_id,action,actor,reason,next_state)
 SELECT rr.restaurant_id,rr.restaurant_id,'unify_requester_receiving',
   '{"system":"migration","subject_id":"20261020153000"}'::jsonb,
   'Owner decision: the PR account receives, confirms inspection and posts stock',
   jsonb_build_object('subject_id',rr.subject_id,'stage',rr.stage)
 FROM public.procurement_role_roster rr
 JOIN public.users u ON u.auth_id=rr.subject_id AND u.is_active
 JOIN public.store_fixed_account_requirements q ON q.provisioned_user_id=u.id
   AND q.store_id=rr.restaurant_id AND q.is_active AND q.scope='store'
 LEFT JOIN requester_receiving_before b ON b.restaurant_id=rr.restaurant_id
   AND b.system=rr.system AND b.subject_id=rr.subject_id AND b.stage=rr.stage
 WHERE rr.system='pos' AND rr.stage IN('receiver','verifier') AND b.subject_id IS NULL
   AND q.role='inventory_orderer' AND q.account_code LIKE '%\_pr1' ESCAPE '\';

DO $verify$
BEGIN
 IF EXISTS(
   SELECT 1 FROM public.store_fixed_account_requirements q
   JOIN public.restaurants r ON r.id=q.store_id AND r.is_active
   JOIN public.users u ON u.id=q.provisioned_user_id AND u.is_active
     AND u.auth_id IS NOT NULL AND u.role=q.role AND u.fixed_account_code=q.account_code
   JOIN public.user_store_access a ON a.user_id=u.id AND a.store_id=r.id AND a.is_active
   LEFT JOIN (
     SELECT restaurant_id,subject_id,count(DISTINCT stage) stages
     FROM public.procurement_role_roster
     WHERE system='pos' AND account_kind='shared_role' AND valid_from<=now()
       AND valid_until>now() AND stage IN('requester','receiver','verifier')
     GROUP BY restaurant_id,subject_id
   ) rr ON rr.restaurant_id=r.id AND rr.subject_id=u.auth_id
   WHERE q.is_active AND q.scope='store' AND q.role='inventory_orderer'
     AND q.account_code LIKE '%\_pr1' ESCAPE '\' AND coalesce(rr.stages,0)<>3
 ) OR position('ARRAY[''requester'',''receiver'',''verifier'']' IN
   pg_get_functiondef('public.connect_procurement_stores(uuid[])'::regprocedure))=0
 THEN RAISE EXCEPTION 'UNIFIED_REQUESTER_RECEIVING_VERIFICATION_FAILED'; END IF;
END $verify$;
COMMIT;
