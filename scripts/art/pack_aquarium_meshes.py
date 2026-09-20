"""Build exact float32/uint streams; original source JSON remains editable and auditable."""
from pathlib import Path
import json,struct,hashlib
root=Path(__file__).resolve().parents[2]/'Sources/WhileAIWorks/Resources/AquariumAssets'
paths=list((root/'Generated').glob('*/fish.json'))+[root/'Puffer/puffer.json',root/'Aquascape/aquascape.json',root/'Aquascape/aquascape-display.json',root/'Aquascape/plants.json']
paths += [p for p in (root/'Aquascape').glob('*/prop*.json') if not p.name.endswith('.meta.json')]
for path in paths:
    raw=path.read_bytes();meta=json.loads(raw);blob=bytearray();ranges={}
    for name,kind,fmt in [('positions','f32','f'),('normals','f32','f'),('uvs','f32','f'),('weights','f32','f'),('indices','u32','I'),('influenceIndices','u16','H'),('tangents','f32','f')]:
        if name not in meta or meta[name] is None:continue
        values=meta.pop(name)
        while len(blob)%4:blob.append(0)
        ranges[name]={'offset':len(blob),'count':len(values),'type':kind}
        blob.extend(struct.pack('<'+fmt*len(values),*values))
    meta['_buffers']=ranges;meta['_sourceSHA256']=hashlib.sha256(raw).hexdigest()
    path.with_suffix('.meta.json').write_text(json.dumps(meta,separators=(',',':')))
    path.with_suffix('.meshbin').write_bytes(blob)
    print(path.parent.name,len(blob))
