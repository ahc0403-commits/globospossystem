"""Actual upload/sign/download/delete and private-object enforcement, no mock."""
import hashlib
import json
from pathlib import Path
import urllib.error
import urllib.request


def image_bytes():
    # Generated solid-color 96x72 JPEG; no camera image or personal data.
    return (Path(__file__).with_name('fixtures')/'attendance.jpg').read_bytes()


def run(platform,project='pos'):
    image=image_bytes()
    config=platform.projects[project]
    bucket={'pos':'attendance-photos','office':'quality-evidence'}[project]
    path='fixture-'+platform.run_id+'/probe.jpg'
    url='/storage/v1/object/'+bucket+'/'+path
    status,raw=platform.exchange(project,url,image,token=config['service'],key=config['service'],
      method='POST',headers={'Content-Type':'image/jpeg'})
    if status!=200:
        from owned_platform import private_json
        private_json(platform.output/'storage-upload-failure.json',{'status':status,'body':raw.decode(errors='replace')})
    platform.check(status==200,project+'-real-storage-upload')
    status,signed=platform.request(project,'/storage/v1/object/sign/'+bucket+'/'+path,
      {'expiresIn':60*60*24*365*10},token=config['service'],key=config['service'])
    platform.check(status==200 and isinstance(signed.get('signedURL'),str),project+'-real-storage-signed-url')
    signed_path=signed['signedURL']
    platform.redactions.append(signed_path)
    platform.schema.require(signed_path.startswith('/object/sign/'+bucket+'/'),'Unexpected signed object target')
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(config['url']+'/storage/v1'+signed_path,timeout=10) as response:
        downloaded=response.read(1024*1024)
        platform.check(response.status==200 and hashlib.sha256(downloaded).digest()==hashlib.sha256(image).digest(),
          project+'-signed-object-actually-downloads-original-bytes-without-api-key')
    # The source attendance bucket is private. Its unsigned public URL must not
    # become accessible because the fixture gateway supports ordinary image GET.
    public=config['url']+'/storage/v1/object/public/'+bucket+'/'+path
    try:
        with opener.open(public,timeout=10) as response:status=response.status
    except urllib.error.HTTPError as error:status=error.code
    platform.check(status in (400,401,403,404),project+'-private-bucket-unsigned-download-denied')
    status,result=platform.request(project,'/storage/v1/object/'+bucket,{'prefixes':[path]},
      method='DELETE',token=config['service'],key=config['service'])
    platform.check(status==200,project+'-real-storage-delete')
    count=platform.sql(project,'SELECT count(*) FROM storage.objects WHERE bucket_id='+platform.schema.lit(bucket)+' AND name='+platform.schema.lit(path)+';').stdout.strip()
    platform.check(count=='0',project+'-storage-object-metadata-cleaned')
    platform.result.setdefault('storageProbes',{})[project]={'project':project,'bucket':bucket,'uploadBytes':len(image),'signedDownloadSha256':hashlib.sha256(image).hexdigest(),
      'privateBucket':True,'serviceRoleTransfer':True,'userScopedBusinessUploadExercised':False,
      'cameraExercised':False,'employeeAttendanceExercised':False,'productionModified':False}
    platform.save()
