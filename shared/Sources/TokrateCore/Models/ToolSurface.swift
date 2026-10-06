import Foundation

/// Where a coding tool ran. Only this category is stored and shared; the originator or entrypoint
/// string it is derived from never leaves the parser (contract "Surface").
public enum ToolSurface: String, Codable, Sendable, CaseIterable {
    case cli, desktop, ide, sdk, other

    /// Codex: from `session_meta.payload.originator`. `payload.source` is deliberately not used; it is
    /// unreliable (Codex Desktop sessions report "vscode").
    public static func codex(originator: String?) -> ToolSurface? {
        guard let value = normalized(originator) else { return nil }
        switch value {
        case "codex desktop", "codex_work_desktop": return .desktop
        case "codex_cli_rs", "codex-tui", "codex_tui": return .cli
        case "codex_exec": return .sdk
        default:
            if containsEditor(value) { return .ide }
            if value.hasPrefix("codex_sdk") { return .sdk }
            return .other
        }
    }

    /// Claude Code: from the top-level `entrypoint` of a transcript record.
    public static func claude(entrypoint: String?) -> ToolSurface? {
        guard let value = normalized(entrypoint) else { return nil }
        switch value {
        case "cli": return .cli
        case "claude-desktop": return .desktop
        default:
            if containsEditor(value) || value.contains("ide") { return .ide }
            if value.hasPrefix("sdk") { return .sdk }
            return .other
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func containsEditor(_ value: String) -> Bool {
        ["vscode", "jetbrains", "cursor", "windsurf"].contains { value.contains($0) }
    }
}
