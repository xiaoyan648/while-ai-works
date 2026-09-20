"""Cover complete animated triangles with compact local spheres, preserving source hashes."""
from pathlib import Path
import json,sys,numpy as np
root=Path(__file__).resolve().parents[2];base=root/'Sources/WhileAIWorks/Resources/AquariumAssets';path=base/'fish-envelopes.json';report=json.loads(path.read_text())
(root/'art/aquarium-collision-v1').mkdir(parents=True,exist_ok=True)
for id,record in report.items():
    if len(sys.argv)>1 and id not in sys.argv[1:]: continue
    asset=base/'Puffer/puffer.json'if id=='puffer'else base/'Generated'/id/'fish.json';a=json.loads(asset.read_text())
    points=np.array(a['positions']).reshape(-1,3);tri=np.array(a['indices']).reshape(-1,3);centroids=points[tri].mean(axis=1)
    k=24 if id in ['eel','oarfish'] else 16
    centers=[centroids[np.argmax(centroids[:,0])]];distances=np.full(len(centroids),np.inf)
    for _ in range(k-1):
        distances=np.minimum(distances,((centroids-centers[-1])**2).sum(axis=1));centers.append(centroids[np.argmax(distances)])
    centers=np.array(centers)
    for _ in range(12):
        labels=((centroids[:,None,:]-centers[None,:,:])**2).sum(axis=2).argmin(axis=1)
        centers=np.array([centroids[labels==i].mean(axis=0)if np.any(labels==i)else centers[i]for i in range(k)])
    groups=[np.unique(tri[labels==i])for i in range(k)];radii=np.zeros(k);homogeneous=np.c_[points,np.ones(len(points))]
    count=a.get('influenceCount',3);w=np.array(a['weights']).reshape(-1,count);inds=np.array(a.get('influenceIndices',np.tile(np.arange(3),len(points)))).reshape(-1,count)
    binds=np.array(a['inverseBinds']).reshape(-1,4,4).transpose(0,2,1);frames=np.array(a['frames']).reshape(-1,len(binds),4,4).transpose(0,1,3,2)
    for pose in frames:
        transform=pose@binds;vertices=np.zeros_like(homogeneous)
        for slot in range(count):vertices+=np.einsum('nij,nj->ni',transform[inds[:,slot]],homogeneous)*w[:,slot,None]
        for i,group in enumerate(groups):radii[i]=max(radii[i],np.linalg.norm(vertices[group,:3]-centers[i],axis=1).max())
    record['spheres']=[{'center':center.tolist(),'radius':float(radius+record['interpolationMargin'])}for center,radius in zip(centers,radii)]
    record['triangleClusterSHA256']=__import__('hashlib').sha256(labels.astype(np.uint8).tobytes()).hexdigest()
    (root/'art/aquarium-collision-v1'/f'{id}-collision-clusters.bin').write_bytes(labels.astype(np.uint8).tobytes())
    print(id,k,round(float(radii.max()),3),flush=True)
path.write_text(json.dumps(report,indent=2))
