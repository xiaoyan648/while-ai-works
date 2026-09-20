import Foundation
import simd

struct AquariumBall: Decodable {
    let center: SIMD3<Float>
    let radius: Float
    init(center: SIMD3<Float>, radius: Float) { self.center=center;self.radius=radius }
    private enum CodingKeys: String, CodingKey { case center, radius }
    init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self),v=try c.decode([Float].self,forKey:.center)
        guard v.count==3 else { throw CocoaError(.fileReadCorruptFile) }
        center=SIMD3(v[0],v[1],v[2]);radius=try c.decode(Float.self,forKey:.radius)
    }
}

/// Conservative terrain columns cover every triangle AABB of the transformed scenery.
/// Branch overhangs count as solid down to the sand; fish never cut under thin branches.
final class AquariumCollisionField {
    let isOpenWater:Bool
    let cell: Float = 0.16
    let minimum = AquariumLayout.minimum
    let maximum = AquariumLayout.maximum
    let width: Int, depth: Int
    private(set) var heights: [Float]
    init(positions: [SIMD3<Float>], indices: [UInt32]) {
        isOpenWater=positions.isEmpty
        width = Int(ceil((maximum.x-minimum.x)/cell)); depth = Int(ceil((maximum.z-minimum.z)/cell))
        heights = Array(repeating: minimum.y, count: width * depth)
        for i in stride(from: 0, to: indices.count, by: 3) {
            let a = AquariumLayout.sceneryPoint(positions[Int(indices[i])])
            let b = AquariumLayout.sceneryPoint(positions[Int(indices[i+1])])
            let c = AquariumLayout.sceneryPoint(positions[Int(indices[i+2])])
            let lo = simd_min(a,simd_min(b,c)), hi = simd_max(a,simd_max(b,c))
            let x0 = max(0,Int(floor((lo.x-minimum.x)/cell))), x1 = min(width-1,Int(floor((hi.x-minimum.x)/cell)))
            let z0 = max(0,Int(floor((lo.z-minimum.z)/cell))), z1 = min(depth-1,Int(floor((hi.z-minimum.z)/cell)))
            if x0 > x1 || z0 > z1 { continue }
            for z in z0...z1 { for x in x0...x1 { heights[z*width+x] = max(heights[z*width+x],hi.y+0.025) } }
        }
    }
    func isFree(_ p: SIMD3<Float>, radius r: Float) -> Bool {
        if p.x-r < minimum.x || p.y-r < minimum.y || p.z-r < minimum.z || p.x+r > maximum.x || p.y+r > maximum.y || p.z+r > maximum.z { return false }
        let x0=max(0,Int((p.x-r-minimum.x)/cell)),x1=min(width-1,Int((p.x+r-minimum.x)/cell))
        let z0=max(0,Int((p.z-r-minimum.z)/cell)),z1=min(depth-1,Int((p.z+r-minimum.z)/cell))
        for z in z0...z1 { for x in x0...x1 {
            let lo=SIMD3(minimum.x+Float(x)*cell,minimum.y,minimum.z+Float(z)*cell)
            let hi=SIMD3(lo.x+cell,heights[z*width+x],lo.z+cell)
            let closest=simd_min(simd_max(p,lo),hi)
            if simd_length_squared(p-closest) < r*r { return false }
        } }
        return true
    }
    func segmentFree(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: Float) -> Bool {
        // Exact distance from a segment to each occupied terrain box. An enclosing
        // midpoint sphere incorrectly blocks sideways movement beside a wall.
        let lo=simd_min(a,b)-SIMD3(repeating:radius), hi=simd_max(a,b)+SIMD3(repeating:radius)
        if lo.x<minimum.x || lo.y<minimum.y || lo.z<minimum.z || hi.x>maximum.x || hi.y>maximum.y || hi.z>maximum.z { return false }
        let x0=max(0,Int((lo.x-minimum.x)/cell)),x1=min(width-1,Int((hi.x-minimum.x)/cell))
        let z0=max(0,Int((lo.z-minimum.z)/cell)),z1=min(depth-1,Int((hi.z-minimum.z)/cell))
        let delta=b-a
        for z in z0...z1 { for x in x0...x1 {
            if heights[z*width+x]<lo.y { continue }
            let boxLo=SIMD3(minimum.x+Float(x)*cell,minimum.y,minimum.z+Float(z)*cell)
            let boxHi=SIMD3(boxLo.x+cell,heights[z*width+x],boxLo.z+cell)
            var cuts:[Float]=[0,1]
            for axis in 0..<3 where abs(delta[axis])>0.0000001 {
                for edge in [boxLo[axis],boxHi[axis]] {
                    let t=(edge-a[axis])/delta[axis]
                    if t>0 && t<1 { cuts.append(t) }
                }
            }
            cuts.sort()
            for i in 0..<(cuts.count-1) {
                let midpoint=(cuts[i]+cuts[i+1])*0.5
                var quadratic:Float=0,linear:Float=0
                for axis in 0..<3 {
                    let p=a[axis]+delta[axis]*midpoint
                    if p<boxLo[axis] || p>boxHi[axis] {
                        let boundary=p<boxLo[axis] ? boxLo[axis]:boxHi[axis]
                        quadratic += delta[axis]*delta[axis];linear += delta[axis]*(a[axis]-boundary)
                    }
                }
                let t=quadratic>0 ? min(cuts[i+1],max(cuts[i],-linear/quadratic)):midpoint
                let p=a+delta*t,closest=simd_min(simd_max(p,boxLo),boxHi)
                if simd_length_squared(p-closest)<radius*radius { return false }
            }
        } }
        return true
    }
}

