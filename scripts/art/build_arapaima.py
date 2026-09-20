"""Author a compact rounded arapaima mesh, projecting the generated specimen onto its sides.

No image pixels are modified: the source illustration is also the color texture.
The body has volume; dorsal, anal, caudal and pectoral fins are separate surfaces.
Output follows the existing native skin format and includes a two-second swim loop.
"""
import json, math, shutil
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'Sources/WhileAIWorks/Resources/AquariumAssets/Generated/arapaima'
OUT.mkdir(parents=True, exist_ok=True)
shutil.copy2(ROOT/'Sources/WhileAIWorks/Resources/FishAssets/arapaima.png', OUT/'color.png')
W,H=1774,887
S=2/1740
positions=[];uvs=[];faces=[]
def vertex(px,py,z):
    positions.append(((px-890)*S,(425-py)*S,z))
    uvs.append((px/W,1-py/H))
    return len(positions)-1
# Pixel coordinates align anatomy with the unmodified side-view painting.
profile=np.array([(235,365,470,.025),(330,296,535,.065),(500,267,566,.115),
 (700,253,579,.16),(900,250,590,.175),(1100,253,590,.17),
 (1250,280,579,.15),(1400,315,564,.12),(1550,366,542,.09),
 (1680,410,507,.048),(1758,439,470,.005)],float)
rings=104;sides=32
for px in np.linspace(profile[0,0],profile[-1,0],rings):
    top,bottom,depth=[np.interp(px,profile[:,0],profile[:,j]) for j in (1,2,3)]
    mid=(top+bottom)/2;radius=(bottom-top)/2
    for j in range(sides):
        angle=j*2*math.pi/sides
        vertex(px,mid-radius*math.cos(angle),depth*math.sin(angle))
for i in range(rings-1):
    for j in range(sides):
        a=i*sides+j;b=i*sides+(j+1)%sides;c=(i+1)*sides+j;d=(i+1)*sides+(j+1)%sides
        faces.extend([(a,b,c),(b,d,c)])
# Flat fin fans retain natural translucent edges from the illustration.
def fin(points,z,anchor):
    center=vertex(*anchor,z);edge=[vertex(x,y,z+dz) for x,y,dz in points]
    for a,b in zip(edge,edge[1:]+edge[:1]):faces.append((center,a,b))
fin([(28,365,0),(50,305,0),(115,277,0),(180,302,0),(265,365,0),
     (263,471,0),(168,533,0),(85,535,0),(31,486,0)],0,(180,412))
fin([(241,286,0),(265,238,0),(334,204,0),(418,207,0),(481,232,0),
     (575,266,0),(490,283,0),(330,315,0)],0,(382,275))
fin([(234,520,0),(295,578,0),(369,607,0),(449,607,0),(546,571,0),
     (496,544,0),(330,515,0)],0,(386,556))
for sign in (-1,1):
    fin([(1248,522,.01*sign),(1318,543,.015*sign),(1260,599,.055*sign),
         (1179,633,.10*sign),(1148,618,.10*sign),(1190,571,.055*sign)],.14*sign,(1248,553))
    fin([(769,563,.015*sign),(740,591,.04*sign),(670,624,.07*sign),
         (652,611,.07*sign),(687,579,.035*sign)],.15*sign,(719,585))
v=np.array(positions);tri=np.array(faces);normals=np.zeros_like(v)
for a,b,c in tri:
    n=np.cross(v[b]-v[a],v[c]-v[a]);n/=max(1e-10,np.linalg.norm(n))
    normals[a]+=n;normals[b]+=n;normals[c]+=n
normals/=np.maximum(1e-10,np.linalg.norm(normals,axis=1))[:,None]
anchors=[.48,-.10,-.68]
weights=[]
for x,y,z in positions:
    if x>=anchors[0]: w=[1,0,0]
    elif x>=anchors[1]: t=(anchors[0]-x)/(anchors[0]-anchors[1]);w=[1-t,t,0]
    elif x>=anchors[2]: t=(anchors[1]-x)/(anchors[1]-anchors[2]);w=[0,1-t,t]
    else:w=[0,0,1]
    weights.extend(w)
def columns(m):return m.T.flatten().round(8).tolist()
binds=[]
for x in anchors:
    m=np.eye(4);m[0,3]=-x;binds.append(columns(m))
frames=[]
for i in range(49):
    phase=i/48*2*math.pi;frame=[]
    for j,x in enumerate(anchors):
        angle=[.006,.045,.13][j]*math.sin(phase-j*.85)
        co,si=math.cos(angle),math.sin(angle)
        m=np.array([[co,0,si,x],[0,1,0,0],[-si,0,co,[0,.006,.023][j]*math.sin(phase-j*.85)],[0,0,0,1]])
        frame.append(columns(m))
    frames.append(frame)
asset=dict(version=1,positions=v.round(7).flatten().tolist(),normals=normals.round(7).flatten().tolist(),
 uvs=np.array(uvs).round(7).flatten().tolist(),indices=tri.flatten().tolist(),weights=weights,
 boneNames=['head','body','tail_fin'],inverseBinds=binds,frames=frames,fps=24,
 length=float(v[:,0].max()-v[:,0].min()),colorTexture='color.png')
(OUT/'fish.json').write_text(json.dumps(asset,separators=(',',':')))
print('arapaima',len(v),'vertices',len(tri),'triangles')
