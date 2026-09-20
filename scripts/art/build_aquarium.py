"""Reproducible Blender source art; run with Blender --background --python this_file.

No external models or textures. Meshes, materials and loopable shape-key animation
are authored here. JSON is a small native-runtime mesh interchange, GLB is portable.
"""
import bpy, math, random, json
from pathlib import Path
from mathutils import Vector
from mathutils.noise import noise_vector

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'art/aquarium3d'
RES = ROOT / 'Sources/WhileAIWorks/Resources/AquariumAssets/Models'
OUT.mkdir(parents=True, exist_ok=True); RES.mkdir(parents=True, exist_ok=True)
random.seed(42)
bpy.ops.object.select_all(action='SELECT'); bpy.ops.object.delete(use_global=False)
MATS = {}
GROUPS = {}

def mat(name, rgb, rough=.55, metal=0):
    m = bpy.data.materials.new(name); m.diffuse_color = (*rgb, 1)
    m.use_nodes = True
    p = next((n for n in m.node_tree.nodes if n.type == 'BSDF_PRINCIPLED'), None)
    if p is None:
        p = m.node_tree.nodes.new('ShaderNodeBsdfPrincipled')
        output = m.node_tree.nodes.new('ShaderNodeOutputMaterial')
        m.node_tree.links.new(p.outputs['BSDF'], output.inputs['Surface'])
    p.inputs['Base Color'].default_value = (*rgb,1)
    p.inputs['Roughness'].default_value = rough
    p.inputs['Metallic'].default_value = metal
    MATS[name] = dict(color=list(rgb), roughness=rough, metalness=metal)
    return m

sand = mat('warm fine sand', (.49,.43,.29),.95)
stone = [mat('slate '+str(i), (.16+i*.018,.21+i*.016,.20+i*.015), .85) for i in range(4)]
wood = [mat('driftwood '+str(i), (.12+i*.022,.072+i*.013,.039+i*.009),.87) for i in range(4)]
leafm = [mat('leaf '+str(i), c,.52) for i,c in enumerate([
    (.08,.23,.105),(.12,.31,.13),(.19,.37,.12),(.25,.42,.17),(.10,.28,.22),(.29,.33,.12)])]
black = mat('obsidian pupil',(.009,.016,.018),.14)
iris = mat('antique gold iris',(.55,.48,.24),.3,.25)
white = mat('eye catchlight',(.80,.92,.87),.18)

def register(obj, group):
    GROUPS.setdefault(group,[]).append(obj); obj['asset_group'] = group
    collection=bpy.data.collections.get(group)
    if collection is None:
        collection=bpy.data.collections.new(group); bpy.context.scene.collection.children.link(collection)
    for previous in list(obj.users_collection): previous.objects.unlink(obj)
    collection.objects.link(obj)
    return obj

def mesh(name, vertices, faces, material, group, assignments=None):
    data = bpy.data.meshes.new(name); data.from_pydata(vertices,[],faces); data.update()
    obj = bpy.data.objects.new(name,data); bpy.context.collection.objects.link(obj)
    materials = material if isinstance(material,list) else [material]
    for m in materials: data.materials.append(m)
    for i,p in enumerate(data.polygons):
        p.use_smooth=True
        if assignments: p.material_index=assignments[i]
    return register(obj,group)

def ellipsoid(name, pos, scale, material, group, subdivisions=2):
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=subdivisions, radius=1, location=pos)
    obj=bpy.context.object; obj.name=name; obj.scale=scale
    obj.data.materials.append(material)
    for p in obj.data.polygons: p.use_smooth=True
    return register(obj,group)

