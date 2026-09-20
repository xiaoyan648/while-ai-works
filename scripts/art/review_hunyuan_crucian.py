"""Import the generated GLB unchanged, stage it for inspection, and render four sides."""
import bpy, json
from pathlib import Path
from mathutils import Vector

root = Path(__file__).resolve().parents[2]
out = root/'art/provider-comparison-v1/hunyuan-crucian'
source = out/'generated.glb'
assert source.exists(), 'Generate and download the actual model first'
bpy.ops.object.select_all(action='SELECT'); bpy.ops.object.delete(use_global=False)
bpy.ops.import_scene.gltf(filepath=str(source))
meshes=[o for o in bpy.context.scene.objects if o.type=='MESH']
assert meshes, 'GLB must contain actual geometry'
points=[o.matrix_world@Vector(c) for o in meshes for c in o.bound_box]
lo=Vector(tuple(min(p[i] for p in points) for i in range(3)))
hi=Vector(tuple(max(p[i] for p in points) for i in range(3)))
center=(lo+hi)*.5; scale=2/max(hi-lo)
holder=bpy.data.objects.new('Generated crucian - original geometry',None)
bpy.context.collection.objects.link(holder)
for obj in list(bpy.context.scene.objects):
    if obj!=holder and obj.parent is None: obj.parent=holder
holder.scale=(scale,)*3; holder.location=-center*scale
report={
    'source':'generated.glb',
    'mesh_objects':len(meshes),
    'vertices':sum(len(o.data.vertices) for o in meshes),
    'triangles':sum(sum(len(p.vertices)-2 for p in o.data.polygons) for o in meshes),
    'uv_layers':sum(len(o.data.uv_layers) for o in meshes),
    'materials':[m.name for m in bpy.data.materials if m.users],
    'textures':[{'name':im.name,'size':list(im.size)} for im in bpy.data.images if im.size[0]>0 and im.name not in ['Render Result','Viewer Node']],
    'original_bounds':{'min':list(lo),'max':list(hi)},
    'review_changes':'Only uniform scale, centering, camera and lighting; source geometry and textures are retained.'
}
assert report['uv_layers'] and report['textures'], 'Textured 3D output required'
(out/'model-inspection.json').write_text(json.dumps(report,indent=2,ensure_ascii=False))

scene=bpy.context.scene
scene.world.use_nodes=True
bg=next(n for n in scene.world.node_tree.nodes if n.type=='BACKGROUND')
bg.inputs['Color'].default_value=(.055,.075,.08,1); bg.inputs['Strength'].default_value=.55
def area(name,pos,power,color,size):
    bpy.ops.object.light_add(type='AREA',location=pos); ob=bpy.context.object; ob.name=name
    ob.data.energy=power; ob.data.color=color; ob.data.shape='DISK'; ob.data.size=size
    ob.rotation_euler=(-ob.location).to_track_quat('-Z','Y').to_euler()
area('soft key',(-3,-4,5),350,(1,.94,.83),4)
area('cool soft fill',(4,-1,2),220,(.75,.88,1),4)
area('back softbox',(0,4,4),350,(1,1,1),3)
bpy.ops.object.camera_add(location=(0,-4,1))
cam=bpy.context.object; cam.data.type='ORTHO'; cam.data.ortho_scale=2.7; scene.camera=cam
scene.render.engine='CYCLES'; scene.cycles.samples=16
scene.render.resolution_x=800; scene.render.resolution_y=800; scene.render.resolution_percentage=100
scene.render.image_settings.file_format='PNG'; scene.view_settings.view_transform='AgX'
for name,pos in [('front',(0,4,.6)),('right',(4,0,.6)),('back',(0,-4,.6)),('left',(-4,0,.6))]:
    cam.location=pos; cam.rotation_euler=(-cam.location).to_track_quat('-Z','Y').to_euler()
    scene.render.filepath=str(out/('review-'+name+'.png'))
    bpy.ops.render.render(write_still=True)
cam.location=(2.6,-4,1.2); cam.rotation_euler=(-cam.location).to_track_quat('-Z','Y').to_euler()
bpy.ops.file.pack_all()
bpy.ops.wm.save_as_mainfile(filepath=str(out/'crucian-review.blend'))
print('REVIEW_COMPLETE',json.dumps(report))
