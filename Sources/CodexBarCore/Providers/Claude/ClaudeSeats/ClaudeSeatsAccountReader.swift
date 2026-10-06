import Foundation

/// Result of probing every configured seat.
public struct ClaudeSeatsAccountList {
    public let list: ClaudeSwapAccountList
    /// Seat name to failure message for seats whose probe produced no usage.
    /// Surfaced through the adapter error text; never persisted with identity.
    public let seatErrors: [String: String]

    public init(list: ClaudeSwapAccountList, seatErrors: [String: String] = [:]) {
        self.list = list
        self.seatErrors = seatErrors
    }
}

/// Reads subscription usage for every configured Claude Code seat.
///
/// Each seat is probed through the same bounded Claude CLI machinery as the
/// ambient Claude card, with that seat's `CLAUDE_CONFIG_DIR` in the probe
/// environment. Credentials stay Claude Code-owned: every probe process reads
/// and refreshes only its own config directory's Keychain item, so CodexBar
/// never touches seat credentials directly (matching the claude-swap contract
/// in `docs/claude-multi-account-and-status-items.md`).
///
/// Probes run sequentially: the Claude CLI session actor serializes PTY probes
/// anyway, and three concurrent ~280 MB Claude processes would thrash.
public enum ClaudeSeatsAccountReader {
    public static let defaultTimeout: TimeInterval = 30

    public typealias SeatProbe = @Sendable (ClaudeSeatDefinition, [String: String]) async throws
        -> ClaudeUsageSnapshot

    /// Reads one row per seat, in seat order. The first seat represents the
    /// ambient (`~/.claude` or explicitly configured) credential and is marked
    /// active so menu precedence and the bar snapshot stay consistent.
    ///
    /// When `cache` is supplied and `force` is false, seats probed within the
    /// cache's background floor reuse their recent snapshot, so background
    /// refresh ticks do not relaunch the Claude binary per seat. User-initiated
    /// refreshes pass `force: true` and always probe.
    public static func readAccountList(
        seats: [ClaudeSeatDefinition],
        browserDetection: BrowserDetection,
        environment: [String: String],
        timeout: TimeInterval = ClaudeSeatsAccountReader.defaultTimeout,
        force: Bool = false,
        cache: ClaudeSeatsProbeCache? = nil,
        probe: SeatProbe? = nil) async throws -> ClaudeSeatsAccountList
    {
        guard !seats.isEmpty else {
            throw ClaudeSeatsReaderError.noSeatsConfigured
        }
        let effectiveProbe = probe ?? Self.defaultProbe(
            browserDetection: browserDetection,
            timeout: timeout)
        var rows: [ClaudeSwapAccountRow] = []
        var seatErrors: [String: String] = [:]
        for (index, seat) in seats.enumerated() {
            try Task.checkCancellation()
            let seatEnvironment = Self.environment(for: seat, base: environment)
            do {
                let snapshot = try await Self.probedSnapshot(
                    seat: seat,
                    seatEnvironment: seatEnvironment,
                    force: force,
                    cache: cache,
                    probe: effectiveProbe)
                rows.append(Self.row(
                    for: seat,
                    number: index + 1,
                    isActive: index == 0,
                    snapshot: snapshot))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                seatErrors[seat.name] = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                rows.append(Self.unavailableRow(for: seat, number: index + 1, isActive: index == 0))
            }
        }
        return ClaudeSeatsAccountList(
            list: ClaudeSwapAccountList(
                activeAccountNumber: 1,
                accounts: rows,
                supportsAccountSwitching: false),
            seatErrors: seatErrors)
    }

    private static func probedSnapshot(
        seat: ClaudeSeatDefinition,
        seatEnvironment: [String: String],
        force: Bool,
        cache: ClaudeSeatsProbeCache?,
        probe: SeatProbe) async throws -> ClaudeUsageSnapshot
    {
        if let cache, !force,
           let cached = cache.snapshot(for: seat, now: Date())
        {
            return cached
        }
        let snapshot = try await probe(seat, seatEnvironment)
        cache?.record(snapshot, for: seat, now: Date())
        return snapshot
    }

    /// Per-seat environment: only `CLAUDE_CONFIG_DIR` changes between seats.
    public static func environment(for seat: ClaudeSeatDefinition, base: [String: String]) -> [String: String] {
        var environment = base
        environment[ClaudeConfigPaths.configDirectoryEnvironmentKey] =
            (seat.configDirectory as NSString).expandingTildeInPath
        return environment
    }

    static func defaultProbe(
        browserDetection: BrowserDetection,
        timeout: TimeInterval) -> SeatProbe
    {
        { _, seatEnvironment in
            let fetcher = ClaudeUsageFetcher(
                browserDetection: browserDetection,
                environment: seatEnvironment,
                runtime: .app,
                dataSource: .cli)
            return try await fetcher.loadLatestUsage(model: "sonnet")
        }
    }

