"""Export the approved mesh, original texture pixels and Blender skeleton to SceneKit.

Run with Blender --background --python-exit-code 1 --python this_file.py.
PUFFER_TEXTURE_PYTHON can point to a Python interpreter with Pillow installed.
"""
import bpy, json, struct, hashlib, os, subprocess
from pathlib import Path
from mathutils import Matrix

root=Path(__file__).resolve().parents[2]
source=root/'art/puffer-generated-v1'
out=root/'Sources/WhileAIWorks/Resources/AquariumAssets/Puffer'; out.mkdir(exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=str(source/'puffer-swim-test.blend'))
holder=bpy.data.objects['Generated puffer - original geometry']
obj=next(o for o in bpy.context.scene.objects if o.type=='MESH')
rig=bpy.data.objects['Puffer swim rig']
# Blender head +Y, up +Z -> application head +X, up +Y, preserving handedness.
C=Matrix(((0,1,0,0),(0,0,1,0),(1,0,0,0),(0,0,0,1)))
matrix=C@holder.matrix_world.inverted()@obj.matrix_world
normal_matrix=matrix.to_3x3().inverted().transposed()
bone_names=['body','tail_base','tail_fin']
group_names={g.index:g.name for g in obj.vertex_groups}
data=obj.data; data.calc_loop_triangles()
positions=[]; normals=[]; uvs=[]; weights=[]; indices=[]; seen={}
for triangle in data.loop_triangles:
    for li in triangle.loops:
        loop=data.loops[li]; vi=loop.vertex_index; v=data.vertices[vi]
        uv=data.uv_layers.active.data[li].uv
        normal=normal_matrix@data.corner_normals[li].vector; normal.normalize()
        key=(vi,round(uv.x,7),round(uv.y,7),*(round(x,6) for x in normal))
        if key not in seen:
            seen[key]=len(positions)//3
            p=matrix@v.co
            positions.extend(round(x,7) for x in p); normals.extend(round(x,7) for x in normal)
            uvs.extend([round(uv.x,7),round(uv.y,7)])
            wg={group_names[g.group]:g.weight for g in v.groups}
            ws=[wg.get(n,0) for n in bone_names]; total=sum(ws)
            assert total>.999
            weights.extend(round(w/total,7) for w in ws)
        indices.append(seen[key])

def columns(m): return [round(m[r][c],8) for c in range(4) for r in range(4)]
inverse_binds=[columns(C@rig.data.bones[n].matrix_local.inverted()@C.inverted()) for n in bone_names]
frames=[]
for frame in range(1,50):
    bpy.context.scene.frame_set(frame)
    frames.append([columns(C@rig.pose.bones[n].matrix@C.inverted()) for n in bone_names])

# Extract the original embedded WebP textures, then preserve their decoded pixels as PNG.
raw=(source/'puffer-swim-test.glb').read_bytes()
json_size=struct.unpack_from('<I',raw,12)[0]; gltf=json.loads(raw[20:20+json_size])
binary=raw[28+json_size:]
material=gltf['materials'][0]['pbrMetallicRoughness']
for key,name in [('baseColorTexture','color.png'),('metallicRoughnessTexture','surface.png')]:
    texture=gltf['textures'][material[key]['index']]
    im=gltf['images'][texture.get('source', texture.get('extensions',{}).get('EXT_texture_webp',{}).get('source'))]; assert im['mimeType']=='image/webp'
    view=gltf['bufferViews'][im['bufferView']]; offset=view.get('byteOffset',0)
    content=binary[offset:offset+view['byteLength']]; assert content.startswith(b'RIFF')
    (out/name).with_suffix('.webp').write_bytes(content)

texture_python = os.environ.get('PUFFER_TEXTURE_PYTHON', str(root/'.build/puffer-generation-env/bin/python'))
subprocess.run([texture_python, '-c', '''
import sys
from pathlib import Path
from PIL import Image
for name in ('color', 'surface'):
    original = Path(sys.argv[1]) / (name + '.webp')
    image = Image.open(original)
    target = original.with_suffix('.png')
    image.save(target)
    saved = Image.open(target)
    assert saved.mode == image.mode and saved.size == image.size
    assert saved.tobytes() == image.tobytes(), 'Texture pixel conversion changed content'
    original.unlink()
''', str(out)], check=True)

asset=dict(version=1,positions=positions,normals=normals,uvs=uvs,weights=weights,indices=indices,
    boneNames=bone_names,inverseBinds=inverse_binds,frames=frames,fps=24,
    length=max(positions[0::3])-min(positions[0::3]),colorTexture='color.png',surfaceTexture='surface.png')
(out/'puffer.json').write_text(json.dumps(asset,separators=(',',':')))
report=dict(source_sha256=hashlib.sha256(raw).hexdigest(),vertices=len(positions)//3,triangles=len(indices)//3,
    bones=len(bone_names),frames=len(frames),textures='Embedded WebP decoded to PNG with identical pixels; no repainting',
    geometry='Approved mesh retained without decimation')
(source/'native-export.json').write_text(json.dumps(report,indent=2)); print(report)
