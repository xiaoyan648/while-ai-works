"""Add a three-bone tail test to the actual generated mesh, retaining its UV/PBR maps."""
import bpy, math, json
from pathlib import Path
from mathutils import Vector

root=Path(__file__).resolve().parents[2]; out=root/'art/puffer-generated-v1'
bpy.ops.wm.open_mainfile(filepath=str(out/'puffer-textured-review.blend'))
scene=bpy.context.scene
holder=bpy.data.objects['Generated puffer - original geometry']
meshes=[o for o in scene.objects if o.type=='MESH']
arm=bpy.data.armatures.new('Puffer tail skeleton')
rig=bpy.data.objects.new('Puffer swim rig',arm); bpy.context.collection.objects.link(rig); rig.parent=holder
bpy.ops.object.select_all(action='DESELECT'); rig.select_set(True); bpy.context.view_layer.objects.active=rig
bpy.ops.object.mode_set(mode='EDIT')
body=arm.edit_bones.new('body'); body.head=(0,.45,0); body.tail=(0,-.12,0)
tail=arm.edit_bones.new('tail_base'); tail.head=body.tail; tail.tail=(0,-.34,0); tail.parent=body; tail.use_connect=True
tip=arm.edit_bones.new('tail_fin'); tip.head=tail.tail; tip.tail=(0,-.51,0); tip.parent=tail; tip.use_connect=True
bpy.ops.object.mode_set(mode='OBJECT')
counts={'body':0,'tail_base':0,'tail_fin':0}
for obj in meshes:
    groups={name:obj.vertex_groups.new(name=name) for name in counts}
    matrix=holder.matrix_world.inverted()@obj.matrix_world
    for v in obj.data.vertices:
        y=(matrix@v.co).y
        a=max(0,min(1,(-y-.08)/.20)); b=max(0,min(1,(-y-.29)/.17))
        weights={'body':1-a,'tail_base':a*(1-b),'tail_fin':a*b}
        for name,w in weights.items():
            if w>0: groups[name].add([v.index],w,'REPLACE'); counts[name]+=1
    modifier=obj.modifiers.new('Generated mesh - weighted tail test','ARMATURE'); modifier.object=rig
    modifier.use_deform_preserve_volume=True

for frame in range(1,50,6):
    phase=(frame-1)/48*math.tau
    for name,amplitude,lag in [('tail_base',.12,0),('tail_fin',.21,-.6)]:
        bone=rig.pose.bones[name]; bone.rotation_mode='XYZ'
        bone.rotation_euler.z=math.sin(phase+lag)*amplitude
        bone.keyframe_insert(data_path='rotation_euler',frame=frame,group=name)
scene.frame_start=1; scene.frame_end=49; scene.render.fps=24
scene.frame_set(1)
for obj in scene.objects: obj.select_set(obj==holder or obj==rig or obj in meshes)
bpy.context.view_layer.objects.active=rig
bpy.ops.export_scene.gltf(filepath=str(out/'puffer-swim-test.glb'),use_selection=True,export_format='GLB',
                          export_animations=True,export_animation_mode='ACTIVE_ACTIONS',export_skins=True)

# Check actual evaluated deformation instead of trusting the presence of keyframes.
obj=meshes[0]
def coords(frame):
    scene.frame_set(frame); dg=bpy.context.evaluated_depsgraph_get(); ev=obj.evaluated_get(dg); me=ev.to_mesh()
    values=[v.co.copy() for v in me.vertices]; ev.to_mesh_clear(); return values
a=coords(1); b=coords(13)
movement=max((p-q).length for p,q in zip(a,b))
assert movement>.002, 'Tail must actually deform the generated mesh'
scene.frame_set(1)
scene.camera.location=(3.6,3,.9)
scene.camera.rotation_euler=(-scene.camera.location).to_track_quat('-Z','Y').to_euler()
bpy.ops.wm.save_as_mainfile(filepath=str(out/'puffer-swim-test.blend'))
(out/'animation-inspection.json').write_text(json.dumps({'bones':list(counts),'weighted_vertices':counts,
    'maximum_local_displacement':movement,'loop_frames':[1,49],'fps':24,
    'scope':'Tail-only deformation test. Pectoral fins and mouth are not independently rigged.'},indent=2))

# Render a turntable while the tail cycle plays. Only the preview rotates the whole fish.
scene.render.resolution_x=720; scene.render.resolution_y=720; scene.render.resolution_percentage=100
scene.cycles.samples=12; scene.cycles.use_denoising=True
frames=out/'turntable-frames'; frames.mkdir(exist_ok=True)
for frame in range(96):
    scene.frame_set(1+frame%48)
    holder.rotation_euler.z=frame/96*math.tau
    scene.render.filepath=str(frames/f'{frame:04d}.png')
    bpy.ops.render.render(write_still=True)
print('ANIMATED_PUFFER_COMPLETE',movement,counts)
