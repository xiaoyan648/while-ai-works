"""Five-bone chain follows the generated long fish's surface distance, including S bends."""
import bpy,heapq,math
from mathutils import Vector,Quaternion
from mathutils.kdtree import KDTree

def make_long_rig(obj, head_upper=False):
    mesh=obj.data;vertices=[v.co.copy()for v in mesh.vertices];adj=[[]for _ in vertices]
    for edge in mesh.edges:
        a,b=edge.vertices;length=(vertices[a]-vertices[b]).length;adj[a].append((b,length));adj[b].append((a,length))
    seed=max((i for i,v in enumerate(vertices) if not head_upper or v.z>0),key=lambda i:vertices[i].x)
    distances=[math.inf]*len(vertices);distances[seed]=0;queue=[(0,seed)]
    while queue:
        cost,i=heapq.heappop(queue)
        if cost!=distances[i]:continue
        for j,w in adj[i]:
            alt=cost+w
            if alt<distances[j]:distances[j]=alt;heapq.heappush(queue,(alt,j))
    valid=[i for i,d in enumerate(distances)if math.isfinite(d)]
    assert len(valid)>len(vertices)*.7,'Main connected surface must include the fish body'
    tree=KDTree(len(valid))
    for i in valid:tree.insert(vertices[i],i)
    tree.balance()
    for i,d in enumerate(distances):
        if not math.isfinite(d):distances[i]=distances[tree.find(vertices[i])[1]]
    maximum=sorted(distances)[int(len(distances)*.998)]
    t=[min(1,d/maximum)for d in distances]
    def center(fraction):
        subset=[v for v,d in zip(vertices,t)if abs(d-fraction)<.025]
        if not subset:subset=[vertices[min(range(len(t)),key=lambda i:abs(t[i]-fraction))]]
        return sum(subset,Vector())/len(subset)
    points=[center(x)for x in [0,.25,.45,.65,.85,1.0]]
    names=['body','spine_1','spine_2','tail_base','tail_fin']
    arm=bpy.data.armatures.new('Long fish curved skeleton');rig=bpy.data.objects.new('Generated fish swim',arm);bpy.context.collection.objects.link(rig)
    bpy.ops.object.select_all(action='DESELECT');rig.select_set(True);bpy.context.view_layer.objects.active=rig;bpy.ops.object.mode_set(mode='EDIT')
    previous=None
    for i,name in enumerate(names):
        bone=arm.edit_bones.new(name);bone.head=points[i];bone.tail=points[i+1]
        if previous:bone.parent=previous;bone.use_connect=True
        previous=bone
    bpy.ops.object.mode_set(mode='OBJECT')
    groups={n:obj.vertex_groups.new(name=n)for n in names}
    for v,d in zip(mesh.vertices,t):
        u=max(0,min(4,(d-.15)/.2));i=min(3,int(u));w=max(0,min(1,u-i));w=w*w*(3-2*w)
        groups[names[i]].add([v.index],1-w,'REPLACE');groups[names[i+1]].add([v.index],w,'REPLACE')
    mod=obj.modifiers.new('Curved-body swimming','ARMATURE');mod.object=rig;mod.use_deform_preserve_volume=True
    axes={}
    for name in names[1:]:
        bone=arm.bones[name];direction=(bone.tail_local-bone.head_local).normalized()
        axis=direction.cross(Vector((0,1,0))).normalized()
        axes[name]=(bone.matrix_local.to_3x3().inverted()@axis).normalized()
    for frame in range(1,50):
        phase=(frame-1)/48*math.tau
        for i,name in enumerate(names[1:],1):
            bone=rig.pose.bones[name];bone.rotation_mode='QUATERNION'
            bone.rotation_quaternion=Quaternion(axes[name],(.025+i*.025)*math.sin(phase-i*.8))
            bone.keyframe_insert(data_path='rotation_quaternion',frame=frame,group=name)
    return rig,{'method':'surface-distance curved chain','bones':names,'path':[list(v)for v in points],'main_surface_fraction':len(valid)/len(vertices)}
