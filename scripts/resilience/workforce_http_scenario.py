"""New-store initial password, actual employee/photo attendance, isolation.

Uses actual application/Auth/Storage APIs; never fabricates physical acceptance.
Returned photos/IDs/passwords and detailed responses stay private to this run.
"""
from datetime import datetime, timezone
import hashlib
import secrets
import urllib.request

from owned_platform import private_json
from storage_probe import image_bytes


def run(platform,accounts,registered):
    config=platform.projects['pos'];image=image_bytes();completed=[]
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def request(path,body,token):
        status,result=platform.request('pos',path,body,token=token)
        if status!=200:
            private_json(platform.output/'workforce-failed-response.json',{'path':path,'status':status,'body':result})
            raise RuntimeError('Actual workforce API failed: '+path)
        return result
    def profile(session):
        rows=request('/rest/v1/users?select=must_change_password,password_change_generation&auth_id=eq.'+
          session['user']['id'],None,session['access_token'])
        platform.schema.require(isinstance(rows,list) and len(rows)==1,'Own profile singleton required')
        return rows[0]
    for index,store in enumerate(registered['stores']):
        sessions={}
        for role in ('store_admin','cashier'):
            account=next(a for a in registered['accounts'] if a['storeId']==store and a['role']==role)
            session=request('/auth/v1/token?grant_type=password',{'email':account['email'],'password':account['password']},None)
            original_profile=profile(session)
            platform.check(original_profile.get('must_change_password') is True,'new-account-requires-password-'+role+'-'+str(index))
            password='Fixture-Aa9!'+secrets.token_urlsafe(24)
            platform.redactions.append(password)
            changed=request('/functions/v1/complete-initial-password-change',{'new_password':password},session['access_token'])
            platform.check(changed.get('password_changed') is True,'actual-initial-password-edge-'+role+'-'+str(index))
            fresh=request('/auth/v1/token?grant_type=password',{'email':account['email'],'password':password},None)
            platform.redactions.extend([fresh['access_token'],fresh['refresh_token']])
            updated_profile=profile(fresh)
            platform.check(updated_profile.get('must_change_password') is False
              and updated_profile['password_change_generation']==original_profile['password_change_generation']+1,
              'new-password-login-and-generation-completed-'+role+'-'+str(index))
            sessions[role]=fresh['access_token']
            account['password']=password
        manager=sessions['store_admin'];cashier=sessions['cashier']
        today=datetime.now(timezone.utc).date().isoformat()
        employee=request('/rest/v1/rpc/create_store_employee_with_dates',{
          'p_store_id':store,'p_full_name':'Synthetic full-time employee '+str(index+1),'p_employment_role':'full_time',
          'p_phone':None,'p_bank_name':None,'p_bank_account_number':None,'p_bank_account_holder':None,
          'p_probation_start_date':today,'p_employment_start_date':today},manager)
        platform.check(employee.get('store_id')==store and bool(employee.get('employee_number')),
          'actual-new-store-full-time-employee-'+str(index))
        employee_number=employee['employee_number']
        photo_path=store+'/'+employee_number+'/'+today+'/'+platform.run_id+'_clock_in.jpg'
        status,raw=platform.exchange('pos','/storage/v1/object/attendance-photos/'+photo_path,image,
          method='POST',token=cashier,headers={'Content-Type':'image/jpeg'})
        if status!=200:private_json(platform.output/'attendance-upload-failure.json',{'status':status,'body':raw.decode(errors='replace')})
        platform.check(status==200,'new-store-cashier-actually-uploads-attendance-photo-'+str(index))
        signed=request('/storage/v1/object/sign/attendance-photos/'+photo_path,{'expiresIn':315360000},cashier)
        photo_url=config['url']+'/storage/v1'+signed['signedURL']
        platform.redactions.append(photo_url)
        with opener.open(photo_url,timeout=10) as response:
            downloaded=response.read(1024*1024)
            platform.check(response.status==200 and hashlib.sha256(downloaded).digest()==hashlib.sha256(image).digest(),
              'new-store-actual-private-photo-signed-download-'+str(index))
        events=[]
        for event in ('clock_in','clock_out','clock_in','clock_out'):
            result=request('/rest/v1/rpc/record_employee_attendance_with_photo',{
              'p_store_id':store,'p_employee_number':employee_number,'p_type':event,'p_photo_url':photo_url},cashier)
            platform.check(result.get('employee_id')==employee['id'] and result.get('type')==event
              and result.get('photo_url')==photo_url,'real-employee-photo-'+event+'-'+str(len(events))+'-'+str(index))
            events.append(result['id'])
        platform.check(len(set(events))==4,'two-real-split-shifts-have-four-distinct-events-'+str(index))
        other=registered['stores'][1-index]
        status,denied=platform.request('pos','/rest/v1/rpc/record_employee_attendance_with_photo',{
          'p_store_id':other,'p_employee_number':employee_number,'p_type':'clock_in','p_photo_url':photo_url},token=cashier)
        platform.check(status in (400,401,403) and denied.get('message')=='ATTENDANCE_ENTRY_FORBIDDEN',
          'cashier-cannot-record-another-store-attendance-'+str(index))
        status,_=platform.exchange('pos','/storage/v1/object/attendance-photos/'+other+'/forbidden.jpg',image,
          method='POST',token=cashier,headers={'Content-Type':'image/jpeg'})
        platform.check(status in (400,401,403),'cashier-cannot-upload-another-store-photo-'+str(index))
        readiness=request('/rest/v1/rpc/admin_get_store_workforce_readiness',{'p_store_id':store},manager)
        private_json(platform.output/('store-'+str(index+1)+'-workforce-after.json'),readiness)
        completed.append({'store':store,'employee':employee['id'],'events':events,'cameraExercised':False})
    private_json(platform.output/'generated-pos-accounts.private.json',registered['accounts'])
    private_json(platform.output/'new-store-workforce.private.json',completed)
    platform.result['workforceHttpScenario']={'newStores':len(completed),'employeesCreated':len(completed),
      'attendanceEvents':sum(len(row['events']) for row in completed),'photoBytes':len(image),
      'actualInitialPasswordEdge':True,'actualAuthStorageRlsAndRpc':True,'cameraExercised':False,
      'physicalOpeningAccepted':False,'wholeBusinessLifecycleComplete':False,'productionModified':False}
    platform.save()