    private static func row(
        for seat: ClaudeSeatDefinition,
        number: Int,
        isActive: Bool,
        snapshot: ClaudeUsageSnapshot) -> ClaudeSwapAccountRow
    {
        let fiveHour = snapshot.primaryWindowKind == .usage
            ? Self.window(from: snapshot.primary, expectedWindowMinutes: 5 * 60)
            : nil
        let sevenDay = Self.window(from: snapshot.secondary, expectedWindowMinutes: 7 * 24 * 60)
        var scoped: [ClaudeSwapScopedUsageWindow] = []
        if let opus = snapshot.opus {
            scoped.append(ClaudeSwapScopedUsageWindow(
                name: "Opus",
                usedPercent: opus.usedPercent,
                resetsAt: opus.resetsAt))
        }
        scoped.append(contentsOf: (snapshot.extraRateWindows ?? []).compactMap { named in
            guard named.usageKnown else { return nil }
            return ClaudeSwapScopedUsageWindow(
                name: Self.scopedName(from: named.title),
                usedPercent: named.window.usedPercent,
                resetsAt: named.window.resetsAt)
        })
        return ClaudeSwapAccountRow(
            number: number,
            email: snapshot.accountEmail ?? "",
            organizationName: snapshot.accountOrganization ?? "",
            alias: seat.name,
            isActive: isActive,
            usageStatus: .ok,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            scoped: scoped,
            usageFetchedAt: snapshot.updatedAt)
    }

    private static func unavailableRow(
        for seat: ClaudeSeatDefinition,
        number: Int,
        isActive: Bool) -> ClaudeSwapAccountRow
    {
        ClaudeSwapAccountRow(
            number: number,
            email: "",
            organizationName: "",
            alias: seat.name,
            isActive: isActive,
            usageStatus: .unavailable,
            fiveHour: nil,
            sevenDay: nil)
    }

    private static func window(
        from rateWindow: RateWindow?,
        expectedWindowMinutes: Int) -> ClaudeSwapUsageWindow?
    {
        guard let rateWindow, rateWindow.windowMinutes == expectedWindowMinutes || rateWindow.windowMinutes == nil
        else { return nil }
        return ClaudeSwapUsageWindow(
            usedPercent: rateWindow.usedPercent,
            resetsAt: rateWindow.resetsAt)
    }

    /// Scoped rows feed back through `ClaudeScopedWeeklyLimitMapper`, which
    /// appends "only" to the model name, so strip a probe's rendered suffix.
    private static func scopedName(from title: String) -> String {
        let suffix = " only"
        guard title.hasSuffix(suffix) else { return title }
        return String(title.dropLast(suffix.count))
    }
}

/// Per-seat snapshots from recent probes. Matches the repo's 15-minute
/// expensive-local-work floor (`ClaudeCLIUsageSpawnThrottle`): each seat probe
/// spawns the full Claude binary, so background refresh ticks reuse recent
/// results instead of respawning. A cached snapshot expires once any of its
/// windows crosses its reset boundary, so post-reset state publishes promptly.
/// Measurement age stays honest: rows carry the snapshot's own `updatedAt`.
public final class ClaudeSeatsProbeCache: @unchecked Sendable {
    public static let minimumBackgroundInterval: TimeInterval = 15 * 60

    private struct Entry {
        let snapshot: ClaudeUsageSnapshot
        let recordedAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    public func removeAll() {
        self.lock.withLock { self.entries.removeAll() }
    }

    func snapshot(for seat: ClaudeSeatDefinition, now: Date) -> ClaudeUsageSnapshot? {
        self.lock.withLock {
            guard let entry = self.entries[ClaudeSeatsProbeCache.key(for: seat)] else { return nil }
            let age = now.timeIntervalSince(entry.recordedAt)
            guard age >= 0,
                  age < ClaudeSeatsProbeCache.minimumBackgroundInterval,
                  !ClaudeSeatsProbeCache.anyWindowHasReset(in: entry.snapshot, now: now)
            else {
                self.entries.removeValue(forKey: ClaudeSeatsProbeCache.key(for: seat))
                return nil
            }
            return entry.snapshot
        }
    }

    func record(_ snapshot: ClaudeUsageSnapshot, for seat: ClaudeSeatDefinition, now: Date) {
        self.lock.withLock {
            self.entries[ClaudeSeatsProbeCache.key(for: seat)] = Entry(
                snapshot: snapshot,
                recordedAt: now)
        }
    }

    private static func key(for seat: ClaudeSeatDefinition) -> String {
        "\(seat.name.lowercased())\u{0}\((seat.configDirectory as NSString).expandingTildeInPath)"
    }

    private static func anyWindowHasReset(in snapshot: ClaudeUsageSnapshot, now: Date) -> Bool {
        let windows = [snapshot.primary, snapshot.secondary, snapshot.opus].compactMap(\.self)
            + (snapshot.extraRateWindows ?? []).map(\.window)
        return windows.contains { window in
            guard let resetsAt = window.resetsAt else { return false }
            return resetsAt <= now
        }
    }
}

public enum ClaudeSeatsReaderError: LocalizedError, Sendable {
    case noSeatsConfigured

    public var errorDescription: String? {
        switch self {
        case .noSeatsConfigured:
            "No Claude Code seats are configured or discovered."
        }
    }
}
