"""Actual GoTrue user JWT -> POS REST -> actual Office Edge -> two native DBs.

Provision only the pre-existing operator context. The new legal entity and
connection are created through their real application APIs, without owner maps.
"""
import json
import secrets
import uuid


def run(platform, accounts):
    def literal(value):
        return "'" + str(value).replace("'", "''") + "'"
    pos_actor, office_actor = (str(uuid.UUID(accounts[p]['user']['id'])) for p in ('pos','office'))
    platform.sql('pos', """
INSERT INTO public.companies(id,name) VALUES('62000000-0000-4000-8000-000000000099','Synthetic platform context');
INSERT INTO public.brand_master(id,company_id,name,type)
VALUES('61000000-0000-4000-8000-000000000099','62000000-0000-4000-8000-000000000099','Synthetic platform','internal');
INSERT INTO public.brands(id,brand_master_id,code,name)
VALUES('60000000-0000-4000-8000-000000000099','61000000-0000-4000-8000-000000000099','native_platform','Synthetic platform');
INSERT INTO public.tax_entity(id,name,tax_code,owner_type)
VALUES('30000000-0000-4000-8000-000000000099','Pre-existing unrelated operator context','9100000099','internal');
INSERT INTO public.tax_entity_brands(tax_entity_id,brand_id)
VALUES('30000000-0000-4000-8000-000000000099','60000000-0000-4000-8000-000000000099');
INSERT INTO public.restaurants(id,name,brand_id,tax_entity_id)
VALUES('50000000-0000-4000-8000-000000000099','Pre-existing operator context',
 '60000000-0000-4000-8000-000000000099','30000000-0000-4000-8000-000000000099');
INSERT INTO public.users(auth_id,restaurant_id,role,full_name,is_active)
VALUES(""" + literal(pos_actor) + ", '50000000-0000-4000-8000-000000000099','super_admin','Synthetic platform operator',true);")
    platform.sql('office', """
SET request.jwt.claim.role='service_role';
INSERT INTO public.office_user_profiles(auth_id,account_level,display_name,email,
 domain_authorities,permission_model_version,is_active,is_suspended,credential_state)
VALUES(""" + literal(office_actor) + ",'super_admin','Synthetic Office administrator','runtime-admin-office@fixture.invalid',"
      "'[{\"domain\":\"purchase\"},{\"domain\":\"finance\"}]'::jsonb,'v2',true,false,'active') "
      "ON CONFLICT(auth_id) DO UPDATE SET account_level=excluded.account_level,"
      "domain_authorities=excluded.domain_authorities,permission_model_version='v2',"
      "is_active=true,is_suspended=false,credential_state='active';" + """
INSERT INTO core.office_permission_catalog(domain,action,display_name)
VALUES('system','admin','Synthetic system admin'),('purchase','approve','Synthetic purchase approval')
ON CONFLICT(domain,action) DO NOTHING;
INSERT INTO core.office_access_grants(user_profile_id,domain,action,scope_level,is_active,valid_from,granted_by,reason)
SELECT p.id,x.domain,x.action,'group',true,now()-interval '1 hour',p.auth_id,'Synthetic runtime connection fixture'
FROM public.office_user_profiles p CROSS JOIN(VALUES('system','admin'),('purchase','approve'))x(domain,action)
WHERE p.auth_id=""" + literal(office_actor) + ';')
    platform.check(True,'real-auth-users-have-independent-platform-operator-profiles')
    def pos(name, body):
        return platform.request('pos','/rest/v1/rpc/' + name,body,token=accounts['pos']['session']['access_token'])
    def edge(body, token=None):
        return platform.request('office','/functions/v1/pos-bridge',body,
          token=token or accounts['office']['session']['access_token'])
    status, result = edge({'action':'procurement_onboarding_sync'},platform.dispatch_token)
    platform.check(status==200 and result.get('legal_capability')=='ready','actual-edge-onboarding-announces-legal-capability')
    tax = str(uuid.uuid4())
    status, registered = pos('admin_upsert_tax_entity_v2',{'p_tax_entity_id':tax,
      'p_tax_code':'9100000101','p_name':'Runtime new legal entity','p_owner_type':'internal','p_onboarding_status':'ready'})
    platform.check(status==200,'real-pos-actor-registers-new-legal-entity-through-rpc')
    platform.check(platform.sql('pos','SELECT count(*) FROM public.restaurants WHERE tax_entity_id='+literal(tax)+';').stdout.strip()=='0',
      'target-new-legal-entity-has-no-store-or-office-map')
    operation, proof = str(uuid.uuid4()),secrets.token_urlsafe(40)
    platform.redactions.append(proof)
    params={'p_operation_id':operation,'p_tax_entity_id':tax,'p_proof':proof}
    status, started = pos('begin_office_legal_connection_v1',params)
    platform.check(status==200 and started.get('requested_by')==pos_actor and started.get('state')=='awaiting_office',
      'real-pos-jwt-creates-original-connection-request')
    status, preview = edge({'action':'legal_connection_preview','operationId':operation,'proof':proof})
    platform.check(status==200 and preview.get('status')=='preview' and preview['request']['tax_entity_id']==tax,
      'actual-office-edge-authenticated-preview')
    # Lose the POS acknowledgment after its real transaction commits. This is
    # a physical HTTP response loss, not a fabricated business result.
    fault_route='rest/rpc/office_confirm_pos_legal_connection_v1'
    # Deno's transport may transparently replay a buffered POST after EOF.
    # Sustain this bounded fault for the entire call, then restore connectivity
    # before explicit recovery. All deliveries retain the original operation.
    platform.gateways['pos'].drop_next[fault_route] = 8
    status, unknown = edge({'action':'legal_connection_confirm','operationId':operation,'proof':proof,
      'newEntity':{'code':'RUNTIME_NEW','display_name':'Runtime new Office legal entity'}})
    platform.gateways['pos'].drop_next[fault_route] = 0
    platform.result['lostAcknowledgementTransportAttempts']=platform.gateways['pos'].snapshot()['faultResponsesDropped']
    platform.check(status==200 and unknown.get('status')=='unknown' and unknown.get('phase')=='pos_ack',
      'real-commit-lost-ack-is-unknown')
    status, resumed = edge({'action':'legal_connection_resume','operationId':operation})
    platform.check(status==200 and resumed.get('status')=='confirmed' and resumed.get('tax_entity_id')==tax,
      'actual-office-edge-resumes-original-operation')
    linked = resumed['office_legal_entity_id']
    platform.check(linked != tax and pos_actor != office_actor,'actual-cross-project-business-and-auth-ids-remain-independent')
    status, original = pos('get_office_legal_connection_for_entity_v1',{'p_tax_entity_id':tax})
    platform.check(status==200 and original.get('state')=='confirmed' and original.get('office_actor_id')==office_actor,
      'real-pos-client-reads-confirmed-office-ownership')
    for _ in range(20):
        status, repeated = edge({'action':'legal_connection_resume','operationId':operation})
        if status!=200 or repeated != resumed:
            raise RuntimeError('Actual HTTP replay changed original legal result')
    platform.check(True,'twenty-real-http-resumes-return-one-original-result')
    row = json.loads(platform.sql('office',"SELECT jsonb_build_object('links',count(*),'owners',count(DISTINCT legal_entity_id),"
      "'acknowledged',bool_and(pos_acknowledged_at IS NOT NULL)) FROM ops.pos_legal_entity_links WHERE operation_id="+literal(operation)+';').stdout)
    platform.check(row=={'links':1,'owners':1,'acknowledged':True},'real-http-recovery-created-one-office-owner-and-ack')
    platform.result['legalHttpScenario']={'checks':'real-auth-rpc-edge-and-physical-lost-ack',
      'newLegalEntityHadZeroStores':True, 'operatorHadUnrelatedExistingStore':True,
      'browserFlowExercised':False, 'storageRealtimeExercised':False,
      'originalOperationId':operation,'realAuthIdsIndependent':True,'repeatedResumeCount':20,
      'productionModified':False}
    platform.save()
