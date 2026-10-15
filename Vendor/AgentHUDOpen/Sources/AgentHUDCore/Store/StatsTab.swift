/// The statistics window's two pages: token charts, and the session list with each session's page. The store keeps
/// the page with the other selections that move it (`UsageStore.statsTab`); the window names it.
public enum StatsTab: Hashable, Sendable {
    case tokens, sessions
}
