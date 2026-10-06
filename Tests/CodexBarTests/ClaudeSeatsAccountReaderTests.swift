import Foundation
import Testing
@testable import CodexBarCore

/// Thread-safe probe call counter for @Sendable stub closures.
private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() {
        self.lock.withLock { self.count += 1 }
    }
}

/// Thread-safe environment recorder for @Sendable stub closures.
private final class EnvironmentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String: String]] = []

    var all: [[String: String]] {
        self.lock.withLock { self.recorded }
    }

    func record(_ environment: [String: String]) {
        self.lock.withLock { self.recorded.append(environment) }
    }
}

/// Seat reader tests use stub probes only: no Claude CLI, no credentials,
/// no Keychain access.
@Suite(.serialized)
struct ClaudeSeatsAccountReaderTests {
    private let seats = [
        ClaudeSeatDefinition(name: "claude", configDirectory: "~/.claude"),
        ClaudeSeatDefinition(name: "claude2", configDirectory: "~/.claude-b"),
        ClaudeSeatDefinition(name: "claude3", configDirectory: "~/.claude-c"),
    ]

    @Test
    func `probes seats in order with the first seat active`() async throws {
        let probedEnvironments = ProbeCounter()
        let environments = EnvironmentRecorder()
        let result = try await ClaudeSeatsAccountReader.readAccountList(
            seats: self.seats,
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: ["HOME": "/synthetic/home", "PATH": "/usr/bin"],
            probe: { seat, environment in
                environments.record(environment)
                probedEnvironments.increment()
                return Self.snapshot(
                    fiveHourUsed: 10 + Double(seat.name.count),
                    weeklyUsed: 20,
                    email: "\(seat.name)@example.com")
            })

        #expect(result.seatErrors.isEmpty)
        #expect(result.list.supportsAccountSwitching == false)
        #expect(result.list.activeAccountNumber == 1)
        #expect(result.list.accounts.map(\.alias) == ["claude", "claude2", "claude3"])
        #expect(result.list.accounts.map(\.isActive) == [true, false, false])
        #expect(result.list.accounts.map(\.usageStatus) == [.ok, .ok, .ok])
        // Each probe carries only its own CLAUDE_CONFIG_DIR override.
        #expect(probedEnvironments.value == 3)
        let recorded = environments.all
        #expect(recorded.count == 3)
        #expect(recorded[0]["CLAUDE_CONFIG_DIR"]?.hasSuffix("/.claude") == true)
        #expect(recorded[1]["CLAUDE_CONFIG_DIR"]?.hasSuffix("/.claude-b") == true)
        #expect(recorded[2]["CLAUDE_CONFIG_DIR"]?.hasSuffix("/.claude-c") == true)
        #expect(recorded.allSatisfy { $0["PATH"] == "/usr/bin" })
        #expect(result.list.accounts.first?.fiveHour?.usedPercent == 10 + Double("claude".count))
    }

