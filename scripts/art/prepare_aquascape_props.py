"""Clean the two separately generated props; preserve source GLBs and UV textures."""
import bpy,json,math,struct,hashlib,subprocess
from pathlib import Path
from mathutils import Vector,Matrix
ROOT=Path(__file__).resolve().parents[2]
ART=ROOT/'art/aquascape-v3';RES=ROOT/'Sources/WhileAIWorks/Resources/AquariumAssets/Aquascape'
spec=json.loads((ART/'tasks.json').read_text())
C=Matrix(((1,0,0,0),(0,0,1,0),(0,-1,0,0),(0,0,0,1)))
# Runtime scenery transform is shared by display and conservative collision.
LOCAL=Matrix.Diagonal((1/.93,1/.9,1/.82,1))@Matrix.Translation((0,-.08,.97))
parts=[]
for asset in spec['assets']:
 ident=asset['id'];out=ART/ident;folder=RES/ident;folder.mkdir(exist_ok=True)
 bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
 bpy.ops.import_scene.gltf(filepath=str(out/'generated.glb'))
 objects=[o for o in bpy.context.scene.objects if o.type=='MESH'];assert len(objects)==1
 obj=objects[0];bpy.context.view_layer.objects.active=obj;obj.select_set(True)
 # Provider reference faces along X. Rotate the widest horizontal axis across the tank.
 obj.matrix_world=Matrix.Rotation(math.pi/2,4,"Z")@obj.matrix_world
 bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
 lo=Vector(tuple(min(v.co[i]for v in obj.data.vertices)for i in range(3)));hi=Vector(tuple(max(v.co[i]for v in obj.data.vertices)for i in range(3)))
 dx,dy,dz=asset['dimensionsXYZ'];cx,cz=asset['centerXZ'];size=hi-lo
 for v in obj.data.vertices:
  q=v.co-lo;v.co=(cx+(q.x/size.x-.5)*dx,-cz+(q.y/size.y-.5)*dz,.20+q.z/size.z*dy)
 bpy.ops.object.mode_set(mode='EDIT');bpy.ops.mesh.select_all(action='SELECT');bpy.ops.mesh.remove_doubles(threshold=.00001);bpy.ops.object.mode_set(mode='OBJECT')
 sourceFaces=len(obj.data.polygons)
 mod=obj.modifiers.new('Preserve silhouette and UVs','DECIMATE');mod.ratio=asset['triangleBudget']/sourceFaces;mod.use_collapse_triangulate=True;bpy.ops.object.modifier_apply(modifier=mod.name)
 if obj.data.has_custom_normals:bpy.ops.mesh.customdata_custom_splitnormals_clear()
 for p in obj.data.polygons:p.use_smooth=True
 for e in obj.data.edges:e.use_edge_sharp=False
 obj.name=ident
 raw=(out/'generated.glb').read_bytes();n=struct.unpack_from('<I',raw,12)[0];g=json.loads(raw[20:20+n]);binary=raw[28+n:];material=g['materials'][0];pbr=material['pbrMetallicRoughness'];textures={}
 for ref,name in [(pbr['baseColorTexture'],'color'),(pbr['metallicRoughnessTexture'],'surface'),(material.get('normalTexture'),'normal')]:
  if not ref:continue
  im=g['images'][g['textures'][ref['index']]['source']];view=g['bufferViews'][im['bufferView']];start=view.get('byteOffset',0);blob=binary[start:start+view['byteLength']]
  source=folder/(name+'.source');source.write_bytes(blob)
  subprocess.run([str(ROOT/'.build/puffer-generation-env/bin/python'),'-c','from PIL import Image;import sys;im=Image.open(sys.argv[1]);im.thumbnail((2048,2048));im.save(sys.argv[2])',str(source),str(folder/(name+'.png'))],check=True);source.unlink()
  textures[name]=hashlib.sha256((folder/(name+'.png')).read_bytes()).hexdigest()
 def export(model,name):
  data=model.data;data.calc_loop_triangles();data.calc_tangents();positions=[];normals=[];uvs=[];tangents=[];indices=[];seen={};M=LOCAL@C;N=M.to_3x3().inverted().transposed()
  for t in data.loop_triangles:
   for li in t.loops:
    loop=data.loops[li];v=data.vertices[loop.vertex_index];uv=data.uv_layers.active.data[li].uv;normal=(N@data.corner_normals[li].vector).normalized();tangent=(M.to_3x3()@loop.tangent).normalized()
    key=(v.index,*[round(x,6)for x in (*uv,*normal,*tangent)],loop.bitangent_sign)
    if key not in seen:
     seen[key]=len(positions)//3;positions.extend(round(x,7)for x in M@v.co);normals.extend(round(x,7)for x in normal);uvs.extend(uv);tangents.extend([*tangent,loop.bitangent_sign])
    indices.append(seen[key])
  a=dict(version=1,positions=positions,normals=normals,uvs=uvs,tangents=tangents,indices=indices,colorTexture='color.png',surfaceTexture='surface.png',normalTexture='normal.png')
  (folder/(name+'.json')).write_text(json.dumps(a,separators=(',',':')));return len(indices)//3
 high=export(obj,'prop');low=obj.copy();low.data=obj.data.copy();bpy.context.collection.objects.link(low);bpy.context.view_layer.objects.active=low
 mod=low.modifiers.new('Small preview LOD','DECIMATE');mod.ratio=.5;mod.use_collapse_triangulate=True;bpy.ops.object.modifier_apply(modifier=mod.name)
 lowCount=export(low,'prop-low');bpy.data.objects.remove(low,do_unlink=True)
 scene=bpy.context.scene;scene.world.use_nodes=True
 bg=next(n for n in scene.world.node_tree.nodes if n.type=='BACKGROUND');bg.inputs['Color'].default_value=(.07,.09,.10,1);bg.inputs['Strength'].default_value=.6
 target=Vector((cx,-cz,.2+dy*.48))
 for pos,power in [((-3,-4,6),650),((4,-2,4),380),((0,4,5),500)]:
  bpy.ops.object.light_add(type='AREA',location=target+Vector(pos));lamp=bpy.context.object;lamp.data.energy=power;lamp.data.size=4;lamp.rotation_euler=(target-lamp.location).to_track_quat('-Z','Y').to_euler()
 bpy.ops.object.camera_add(location=target+Vector((0,-6,1)));cam=bpy.context.object;cam.data.type='ORTHO';cam.data.ortho_scale=max(dx,dy)*1.25;scene.camera=cam
 scene.render.engine='CYCLES';scene.cycles.samples=12;scene.cycles.use_denoising=True;scene.render.resolution_x=700;scene.render.resolution_y=700;scene.render.resolution_percentage=100;scene.render.image_settings.file_format='PNG';scene.view_settings.view_transform='AgX'
 for name,offset in [('front',(0,-6,1)),('back',(0,6,1)),('side',(6,0,1))]:
  cam.location=target+Vector(offset);cam.rotation_euler=(target-cam.location).to_track_quat('-Z','Y').to_euler();scene.render.filepath=str(out/('game-'+name+'.png'));bpy.ops.render.render(write_still=True)
 bpy.ops.file.pack_all();bpy.ops.wm.save_as_mainfile(filepath=str(out/'prop-game.blend'))
 report={'sourceTriangles':sourceFaces,'displayTriangles':high,'previewTriangles':lowCount,'dimensionsXYZ':asset['dimensionsXYZ'],'centerXZ':asset['centerXZ'],'bottomY':.2,'texturesSHA256':textures,'sourceSHA256':hashlib.sha256(raw).hexdigest(),'coordinates':'Native data is inverse scenery transform of world-space Blender geometry; scene and collision use identical forward transform.'};(out/'native-export.json').write_text(json.dumps(report,indent=2));print(ident,report,flush=True)
 parts.append({'id':ident,'mesh':ident+'/prop.json','lowMesh':ident+'/prop-low.json'})
(RES/'props.json').write_text(json.dumps({'version':1,'parts':parts},indent=2))
