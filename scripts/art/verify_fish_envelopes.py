"""Check source hashes and all vertices at between-frame quaternion-interpolated poses."""
from pathlib import Path
import json,hashlib,sys,numpy as np
root=Path(__file__).resolve().parents[2];base=root/'Sources/WhileAIWorks/Resources/AquariumAssets';limits=json.loads((base/'fish-envelopes.json').read_text())
def quat(m):
    q=np.empty(4);trace=np.trace(m)
    if trace>0:
        s=np.sqrt(trace+1)*2;q[:]=[(m[2,1]-m[1,2])/s,(m[0,2]-m[2,0])/s,(m[1,0]-m[0,1])/s,s/4]
    else:
        i=int(np.argmax(np.diag(m)));j=(i+1)%3;k=(i+2)%3;s=np.sqrt(1+m[i,i]-m[j,j]-m[k,k])*2
        q[i]=s/4;q[j]=(m[j,i]+m[i,j])/s;q[k]=(m[k,i]+m[i,k])/s;q[3]=(m[k,j]-m[j,k])/s
    return q/np.linalg.norm(q)
def rotation(q):
    x,y,z,w=q
    return np.array([[1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],[2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],[2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]])
report={}
for id,limit in limits.items():
    if len(sys.argv)>1 and id not in sys.argv[1:]:continue
    path=base/'Puffer/puffer.json'if id=='puffer'else base/'Generated'/id/'fish.json';raw=path.read_bytes()
    assert hashlib.sha256(raw).hexdigest()==limit['sourceSHA256']
    a=json.loads(raw);points=np.array(a['positions']).reshape(-1,3);points=np.c_[points,np.ones(len(points))]
    count=a.get('influenceCount',3);w=np.array(a['weights']).reshape(-1,count);assert np.allclose(w.sum(axis=1),1,atol=1e-5)
    indices=np.array(a.get('influenceIndices',np.tile(np.arange(3),len(points)))).reshape(-1,count)
    binds=np.array(a['inverseBinds']).reshape(-1,4,4).transpose(0,2,1);frames=np.array(a['frames']).reshape(-1,len(binds),4,4).transpose(0,1,3,2)
    labelsRaw=(root/'art/aquarium-collision-v1'/f'{id}-collision-clusters.bin').read_bytes()
    assert hashlib.sha256(labelsRaw).hexdigest()==limit['triangleClusterSHA256']
    labels=np.frombuffer(labelsRaw,dtype=np.uint8);tri=np.array(a['indices']).reshape(-1,3)
    groups=[np.unique(tri[labels==i])for i in range(len(limit['spheres']))]
    maximum=0;tests=0
    for frame,(left,right)in enumerate(zip(frames[:-1],frames[1:])):
        t=[.17,.37,.71,.91][frame%4];pose=np.repeat(np.eye(4)[None],len(binds),axis=0)
        for bone in range(len(binds)):
            q1=quat(left[bone,:3,:3]);q2=quat(right[bone,:3,:3]);dot=np.dot(q1,q2)
            if dot<0:q2=-q2;dot=-dot
            theta=np.arccos(np.clip(dot,-1,1))
            q=(q1*(1-t)+q2*t)if theta<1e-6 else(q1*np.sin((1-t)*theta)+q2*np.sin(t*theta))/np.sin(theta)
            pose[bone,:3,:3]=rotation(q/np.linalg.norm(q));pose[bone,:3,3]=left[bone,:3,3]*(1-t)+right[bone,:3,3]*t
        transforms=pose@binds;v=np.zeros_like(points)
        for slot in range(count):v+=np.einsum('nij,nj->ni',transforms[indices[:,slot]],points)*w[:,slot,None]
        distance=np.linalg.norm(v[:,:3],axis=1);maximum=max(maximum,float(distance.max()));tests+=len(points)
        assert distance.max()<limit['radius'],(id,frame,distance.max(),limit['radius'])
        for group,ball in zip(groups,limit['spheres']):
            assert np.linalg.norm(v[group,:3]-ball['center'],axis=1).max()<ball['radius'],(id,frame,'local collider')
    report[id]={'interpolatedVerticesChecked':tests,'maximumRadius':maximum,'envelope':limit['radius'],'sourceHashMatches':True,'triangleClustersCovered':len(groups)}
(root/'.build/fish-envelope-verification.json').write_text(json.dumps(report,indent=2));print(f'{len(report)} fish: between-frame vertices fit their collision envelopes',sum(v['interpolatedVerticesChecked']for v in report.values()))
