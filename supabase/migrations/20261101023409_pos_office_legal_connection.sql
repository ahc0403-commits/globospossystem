-- production-gate: self-verifying
BEGIN;
CREATE TABLE public.pos_office_legal_capability (
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
  ready boolean NOT NULL,
  reported_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pos_office_legal_capability ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pos_office_legal_capability FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.pos_office_legal_capability TO service_role;
CREATE FUNCTION public.office_report_legal_capability_v1(p_ready boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' OR p_ready IS NULL THEN
    RAISE insufficient_privilege; END IF;
  INSERT INTO public.pos_office_legal_capability(singleton,ready) VALUES(true,p_ready)
    ON CONFLICT(singleton) DO UPDATE SET ready=excluded.ready,reported_at=now();
END $$;
REVOKE ALL ON FUNCTION public.office_report_legal_capability_v1(boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.office_report_legal_capability_v1(boolean) TO service_role;
CREATE FUNCTION public.get_office_legal_capability_v1() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' AND
      (auth.uid() IS NULL OR NOT coalesce(public.is_super_admin(),false)) THEN
    RAISE insufficient_privilege; END IF;
  RETURN jsonb_build_object('contract_version',1,'ready',coalesce((
    SELECT ready AND reported_at>now()-interval '15 minutes'
    FROM public.pos_office_legal_capability WHERE singleton),false));
END $$;
REVOKE ALL ON FUNCTION public.get_office_legal_capability_v1() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_office_legal_capability_v1() TO authenticated,service_role;
CREATE TABLE public.pos_office_legal_connections (
  operation_id uuid PRIMARY KEY,
  tax_entity_id uuid NOT NULL REFERENCES public.tax_entity(id),
  requested_by uuid NOT NULL REFERENCES auth.users(id),
  proof_sha256 text NOT NULL CHECK(length(proof_sha256)=64),
  payload jsonb NOT NULL CHECK(jsonb_typeof(payload)='object'),
  payload_sha256 text NOT NULL CHECK(length(payload_sha256)=64),
  state text NOT NULL DEFAULT 'awaiting_office' CHECK(state IN('awaiting_office','confirmed','requires_review')),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  office_legal_entity_id uuid,
  office_actor_id uuid,
  office_confirmed_at timestamptz,
  confirmed_at timestamptz,
  CHECK(expires_at>created_at),
  CHECK(state<>'confirmed' OR (office_legal_entity_id IS NOT NULL AND office_actor_id IS NOT NULL AND confirmed_at IS NOT NULL))
);
CREATE UNIQUE INDEX pos_office_one_active_legal_connection ON public.pos_office_legal_connections(tax_entity_id)
  WHERE state='confirmed';
CREATE INDEX pos_office_legal_actor_operations ON public.pos_office_legal_connections(requested_by,created_at DESC,operation_id);
CREATE INDEX pos_office_legal_entity_operations ON public.pos_office_legal_connections(tax_entity_id,created_at DESC,operation_id);
ALTER TABLE public.pos_office_legal_connections ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pos_office_legal_connections FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.pos_office_legal_connections TO service_role;

CREATE FUNCTION public.pos_office_legal_connection_result_v1(p_row public.pos_office_legal_connections)
RETURNS jsonb LANGUAGE sql STABLE SET search_path='' AS $$
  SELECT jsonb_build_object('contract_version',1,'operation_id',p_row.operation_id,
    'pos_project','ynriuoomotxuwhuxxmhj','office_project','raghsbaxcwrxlsacaoau',
    'tax_entity_id',p_row.tax_entity_id,'requested_by',p_row.requested_by,
    'payload',p_row.payload,'payload_sha256',p_row.payload_sha256,
    'state',CASE WHEN p_row.state='awaiting_office' AND p_row.expires_at<now()
      THEN 'expired' ELSE p_row.state END,
    'created_at',p_row.created_at,'expires_at',p_row.expires_at,
    'office_legal_entity_id',p_row.office_legal_entity_id,'office_actor_id',p_row.office_actor_id,
    'office_confirmed_at',p_row.office_confirmed_at,'confirmed_at',p_row.confirmed_at)
$$;
REVOKE ALL ON FUNCTION public.pos_office_legal_connection_result_v1(public.pos_office_legal_connections)
  FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.begin_office_legal_connection_v1(p_operation_id uuid,p_tax_entity_id uuid,p_proof text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE previous public.pos_office_legal_connections; body jsonb; body_hash text; proof_hash text;
BEGIN
  IF auth.uid() IS NULL OR NOT coalesce(public.is_super_admin(),false) THEN
    RAISE EXCEPTION 'POS_OFFICE_LEGAL_CONNECTION_FORBIDDEN' USING ERRCODE='42501';
  END IF;
  IF p_operation_id IS NULL OR p_tax_entity_id IS NULL OR length(coalesce(p_proof,'')) NOT BETWEEN 32 AND 128 THEN
    RAISE EXCEPTION 'POS_OFFICE_LEGAL_CONNECTION_INPUT_INVALID' USING ERRCODE='22023';
  END IF;
  proof_hash:=encode(sha256(convert_to(p_proof,'UTF8')),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended('pos-office-legal:'||p_tax_entity_id,0));
  SELECT * INTO previous FROM public.pos_office_legal_connections WHERE operation_id=p_operation_id;
  IF FOUND THEN
    IF previous.tax_entity_id<>p_tax_entity_id OR previous.requested_by<>auth.uid() OR previous.proof_sha256<>proof_hash THEN
      RAISE EXCEPTION 'POS_OFFICE_LEGAL_CONNECTION_OPERATION_CONFLICT';
    END IF;
    RETURN public.pos_office_legal_connection_result_v1(previous);
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_office_legal_connections WHERE tax_entity_id=p_tax_entity_id AND state='confirmed') THEN
    RAISE EXCEPTION 'POS_OFFICE_LEGAL_ENTITY_ALREADY_CONNECTED';
  END IF;
  IF NOT coalesce((public.get_office_legal_capability_v1()->>'ready')::boolean,false) THEN
    RAISE EXCEPTION 'POS_OFFICE_LEGAL_CAPABILITY_NOT_READY'; END IF;
  SELECT jsonb_build_object('tax_entity_id',e.id,'name',e.name,'tax_code',e.tax_code,'owner_type',e.owner_type)
    INTO body FROM public.tax_entity e WHERE e.id=p_tax_entity_id;
  IF body IS NULL THEN RAISE EXCEPTION 'POS_OFFICE_LEGAL_ENTITY_NOT_FOUND'; END IF;
  IF octet_length(body::text)>16384 THEN RAISE EXCEPTION 'POS_OFFICE_LEGAL_CONNECTION_INPUT_INVALID'; END IF;
  -- Preserve the current Office eligibility policy: new external entities are
  -- not implicitly granted Office ownership by matching tax code/name/UUID.
  IF body->>'owner_type' IS DISTINCT FROM 'internal' THEN RAISE EXCEPTION 'POS_OFFICE_EXTERNAL_LEGAL_ENTITY_UNSUPPORTED'; END IF;
  body_hash:=encode(sha256(convert_to(body::text,'UTF8')),'hex');
  INSERT INTO public.pos_office_legal_connections(operation_id,tax_entity_id,requested_by,proof_sha256,
    payload,payload_sha256,expires_at)
  VALUES(p_operation_id,p_tax_entity_id,auth.uid(),proof_hash,body,body_hash,now()+interval '20 minutes') RETURNING * INTO previous;
  RETURN public.pos_office_legal_connection_result_v1(previous);
END $$;
REVOKE ALL ON FUNCTION public.begin_office_legal_connection_v1(uuid,uuid,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.begin_office_legal_connection_v1(uuid,uuid,text) TO authenticated;

CREATE FUNCTION public.get_office_legal_connection_v1(p_operation_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE previous public.pos_office_legal_connections;
BEGIN
  IF auth.uid() IS NULL OR NOT coalesce(public.is_super_admin(),false) THEN
    RAISE EXCEPTION 'POS_OFFICE_LEGAL_CONNECTION_FORBIDDEN' USING ERRCODE='42501'; END IF;
  SELECT * INTO previous FROM public.pos_office_legal_connections
    WHERE operation_id=p_operation_id AND requested_by=auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'POS_OFFICE_LEGAL_CONNECTION_NOT_FOUND'; END IF;
  RETURN public.pos_office_legal_connection_result_v1(previous);
END $$;
REVOKE ALL ON FUNCTION public.get_office_legal_connection_v1(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.get_office_legal_connection_v1(uuid) TO authenticated;

CREATE FUNCTION public.get_office_legal_connection_for_entity_v1(p_tax_entity_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE previous public.pos_office_legal_connections;
BEGIN
  IF auth.uid() IS NULL OR NOT coalesce(public.is_super_admin(),false) THEN
    RAISE EXCEPTION 'POS_OFFICE_LEGAL_CONNECTION_FORBIDDEN' USING ERRCODE='42501'; END IF;
  SELECT * INTO previous FROM public.pos_office_legal_connections
    WHERE tax_entity_id=p_tax_entity_id AND (state='confirmed' OR requested_by=auth.uid())
    ORDER BY (state='confirmed') DESC,created_at DESC,operation_id DESC LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN public.pos_office_legal_connection_result_v1(previous);
END $$;
REVOKE ALL ON FUNCTION public.get_office_legal_connection_for_entity_v1(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.get_office_legal_connection_for_entity_v1(uuid) TO authenticated;

CREATE FUNCTION public.office_resolve_pos_legal_connection_v1(p_operation_id uuid,p_proof text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE previous public.pos_office_legal_connections; body jsonb;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE insufficient_privilege; END IF;
  SELECT * INTO previous FROM public.pos_office_legal_connections WHERE operation_id=p_operation_id;
  IF NOT FOUND OR previous.proof_sha256<>encode(sha256(convert_to(coalesce(p_proof,''),'UTF8')),'hex') THEN
    RAISE EXCEPTION 'POS_OFFICE_LEGAL_CONNECTION_PROOF_INVALID' USING ERRCODE='42501'; END IF;
  IF previous.expires_at<now() THEN RAISE EXCEPTION 'POS_OFFICE_LEGAL_CONNECTION_EXPIRED'; END IF;
  IF previous.state<>'awaiting_office' THEN RAISE EXCEPTION 'POS_OFFICE_LEGAL_CONNECTION_CONSUMED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.users u WHERE u.auth_id=previous.requested_by AND u.is_active AND u.role='super_admin') THEN
    RAISE EXCEPTION 'POS_OFFICE_LEGAL_CONNECTION_ACTOR_REVOKED' USING ERRCODE='42501'; END IF;
  SELECT jsonb_build_object('tax_entity_id',e.id,'name',e.name,'tax_code',e.tax_code,'owner_type',e.owner_type)
    INTO body FROM public.tax_entity e WHERE e.id=previous.tax_entity_id;
  IF body IS DISTINCT FROM previous.payload THEN RAISE EXCEPTION 'POS_OFFICE_LEGAL_ENTITY_CHANGED'; END IF;
  RETURN public.pos_office_legal_connection_result_v1(previous);
END $$;
REVOKE ALL ON FUNCTION public.office_resolve_pos_legal_connection_v1(uuid,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.office_resolve_pos_legal_connection_v1(uuid,text) TO service_role;

CREATE FUNCTION public.office_confirm_pos_legal_connection_v1(p_operation_id uuid,p_payload_sha256 text,
  p_office_legal_entity_id uuid,p_office_actor_id uuid,p_office_confirmed_at timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE previous public.pos_office_legal_connections; body jsonb;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE insufficient_privilege; END IF;
  SELECT * INTO previous FROM public.pos_office_legal_connections WHERE operation_id=p_operation_id FOR UPDATE;
  IF NOT FOUND OR previous.payload_sha256 IS DISTINCT FROM p_payload_sha256 OR p_office_legal_entity_id IS NULL
    OR p_office_actor_id IS NULL OR p_office_confirmed_at IS NULL THEN RAISE EXCEPTION 'POS_OFFICE_LEGAL_CONFIRMATION_INVALID'; END IF;
  IF previous.state='confirmed' THEN
    IF previous.office_legal_entity_id<>p_office_legal_entity_id OR previous.office_actor_id<>p_office_actor_id THEN
      RAISE EXCEPTION 'POS_OFFICE_LEGAL_CONNECTION_OPERATION_CONFLICT'; END IF;
    RETURN public.pos_office_legal_connection_result_v1(previous);
  END IF;
  IF p_office_confirmed_at<previous.created_at OR p_office_confirmed_at>previous.expires_at
    OR p_office_confirmed_at>now()+interval '2 minutes' THEN
    RAISE EXCEPTION 'POS_OFFICE_LEGAL_CONNECTION_EXPIRED'; END IF;
  SELECT jsonb_build_object('tax_entity_id',e.id,'name',e.name,'tax_code',e.tax_code,'owner_type',e.owner_type)
    INTO body FROM public.tax_entity e WHERE e.id=previous.tax_entity_id;
  IF body IS DISTINCT FROM previous.payload OR NOT EXISTS(
      SELECT 1 FROM public.users u WHERE u.auth_id=previous.requested_by
      AND u.is_active AND u.role='super_admin') THEN
    UPDATE public.pos_office_legal_connections SET state='requires_review' WHERE operation_id=p_operation_id RETURNING * INTO previous;
    RETURN public.pos_office_legal_connection_result_v1(previous);
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_office_legal_connections WHERE tax_entity_id=previous.tax_entity_id
    AND state='confirmed' AND operation_id<>p_operation_id) THEN RAISE EXCEPTION 'POS_OFFICE_LEGAL_ENTITY_ALREADY_CONNECTED'; END IF;
  UPDATE public.pos_office_legal_connections SET state='confirmed',office_legal_entity_id=p_office_legal_entity_id,
    office_actor_id=p_office_actor_id,office_confirmed_at=p_office_confirmed_at,confirmed_at=now()
    WHERE operation_id=p_operation_id RETURNING * INTO previous;
  RETURN public.pos_office_legal_connection_result_v1(previous);
END $$;
REVOKE ALL ON FUNCTION public.office_confirm_pos_legal_connection_v1(uuid,text,uuid,uuid,timestamptz)
  FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.office_confirm_pos_legal_connection_v1(uuid,text,uuid,uuid,timestamptz) TO service_role;

DO $$ BEGIN
  IF has_table_privilege('authenticated','public.pos_office_legal_connections','SELECT')
    OR has_table_privilege('authenticated','public.pos_office_legal_capability','SELECT')
    OR has_function_privilege('authenticated','public.office_report_legal_capability_v1(boolean)','EXECUTE')
    OR has_table_privilege('anon','public.pos_office_legal_connections','SELECT')
    OR has_function_privilege('authenticated','public.office_resolve_pos_legal_connection_v1(uuid,text)','EXECUTE')
    OR has_function_privilege('anon','public.office_confirm_pos_legal_connection_v1(uuid,text,uuid,uuid,timestamptz)','EXECUTE')
    OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.pos_office_legal_connections'::regclass) THEN
    RAISE EXCEPTION 'POS_OFFICE_LEGAL_ACL_CONTRACT_FAILED'; END IF;
END $$;
COMMIT;
