import Foundation

/// The fork's first-launch defaults: Agent Home is the sidebar, the T3 chat
/// is on, per-agent usage is sampled, and anonymous telemetry to upstream is
/// off. Applied once per app identity; anything the user changes later sticks.
enum AgentHomeFirstLaunchDefaults {
    static let seededKey = "agentHomeFirstLaunchDefaultsSeeded"

    static func seedIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: seededKey) else { return }
        if defaults.object(forKey: CmuxExtensionSidebarSelection.defaultsKey) == nil {
            CmuxExtensionSidebarSelection.setProviderId(CmuxExtensionSidebarSelection.agentHomeProviderId, defaults: defaults)
        }
        let chatFlagOverride = "cmux.flags.override.agent-chat-ui-enabled-release"
        if defaults.object(forKey: chatFlagOverride) == nil {
            defaults.set(true, forKey: chatFlagOverride)
        }
        if defaults.object(forKey: "sidebarShowAgentUsage") == nil {
            defaults.set(true, forKey: "sidebarShowAgentUsage")
        }
        if defaults.object(forKey: "sendAnonymousTelemetry") == nil {
            defaults.set(false, forKey: "sendAnonymousTelemetry")
        }
        defaults.set(true, forKey: seededKey)
    }
}