def tube(name, points, radii, material, group, sides=8):
    if 'wood' in name:
        old=points; rr=radii; points=[]; radii=[]
        for i in range(len(old)-1):
            p0=Vector(old[max(0,i-1)]); p1=Vector(old[i]); p2=Vector(old[i+1]); p3=Vector(old[min(len(old)-1,i+2)])
            for j in range(5):
                t=j/5
                p=.5*((2*p1)+(-p0+p2)*t+(2*p0-5*p1+4*p2-p3)*t*t+(-p0+3*p1-3*p2+p3)*t*t*t)
                points.append(tuple(p)); radii.append(rr[i]*(1-t)+rr[i+1]*t)
        points.append(old[-1]); radii.append(rr[-1])
    verts=[]; faces=[]
    for i,p in enumerate(points):
        direction=Vector(points[min(i+1,len(points)-1)])-Vector(points[max(i-1,0)])
        direction.normalize(); side=direction.cross(Vector((0,0,1)))
        if side.length<.01: side=direction.cross(Vector((0,1,0)))
        side.normalize(); up=direction.cross(side).normalized()
        for j in range(sides):
            v=Vector(p)+radii[i]*(math.cos(j*math.tau/sides)*side+math.sin(j*math.tau/sides)*up)
            verts.append(tuple(v))
        if i:
            for j in range(sides): faces.append(((i-1)*sides+j,(i-1)*sides+(j+1)%sides,i*sides+(j+1)%sides,i*sides+j))
    faces += [tuple(reversed(range(sides))),tuple((len(points)-1)*sides+j for j in range(sides))]
    return mesh(name,verts,faces,material,group)

# A sloping planted island and a clean foreground sand corridor.
verts=[]; faces=[]
for iy in range(29):
    y=-1.45+iy*2.9/28
    for ix in range(57):
        x=-3.45+ix*6.9/56
        z=.065+.018*math.sin(x*12+y*9)+.017*random.random()+.18*max(0,y+.1)
        z+=.14*math.exp(-((x+2.2)**2+(y-.7)**2)*1.1)
        verts.append((x,y,z))
        if ix and iy:
            a=iy*57+ix; faces.append((a-58,a-57,a,a-1))
mesh('contoured sand bed',verts,faces,sand,'environment')
for i in range(33):
    if i<8:
        x,y=random.uniform(-2.9,-1.5),random.uniform(-.25,1)
        scale=(random.uniform(.3,.72),random.uniform(.3,.5),random.uniform(.35,.8))
    else:
        x,y=random.uniform(-3.1,3.1),random.uniform(-1.25,1.25)
        if abs(x)<1.3: continue
        scale=(random.uniform(.07,.27),random.uniform(.06,.22),random.uniform(.05,.22))
    obj=ellipsoid('weathered river stone',(x,y,scale[2]*.45+.1),scale,random.choice(stone),'environment')
    for v in obj.data.vertices:
        n=noise_vector(v.co*3.6); v.co*=1+n.x*.18
    obj.rotation_euler=(random.random()*.35,random.random()*.4,random.random()*3)

branches=[([(-2.5,.4,.22),(-2.2,.35,.65),(-1.65,.3,1.12),(-.95,.38,1.55),(-.3,.55,1.78)], [.22,.21,.15,.075,.014]),
          ([(-1.85,.33,.98),(-1.5,.42,1.65),(-1.7,.55,2.05),(-1.55,.6,2.35)],[.12,.075,.04,.009]),
          ([(-1.02,.4,1.5),(-.9,.7,1.97),(-.56,.84,2.2)],[.065,.033,.007]),
          ([(-2.2,.35,.66),(-2.72,.14,1.12),(-2.95,.3,1.55)],[.12,.068,.009]),
          ([(2.72,.8,.15),(2.28,.7,.6),(1.85,.95,.85),(1.5,1.13,1.15)],[.15,.12,.07,.01])]
for i,(points,radii) in enumerate(branches):
    tube('tapered driftwood branch',points,radii,wood[i%4],'environment',12)
    for k in range(3):
        angle=k*2.1
        grooved=[(x+math.cos(angle)*r*.87,y+math.sin(angle)*r*.87,z) for (x,y,z),r in zip(points,radii)]
        tube('wood grain ridge',grooved,[r*.12 for r in radii],wood[(i+1)%4],'environment',5)

def leaf(base, length, width, angle, lean, group, material):
    verts=[]; faces=[]
    for i in range(10):
        t=i/9; w=width*math.sin(math.pi*t)**.7
        center=Vector(base)+Vector((math.cos(angle)*lean*t*t,math.sin(angle)*lean*t*t,length*t))
        for s in [-1,-.5,0,.5,1]:
            v=center+Vector((-math.sin(angle)*w*s, math.cos(angle)*w*s, -.07*s*s*math.sin(t*math.pi)))
            verts.append(tuple(v))
        if i:
            for k in range(4):
                a=i*5+k; faces.append((a-5,a-4,a+1,a))
    obj=mesh('arched aquatic leaf',verts,faces,material,group)
    return obj

