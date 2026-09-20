"""Submit/resume a user-authorized Hunyuan 3D trial using a local API-key file.

Does not log credentials or embedded reference image data. Submission is never
retried automatically; a persisted JobId is reused for queries/downloads.
"""
import argparse,base64,hashlib,json,time,urllib.request,urllib.error
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('action',choices=['submit','query']);p.add_argument('--key-file',required=True)
p.add_argument('--output',required=True);p.add_argument('--reference')
a=p.parse_args();root=Path(__file__).resolve().parents[2];out=root/a.output;out.mkdir(parents=True,exist_ok=True)
manifest=out/'generation-manifest.json';key=Path(a.key_file).read_text().strip()
assert key.startswith('sk-') and '\n' not in key,'Expected a single API key'
def call(action,payload):
    req=urllib.request.Request('https://api.ai3d.cloud.tencent.com/v1/ai3d/'+action,
        data=json.dumps(payload).encode(),headers={'Authorization':key,'Content-Type':'application/json'})
    try:
        with urllib.request.urlopen(req,timeout=90) as response: return json.load(response)
    except urllib.error.HTTPError as e:
        raw=e.read().decode(errors='replace')
        safe=raw.replace(key,'[REDACTED]')
        raise RuntimeError('HTTP '+str(e.code)+' '+safe[:1400])
def save():manifest.write_text(json.dumps(record,ensure_ascii=False,indent=2))
if a.action=='submit':
    if manifest.exists():
        old=json.loads(manifest.read_text())
        if old.get('job_id') or old.get('status') in ['submitting','submission_uncertain']:
            raise SystemExit('Submission already recorded; query existing job or inspect uncertain status before retrying.')
    reference=root/a.reference;raw=reference.read_bytes()
    params={'Model':'3.1','EnablePBR':True,'GenerateType':'Normal'}
    record=dict(provider='Tencent Hunyuan 3D API',reference=a.reference,reference_sha256=hashlib.sha256(raw).hexdigest(),
        parameters=params,status='submitting',started_at=time.time())
    save()
    try:
        result=call('submit',{**params,'ImageBase64':base64.b64encode(raw).decode()})
        record['submit_response']=result
        body=result.get('Response',result)
        record['job_id']=body.get('JobId',body.get('job_id'))
        record['status']='submitted' if record['job_id'] else 'rejected'
    except Exception as e:
        record['status']='submission_uncertain';record['error']=str(e).replace(key,'[REDACTED]')
    save();print(json.dumps({k:record[k] for k in ['status','job_id','error','submit_response'] if k in record},ensure_ascii=False))
else:
    record=json.loads(manifest.read_text());assert record.get('job_id')
    result=call('query',{'JobId':record['job_id']});body=result.get('Response',result)
    record['last_query']=result;record['status']=body.get('Status',body.get('status','unknown'));save()
    print(json.dumps({'status':record['status'],'job_id':record['job_id'],'response_keys':list(body)},ensure_ascii=False))
    if record['status']=='DONE':
        for i,item in enumerate(body.get('ResultFile3Ds',[])):
            url=item.get('Url') or item.get('url');kind=(item.get('Type') or '').lower()
            if not url:continue
            suffix='glb' if kind=='glb' or '.glb' in url.split('?')[0].lower() else 'zip' if '.zip' in url.split('?')[0].lower() else None
            if suffix:
                target=out/('generated.'+suffix)
                if not target.exists():
                    with urllib.request.urlopen(url,timeout=120) as r:target.write_bytes(r.read())
                record['model']=target.name;record['model_sha256']=hashlib.sha256(target.read_bytes()).hexdigest();save()
                print('DOWNLOADED',target.name,target.stat().st_size)