    @Test
    func `maps usage windows and scoped rows into the swap row shape`() async throws {
        let reset = Date(timeIntervalSince1970: 1_900_000_000)
        let result = try await ClaudeSeatsAccountReader.readAccountList(
            seats: [self.seats[0]],
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            probe: { _, _ in
                ClaudeUsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 42,
                        windowMinutes: 5 * 60,
                        resetsAt: reset,
                        resetDescription: nil),
                    secondary: RateWindow(
                        usedPercent: 7,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: nil,
                        resetDescription: nil),
                    opus: RateWindow(
                        usedPercent: 55,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: nil,
                        resetDescription: nil),
                    extraRateWindows: [
                        NamedRateWindow(
                            id: "claude-weekly-scoped-fable",
                            title: "Fable only",
                            window: RateWindow(
                                usedPercent: 66,
                                windowMinutes: 7 * 24 * 60,
                                resetsAt: nil,
                                resetDescription: nil)),
                    ],
                    updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    accountEmail: "seat@example.com",
                    accountOrganization: "Example Org",
                    loginMethod: "claude-cli",
                    rawText: nil)
            })

        let row = try #require(result.list.accounts.first)
        #expect(row.email == "seat@example.com")
        #expect(row.organizationName == "Example Org")
        #expect(row.fiveHour == ClaudeSwapUsageWindow(usedPercent: 42, resetsAt: reset))
        #expect(row.sevenDay == ClaudeSwapUsageWindow(usedPercent: 7, resetsAt: nil))
        #expect(row.scoped.map(\.name) == ["Opus", "Fable"])
        #expect(row.usageFetchedAt == Date(timeIntervalSince1970: 1_800_000_000))

        let snapshot = try #require(
            ClaudeSwapAccountProjection.accountSnapshots(from: result.list).first?.snapshot)
        #expect(snapshot.primary?.usedPercent == 42)
        #expect(snapshot.secondary?.usedPercent == 7)
        #expect(snapshot.extraRateWindows?.map(\.title) == ["Opus only", "Fable only"])
    }

    @Test
    func `a failed seat becomes an unavailable row without failing siblings`() async throws {
        let result = try await ClaudeSeatsAccountReader.readAccountList(
            seats: self.seats,
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            probe: { seat, _ in
                if seat.name == "claude2" {
                    throw ClaudeUsageError.claudeNotInstalled
                }
                return Self.snapshot(fiveHourUsed: 1, weeklyUsed: 2, email: nil)
            })

        #expect(result.seatErrors["claude2"] == ClaudeUsageError.claudeNotInstalled.localizedDescription)
        #expect(result.seatErrors.count == 1)
        #expect(result.list.accounts.map(\.usageStatus) == [.ok, .unavailable, .ok])
        let failedRow = try #require(result.list.accounts.first(where: { $0.alias == "claude2" }))
        #expect(failedRow.fiveHour == nil)
        #expect(failedRow.isActive == false)
    }

    @Test
    func `requires at least one seat`() async {
        await #expect(throws: ClaudeSeatsReaderError.noSeatsConfigured) {
            try await ClaudeSeatsAccountReader.readAccountList(
                seats: [],
                browserDetection: BrowserDetection(cacheTTL: 0),
                environment: [:])
        }
    }

    @Test
    func `background ticks reuse cached seat probes until the floor expires`() async throws {
        let cache = ClaudeSeatsProbeCache()
        let probeCount = ProbeCounter()
        let probe: ClaudeSeatsAccountReader.SeatProbe = { _, _ in
            probeCount.increment()
            return Self.snapshot(fiveHourUsed: 5, weeklyUsed: 6, email: nil)
        }

        func read(force: Bool) async throws -> ClaudeSeatsAccountList {
            try await ClaudeSeatsAccountReader.readAccountList(
                seats: self.seats,
                browserDetection: BrowserDetection(cacheTTL: 0),
                environment: [:],
                force: force,
                cache: cache,
                probe: probe)
        }

        _ = try await read(force: false)
        _ = try await read(force: false)
        #expect(probeCount.value == 3)

        _ = try await read(force: true)
        #expect(probeCount.value == 6)
    }

    @Test
    func `cache expires a seat once any window resets`() async throws {
        let cache = ClaudeSeatsProbeCache()
        let resetSoon = Date().addingTimeInterval(2)
        let probeCount = ProbeCounter()
        let probe: ClaudeSeatsAccountReader.SeatProbe = { _, _ in
            probeCount.increment()
            return Self.snapshot(fiveHourUsed: 5, weeklyUsed: 6, email: nil, resetsAt: resetSoon)
        }

        _ = try await ClaudeSeatsAccountReader.readAccountList(
            seats: [self.seats[0]],
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            cache: cache,
            probe: probe)
        #expect(probeCount.value == 1)

        // Still inside the floor but past the window reset: the cache must not serve it.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        _ = try await ClaudeSeatsAccountReader.readAccountList(
            seats: [self.seats[0]],
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [:],
            cache: cache,
            probe: probe)
        #expect(probeCount.value == 2)
    }

    private static func snapshot(
        fiveHourUsed: Double,
        weeklyUsed: Double,
        email: String?,
        resetsAt: Date? = nil) -> ClaudeUsageSnapshot
    {
        ClaudeUsageSnapshot(
            primary: RateWindow(
                usedPercent: fiveHourUsed,
                windowMinutes: 5 * 60,
                resetsAt: resetsAt,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: weeklyUsed,
                windowMinutes: 7 * 24 * 60,
                resetsAt: resetsAt,
                resetDescription: nil),
            opus: nil,
            updatedAt: Date(),
            accountEmail: email,
            accountOrganization: nil,
            loginMethod: "claude-cli",
            rawText: nil)
    }
}
