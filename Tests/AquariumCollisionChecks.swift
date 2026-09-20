import AppKit
import SceneKit
import WhileCore
import simd

@main enum AquariumCollisionChecks {
    static func main() throws {
        setbuf(stdout,nil)
        func require(_ value: Bool, _ message: String) {
            if !value { print("FAILED:",message);exit(1) }
        }
        _ = NSApplication.shared
        let empty=AquariumCollisionField(positions:[],indices:[])
        require(empty.segmentFree(from:SIMD3(empty.minimum.x+0.2001,2,-1),to:SIMD3(empty.minimum.x+0.2001,2,1),radius:0.2),"A fish can slide parallel to glass without a false collision")
        let obstacle=[SIMD3<Float>(-0.1,1.3,-0.1),SIMD3(0.1,1.3,-0.1),SIMD3(0,1.3,0.1)].map{($0-AquariumLayout.sceneryPosition)/AquariumLayout.sceneryScale}
        let simple=AquariumCollisionField(positions:obstacle,indices:[0,1,2])
        require(!simple.segmentFree(from:SIMD3(0,1,-1),to:SIMD3(0,1,1),radius:0.1),"Sweeps detect scenery between two clear endpoints")
        require(simple.segmentFree(from:SIMD3(0,2,-1),to:SIMD3(0,2,1),radius:0.1),"Sweeps pass above scenery")
        if CommandLine.arguments.contains("--primitives-only") { print("Collision sweep primitives passed"); return }
        let field = AquariumCollisionField(positions:[],indices:[])
        let nav = AquariumNavigation(field:field)
        struct Envelope: Decodable { let radius: Float; let spheres:[AquariumBall] }
        let base=URL(fileURLWithPath:"Sources/WhileAIWorks/Resources/AquariumAssets")
        let envelope=try JSONDecoder().decode([String:Envelope].self,from:Data(contentsOf:base.appendingPathComponent("fish-envelopes.json")))
        let fish=CatchSpecies.catalog.filter(\.isFish)
        var radii:[String:Float]=[:]
        var shapes:[String:[AquariumBall]]=[:]
        for item in fish {
            let length = item.id=="puffer" ? try GeneratedPuffer().length:try GeneratedFish(id:item.id).length
            let size=item.displayLength(for:item.maxCM)
            radii[item.id]=envelope[item.id]!.radius*Float(size/length)+0.14
            shapes[item.id]=envelope[item.id]!.spheres.map { AquariumBall(center:$0.center*Float(size/length),radius:$0.radius*Float(size/length)+0.12) }
        }
        // All 3,003 choices of six species, at their largest allowed catch sizes.
        let ids=fish.map(\.id).sorted()
        var combinations:[[String]]=[]
        func choose(_ start:Int,_ values:[String]) {
            if values.count==6 { combinations.append(values);return }
            if start>=ids.count { return }
            for i in start..<ids.count { choose(i+1,values+[ids[i]]) }
        }
        choose(0,[])
        var packingFailures:[[String]]=[]
        for group in combinations {
            try nav.configure(radii:[:])
            do { try nav.configure(radii:Dictionary(uniqueKeysWithValues:group.map{($0,radii[$0]!)}),shapes:shapes) }
            catch { packingFailures.append(group) }
        }
        print("packing",combinations.count,"failures",packingFailures.count,Array(packingFailures.prefix(5)))
        require(packingFailures.isEmpty,"Every full aquarium must fit its six largest fish")
        var simulations=[Array(ids.sorted{radii[$0]!>radii[$1]!}.prefix(6)),["crucian","sardine","perch","trout","salmon","puffer"]]
        for i in 0..<ids.count { simulations.append((0..<6).map{ ids[(i+$0*2)%ids.count] }) }
        var samples=0;var minGap:Float=100;var blockedFish:[String]=[];var minimumMinuteTravel:Float = .infinity
        for (groupIndex,group) in simulations.enumerated() {
            try nav.configure(radii:[:]);try nav.configure(radii:Dictionary(uniqueKeysWithValues:group.map{($0,radii[$0]!)}),shapes:shapes)
            var minuteStart=nav.agents.mapValues(\.distanceTravelled)
            for frame in 0..<18000 { // Ten simulated minutes at 30 Hz, including every move.
                let previous=nav.agents
                nav.advance(1/30)
                for (id,a) in nav.agents {
                    for ball in nav.balls(for:a) { require(field.isFree(ball.center,radius:ball.radius),"Animated surface intersects glass or scenery") }
                    if !nav.motionIsSafe(id:id,candidate:a,starting:previous) {
                        print("FAILURE CONTEXT",groupIndex,group,frame,id)
                        _ = nav.motionIsSafe(id:id,candidate:a,starting:previous,diagnose:true)
                        require(false,"Simultaneous translation/rotation sweeps must clear scenery and other fish")
                    }
                    for (other,b) in nav.agents where id<other {
                        let rootGap=simd_distance(a.position,b.position)-a.radius-b.radius
                        if rootGap>0.03 { minGap=min(minGap,rootGap);continue }
                        for x in nav.balls(for:a) { for y in nav.balls(for:b) {
                            let gap=simd_distance(x.center,y.center)-x.radius-y.radius
                            require(gap>=0.019,"Fish body or tail penetrates another fish")
                            minGap=min(minGap,gap)
                        } }
                    }
                    samples += 1
                }
                if (frame+1)%1800==0 {
                    for (id,a) in nav.agents {
                        let travelled=a.distanceTravelled-minuteStart[id]!
                        minimumMinuteTravel=min(minimumMinuteTravel,travelled)
                        if travelled<=0.5 { print("SLOW",groupIndex,id,frame,travelled,nav.agents[id]!.position) }
                        require(travelled>0.5,"Each fish must keep swimming throughout every minute")
                    }
                    minuteStart=nav.agents.mapValues(\.distanceTravelled)
                }
                if frame==17999 {
                    for (id,a) in nav.agents where a.distanceTravelled<10 { blockedFish.append("\(id):\(a.distanceTravelled)") }
                }
            }
            print("completed group",groupIndex+1,"blocked",blockedFish)
        }
        print("movement",samples,"minimum clearance",minGap,"blocked",blockedFish)
        require(blockedFish.isEmpty,"Collision safety must not be implemented by freezing fish")
        let report:[String:Any]=["packingCombinations":combinations.count,"packingFailures":0,"simulationGroups":simulations.count,"secondsPerGroup":600,"agentSamples":samples,"minimumConservativePairClearance":minGap,"blockedFish":blockedFish,"minimumDistancePerMinute":minimumMinuteTravel]
        try JSONSerialization.data(withJSONObject:report,options:.prettyPrinted).write(to:URL(fileURLWithPath:".build/aquarium-collision-report.json"))
    }
}
