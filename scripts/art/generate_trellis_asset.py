"""Resumable single TRELLIS.2 asset job. Never provisions paid compute.

One session contains preprocessing, generation and export. Existing completed jobs
are reused; failures are recorded and stop the caller rather than switching services.
"""
from pathlib import Path
from gradio_client import Client, handle_file
import argparse, json, shutil, hashlib, time, struct

parser = argparse.ArgumentParser()
parser.add_argument('--reference', required=True)
parser.add_argument('--output', required=True)
parser.add_argument('--seed', type=int, default=42)
parser.add_argument('--triangles', type=int, default=100000)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
reference = (root / args.reference).resolve()
out = (root / args.output).resolve(); out.mkdir(parents=True, exist_ok=True)
manifest = out/'generation-manifest.json'
if manifest.exists():
    previous = json.loads(manifest.read_text())
    if previous.get('status') == 'completed' and (out/'generated.glb').exists():
        print('REUSING_COMPLETED', out, flush=True)
        raise SystemExit(0)
record = dict(provider='microsoft/TRELLIS.2', reference=str(reference.relative_to(root)),
    reference_sha256=hashlib.sha256(reference.read_bytes()).hexdigest(),
    seed=args.seed, resolution='1024', texture_size=2048,
    decimation_target=args.triangles, status='preparing', started_at=time.time())
def save():
    manifest.write_text(json.dumps(record, ensure_ascii=False, indent=2))
def step(status):
    record['status']=status; save(); print(status, flush=True)
save()
try:
    client = Client('microsoft/TRELLIS.2', verbose=False, download_files=str(out/'downloads'))
    client.predict(api_name='/start_session')
    prepared = client.predict(handle_file(str(reference)), api_name='/preprocess_image')
    step('generating')
    preview = client.predict(image=handle_file(prepared), seed=args.seed, resolution='1024', api_name='/image_to_3d')
    (out/'provider-preview.html').write_text(preview)
    step('exporting')
    model, download = client.predict(decimation_target=args.triangles, texture_size=2048, api_name='/extract_glb')
    raw = Path(model).read_bytes()
    assert raw[:4] == b'glTF' and struct.unpack_from('<I',raw,8)[0] == len(raw)
    shutil.copy2(model, out/'generated.glb')
    record.update(model='generated.glb', model_sha256=hashlib.sha256(raw).hexdigest(), completed_at=time.time())
    step('completed')
except Exception as exc:
    record.update(error_type=type(exc).__name__, error=str(exc), failed_at=time.time())
    step('failed')
    print(type(exc).__name__+': '+str(exc), flush=True)
    raise SystemExit(1)