for side in [-1,1]:
    for clump in range(11):
        x=side*random.uniform(2.1,3.15); y=random.uniform(.15,1.18)
        base=(x,y,.14+max(0,y)*.18)
        for j in range(random.randint(7,11)):
            leaf(base,random.uniform(.65,1.75),random.uniform(.06,.12),random.random()*math.tau,random.uniform(.15,.6),
                 'plants-back',random.choice(leafm[:5]))
    for clump in range(6):
        base=(side*random.uniform(1.95,3.1),random.uniform(-1.05,.2),.14)
        for j in range(6):
            leaf(base,random.uniform(.25,.6),random.uniform(.10,.19),random.random()*math.tau,random.uniform(.2,.5),
                 'plants-front',random.choice(leafm))

# Fish: longitudinal lofts, tapered peduncles, forked fins, gills and eyes.
# Parameters deliberately preserve species silhouettes rather than recolouring one sphere.
specs={
 'crucian':(.31,.15,(.52,.46,.27)), 'carp':(.30,.17,(.63,.33,.12)),
 'sardine':(.16,.095,(.37,.62,.66)), 'perch':(.27,.13,(.39,.49,.21)),
 'trout':(.22,.12,(.52,.57,.53)), 'catfish':(.19,.18,(.23,.31,.31)),
 'salmon':(.24,.13,(.47,.56,.57)), 'eel':(.10,.10,(.24,.32,.22)),
 'puffer':(.38,.31,(.66,.59,.30)), 'koi':(.28,.16,(.86,.84,.72)),
 'tuna':(.27,.15,(.20,.39,.53)), 'oarfish':(.13,.05,(.67,.70,.72)),
 'moonfish':(.45,.13,(.49,.56,.75)), 'dragon':(.27,.15,(.21,.57,.43))}