final class AquariumNavigation {
    struct Agent {
        var position: SIMD3<Float>
        var forward: SIMD3<Float>
        var target: SIMD3<Float>
        let radius: Float
        let body: [AquariumBall]
        var orientation = simd_quatf(angle:0,axis:SIMD3<Float>(0,1,0))
        var retarget: Float
        var cruisePhase:Float=0
        var cruiseLane:Int=0
        var turn:Float=0
        var velocity = SIMD3<Float>(repeating:0)
        var steering = SIMD3<Float>(1,0,0)
        var blockedTime:Float = 0
        var distanceTravelled: Float = 0
        var path: [SIMD3<Float>] = []
    }
    let field: AquariumCollisionField
    private(set) var agents: [String:Agent] = [:]
    private struct Grid { let points: [SIMD3<Float>]; let links: [[Int]] }
    private var grids: [String:Grid] = [:]
    private var random: UInt64 = 0xA9136B
    private var iteration = 0
    init(field: AquariumCollisionField) { self.field=field }
    private func number() -> Float {
        random = random &* 6364136223846793005 &+ 1442695040888963407
        return Float(random >> 40)/Float(1<<24)
    }
    private func candidates(id: String, radius: Float, body: [AquariumBall]) -> [SIMD3<Float>] {
        let key=id+"-"+String(radius.bitPattern), r:Float=0.18
        let reversed=simd_quatf(angle:Float.pi,axis:SIMD3<Float>(0,1,0))
        func fits(_ p: SIMD3<Float>) -> Bool {
            body.allSatisfy { field.isFree(p+$0.center,radius:$0.radius+0.015) && field.isFree(p+simd_act(reversed,$0.center),radius:$0.radius+0.015) }
        }
        if let found=grids[key] { return found.points }
        var result:[SIMD3<Float>]=[]
        var y=field.minimum.y+r+0.015
        while y<=field.maximum.y-r {
            var z=field.minimum.z+r+0.015
            while z<=field.maximum.z-r {
                var x=field.minimum.x+r+0.015
                while x<=field.maximum.x-r {
                    let p=SIMD3(x,y,z)
                    if fits(p) { result.append(p) }
                    x += 0.32
                }; z += 0.32
            }; y += 0.32
        }
        let origin=field.minimum+SIMD3(repeating:r+0.015)
        let coordinates=result.map { p in SIMD3<Int>(Int(round((p.x-origin.x)/0.32)),Int(round((p.y-origin.y)/0.32)),Int(round((p.z-origin.z)/0.32))) }
        let lookup=Dictionary(uniqueKeysWithValues:coordinates.enumerated().map{($0.element,$0.offset)})
        let offsets=[SIMD3<Int>(1,0,0),SIMD3(-1,0,0),SIMD3(0,1,0),SIMD3(0,-1,0),SIMD3(0,0,1),SIMD3(0,0,-1)]
        var links=Array(repeating:[Int](),count:result.count)
        for (i,c) in coordinates.enumerated() {
            for offset in offsets {
                if let j=lookup[c &+ offset], body.allSatisfy({ lineFree(result[i]+$0.center,result[j]+$0.center,radius:$0.radius) && lineFree(result[i]+simd_act(reversed,$0.center),result[j]+simd_act(reversed,$0.center),radius:$0.radius) }) { links[i].append(j) }
            }
        }
        var visited=Set<Int>(), largest:[Int]=[]
        for start in result.indices where !visited.contains(start) {
            var component=[start],cursor=0;visited.insert(start)
            while cursor<component.count {
                for j in links[component[cursor]] where !visited.contains(j) { visited.insert(j);component.append(j) }
                cursor += 1
            }
            if component.count>largest.count { largest=component }
        }
        let remap=Dictionary(uniqueKeysWithValues:largest.enumerated().map{($0.element,$0.offset)})
        let grid=Grid(points:largest.map{result[$0]},links:largest.map{links[$0].compactMap{remap[$0]}})
        grids[key]=grid;return grid.points
    }
    func configure(radii: [String:Float], shapes: [String:[AquariumBall]] = [:]) throws {
        if Set(radii.keys)==Set(agents.keys) && radii.allSatisfy({ abs((agents[$0.key]?.radius ?? 0)-$0.value)<0.0001 }) { return }
        if field.isOpenWater {
            var prepared:[String:Agent]=[:]
            for (index,id) in radii.keys.sorted().enumerated() {
                let lane=index/3,phase = -Float.pi/2+0.45+Float(index%3)*Float.pi*2/3+Float(lane)*0.9
                let pose=cruise(phase:phase,lane:lane)
                var a=Agent(position:pose.position,forward:unit(pose.tangent),target:pose.position,radius:radii[id]!,body:shapes[id] ?? [AquariumBall(center:.zero,radius:radii[id]!)],retarget:0)
                a.orientation=heading(a.forward);a.cruisePhase=phase;a.cruiseLane=lane
                a.velocity=pose.tangent*(0.052+Float(lane)*0.006)
                guard balls(for:a).allSatisfy({field.isFree($0.center,radius:$0.radius)}) else {throw CocoaError(.fileReadCorruptFile)}
                prepared[id]=a
            }
            agents=prepared;return
        }
        // Stage a complete valid packing before replacing current state, including growth.
        var placed:[String:Agent]=[:]
        let ids=radii.keys.sorted { radii[$0]==radii[$1] ? $0<$1 : radii[$0]!>radii[$1]! }
        for (index,id) in ids.enumerated() {
            let r=radii[id]!
            let body=shapes[id] ?? [AquariumBall(center:.zero,radius:r)]
            let desired=SIMD3<Float>([-2.2,0,2.2][index%3],index<3 ? 1.30:3.35,1.35)
            let existing=agents[id]?.position
            let available=candidates(id:id,radius:r,body:body).filter { p in placed.values.allSatisfy { simd_distance(p,$0.position)>r+$0.radius+0.08 } }
            guard let p=available.min(by:{ simd_distance($0,existing ?? desired)<simd_distance($1,existing ?? desired) }) else { throw CocoaError(.fileReadCorruptFile) }
            placed[id]=Agent(position:p,forward:SIMD3(index%2==0 ? 1:-1,0,0),target:p,radius:r,body:body,retarget:0)
            placed[id]?.orientation=simd_quatf(angle:index%2==0 ? 0:Float.pi,axis:SIMD3<Float>(0,1,0))
        }
        agents=placed
    }
    private func lineFree(_ a: SIMD3<Float>, _ b: SIMD3<Float>, radius: Float) -> Bool {
        let count=max(1,Int(ceil(simd_distance(a,b)/0.06)))
        for i in 0..<count {
            let p=a+(b-a)*(Float(i)/Float(count)),q=a+(b-a)*(Float(i+1)/Float(count))
            if !field.segmentFree(from:p,to:q,radius:radius) { return false }
        }
        return true
    }
    private func route(for agent: Agent, id: String) -> [SIMD3<Float>] {
        let points=candidates(id:id,radius:agent.radius,body:agent.body),key=id+"-"+String(agent.radius.bitPattern)
        func reachable(_ a: SIMD3<Float>,_ b: SIMD3<Float>) -> Bool {
            agent.body.allSatisfy{ lineFree(a+simd_act(agent.orientation,$0.center),b+simd_act(agent.orientation,$0.center),radius:$0.radius) }
        }
        guard let grid=grids[key], !points.isEmpty else { return [] }
        let nearby=points.indices.sorted{simd_distance_squared(points[$0],agent.position)<simd_distance_squared(points[$1],agent.position)}
        guard let start=nearby.prefix(30).first(where:{reachable(agent.position,points[$0])}) else { return [] }
        var goal=start
        for _ in 0..<40 {
            let candidate=min(points.count-1,Int(number()*Float(points.count)))
            if simd_distance(points[candidate],agent.position)>1.5 { goal=candidate;break }
        }
        if goal==start { goal=points.indices.max{simd_distance_squared(points[$0],agent.position)<simd_distance_squared(points[$1],agent.position)}! }
        var queue=[start],cursor=0,previous=Array(repeating:-1,count:points.count)
        previous[start]=start
        while cursor<queue.count && previous[goal]<0 {
            let i=queue[cursor];cursor += 1
            for j in grid.links[i] where previous[j]<0 { previous[j]=i;queue.append(j) }
        }
        guard previous[goal]>=0 else { return [] }
        var result=[points[goal]],i=goal
        while i != start { i=previous[i];result.append(points[i]) }
        result.reverse()
        // String-pull the grid route into long, smooth, collision-free segments.
        var smooth:[SIMD3<Float>]=[],anchor=agent.position,next=0
        while next<result.count {
            var last=next
            for j in stride(from:result.count-1,through:next,by:-1) {
                if reachable(anchor,result[j]) { last=j;break }
            }
            smooth.append(result[last]);anchor=result[last];next=last+1
        }
        return smooth
    }
    private func unit(_ v: SIMD3<Float>) -> SIMD3<Float> { simd_length_squared(v)>0.000001 ? simd_normalize(v):SIMD3(1,0,0) }
    func balls(for agent: Agent) -> [AquariumBall] {
        agent.body.map { AquariumBall(center:agent.position+simd_act(agent.orientation,$0.center),radius:$0.radius) }
    }
    private func angle(_ a:simd_quatf,_ b:simd_quatf) -> Float { 2*acos(min(1,abs(simd_dot(a.vector,b.vector)))) }
    private func segmentDistance(_ a:SIMD3<Float>,_ b:SIMD3<Float>) -> Float {
        let d=b-a,denominator=simd_length_squared(d)
        let t=denominator>0 ? min(1,max(0,-simd_dot(a,d)/denominator)):0
        return simd_length(a+d*t)
    }
    func motionIsSafe(id:String, candidate:Agent, starting:[String:Agent], diagnose:Bool=false) -> Bool {
        let old=starting[id]!,before=balls(for:old),after=balls(for:candidate)
        let theta=angle(old.orientation,candidate.orientation)
        let arc=candidate.body.map{simd_length($0.center)*(1-cos(theta/2))}
        for i in before.indices {
            if !field.segmentFree(from:before[i].center,to:after[i].center,radius:after[i].radius+(arc[i]+0.0001)) { if diagnose { print("TERRAIN",id,i,"arc",arc[i],"before",before[i].center,"after",after[i].center,"r",after[i].radius) }; return false }
        }
        for (otherID,other) in agents where otherID != id {
            let start=starting[otherID]!
            if segmentDistance(old.position-start.position,candidate.position-other.position)>candidate.radius+other.radius+0.03 { continue }
            let b0=balls(for:start),b1=balls(for:other),otherAngle=angle(start.orientation,other.orientation)
            for i in before.indices { for j in b0.indices {
                // Sum the two arc bounds first. Adding the epsilon to only one
                // fish made reciprocal checks differ by Float rounding at contact.
                let otherArc=simd_length(other.body[j].center)*(1-cos(otherAngle/2))
                let extra=(otherArc+arc[i])+0.0201
                if segmentDistance(before[i].center-b0[j].center,after[i].center-b1[j].center)<after[i].radius+b1[j].radius+extra { if diagnose {print("PAIR",id,otherID,i,j,"distance",segmentDistance(before[i].center-b0[j].center,after[i].center-b1[j].center),"required",after[i].radius+b1[j].radius+extra,"angles",theta,otherAngle)}; return false }
            } }
        }
        return true
    }
    private func rotation(from current:simd_quatf, toward direction:SIMD3<Float>, dt:Float) -> simd_quatf {
        // Fish change depth while keeping a gentle, natural body pitch.
        let horizontal=SIMD3<Float>(direction.x,0,direction.z)
        let heading=simd_length_squared(horizontal)>0.0001 ? unit(horizontal):unit(SIMD3(simd_act(current,SIMD3<Float>(1,0,0)).x,0,simd_act(current,SIMD3<Float>(1,0,0)).z))
        let direction=unit(heading+SIMD3<Float>(0,max(-0.22,min(0.22,direction.y)),0))
        let side=unit(simd_cross(direction,SIMD3<Float>(0,1,0))),up=unit(simd_cross(side,direction))
        let target=simd_quatf(simd_float3x3(columns:(direction,up,side))),distance=angle(current,target)
        return simd_slerp(current,target,min(1,0.55*dt/max(0.001,distance)))
    }
    private func heading(_ direction:SIMD3<Float>)->simd_quatf {
        let forward=unit(direction),side=unit(simd_cross(forward,SIMD3<Float>(0,1,0)))
        return simd_quatf(simd_float3x3(columns:(forward,unit(simd_cross(side,forward)),side)))
    }
    private func cruise(phase:Float,lane:Int)->(position:SIMD3<Float>,tangent:SIMD3<Float>) {
        // Three fish are spaced evenly around each circuit; two separated height
        // bands let all six silhouettes keep moving without stop/start avoidance.
        let y=Float(1.50)+Float(lane)*2.25
        return (SIMD3(2.65*cos(phase),y+0.08*sin(phase*2),1.55*sin(phase)),
                SIMD3(-2.65*sin(phase),0.16*cos(phase*2),1.55*cos(phase)))
    }
    private func advanceCruise(_ dt:Float) {
        for id in agents.keys.sorted() {
            var a=agents[id]!,previous=a.position
            let rate=0.052+Float(a.cruiseLane)*0.006
            a.cruisePhase = (a.cruisePhase+rate*dt).truncatingRemainder(dividingBy:2*Float.pi)
            let pose=cruise(phase:a.cruisePhase,lane:a.cruiseLane),forward=unit(pose.tangent)
            let yaw=atan2(simd_cross(a.forward,forward).y,simd_dot(a.forward,forward))/dt
            a.turn += (max(-1,min(1,yaw/0.22))-a.turn)*(1-exp(-dt*4))
            a.position=pose.position;a.forward=forward;a.orientation=heading(forward)
            a.velocity=(a.position-previous)/dt;a.distanceTravelled += simd_distance(a.position,previous)
            a.target=cruise(phase:a.cruisePhase+0.25,lane:a.cruiseLane).position
            agents[id]=a
        }
    }
    func advance(_ dt: Float) {
        guard dt>0, !agents.isEmpty else { return }
        if field.isOpenWater {advanceCruise(dt);return}
        let starting=agents
        iteration += 1
        let sorted=agents.keys.sorted(), shift=(iteration/45)%agents.count
        let order=Array(sorted[shift...])+Array(sorted[..<shift])
        for id in order {
            var agent=agents[id]!
            agent.retarget -= dt
            if agent.retarget<=0 || agent.path.isEmpty {
                agent.path=route(for:agent,id:id);agent.retarget=30+number()*20
            }
            while let next=agent.path.first, simd_distance(next,agent.position)<0.18 { agent.path.removeFirst() }
            agent.target=agent.path.first ?? agent.position
            var desired=unit(agent.target-agent.position)
            for (otherId,other) in agents where otherId != id {
                let delta=agent.position-other.position, distance=simd_length(delta), threshold=(agent.radius+other.radius)*0.5+0.3
                if distance<threshold { desired += unit(delta)*(threshold-distance)*2 }
            }
            desired=unit(desired)
            var directions=[unit(agent.forward*0.92+desired*0.08),desired,agent.forward]
            for yaw: Float in [-0.65,0.65,-1.3,1.3,2.2,-2.2,Float.pi] {
                let f=agent.forward
                for pitch: Float in [-0.4,0,0.4] { directions.append(unit(SIMD3(f.x*cos(yaw)+f.z*sin(yaw),f.y+pitch,-f.x*sin(yaw)+f.z*cos(yaw)))) }
            }
            let speed: Float = ["eel","oarfish"].contains(id) ? 0.17:0.23
            var chosen:Agent?,best:Float = -.infinity
            func moving(toward direction:SIMD3<Float>,speed:Float,turn:Bool=true)->Agent {
                var candidate=agent
                let wanted=direction*speed,delta=wanted-agent.velocity
                let change=simd_length(delta),limit:Float=0.16*dt
                candidate.velocity=agent.velocity+delta*(change>limit ? limit/change:1)
                if turn && simd_length_squared(candidate.velocity)>0.00001 {
                    candidate.orientation=rotation(from:agent.orientation,toward:unit(candidate.velocity),dt:dt)
                    candidate.forward=simd_act(candidate.orientation,SIMD3<Float>(1,0,0))
                }
                candidate.position += candidate.velocity*dt
                candidate.distanceTravelled += simd_length(candidate.velocity)*dt
                candidate.steering=direction
                return candidate
            }
            for direction in directions {
                let alignment=max(0.25,simd_dot(agent.forward,direction))
                let candidate=moving(toward:direction,speed:speed*alignment)
                guard motionIsSafe(id:id,candidate:candidate,starting:starting) else { continue }
                let score=simd_dot(direction,desired)*0.7+simd_dot(direction,agent.forward)*0.3+simd_dot(direction,agent.steering)*0.22
                if score>best { best=score;chosen=candidate }
            }
            // Back away without turning when a fin or tail is too close to scenery.
            // Separating translation from rotation lets a long fish leave a narrow pocket.
            if chosen == nil {
                for x:Float in [-1,0,1] { for y:Float in [-1,0,1] { for z:Float in [-1,0,1] {
                    if x==0 && y==0 && z==0 { continue }
                    let direction=unit(SIMD3(x,y,z))
                    let candidate=moving(toward:direction,speed:speed*0.35,turn:false)
                    guard motionIsSafe(id:id,candidate:candidate,starting:starting) else { continue }
                    let score=simd_dot(direction,desired)
                    if score>best { best=score;chosen=candidate }
                } } }
            }
            if let chosen { agent=chosen;agent.blockedTime=0 } else {
                // Stop at a real obstacle. Replan at a bounded cadence, never every frame.
                agent.velocity = .zero;agent.blockedTime += dt
                if agent.blockedTime>0.8 {agent.retarget=0;agent.blockedTime=0}
            }
            agents[id]=agent
        }
    }
}
