import json, os, time, uuid
from urllib.request import Request, urlopen
from urllib.error import HTTPError
base=os.environ['SUPABASE_URL'].rstrip('/')
assert base=='https://ynriuoomotxuwhuxxmhj.supabase.co'
headers={'content-type':'application/json','origin':'https://globospossystem.vercel.app','apikey':os.environ['SUPABASE_ANON_KEY'],'authorization':'Bearer '+os.environ['SUPABASE_ANON_KEY']}
def call(body):
    started=time.monotonic()
    req=Request(base+'/functions/v1/direct-order-public',data=json.dumps(body).encode(),headers=headers,method='POST')
    try:
        response=urlopen(req,timeout=20)
    except HTTPError as error:
        response=error
    with response:
        value=json.load(response)
        return response.status,value,round((time.monotonic()-started)*1000,1),response.headers.get('access-control-allow-origin')
status,body,ms,cors=call({'action':'storefront_v3','slug':'bunsikclub-binh-thanh','limit':1})
assert status==200 and isinstance(body.get('data'),dict) and body['data'].get('slug')=='bunsikclub-binh-thanh',(status,body.get('error'))
assert cors==headers['origin'],cors
print(json.dumps({'check':'public_storefront_v3','result':'PASS','http':status,'duration_ms':ms,'cors':cors}))
fake={'session_id':str(uuid.uuid4()),'secret':'a'*64,'request_id':str(uuid.uuid4()),'quote_id':str(uuid.uuid4()),'expected_message_id':None}
for action,extra in [('updates',{}),('proof_upload_url_v3',{'mime_type':'image/png','size_bytes':1024}),('proof_commit_v3',{'path':str(uuid.uuid4())+'/'+fake['request_id']+'/'+str(uuid.uuid4())+'.png'})]:
    status,body,ms,cors=call(fake|{'action':action}|extra)
    assert status==404 and body.get('error')=='DIRECT_ORDER_UNAVAILABLE',(action,status,body.get('error'))
    print(json.dumps({'check':action+'_invalid_session','result':'PASS','http':status,'error':body['error'],'duration_ms':ms}))
