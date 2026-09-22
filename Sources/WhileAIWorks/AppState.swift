import AppKit
import Combine
import WhileCore

enum SettingsSection: String, CaseIterable {
    case desktop, miniToo
    var title: String { self == .desktop ? "桌面游戏" : "MiniToo" }
}

enum PlayMode: String, CaseIterable, Identifiable {
    case wipe, bubbles, woodfish, fishing
    var id: String { rawValue }
    var title: String {
        switch self { case .wipe: return "擦污渍"; case .bubbles: return "捏气泡"; case .woodfish: return "敲木鱼"; case .fishing: return "钓鱼" }
    }
    var symbol: String {
        switch self { case .wipe: return "sparkles"; case .bubbles: return "circle.grid.3x3"; case .woodfish: return "music.note"; case .fishing: return "fish" }
    }
    var hint: String {
        switch self {
        case .wipe: return "开启操作后拖动，慢慢擦干净。"
        case .bubbles: return "开启操作后点击或划过气泡。"
        case .woodfish: return "开启操作后点击木鱼，每敲一下 +1。"
        case .fishing: return "开启操作后点击抛竿；咬钩后按下上浮、松开下沉，绿条包住鱼。"
        }
    }
}

enum PlayArea: String, CaseIterable, Identifiable {
    case edges, fullScreen
    var id: String { rawValue }
    var title: String { self == .edges ? "屏幕边缘" : "整个屏幕" }
}

enum WorkSource: String, CaseIterable, Identifiable {
    case codex, qoder, workbuddy
    var id: String { rawValue }
    var clientName: String {
        switch self { case .codex: return "Codex"; case .qoder: return "Qoder"; case .workbuddy: return "WorkBuddy" }
    }
    var hookProvider: HookProvider? { HookProvider(rawValue: rawValue) }
}

struct DesktopScreenChoice: Identifiable, Equatable {
    let id:String
    let title:String
    static func id(for screen:NSScreen)->String {
        let number=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return String(number)
    }
    static func selectedID(preferred:String,available:[String],primary:String?)->String? {
        if available.contains(preferred) {return preferred}
        if let primary,available.contains(primary) {return primary}
        return available.first
    }
}

