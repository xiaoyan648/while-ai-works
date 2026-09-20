"""Inspect a generated aquascape, retain its textures, and fit its solid mesh to the native tank."""
import bpy, json, struct, hashlib, subprocess, os
from pathlib import Path
from mathutils import Matrix, Vector

root=Path(__file__).resolve().parents[2]
source=root/'art/aquascape-generated-v1'
out=root/'Sources/WhileAIWorks/Resources/AquariumAssets/Aquascape'; out.mkdir(parents=True,exist_ok=True)
bpy.ops.object.select_all(action='SELECT'); bpy.ops.object.delete(use_global=False)
bpy.ops.import_scene.gltf(filepath=str(source/'generated.glb'))
meshes=[o for o in bpy.context.scene.objects if o.type=='MESH']
assert len(meshes)==1, 'Review multi-mesh generation before importing'
obj=meshes[0]; data=obj.data; data.calc_loop_triangles()
assert data.uv_layers.active
# Inspected aquascape image-facing +Y, image-right -X, up +Z -> native front +Z, right +X, up +Y.
C=Matrix(((-1,0,0,0),(0,0,1,0),(0,1,0,0),(0,0,0,1)))
points=[C@obj.matrix_world@v.co for v in data.vertices]
lo=Vector(tuple(min(p[i] for p in points) for i in range(3)))
hi=Vector(tuple(max(p[i] for p in points) for i in range(3)))
size=hi-lo; center=(lo+hi)*.5
# Environment is intentionally fitted across the floor, with headroom below the water.
fit=Vector((6.65/size.x,3.35/size.y,2.70/size.z))
M=Matrix.Translation(Vector((0,1.675,0)))@Matrix.Diagonal((*fit,1))@Matrix.Translation(-center)@C@obj.matrix_world
N=M.to_3x3().inverted().transposed()
positions=[]; normals=[]; uvs=[]; indices=[]; seen={}
for tri in data.loop_triangles:
    for li in tri.loops:
        vi=data.loops[li].vertex_index; uv=data.uv_layers.active.data[li].uv
        n=N@data.corner_normals[li].vector; n.normalize()
        key=(vi,round(uv.x,7),round(uv.y,7),*(round(v,6) for v in n))
        if key not in seen:
            seen[key]=len(positions)//3
            p=M@data.vertices[vi].co
            positions.extend(round(v,7) for v in p); normals.extend(round(v,7) for v in n)
            uvs.extend([round(uv.x,7),round(uv.y,7)])
        indices.append(seen[key])
raw=(source/'generated.glb').read_bytes(); js=struct.unpack_from('<I',raw,12)[0]
gltf=json.loads(raw[20:20+js]); binary=raw[28+js:]
assert len(gltf['materials'])==1
material=gltf['materials'][0]['pbrMetallicRoughness']
for key,name in [('baseColorTexture','color'),('metallicRoughnessTexture','surface')]:
    texture=gltf['textures'][material[key]['index']]
    image=gltf['images'][texture.get('source',texture.get('extensions',{}).get('EXT_texture_webp',{}).get('source'))]
    view=gltf['bufferViews'][image['bufferView']]; start=view.get('byteOffset',0)
    ext={'image/webp':'webp','image/png':'png','image/jpeg':'jpg'}[image['mimeType']]
    (out/(name+'.source.'+ext)).write_bytes(binary[start:start+view['byteLength']])
subprocess.run([os.environ.get('PUFFER_TEXTURE_PYTHON',str(root/'.build/puffer-generation-env/bin/python')),'-c','''
from pathlib import Path
from PIL import Image
import sys
p=Path(sys.argv[1])
for name in ('color','surface'):
    source=next(p.glob(name+'.source.*')); image=Image.open(source); target=p/(name+'.png')
    image.save(target); assert Image.open(target).tobytes()==image.tobytes(); source.unlink()
''',str(out)],check=True)
asset=dict(version=1,positions=positions,normals=normals,uvs=uvs,indices=indices,colorTexture='color.png',surfaceTexture='surface.png')
(out/'aquascape.json').write_text(json.dumps(asset,separators=(',',':')))
report=dict(source_sha256=hashlib.sha256(raw).hexdigest(),vertices=len(positions)//3,triangles=len(indices)//3,
    source_native_bounds=[list(lo),list(hi)],fit_scale=list(fit),native_dimensions=[6.65,3.35,2.7],
    textures='Original embedded textures decoded to PNG with identical pixels',notes='Solid scenery only; native glass and water are separate.')
(source/'native-export.json').write_text(json.dumps(report,indent=2))
# Save the original model with editable materials and review lighting. Do not modify the source GLB.
scene=bpy.context.scene; scene.world.use_nodes=True
bg=scene.world.node_tree.nodes.get('Background'); bg.inputs['Color'].default_value=(.045,.07,.075,1); bg.inputs['Strength'].default_value=.6
for pos,power in [((2,-3,4),250),((2,3,2),120),((-3,0,4),180)]:
    bpy.ops.object.light_add(type='AREA',location=pos); lamp=bpy.context.object
    lamp.data.energy=power; lamp.data.size=4; lamp.rotation_euler=(-lamp.location).to_track_quat('-Z','Y').to_euler()
bpy.ops.object.camera_add(location=(3,0,1)); cam=bpy.context.object; cam.data.type='ORTHO'; cam.data.ortho_scale=1.25; scene.camera=cam
scene.render.engine='CYCLES'; scene.cycles.samples=20; scene.cycles.use_denoising=True
scene.render.resolution_x=1000; scene.render.resolution_y=700; scene.render.resolution_percentage=100
scene.render.image_settings.file_format='PNG'; scene.view_settings.view_transform='AgX'
for name,pos in [('front',(0,3,.8)),('back',(0,-3,.8)),('side',(3,0,.8))]:
    cam.location=pos; cam.rotation_euler=(-cam.location).to_track_quat('-Z','Y').to_euler()
    scene.render.filepath=str(source/('review-'+name+'.png')); bpy.ops.render.render(write_still=True)
cam.location=(0,3,.8); cam.rotation_euler=(-cam.location).to_track_quat('-Z','Y').to_euler()
bpy.ops.file.pack_all(); bpy.ops.wm.save_as_mainfile(filepath=str(source/'aquascape-review.blend'))
print('AQUASCAPE_EXPORTED',report,flush=True)
