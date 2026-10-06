import Foundation

/// The default location of each supported tool's local data, resolved exactly as the Mac app resolves
/// it before any folder the user picked in Settings. The environment variables are the ones the tools
/// themselves honor: `CLAUDE_CONFIG_DIR`, `GROK_HOME` and `XDG_DATA_HOME`.
public struct SourceFolders: Sendable, Equatable {
    public let codex: URL
    public let claudeCode: URL
    public let grokBuild: URL
    /// The data root that holds the `antigravity*/conversations` folders.
    public let antigravity: URL
    /// The data root that holds `opencode.db`.
    public let openCode: URL

    public init(codex: URL, claudeCode: URL, grokBuild: URL, antigravity: URL, openCode: URL) {
        self.codex = codex
        self.claudeCode = claudeCode
        self.grokBuild = grokBuild
        self.antigravity = antigravity
        self.openCode = openCode
    }

    public static func defaults(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SourceFolders {
        let claudeConfig = configuredDirectory(override: environment["CLAUDE_CONFIG_DIR"], fallback: home.appendingPathComponent(".claude", isDirectory: true))
        let grokHome = configuredDirectory(override: environment["GROK_HOME"], fallback: home.appendingPathComponent(".grok", isDirectory: true))
        // OpenCode resolves its data folder from XDG_DATA_HOME on every platform.
        let dataHome = configuredDirectory(override: environment["XDG_DATA_HOME"], fallback: home.appendingPathComponent(".local/share", isDirectory: true))
        return SourceFolders(
            codex: home.appendingPathComponent(".codex/sessions", isDirectory: true),
            claudeCode: claudeConfig.appendingPathComponent("projects", isDirectory: true),
            grokBuild: grokHome.appendingPathComponent("sessions", isDirectory: true),
            antigravity: home.appendingPathComponent(".gemini", isDirectory: true),
            openCode: dataHome.appendingPathComponent("opencode", isDirectory: true)
        )
    }

    private static func configuredDirectory(override: String?, fallback: URL) -> URL {
        guard let override, !override.isEmpty else { return fallback }
        return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
    }
}
