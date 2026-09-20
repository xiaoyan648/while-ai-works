"""Resumable Hyper3D generation through the user-selected Volcengine Ark endpoint.

The interactive server keeps its credential in memory only. Submit commands never
retry an ambiguous POST; query commands reuse the persisted task ID.
Run --serve, enter the API key at the hidden prompt, then send JSON commands:
  {"action":"submit","id":"carp"}
  {"action":"query","id":"carp"}
  {"action":"exit"}
Alternatively use --action and --id with ARK_API_KEY set by your secret manager.
"""
import argparse,base64,getpass,hashlib,json,os,re,sys,time,urllib.request,urllib.error
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
BASE='https://ark.cn-beijing.volces.com/api/v3/contents/generations/tasks'
MODEL='hyper3d-gen2-260112'

def run(key,command):
    species=command['id'];assert re.fullmatch('[a-z]+',species)
    kind=command.get('kind','fish')
    assert kind in ('fish','aquascape'), 'Unknown asset kind'
    specification=None
    if kind=='aquascape':
        catalog=json.loads((ROOT/'art/aquascape-v3/tasks.json').read_text())
        specification=next((a for a in catalog['assets'] if a['id']==species),None)
        assert specification is not None, 'Unknown aquascape prop'
    out=ROOT/('art/aquascape-v3' if kind=='aquascape' else 'art/volcengine-fish-v1')/species
    out.mkdir(parents=True,exist_ok=True)
    path=out/'generation-manifest.json'
    def save(record):
        tmp=path.with_suffix('.tmp');tmp.write_text(json.dumps(record,ensure_ascii=False,indent=2));tmp.replace(path)
    def api(method,url,payload=None):
        req=urllib.request.Request(url,data=json.dumps(payload).encode() if payload is not None else None,
            headers={'Authorization':'Bearer '+key,'Content-Type':'application/json'},method=method)
        try:
            with urllib.request.urlopen(req,timeout=120) as response:return json.load(response)
        except urllib.error.HTTPError as e:
            raw=e.read().decode(errors='replace').replace(key,'[REDACTED]')
            error=RuntimeError('HTTP '+str(e.code)+' '+raw[:1200]);error.http_status=e.code;raise error
    if command['action']=='submit':
        if path.exists():raise RuntimeError('Manifest exists; reuse query, never automatically resubmit')
        ref=ROOT/specification['reference'] if specification else ROOT/'Sources/WhileAIWorks/Resources/FishAssets'/f'{species}.png'
        raw=ref.read_bytes()
        prompt=f'Generate one complete textured 3D {species} fish from this single side-view reference. Reconstruct a natural three-dimensional fish with consistent details on both sides, distinct eyes, gills, fins and tail. Preserve the reference silhouette and coloration. Straight neutral swimming pose, tail extended, no stand, no ground, no water, no props. Suitable for a realistic miniature aquarium game.'
        if specification:prompt=specification['prompt']
        record=dict(asset_kind=kind,provider='Volcengine Ark',model=MODEL,species=species,reference=str(ref.relative_to(ROOT)),reference_sha256=hashlib.sha256(raw).hexdigest(),prompt=prompt,seed=8648,status='submitting',started_at=time.time())
        save(record)
        try:
            result=api('POST',BASE,{'model':MODEL,'content':[{'type':'text','text':prompt},{'type':'image_url','image_url':{'url':'data:image/png;base64,'+base64.b64encode(raw).decode()}}],'seed':8648})
            record['task_id']=result.get('id');record['status']='submitted' if record['task_id'] else 'response_without_task_id';record['submit_response']=result
        except Exception as e:
            record['status']='rejected' if getattr(e,'http_status',0) in [400,401,403,404,422,429] else 'submission_uncertain';record['error']=str(e).replace(key,'[REDACTED]')
        save(record)
    else:
        record=json.loads(path.read_text());assert record.get('task_id'),'No existing task to query'
        result=api('GET',BASE+'/'+record['task_id']);record['status']=result.get('status','unknown');record['last_query_at']=time.time()
        # Persist metadata, never signed result links or the credential.
        record['result_metadata']={k:v for k,v in result.items() if k!='content'}
        save(record)
        if record['status']=='succeeded':
            url=result.get('content',{}).get('file_url')
            assert url and url.startswith('https://'),'Expected HTTPS model file URL'
            target=out/'generated.glb'
            if not target.exists():
                with urllib.request.urlopen(url,timeout=180) as response:raw=response.read()
                assert raw[:4]==b'glTF','Expected binary glTF model'
                temp=target.with_suffix('.part');temp.write_bytes(raw);temp.replace(target)
            record['model_file']=target.name;record['model_bytes']=target.stat().st_size;record['model_sha256']=hashlib.sha256(target.read_bytes()).hexdigest();save(record)
    return {k:record[k] for k in ['species','status','task_id','model_file','model_bytes','error'] if k in record}

def main():
    p=argparse.ArgumentParser();p.add_argument('--serve',action='store_true');p.add_argument('--action',choices=['submit','query']);p.add_argument('--id');p.add_argument('--kind',choices=['fish','aquascape'],default='fish');args=p.parse_args()
    key=os.environ.get('ARK_API_KEY') or getpass.getpass('Ark API key (hidden): ')
    if not key:raise SystemExit('Missing API key')
    if args.serve:
        print('READY',flush=True)
        for line in sys.stdin:
            try:
                command=json.loads(line)
                if command.get('action')=='exit':break
                print(json.dumps(run(key,command),ensure_ascii=False),flush=True)
            except Exception as e:print(json.dumps({'error':str(e).replace(key,'[REDACTED]')}),flush=True)
    else:print(json.dumps(run(key,{'action':args.action,'id':args.id,'kind':args.kind}),ensure_ascii=False))
if __name__=='__main__':main()