def fish_asset(sid, height, thickness, color):
    group='fish-'+sid
    dark=tuple(c*.48 for c in color); light=tuple(min(.95,c*.63+.32) for c in color)
    palette=[mat(sid+' flank',color,.46,.10),mat(sid+' back',dark,.42,.13),mat(sid+' belly',light,.4,.12),
             mat(sid+' fins',tuple(c*.75 for c in color),.48,.08),
             mat(sid+' markings',(.66,.14,.075) if sid=='koi' else dark,.4,.15)]
    vs=[]; fs=[]; mi=[]; rings=40; sides=24
    elong=1.55 if sid in ('eel','oarfish') else 1
    for i in range(rings+1):
        t=i/rings; x=(-.72+1.46*t)*elong
        # Slender tail, full shoulder, rounded snout.
        r=.045+.955*math.sin(math.pi*t)**.7
        if sid=='puffer': r=.05+.95*math.sin(math.pi*t)**.47
        for j in range(sides):
            a=j*math.tau/sides
            vs.append((x,math.cos(a)*thickness*r,math.sin(a)*height*r))
        if i:
            for j in range(sides):
                a=(j+.5)*math.tau/sides
                fs.append(((i-1)*sides+j,(i-1)*sides+(j+1)%sides,i*sides+(j+1)%sides,i*sides+j))
                idx=1 if math.sin(a)>.60 else (2 if math.sin(a)<-.40 else 0)
                if sid=='perch' and i%8<2 and .15<t<.85 and math.sin(a)>-.3: idx=4
                if sid=='koi' and math.sin(t*23+math.cos(a)*6)> .3 and math.sin(a)>-.4: idx=4
                if sid in ('trout','salmon','puffer') and i%4==j%4==0 and math.sin(a)>-.35: idx=4
                mi.append(idx)
    fs.extend([tuple(reversed(range(sides))),tuple(rings*sides+j for j in range(sides))]); mi.extend([0,0])
    body = mesh(sid+' sculpted body',vs,fs,palette,group,mi)
    mod=body.modifiers.new('smoothed anatomical loft','SUBSURF'); mod.levels=1; mod.render_levels=1
    # Forked tail, built in bands so bending reads as a fin rather than a flat triangle.
    tailx=-.72*elong
    tailh=.23 if sid not in ('eel','oarfish','puffer') else .11
    verts=[]; faces=[]
    for row in range(6):
        t=row/5
        for col in range(13):
            s=col/6-1
            x=tailx-.48*t+(.16*(1-abs(s))*t*t)
            verts.append((x,.025*math.sin(s*math.pi)*t,s*(.045+tailh*t)))
            if row and col:
                a=row*13+col; faces.append((a-14,a-13,a,a-1))
    mesh(sid+' flexible caudal fin',verts,faces,palette[3],group)
    # Fin rays and dorsal sail.
    dorsalh=.27 if sid in ('perch','moonfish','dragon') else .15
    if sid=='oarfish': dorsalh=.13
    points=[(-.54*elong,0,height*.65),(-.32*elong,0,height+dorsalh),(.05,0,height+dorsalh*.85),(.36,0,height*.8)]
    mesh(sid+' dorsal fin',points,[(0,1,2,3)],palette[4] if sid=='oarfish' else palette[3],group)
    for k in range(5):
        t=.15+k/6; x=(-.48+.60*t)*elong
        tube('dorsal ray',[(x,0,height*.7),(x-.10,0,height+math.sin(t*math.pi)*dorsalh)], [.008,.003],palette[3],group,4)
    for side in [-1,1]:
        mesh(sid+' pectoral fin',[(.27,side*thickness*.8,-.02),(.03,side*thickness*2,-.2),(-.16,side*thickness*1.7,-.13),(.09,side*thickness*.9,-.06)],[(0,1,2,3)],palette[3],group)
        # Eyes sit on the shoulder plane, not on the end of the snout.
        ex=.51*elong; ey=side*thickness*.75; ez=height*.28
        ellipsoid('iris',(ex,ey,ez),(.049,.021,.049),iris,group,2)
        ellipsoid('pupil',(ex+.01,ey+side*.017,ez),(.028,.009,.031),black,group,2)
        ellipsoid('eye glint',(ex+.019,ey+side*.024,ez+.012),(.009,.006,.009),white,group,1)
        tube('gill cover',[(.31*elong,side*thickness*.86,height*.45),(.26*elong,side*thickness*1.015,0),(.3*elong,side*thickness*.81,-height*.45)], [.006]*3,palette[1],group,5)
        if sid in ('carp','catfish','dragon'):
            tube('sensory barbel',[(.68*elong,side*.08,-.035),(.8*elong,side*.18,-.10),(.79*elong,side*.30,-.18)], [.013,.008,.002],palette[2],group,6)
    if sid=='puffer':
        for i in range(36):
            t=.23+random.random()*.52; a=random.random()*math.tau
            r=math.sin(math.pi*t)**.47
            p=Vector((-.72+1.46*t,math.cos(a)*thickness*r,math.sin(a)*height*r))
            n=Vector((0,math.cos(a),math.sin(a)))
            tube('short puffer spine',[tuple(p),tuple(p+n*.04)],[.012,.001],palette[2],group,4)
    return group

for sid,(h,w,c) in specs.items(): fish_asset(sid,h,w,c)

