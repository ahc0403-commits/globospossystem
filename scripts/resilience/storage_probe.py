"""Actual upload/sign/download/delete and private-object enforcement, no mock."""
import base64
import hashlib
import json
import urllib.error
import urllib.request


def run(platform,project='pos'):
    # Public-domain synthetic 1x1 JPEG. No camera image or personal data copied.
    image=base64.b64decode('/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAEf/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABBQJ//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAwEBPwF//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAgEBPwF//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQAGPwJ//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPyF//9oADAMBAAIAAwAAABD/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/EH//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/EH//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/EH//2Q==')
    config=platform.projects[project]
    path='fixture-'+platform.run_id+'/probe.jpg'
    url='/storage/v1/object/attendance-photos/'+path
    status,raw=platform.exchange(project,url,image,token=config['service'],key=config['service'],
      method='POST',headers={'Content-Type':'image/jpeg'})
    if status!=200:
        from owned_platform import private_json
        private_json(platform.output/'storage-upload-failure.json',{'status':status,'body':raw.decode(errors='replace')})
    platform.check(status==200,project+'-real-storage-upload')
    status,signed=platform.request(project,'/storage/v1/object/sign/attendance-photos/'+path,
      {'expiresIn':60*60*24*365*10},token=config['service'],key=config['service'])
    platform.check(status==200 and isinstance(signed.get('signedURL'),str),project+'-real-storage-signed-url')
    signed_path=signed['signedURL']
    platform.redactions.append(signed_path)
    platform.schema.require(signed_path.startswith('/object/sign/attendance-photos/'),'Unexpected signed object target')
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(config['url']+'/storage/v1'+signed_path,timeout=10) as response:
        downloaded=response.read(1024*1024)
        platform.check(response.status==200 and hashlib.sha256(downloaded).digest()==hashlib.sha256(image).digest(),
          project+'-signed-object-actually-downloads-original-bytes-without-api-key')
    # The source attendance bucket is private. Its unsigned public URL must not
    # become accessible because the fixture gateway supports ordinary image GET.
    public=config['url']+'/storage/v1/object/public/attendance-photos/'+path
    try:
        with opener.open(public,timeout=10) as response:status=response.status
    except urllib.error.HTTPError as error:status=error.code
    platform.check(status in (400,401,403,404),project+'-private-bucket-unsigned-download-denied')
    status,result=platform.request(project,'/storage/v1/object/attendance-photos',{'prefixes':[path]},
      method='DELETE',token=config['service'],key=config['service'])
    platform.check(status==200,project+'-real-storage-delete')
    count=platform.sql(project,"SELECT count(*) FROM storage.objects WHERE bucket_id='attendance-photos' AND name="+platform.schema.lit(path)+';').stdout.strip()
    platform.check(count=='0',project+'-storage-object-metadata-cleaned')
    platform.result['storageProbe']={'project':project,'uploadBytes':len(image),'signedDownloadSha256':hashlib.sha256(image).hexdigest(),
      'privateBucket':True,'cameraExercised':False,'employeeAttendanceExercised':False,'productionModified':False}
    platform.save()
