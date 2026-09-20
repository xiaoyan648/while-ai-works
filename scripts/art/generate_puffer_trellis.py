"""One image-to-3D trial through Microsoft's public TRELLIS.2 Space.

Uses the published Gradio API, its standard settings and the same session for export.
No credential, subscription or paid compute is provisioned by this script.
"""
from pathlib import Path
from gradio_client import Client, handle_file
import json, shutil, hashlib, time

root = Path(__file__).resolve().parents[2]
out = root / 'art/puffer-generated-v1'
out.mkdir(parents=True, exist_ok=True)
reference = root / 'Sources/WhileAIWorks/Resources/FishAssets/puffer.png'
record = {
    'provider': 'microsoft/TRELLIS.2',
    'reference': str(reference.relative_to(root)),
    'reference_sha256': hashlib.sha256(reference.read_bytes()).hexdigest(),
    'seed': 42, 'resolution': '1024', 'texture_size': 2048,
    'decimation_target': 100000, 'status': 'preparing',
    'previous_attempt': {'provider': 'Rodin plugin free trial', 'result': 'API_INSUFFICIENT_FUNDS', 'task_created': False},
}
def save(): (out/'generation-manifest.json').write_text(json.dumps(record, ensure_ascii=False, indent=2))
save()
try:
    client = Client('microsoft/TRELLIS.2', verbose=False, download_files=str(out/'downloads'))
    print('Starting session', flush=True)
    client.predict(api_name='/start_session')
    prepared = client.predict(handle_file(str(reference)), api_name='/preprocess_image')
    record['status'] = 'generating'; save()
    print('Generating textured model from the reference', flush=True)
    preview = client.predict(image=handle_file(prepared), seed=42, resolution='1024', api_name='/image_to_3d')
    (out/'provider-preview.html').write_text(preview)
    record['status'] = 'exporting'; save()
    print('Exporting GLB', flush=True)
    model, download = client.predict(decimation_target=100000, texture_size=2048, api_name='/extract_glb')
    shutil.copy2(model, out/'puffer-generated.glb')
    record['status']='completed'; record['model']='puffer-generated.glb'; save()
    print('MODEL_DOWNLOADED', out/'puffer-generated.glb', flush=True)
except Exception as exc:
    record['status']='failed'; record['error']=str(exc); save()
    print(type(exc).__name__ + ': ' + str(exc), flush=True)
    raise SystemExit(1)