# Export evaluated Blender meshes in right-handed Y-up coordinates for SceneKit.
def export_group(group):
    batches={}; dg=bpy.context.evaluated_depsgraph_get()
    for obj in GROUPS[group]:
        evaluated=obj.evaluated_get(dg); data=evaluated.to_mesh(); data.calc_loop_triangles()
        matrix=obj.matrix_world; normal_matrix=matrix.to_3x3().inverted().transposed()
        for tri in data.loop_triangles:
            m=data.materials[tri.material_index]; batch=batches.setdefault(m.name,dict(material=m.name,vertices=[],normals=[],indices=[]))
            for vi in tri.vertices:
                v=matrix@data.vertices[vi].co; n=(normal_matrix@data.vertices[vi].normal).normalized()
                batch['indices'].append(len(batch['vertices'])//3)
                batch['vertices'].extend(round(q,5) for q in (v.x,v.z,-v.y))
                batch['normals'].extend(round(q,5) for q in (n.x,n.z,-n.y))
        evaluated.to_mesh_clear()
    result=dict(version=1,name=group,materials=MATS,meshes=list(batches.values()))
    (RES/(group+'.json')).write_text(json.dumps(result,separators=(',',':')))
    return sum(len(b['indices'])//3 for b in batches.values())

bpy.context.view_layer.update()
counts={g:export_group(g) for g in GROUPS}

# Blender animation: eight keyed shape poses, cyclic tail travelling-wave / plant sway.
for group,objects in GROUPS.items():
    if not (group.startswith('fish-') or group.startswith('plants-')): continue
    for obj in objects:
        if obj.type!='MESH': continue
        obj.shape_key_add(name='Basis')
        for pose in range(8):
            key=obj.shape_key_add(name='flow_%02d'%pose)
            phase=pose*math.tau/8
            for i,v in enumerate(obj.data.vertices):
                x,y,z=v.co
                if group.startswith('fish-'):
                    weight=max(0,min(1, (.35-x)/1.6))**1.65
                    key.data[i].co.y+=math.sin(phase+x*3.8)*weight*.13
                else:
                    key.data[i].co.x+=math.sin(phase+z*1.8+y)*max(0,z-.15)*.022
            for frame,value in [(1+pose*12-12,0),(1+pose*12,1),(1+pose*12+12,0)]:
                key.value=value; key.keyframe_insert(data_path='value',frame=frame)
            if pose==0:
                key.value=1; key.keyframe_insert(data_path='value',frame=97)
            key.value=0

# Portable models export neutral + morph data. Separate collection visibility is editable.
bpy.context.scene.frame_start=1; bpy.context.scene.frame_end=97; bpy.context.scene.render.fps=24
bpy.context.scene.frame_set(1)
for group in GROUPS:
    bpy.ops.object.select_all(action='DESELECT')
    for obj in GROUPS[group]: obj.select_set(True)
    bpy.ops.export_scene.gltf(filepath=str(OUT/(group+'.glb')),use_selection=True,export_format='GLB',export_animations=True,export_animation_mode='ACTIVE_ACTIONS',export_morph=True)

# Stage six representative fish in a planted, open-water composition for the .blend preview.
placements={'crucian':(-.8,-.3,2.0),'carp':(.8,.1,2.5),'sardine':(1.5,-.5,1.3),
            'perch':(-.3,.65,1.4),'koi':(-1.0,.7,2.85),'trout':(1.0,.8,3.0)}
for group,objects in GROUPS.items():
    if group.startswith('fish-'):
        sid=group[5:]
        parent=bpy.data.objects.new(sid+' animated specimen',None); bpy.data.collections[group].objects.link(parent)
        if sid in placements:
            parent.location=placements[sid]; parent.scale=(.68,.68,.68)
        for obj in objects:
            obj.parent=parent
            obj.hide_render=sid not in placements
            obj.hide_set(sid not in placements)


def area(name,pos,power,color,size,target=(0,0,1)):
    bpy.ops.object.light_add(type='AREA',location=pos); o=bpy.context.object; o.name=name
    o.data.energy=power; o.data.color=color; o.data.shape='DISK'; o.data.size=size
    o.rotation_euler=(Vector(target)-o.location).to_track_quat('-Z','Y').to_euler()
area('large warm surface softbox',(-2,-2,6),950,(.85,1,.91),5)
area('cool water rim',(2,2,4),1100,(.40,.78,1),4)
area('front fill',(0,-4,2.6),200,(.64,.85,1),5)
bpy.ops.object.camera_add(location=(.25,-10.8,5.0))
camera=bpy.context.object; camera.rotation_euler=(Vector((0,0,1.65))-camera.location).to_track_quat('-Z','Y').to_euler()
camera.data.type='ORTHO'; camera.data.ortho_scale=7.7; bpy.context.scene.camera=camera
scene=bpy.context.scene; scene.world.use_nodes=True
worldbg=next(n for n in scene.world.node_tree.nodes if n.type=='BACKGROUND')
worldbg.inputs['Color'].default_value=(.035,.095,.105,1); worldbg.inputs['Strength'].default_value=.5
scene.render.engine='CYCLES'; scene.cycles.samples=32
scene.render.resolution_x=1200; scene.render.resolution_y=900; scene.render.resolution_percentage=100
scene.view_settings.view_transform='AgX'; scene.render.image_settings.file_format='PNG'
scene.render.film_transparent=False; scene.frame_start=1; scene.frame_end=96; scene.render.fps=24
scene.render.filepath=str(OUT/'blender-preview.png')
scene.frame_set(1)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'aquarium-study.blend'))
(OUT/'mesh-report.json').write_text(json.dumps(dict(triangles=counts,total=sum(counts.values())),indent=2))
bpy.ops.render.render(write_still=True)
print('AQUARIUM_ASSETS_COMPLETE',counts)