final class AppState: ObservableObject {
    private let defaults: UserDefaults
    private let counter: ActivityCounter
    private let wipeCounter: ActivityCounter
    private let bubbleCounter: ActivityCounter
    private var decay = WorkDecayClock()
    private var timer: Timer?
    private var fishingTimer: Timer?
    private var lastFishingTick = ProcessInfo.processInfo.systemUptime
    private var rotation = RotationClock()
    private var lastTick = ProcessInfo.processInfo.systemUptime
    @Published var settingsSection: SettingsSection = .desktop
    @Published var mode: PlayMode { didSet { defaults.set(mode.rawValue, forKey: "mode"); rotation.reset(); castStartedAt = nil; fishing.reset() } }
    @Published var targetScreenID:String { didSet { defaults.set(targetScreenID,forKey:"desktop.targetScreen") } }
    @Published private(set) var availableScreens:[DesktopScreenChoice] = []
    private var screenObserver:NSObjectProtocol?
    var selectedScreenUnavailable:Bool { !targetScreenID.isEmpty && !availableScreens.contains{$0.id==targetScreenID} }
    func refreshScreens() {
        availableScreens=NSScreen.screens.enumerated().map { index,screen in
            DesktopScreenChoice(id:DesktopScreenChoice.id(for:screen),title:"\(index+1) · \(screen.localizedName)")
        }
    }
    var targetScreen:NSScreen? {
        let screens=NSScreen.screens
        let chosen=DesktopScreenChoice.selectedID(preferred:targetScreenID,available:screens.map{DesktopScreenChoice.id(for:$0)},primary:String(CGMainDisplayID()))
        return screens.first { DesktopScreenChoice.id(for:$0)==chosen }
    }
    @Published var area: PlayArea { didSet { defaults.set(area.rawValue, forKey: "area") } }
    @Published var followAI: Bool { didSet {
        defaults.set(followAI, forKey: "work.followAI")
        clearWorkState()
    } }
    @Published var selectedSources: Set<WorkSource> { didSet {
        defaults.set(selectedSources.map(\.rawValue).sorted(), forKey: "work.sources")
        clearWorkState()
    } }
    @Published var miniTooCodexEnabled = false
    @Published var codexDisplay = CodexDisplay()
    @Published var activeSessionCounts: [WorkSource: Int] = [:]
    var activeSessionCount: Int { activeSessionCounts.values.reduce(0, +) }
    var selectedClientsLabel: String {
        selectedSources.count == WorkSource.allCases.count ? "全部 AI" :
            selectedSources.isEmpty ? "未选择 AI" : WorkSource.allCases.filter { selectedSources.contains($0) }.map(\.clientName).joined(separator: " + ")
    }
    var activeClientsLabel: String {
        WorkSource.allCases.filter { (activeSessionCounts[$0] ?? 0) > 0 }.map(\.clientName).joined(separator: "、")
    }
    func setSource(_ source: WorkSource, selected: Bool) {
        if selected { selectedSources.insert(source) } else { selectedSources.remove(source) }
    }
    func clearWorkState() {
        activeSessionCounts = [:]; detectedWorking = false; workIntensity = 0
        monitorDetail = selectedSources.isEmpty ? "请选择要跟随的 AI" : "等待 AI 开始工作"
    }
    @Published var hookSetupMessage: String?
    func installHooks(_ provider: HookProvider, remove: Bool = false) {
        do {
            guard let helper = Bundle.main.url(forResource: "while-ai-works-hook", withExtension: nil) else {
                throw HookInstallation.Failure.missingHelper
            }
            try HookInstallation.install(provider: provider, helper: helper, remove: remove)
            hookSetupMessage = remove ? "已移除监听配置，请重启 \(provider.title)。" : "已安装，请重启 \(provider.title)；如有 Hooks 审核提示，请在客户端启用。"
        } catch { hookSetupMessage = error.localizedDescription }
    }
    @Published var desktopEnabled: Bool { didSet { defaults.set(desktopEnabled, forKey: "desktopEnabled"); interactionEnabled = desktopEnabled; if !desktopEnabled { castStartedAt = nil; fishing.reset() } } }
    @Published var autoSwitch: Bool { didSet { defaults.set(autoSwitch, forKey: "autoSwitch"); rotation.reset() } }
    @Published var switchInterval: Double { didSet { defaults.set(switchInterval, forKey: "switchInterval"); rotation.reset() } }
    @Published var soundEnabled: Bool {
        didSet {
            defaults.set(soundEnabled, forKey: "sound")
            if !soundEnabled { PlayAudio.shared.stopAll() }
        }
    }
    @Published var volume: Double {
        didSet { defaults.set(volume, forKey: "volume"); PlayAudio.shared.masterVolume = Float(volume) }
    }
    @Published var detectedWorking = false
    @Published var workIntensity = 0.0
    @Published private(set) var aquarium: Aquarium
    @Published private(set) var fishingBook: FishingBook
    @Published private(set) var fishingProgression: FishingProgression
    var canEquipRod: Bool { castStartedAt == nil && (fishing.phase == .ready || fishing.phase == .landed || fishing.phase == .escaped) }
    func equipRod(_ rod: FishingRod) {
        guard canEquipRod, rod.isUnlocked(in: fishingBook), fishing.equip(rod) else { return }
        fishingProgression.equip(rod, book: fishingBook)
        fishingProgression.save(defaults: defaults)
    }
    @Published private(set) var sessionCatches = 0
    private(set) var fishing = FishingGame() {
        didSet {
            if oldValue.phase != fishing.phase || oldValue.rod != fishing.rod { objectWillChange.send() }
        }
    }
    private(set) var fishingNewRecord = false
    struct FishingReward {
        let catchResult: FishingCatch
        let firstDiscovery: Bool
        let newRecord: Bool
        let caughtAt: TimeInterval
        var perfect = false
        var unlockNotices: [String] = []
        static let duration: TimeInterval = 3.8
        static let dismissalDelay: TimeInterval = 1
        func canDismiss(at time: TimeInterval) -> Bool {
            time - caughtAt >= Self.dismissalDelay
        }
        func isVisible(at time: TimeInterval) -> Bool {
            time >= caughtAt && time - caughtAt < Self.duration
        }
        var title: String { firstDiscovery && catchResult.species.isSecret ? "未知巨物揭晓！" : firstDiscovery ? "新图鉴解锁！" : newRecord ? "新纪录！" : "钓到了！" }
    }
    private(set) var fishingReward: FishingReward?
    var fishingIntensity: Double { !followAI ? 0.35 : (detectedWorking ? workIntensity : 0) }
    var fishingActivityLabel: String {
        if !isWorking { return "水面平静 · 等待 AI" }
        if !followAI { return "自由垂钓 · 稳定来鱼" }
        return fishingIntensity > 0.65 ? "鱼群活跃 · AI 高速工作" : fishingIntensity > 0.2 ? "涟漪渐多 · AI 工作中" : "偶有鱼影 · AI 工作中"
    }
    @Published private(set) var fishingEnvironment: FishingEnvironment
    func refreshFishingEnvironment(date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        let environment = FishingEnvironment.resolve(mode: .system, date: date, calendar: calendar)
        if environment != fishingEnvironment { fishingEnvironment = environment }
    }
    @Published var monitorDetail = "等待 Codex 开始工作"
    @Published var resetID = UUID()
    // Interaction always starts off; the preferred shortcut persists across launches.
    @Published var interactionEnabled = false {
        didSet {
            if interactionEnabled && !desktopEnabled { desktopEnabled = true }
            interactionHeld = interactionEnabled
            if !interactionEnabled { fishing.release(); PlayAudio.shared.endWipe() }
        }
    }
    static let shortcutKeys: [(name: String, code: Int)] = [("空格", 49), ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5), ("H", 4), ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45), ("O", 31), ("P", 35), ("Q", 12), ("R", 15), ("S", 1), ("T", 17), ("U", 32), ("V", 9), ("W", 13), ("X", 7), ("Y", 16), ("Z", 6)]
    @Published var shortcutKey = 49 { didSet { defaults.set(shortcutKey, forKey: "interaction.shortcutKey") } }
    @Published var shortcutModifiers = 0 { didSet { defaults.set(shortcutModifiers, forKey: "interaction.shortcutModifiers") } }
    @Published var shortcutError: String?
    var shortcutLabel: String {
        ["⌘⇧", "⌃⌥", "⌃⇧"][shortcutModifiers] + (Self.shortcutKeys.first { $0.code == shortcutKey }?.name ?? "空格")
    }
    var mouseInteractionActive = false
    @Published var interactionHeld = false
    @Published private(set) var totalStrikes: Int
    @Published private(set) var sessionStrikes = 0
    @Published private(set) var totalWipes: Int
    @Published private(set) var totalBubbles: Int
    @Published private(set) var sessionWipes = 0
    @Published private(set) var sessionBubbles = 0
    @Published private(set) var woodBalance: Int
    @Published private(set) var woodDecaySerial = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        targetScreenID=defaults.string(forKey:"desktop.targetScreen") ?? ""
        fishingEnvironment = FishingEnvironment.resolve(mode: .system)
        let savedKey = defaults.object(forKey: "interaction.shortcutKey") as? Int ?? 49
        shortcutKey = Self.shortcutKeys.contains { $0.code == savedKey } ? savedKey : 49
        let savedModifiers = defaults.integer(forKey: "interaction.shortcutModifiers")
        shortcutModifiers = (0...2).contains(savedModifiers) ? savedModifiers : 0
        let book = FishingBook.load(defaults: defaults)
        fishingBook = book
        let progression = FishingProgression(defaults: defaults, book: book)
        fishingProgression = progression
        fishing = FishingGame(rod: progression.selectedRod)
        progression.save(defaults: defaults)
        let tank = Aquarium.load(defaults: defaults, book: book)
        aquarium = tank
        tank.save(defaults: defaults)
        counter = ActivityCounter(defaults: defaults)
        wipeCounter = ActivityCounter(defaults: defaults, key: "wipe.total")
        bubbleCounter = ActivityCounter(defaults: defaults, key: "bubbles.total")
        totalStrikes = counter.total
        totalWipes = wipeCounter.total
        totalBubbles = bubbleCounter.total
        woodBalance = defaults.object(forKey: "woodfish.balance") == nil ? counter.total : defaults.integer(forKey: "woodfish.balance")
        mode = PlayMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .wipe
        area = PlayArea(rawValue: defaults.string(forKey: "area") ?? "") ?? .edges
        // Existing manual mode is preserved; the first multi-source selection defaults to all.
        followAI = defaults.object(forKey: "work.followAI") as? Bool ?? (defaults.string(forKey: "source") != "manual")
        selectedSources = defaults.stringArray(forKey: "work.sources").map { Set($0.compactMap(WorkSource.init(rawValue:))) }
            ?? Set(WorkSource.allCases)
        desktopEnabled = false
        autoSwitch = defaults.bool(forKey: "autoSwitch")
        let savedInterval = defaults.double(forKey: "switchInterval")
        switchInterval = [30.0, 60, 120, 300].contains(savedInterval) ? savedInterval : 120
        soundEnabled = defaults.object(forKey: "sound") as? Bool ?? true
        volume = min(1, max(0, defaults.object(forKey: "volume") as? Double ?? 0.55))
        PlayAudio.shared.masterVolume = Float(volume)
        refreshScreens()
        screenObserver=NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in self?.refreshScreens() }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let fishingTimer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.advanceFishing(delta: now - self.lastFishingTick)
            self.lastFishingTick = now
        }
        RunLoop.main.add(fishingTimer, forMode: .common)
        self.fishingTimer = fishingTimer
    }
    deinit { timer?.invalidate(); fishingTimer?.invalidate(); if let screenObserver {NotificationCenter.default.removeObserver(screenObserver)} }
    var isWorking: Bool { !followAI || detectedWorking }
    var status: String {
        guard desktopEnabled else { return "桌面解压已关闭" }
        if !followAI { return "\(mode.title) · 已开启" }
        return detectedWorking ? "\(activeSessionCount) 个会话工作中 · \(activeClientsLabel)" : monitorDetail
    }
    func putInAquarium(_ id: String, replacing old: String? = nil) {
        if aquarium.add(id, replacing: old, book: fishingBook) { aquarium.save(defaults: defaults) }
    }
    func removeFromAquarium(_ id: String) {
        aquarium.remove(id); aquarium.save(defaults: defaults)
    }
    func reset() { resetID = UUID(); castStartedAt = nil; fishing.reset(); fishingReward = nil }
    /// Returns whether the catch consumed the press, including during its protection period.
    @discardableResult func dismissFishingCatch(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard fishing.phase == .landed else { return false }
        if let reward = fishingReward, !reward.canDismiss(at: time) { return true }
        objectWillChange.send()
        fishingReward = nil
        castStartedAt = nil
        fishing.reset()
        return true
    }
    func fishingPress() {
        guard desktopEnabled, mode == .fishing else { return }
        if dismissFishingCatch() { return }
        if fishing.phase == .escaped || fishing.phase == .ready { fishingReward = nil }
        if fishing.phase == .ready || fishing.phase == .escaped {
            refreshFishingEnvironment()
            castReleasedAt = ProcessInfo.processInfo.systemUptime
            castLanding = CGPoint(x: 0.55, y: 0.7)
            fishing.cast(into: .shallow, period: fishingEnvironment.period)
        } else { fishing.press() }
    }
    @Published var castStartedAt: TimeInterval?
    var castAim = CGPoint(x: 0.5, y: 0.7)
    var castLanding = CGPoint(x: 0.5, y: 0.7)
    var castOrigin = CGPoint(x: 0.84, y: 83.0 / 195)
    private(set) var releasedCastPower = 0.0
    var castReleasedAt: TimeInterval = -100
    @discardableResult func cancelFishingCast() -> Bool {
        guard desktopEnabled, mode == .fishing, castStartedAt != nil else { return false }
        castStartedAt = nil
        fishing.release()
        return true
    }
    func castPower(at time: TimeInterval) -> Double {
        guard let start = castStartedAt else { return 0 }
        let cycle = max(0, time - start).truncatingRemainder(dividingBy: 2.4) / 1.2
        return cycle <= 1 ? cycle : 2 - cycle
    }
    func finishCast(at time: TimeInterval, landing: CGPoint, water: FishingWater, origin: CGPoint? = nil) {
        guard castStartedAt != nil, desktopEnabled else { return }
        releasedCastPower = castPower(at: time)
        castOrigin = origin ?? CGPoint(x: 0.84, y: 83.0 / 195)
        castStartedAt = nil; castLanding = landing; castReleasedAt = time
        refreshFishingEnvironment()
        fishingReward = nil; fishing.cast(into: water, period: fishingEnvironment.period)
        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.0 : 0.55
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.desktopEnabled, self.mode == .fishing, self.soundEnabled,
                  self.castReleasedAt == time, self.fishing.phase == .waiting else { return }
            PlayAudio.shared.splash(position: Double(landing.x) * 2 - 1)
        }
    }
    func fishingRelease() { fishing.release() }
    /// VoiceOver activation toggles a sustained hold during the fight.
    func fishingAccessiblePress() {
        if fishing.phase == .fighting {
            if fishing.pressed {fishingRelease()} else {fishingPress()}
        } else {fishingPress();fishingRelease()}
    }
    func advanceFishing(delta: TimeInterval, random: () -> Double = { Double.random(in: 0..<1) }) {
        guard desktopEnabled, mode == .fishing else { return }
        let before = fishing.phase
        if let result = fishing.advance(delta: delta, working: isWorking, intensity: fishingIntensity,
                                        interacting: interactionHeld, random: random) {
            let firstDiscovery = fishingBook.records[result.species.id] == nil
            let previouslyUnlocked = Set(FishingRod.allCases.filter { $0.isUnlocked(in: fishingBook) })
            fishingNewRecord = fishingBook.record(result)
            let newRods = FishingRod.allCases.filter { !previouslyUnlocked.contains($0) && $0.isUnlocked(in: fishingBook) }
            let achievements = fishingProgression.reconcile(book: fishingBook)
            fishingProgression.save(defaults: defaults)
            fishingReward = FishingReward(catchResult: result, firstDiscovery: firstDiscovery,
                                          newRecord: fishingNewRecord, caughtAt: ProcessInfo.processInfo.systemUptime, perfect: fishing.perfect,
                                          unlockNotices: newRods.map { "钓竿解锁 · " + $0.title } + achievements.map { "成就达成 · " + $0.title })
            fishingBook.save(defaults: defaults)
            aquarium.discover(in: fishingBook)
            aquarium.save(defaults: defaults)
            sessionCatches += 1
            if soundEnabled { PlayAudio.shared.pop(position: 0) }
        }
        if before != fishing.phase, fishing.phase == .bite, soundEnabled {
            PlayAudio.shared.bite(position: Double(castLanding.x) * 2 - 1)
        }
    }
    func strike() {
        counter.increment()
        totalStrikes = counter.total
        sessionStrikes = counter.session
        if woodBalance < Int.max { woodBalance += 1 }
        defaults.set(woodBalance, forKey: "woodfish.balance")
    }
    func wipedStain() {
        wipeCounter.increment()
        totalWipes = wipeCounter.total
        sessionWipes = wipeCounter.session
    }
    func poppedBubble() {
        bubbleCounter.increment()
        totalBubbles = bubbleCounter.total
        sessionBubbles = bubbleCounter.session
    }
    func total(for mode: PlayMode) -> Int {
        switch mode { case .wipe: return totalWipes; case .bubbles: return totalBubbles; case .woodfish: return totalStrikes; case .fishing: return fishingBook.total }
    }
    func session(for mode: PlayMode) -> Int {
        switch mode { case .wipe: return sessionWipes; case .bubbles: return sessionBubbles; case .woodfish: return sessionStrikes; case .fishing: return sessionCatches }
    }
    func countLabel(for mode: PlayMode) -> String {
        switch mode {
        case .wipe: return "已擦净 \(totalWipes.formatted()) 处"
        case .bubbles: return "已捏破 \(totalBubbles.formatted()) 颗"
        case .woodfish: return "已敲击 \(totalStrikes.formatted()) 次"
        case .fishing: return "总鱼获 \(fishingBook.total.formatted()) 件"
        }
    }
    func advanceWorkEffects(delta: TimeInterval) {
        if decay.advance(delta: delta, active: desktopEnabled && mode == .woodfish && isWorking), woodBalance > Int.min {
            woodBalance -= 1
            defaults.set(woodBalance, forKey: "woodfish.balance")
            woodDecaySerial &+= 1
        }
    }
    func nextMode() {
        let modes = PlayMode.allCases
        let index = modes.firstIndex(of: mode) ?? 0
        mode = modes[(index + 1) % modes.count]
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastTick = now }
        if desktopEnabled && mode == .fishing { refreshFishingEnvironment() }
        advanceWorkEffects(delta: now - lastTick)
        if rotation.advance(delta: now - lastTick, enabled: autoSwitch && desktopEnabled,
                            working: isWorking, interacting: mouseInteractionActive || (mode == .fishing &&
                                (fishing.engaged || (fishingReward?.isVisible(at: now) ?? false))), interval: switchInterval) {
            nextMode()
        }
    }
}

extension NSColor {
    static let playInk = NSColor(srgbRed: 0.14, green: 0.21, blue: 0.19, alpha: 1)
    static let playMint = NSColor(srgbRed: 0.23, green: 0.48, blue: 0.39, alpha: 1)
}
