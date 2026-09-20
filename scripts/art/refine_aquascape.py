"""Create a lighter editable aquascape and separately animated, curved aquatic leaves."""
import bpy,json,math,random
from pathlib import Path
from mathutils import Vector
root=Path(__file__).resolve().parents[2];folder=root/'Sources/WhileAIWorks/Resources/AquariumAssets/Aquascape';out=root/'art/aquascape-v2'
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
a=json.loads((folder/'aquascape.json').read_text());coords=[(a['positions'][i],-a['positions'][i+2],a['positions'][i+1])for i in range(0,len(a['positions']),3)];faces=[a['indices'][i:i+3]for i in range(0,len(a['indices']),3)]
mesh=bpy.data.meshes.new('Preserved generated driftwood and stones');mesh.from_pydata(coords,[],faces);mesh.update();obj=bpy.data.objects.new('Driftwood - reduced display mesh',mesh);bpy.context.collection.objects.link(obj);bpy.context.view_layer.objects.active=obj;obj.select_set(True)
uv=mesh.uv_layers.new(name='UVMap')
for loop in mesh.loops:uv.data[loop.index].uv=a['uvs'][loop.vertex_index*2:loop.vertex_index*2+2]
for poly in mesh.polygons:poly.use_smooth=True
mat=bpy.data.materials.new('Original aquascape PBR');mat.use_nodes=True;p=mat.node_tree.nodes.new('ShaderNodeBsdfPrincipled');output=mat.node_tree.nodes.new('ShaderNodeOutputMaterial');mat.node_tree.links.new(p.outputs['BSDF'],output.inputs['Surface']);tex=mat.node_tree.nodes.new('ShaderNodeTexImage');tex.image=bpy.data.images.load(str(folder/'color.png'));mat.node_tree.links.new(tex.outputs['Color'],p.inputs['Base Color']);p.inputs['Roughness'].default_value=.78;obj.data.materials.append(mat)
mod=obj.modifiers.new('Game mesh - preserve silhouette','DECIMATE');mod.ratio=.24;bpy.ops.object.modifier_apply(modifier=mod.name)

def export_object(obj):
 data=obj.data;data.calc_loop_triangles();positions=[];normals=[];uvs=[];indices=[]
 uv=data.uv_layers.active
 for tri in data.loop_triangles:
  for li in tri.loops:
   v=data.vertices[data.loops[li].vertex_index].co;n=data.corner_normals[li].vector;t=uv.data[li].uv
   indices.append(len(indices));positions.extend([v.x,v.z,-v.y]);normals.extend([n.x,n.z,-n.y]);uvs.extend(t)
 return dict(version=1,positions=positions,normals=normals,uvs=uvs,indices=indices,colorTexture='color.png',surfaceTexture='surface.png')
display=export_object(obj);(folder/'aquascape-display.json').write_text(json.dumps(display,separators=(',',':')))
# Blade surfaces, not solid blobs. Each has its own root, curvature, taper and UV veins.
random.seed(72);vertices=[];leaf_uv=[];triangles=[];collision_points=[];collision_tri=[]
clusters=[(-2.85,.19,-.55,1.35,11,'ribbon'),(-2.35,.27,-.70,1.10,8,'ribbon'),(2.65,.16,-.42,1.48,12,'ribbon'),(2.22,.20,.45,.75,7,'broad'),(-2.7,.15,.52,.58,6,'broad')]
for cx,cy,cz,height,count,kind in clusters:
 begin=len(vertices)
 for leaf in range(count):
  angle=leaf*2.399963+random.random()*.3;length=height*random.uniform(.60,1.0);width=(.065 if kind=='ribbon'else .16)*random.uniform(.8,1.3);bend=random.uniform(.2,.55);base=len(vertices);steps=12
  for row in range(steps+1):
   t=row/steps;w=width*max(.015,math.sin(math.pi*t)**(.5 if kind=='broad'else .35));lean=bend*t*t
   for col in range(3):
    across=col-1;x=cx+math.cos(angle)*lean-math.sin(angle)*w*across;z=cz+math.sin(angle)*lean+math.cos(angle)*w*across;y=cy+length*t-.09*across*across*math.sin(math.pi*t)
    vertices.append((x,y,z));leaf_uv.append((col/2,t))
  for row in range(steps):
   for col in range(2):
    q=base+row*3+col;triangles.extend([(q,q+1,q+4),(q,q+4,q+3)])
 points=vertices[begin:];lo=[min(p[j]for p in points)-.08 for j in range(3)];hi=[max(p[j]for p in points)+.08 for j in range(3)];lo[1]=max(0,lo[1]);b=len(collision_points)
 collision_points.extend([(x,y,z)for x in [lo[0],hi[0]]for y in [lo[1],hi[1]]for z in [lo[2],hi[2]]])
 collision_tri.extend([tuple(b+i for i in t)for t in [(0,1,3),(0,3,2),(4,6,7),(4,7,5),(0,4,5),(0,5,1),(2,3,7),(2,7,6),(0,2,6),(0,6,4),(1,5,7),(1,7,3)]])
plant=bpy.data.meshes.new('Individually curved leaf blades');plant.from_pydata([(x,-z,y)for x,y,z in vertices],[],triangles);plant.update();leaves=bpy.data.objects.new('Aquatic leaves - flexible tips',plant);bpy.context.collection.objects.link(leaves);uv=plant.uv_layers.new(name='UVMap')
for loop in plant.loops:uv.data[loop.index].uv=leaf_uv[loop.vertex_index]
for poly in plant.polygons:poly.use_smooth=True
lm=bpy.data.materials.new('Aquatic leaf');lm.diffuse_color=(.12,.32,.12,1);lm.use_nodes=True;lp=lm.node_tree.nodes.new('ShaderNodeBsdfPrincipled');lo=lm.node_tree.nodes.new('ShaderNodeOutputMaterial');lm.node_tree.links.new(lp.outputs['BSDF'],lo.inputs['Surface']);lp.inputs['Base Color'].default_value=(.12,.32,.12,1);lp.inputs['Roughness'].default_value=.65;plant.materials.append(lm)
plants=export_object(leaves);plants['collisionPositions']=[v for p in collision_points for v in p];plants['collisionIndices']=[i for t in collision_tri for i in t];(folder/'plants.json').write_text(json.dumps(plants,separators=(',',':')))
bpy.ops.file.pack_all();bpy.ops.wm.save_as_mainfile(filepath=str(out/'aquascape-refined.blend'))
report={'originalTriangles':len(a['indices'])//3,'displayTriangles':len(display['indices'])//3,'plantTriangles':len(plants['indices'])//3,'leafCount':sum(c[4]for c in clusters),'collision':'Original terrain plus conservative leaf cluster boxes, including sway margin','originalPreserved':True};(out/'manifest.json').write_text(json.dumps(report,indent=2));print(report,flush=True)
