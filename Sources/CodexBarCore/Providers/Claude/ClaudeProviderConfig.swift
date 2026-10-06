import Foundation

/// Where CodexBar discovers multiple Claude subscription accounts.
public enum ClaudeAccountSource: String, CaseIterable, Codable, Sendable {
    /// The external `cswap` executable owns the account slots.
    case claudeSwap = "claude-swap"
    /// Claude Code seat config directories (`CLAUDE_CONFIG_DIR`), probed read-only.
    case seats
}

extension ProviderConfig {
    public var claudeWorkspaceSpendEnabled: Bool? {
        get { self.extensionValue(forKey: "claudeWorkspaceSpendEnabled") }
        set { self.setExtensionValue(newValue, forKey: "claudeWorkspaceSpendEnabled") }
    }

    public var claudeSwapEnabled: Bool? {
        get { self.extensionValue(forKey: "claudeSwapEnabled") }
        set { self.setExtensionValue(newValue, forKey: "claudeSwapEnabled") }
    }

    public var claudeSwapShowSingleAccount: Bool? {
        get { self.extensionValue(forKey: "claudeSwapShowSingleAccount") }
        set { self.setExtensionValue(newValue, forKey: "claudeSwapShowSingleAccount") }
    }

    public var claudeSwapExecutablePath: String? {
        get { self.extensionValue(forKey: "claudeSwapExecutablePath") }
        set { self.setExtensionValue(newValue, forKey: "claudeSwapExecutablePath") }
    }

    public var claudeAccountSource: ClaudeAccountSource? {
        get { self.extensionValue(forKey: "claudeAccountSource") }
        set { self.setExtensionValue(newValue, forKey: "claudeAccountSource") }
    }

    public var claudeSeats: String? {
        get { self.extensionValue(forKey: "claudeSeats") }
        set { self.setExtensionValue(newValue, forKey: "claudeSeats") }
    }

    public var sanitizedClaudeSwapExecutablePath: String? {
        SettingsValue.cleaned(self.claudeSwapExecutablePath)
    }
}
