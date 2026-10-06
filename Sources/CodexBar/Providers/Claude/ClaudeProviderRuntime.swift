import CodexBarCore

@MainActor
final class ClaudeProviderRuntime: ProviderRuntime {
    let id: UsageProvider = .claude
    private var lastSwapConfiguration: Configuration?

    func start(context: ProviderRuntimeContext) {
        self.reconcileSwapConfiguration(context: context)
    }

    func stop(context: ProviderRuntimeContext) {
        self.lastSwapConfiguration = nil
        context.store.clearClaudeSwapAccountState()
    }

    func settingsDidChange(context: ProviderRuntimeContext) {
        self.reconcileSwapConfiguration(context: context)
    }

    private func reconcileSwapConfiguration(context: ProviderRuntimeContext) {
        let configuration = Configuration(
            providerEnabled: context.store.isEnabled(.claude),
            enabled: context.settings.claudeSwapEnabled,
            source: context.settings.claudeAccountSource,
            executablePath: context.settings.claudeSwapExecutablePath,
            seats: context.settings.claudeSeats)
        guard configuration != self.lastSwapConfiguration else { return }
        self.lastSwapConfiguration = configuration

        // Cancel before clearing so an old executable can never repopulate the menu.
        context.store.clearClaudeSwapAccountState()
        guard configuration.providerEnabled, configuration.enabled else { return }
        switch configuration.source {
        case .seats:
            break
        case .claudeSwap:
            guard !configuration.executablePath.isEmpty else { return }
        }
        context.store.scheduleClaudeSwapAccountRefresh()
    }

    private struct Configuration: Equatable {
        let providerEnabled: Bool
        let enabled: Bool
        let source: ClaudeAccountSource
        let executablePath: String
        let seats: String
    }
}
