import Foundation
import Testing
@testable import CodexBarCore

/// Seat plan tests never touch the filesystem home unless discovery is
/// explicitly pointed at a synthetic directory.
struct ClaudeSeatsPlanTests {
    @Test
    func `parses comma separated name path entries`() {
        let seats = ClaudeSeatPlan.parse("claude=~/.claude, claude2=~/.claude-b\nclaude3=~/.claude-c")
        #expect(seats == [
            ClaudeSeatDefinition(name: "claude", configDirectory: "~/.claude"),
            ClaudeSeatDefinition(name: "claude2", configDirectory: "~/.claude-b"),
            ClaudeSeatDefinition(name: "claude3", configDirectory: "~/.claude-c"),
        ])
    }

    @Test
    func `ignores malformed blank and duplicate entries`() {
        let seats = ClaudeSeatPlan.parse(", oops, claude=~/.claude, claude=~, =/tmp/x, claude2=~/.claude-b")
        #expect(seats == [
            ClaudeSeatDefinition(name: "claude", configDirectory: "~/.claude"),
            ClaudeSeatDefinition(name: "claude2", configDirectory: "~/.claude-b"),
        ])
    }

    @Test
    func `configured list wins over discovery`() throws {
        let home = try Self.makeSyntheticHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let seats = ClaudeSeatPlan.resolve(
            configured: "claude=~/.claude",
            homeDirectory: home)
        #expect(seats == [ClaudeSeatDefinition(name: "claude", configDirectory: "~/.claude")])
    }

    @Test
    func `discovers claude config dirs with an account config`() throws {
        let home = try Self.makeSyntheticHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let seats = ClaudeSeatPlan.resolve(configured: "", homeDirectory: home)
        #expect(seats.map(\.name) == ["claude", "claude-b", "claude-c"])
        #expect(seats.allSatisfy { $0.configDirectory.hasPrefix(home.path) })
    }

    @Test
    func `discovery skips dirs without an account config`() throws {
        let home = try Self.makeSyntheticHome(withAccountConfigs: false)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(ClaudeSeatPlan.resolve(configured: "", homeDirectory: home).isEmpty)
    }

    private static func makeSyntheticHome(withAccountConfigs: Bool = true) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-seats-plan-tests-\(UUID().uuidString)", isDirectory: true)
        for name in [".claude", ".claude-b", ".claude-c", ".claude-ignore"] {
            let directory = home.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if withAccountConfigs, name != ".claude-ignore" {
                try "{}".write(to: directory.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
            }
        }
        return home
    }
}
