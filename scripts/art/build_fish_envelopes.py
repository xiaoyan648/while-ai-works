"""Conservative origin-centred spheres enclosing every sampled skin pose + slerp bound."""
import hashlib,json,sys
from pathlib import Path
import numpy as np
root=Path(__file__).resolve().parents[2];base=root/'Sources/WhileAIWorks/Resources/AquariumAssets'
files=[('puffer',base/'Puffer/puffer.json')]+[(p.parent.name,p)for p in sorted((base/'Generated').glob('*/fish.json'))]
selected=set(sys.argv[1:])
if selected: files=[(id,path) for id,path in files if id in selected]
report=json.loads((base/"fish-envelopes.json").read_text()) if selected else {}
for id,path in files:
 raw=path.read_bytes();a=json.loads(raw);p=np.array(a['positions']).reshape(-1,3);p=np.c_[p,np.ones(len(p))]
 count=a.get('influenceCount',3);w=np.array(a['weights']).reshape(-1,count)
 inds=np.array(a.get('influenceIndices',np.tile(np.arange(3),len(p)))).reshape(-1,count)
 binds=np.array(a['inverseBinds']).reshape(-1,4,4).transpose(0,2,1)
 frames=np.array(a['frames']).reshape(-1,len(binds),4,4).transpose(0,1,3,2)
 max_radius=0.;motion_bound=0.
 for pose in frames:
  transforms=pose@binds;v=np.zeros((len(p),4))
  for slot in range(count):v+=np.einsum('nij,nj->ni',transforms[inds[:,slot]],p)*w[:,slot,None]
  max_radius=max(max_radius,np.linalg.norm(v[:,:3],axis=1).max())
 # Any interpolated rotation stays within this chord bound of its endpoint.
 # Translation is linear, hence contained in the convex hull of endpoint spheres.
 for bone in range(len(binds)):
  bp=(binds[bone]@p.T).T[:,:3];lever=np.linalg.norm(bp,axis=1).max()
  for left,right in zip(frames[:-1,bone],frames[1:,bone]):
   relative=left[:3,:3].T@right[:3,:3];angle=np.arccos(np.clip((np.trace(relative)-1)/2,-1,1))
   motion_bound=max(motion_bound,2*lever*np.sin(angle/2))
 radius=float(max_radius+motion_bound+.005)
 report[id]={'radius':radius,'sampledRadius':float(max_radius),'interpolationMargin':float(motion_bound+.005),'sourceSHA256':hashlib.sha256(raw).hexdigest()}
 print(id,round(radius,3))
(base/'fish-envelopes.json').write_text(json.dumps(report,indent=2))
