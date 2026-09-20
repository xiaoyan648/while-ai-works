"""Export a reviewed Blender three-bone fish to native SceneKit (X head, Y up)."""
import bpy,json,struct,hashlib,sys,argparse
from pathlib import Path
from mathutils import Matrix
root=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--id',required=True);p.add_argument('--source',required=True);p.add_argument('--rig',required=True);p.add_argument('--blend',required=True);p.add_argument('--glb',required=True)
a=p.parse_args(sys.argv[sys.argv.index('--')+1:]);source=root/a.source
out=root/'Sources/WhileAIWorks/Resources/AquariumAssets/Generated'/a.id;out.mkdir(parents=True,exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=str(source/a.blend));obj=next(o for o in bpy.context.scene.objects if o.type=='MESH');rig=bpy.data.objects[a.rig]
# Authored model +X head, +Z up, native +X head +Y up; proper rotation.
C=Matrix(((1,0,0,0),(0,0,1,0),(0,-1,0,0),(0,0,0,1)))
matrix=C@obj.matrix_world;normal_matrix=matrix.to_3x3().inverted().transposed()
names=[b.name for b in rig.data.bones];groups={g.index:g.name for g in obj.vertex_groups}
data=obj.data;data.calc_loop_triangles();data.calc_tangents()
positions=[];normals=[];uvs=[];weights=[];indices=[];tangents=[];influence_indices=[];seen={}
for tri in data.loop_triangles:
 for li in tri.loops:
  loop=data.loops[li];v=data.vertices[loop.vertex_index];uv=data.uv_layers.active.data[li].uv
  normal=(normal_matrix@data.corner_normals[li].vector).normalized();tangent=(matrix.to_3x3()@loop.tangent).normalized()
  key=(v.index,round(uv.x,7),round(uv.y,7),*(round(x,6) for x in normal),*(round(x,6) for x in tangent),loop.bitangent_sign)
  if key not in seen:
   seen[key]=len(positions)//3;positions.extend(round(x,7)for x in matrix@v.co);normals.extend(round(x,7)for x in normal);uvs.extend([round(uv.x,7),round(uv.y,7)]);tangents.extend([*(round(x,7)for x in tangent),loop.bitangent_sign])
   wg={groups[g.group]:g.weight for g in v.groups};pairs=sorted(enumerate(wg.get(n,0)for n in names),key=lambda x:x[1],reverse=True)[:4];pairs += [(0,0)]*(4-len(pairs));total=sum(w for i,w in pairs);assert total>.999;weights.extend(round(w/total,7)for i,w in pairs);influence_indices.extend(i for i,w in pairs)
  indices.append(seen[key])
def cols(m):return [round(m[r][c],8)for c in range(4)for r in range(4)]
inverse=[cols((C@rig.matrix_world@rig.data.bones[n].matrix_local@C.inverted()).inverted())for n in names]
frames=[]
for frame in range(1,50):
 bpy.context.scene.frame_set(frame);frames.append([cols(C@rig.matrix_world@rig.pose.bones[n].matrix@C.inverted())for n in names])
raw=(source/a.glb).read_bytes();size=struct.unpack_from('<I',raw,12)[0];gltf=json.loads(raw[20:20+size]);binary=raw[28+size:];mat=gltf['materials'][0];pbr=mat['pbrMetallicRoughness']
textures={}
for ref,name in [(pbr['baseColorTexture'],'color.png'),(pbr['metallicRoughnessTexture'],'surface.png'),(mat.get('normalTexture'),'normal.png')]:
 if ref is None:continue
 tex=gltf['textures'][ref['index']];im=gltf['images'][tex['source']];assert im['mimeType']=='image/png';view=gltf['bufferViews'][im['bufferView']];offset=view.get('byteOffset',0);content=binary[offset:offset+view['byteLength']];assert content.startswith(b'\x89PNG');(out/name).write_bytes(content);textures[name]=hashlib.sha256(content).hexdigest()
asset=dict(version=1,positions=positions,normals=normals,uvs=uvs,tangents=tangents,weights=weights,indices=indices,boneNames=names,influenceCount=4,influenceIndices=influence_indices,inverseBinds=inverse,frames=frames,fps=24,length=max(positions[0::3])-min(positions[0::3]),colorTexture='color.png',surfaceTexture='surface.png',normalTexture='normal.png'if'normal.png'in textures else None)
(out/'fish.json').write_text(json.dumps(asset,separators=(',',':')))
report=dict(species=a.id,source_sha256=hashlib.sha256(raw).hexdigest(),vertices=len(positions)//3,triangles=len(indices)//3,bones=len(names),frames=49,texture_sha256=textures,source=str(source.relative_to(root)/a.glb))
(source/'native-export.json').write_text(json.dumps(report,indent=2));print(report)
