"""Create a local game-size mesh and a verified tail loop; preserve generated original."""
import bpy, math, json
from pathlib import Path
from mathutils import Vector
root=Path(__file__).resolve().parents[2];out=root/'art/provider-comparison-v1/hunyuan-crucian'
bpy.ops.wm.open_mainfile(filepath=str(out/'crucian-review.blend'))
scene=bpy.context.scene
meshes=[o for o in scene.objects if o.type=='MESH']
for obj in meshes:
    world=obj.matrix_world.copy();obj.parent=None;obj.matrix_world=world
    bpy.ops.object.select_all(action='DESELECT');obj.select_set(True);bpy.context.view_layer.objects.active=obj
    bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    mod=obj.modifiers.new('Local game LOD 50k','DECIMATE');mod.ratio=.1;mod.use_collapse_triangulate=True
    bpy.ops.object.modifier_apply(modifier=mod.name)
for im in bpy.data.images:
    if im.size[0]>2048 and im.name not in ['Render Result','Viewer Node']:im.scale(2048,2048);im.pack()
arm=bpy.data.armatures.new('Crucian skeleton');rig=bpy.data.objects.new('Crucian swim',arm);bpy.context.collection.objects.link(rig)
bpy.ops.object.select_all(action='DESELECT');rig.select_set(True);bpy.context.view_layer.objects.active=rig
bpy.ops.object.mode_set(mode='EDIT')
body=arm.edit_bones.new('body');body.head=(.65,0,-.08);body.tail=(-.25,0,-.08)
tail=arm.edit_bones.new('tail_base');tail.head=body.tail;tail.tail=(-.64,0,-.08);tail.parent=body;tail.use_connect=True
tip=arm.edit_bones.new('tail_fin');tip.head=tail.tail;tip.tail=(-1,0,-.08);tip.parent=tail;tip.use_connect=True
bpy.ops.object.mode_set(mode='OBJECT')
def smooth(x):
    x=max(0,min(1,x));return x*x*(3-2*x)
for obj in meshes:
    groups={n:obj.vertex_groups.new(name=n) for n in ['body','tail_base','tail_fin']}
    for v in obj.data.vertices:
        a=smooth((-v.co.x-.20)/.38);b=smooth((-v.co.x-.60)/.32)
        for n,w in {'body':1-a,'tail_base':a*(1-b),'tail_fin':a*b}.items():
            if w>0:groups[n].add([v.index],w,'REPLACE')
    mod=obj.modifiers.new('Swim deformation','ARMATURE');mod.object=rig;mod.use_deform_preserve_volume=True
for frame in range(1,50):
    phase=(frame-1)/48*math.tau
    for name,amp,lag in [('tail_base',.14,0),('tail_fin',.24,-.65)]:
        bone=rig.pose.bones[name];bone.rotation_mode='XYZ';bone.rotation_euler.z=amp*math.sin(phase+lag)
        bone.keyframe_insert(data_path='rotation_euler',frame=frame,group=name)
scene.frame_start=1;scene.frame_end=49;scene.render.fps=24
obj=meshes[0]
def coords(frame):
    scene.frame_set(frame);ev=obj.evaluated_get(bpy.context.evaluated_depsgraph_get());me=ev.to_mesh();v=[x.co.copy() for x in me.vertices];ev.to_mesh_clear();return v
v1=coords(1);v13=coords(13);v49=coords(49)
movement=max((a-b).length for a,b in zip(v1,v13));looperror=max((a-b).length for a,b in zip(v1,v49))
assert movement>.01 and looperror<1e-5,(movement,looperror)
scene.frame_set(1)
for ob in scene.objects:ob.select_set(ob in meshes or ob==rig)
bpy.ops.export_scene.gltf(filepath=str(out/'crucian-game-swim.glb'),use_selection=True,export_format='GLB',export_animations=True,export_animation_mode='ACTIVE_ACTIONS',export_skins=True)
scene.camera.location=(0,4,.6);scene.camera.rotation_euler=(-scene.camera.location).to_track_quat('-Z','Y').to_euler()
scene.render.resolution_x=800;scene.render.resolution_y=800;scene.cycles.samples=16
scene.render.filepath=str(out/'review-game-side.png');bpy.ops.render.render(write_still=True)
bpy.ops.wm.save_as_mainfile(filepath=str(out/'crucian-game-swim.blend'))
(out/'game-inspection.json').write_text(json.dumps(dict(triangles=sum(len(o.data.polygons) for o in meshes),vertices=sum(len(o.data.vertices) for o in meshes),maximum_displacement=movement,loop_error=looperror,bones=3,frames=[1,49],fps=24,textures=2048,scope='Body fixed; tail-base and tail-fin animated. Existing source texture seam retained, not yet retouched. Not integrated into app.'),indent=2))
scene.camera.location=(2.4,4,1.0);scene.camera.rotation_euler=(-scene.camera.location).to_track_quat('-Z','Y').to_euler()
scene.render.resolution_x=640;scene.render.resolution_y=640;scene.cycles.samples=8;scene.cycles.use_denoising=True
frames=out/'swim-frames';frames.mkdir(exist_ok=True)
for i in range(24):
    scene.frame_set(1+i*2);scene.render.filepath=str(frames/f'{i:04d}.png');bpy.ops.render.render(write_still=True)
print('CRUCIAN_GAME_READY',movement,looperror)
