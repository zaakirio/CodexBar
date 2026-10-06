import Foundation

/// One Claude Code seat: a named `CLAUDE_CONFIG_DIR` the user launches through a
/// shell alias such as `claude2='CLAUDE_CONFIG_DIR="$HOME/.claude-b" claude'`.
/// Names and paths are display/configuration values only; they never become
/// account identity (slot numbers do, matching the claude-swap contract).
public struct ClaudeSeatDefinition: Equatable, Sendable {
    public let name: String
    /// Config directory path; `~` is expanded when the seat is probed.
    public let configDirectory: String

    public init(name: String, configDirectory: String) {
        self.name = name
        self.configDirectory = configDirectory
    }
}

public enum ClaudeSeatPlan {
    /// Parses the configured seat list: comma- or newline-separated `name=path`
    /// entries. Blank and malformed entries are ignored; duplicate names keep
    /// the first definition. Returns an empty array for empty input.
    public static func parse(_ raw: String) -> [ClaudeSeatDefinition] {
        var seenNames: Set<String> = []
        var seats: [ClaudeSeatDefinition] = []
        for segment in raw.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            let parts = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !path.isEmpty, seenNames.insert(name.lowercased()).inserted else { continue }
            seats.append(ClaudeSeatDefinition(name: name, configDirectory: path))
        }
        return seats
    }

    /// Resolves the effective seat plan. A non-empty configured list wins;
    /// otherwise seats are discovered from the home directory (`~/.claude` and
    /// `~/.claude-*` directories holding a `.claude.json` account config).
    public static func resolve(
        configured raw: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default) -> [ClaudeSeatDefinition]
    {
        let configuredSeats = self.parse(raw)
        guard configuredSeats.isEmpty else { return configuredSeats }
        return self.discover(in: homeDirectory, fileManager: fileManager)
    }

    /// Discovers seat config roots: `~/.claude` first, then `~/.claude-*`
    /// lexicographically. Names derive from the directory (leading dot dropped).
    /// Only directories with a `.claude.json` account config count as seats.
    public static func discover(
        in homeDirectory: URL,
        fileManager: FileManager = .default) -> [ClaudeSeatDefinition]
    {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: homeDirectory,
            includingPropertiesForKeys: nil,
            options: [])
        else { return [] }
        let candidateNames = entries
            .map(\.lastPathComponent)
            .filter { $0 == ".claude" || $0.hasPrefix(".claude-") }
            .sorted { lhs, rhs in
                if lhs == rhs { return false }
                if lhs == ".claude" { return true }
                if rhs == ".claude" { return false }
                return lhs < rhs
            }
        return candidateNames.compactMap { name in
            let directory = homeDirectory.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  fileManager.fileExists(atPath: directory.appendingPathComponent(".claude.json").path)
            else { return nil }
            return ClaudeSeatDefinition(
                name: String(name.dropFirst()),
                configDirectory: directory.path)
        }
    }
}
