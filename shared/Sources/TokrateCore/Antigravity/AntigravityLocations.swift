import Foundation

/// Known stores only. T3's provider profiles also contain credentials, settings and logs;
/// discovery never descends into those files or follows a profile-directory symlink.
struct AntigravityLocations: Sendable {
    let root: URL
    let t3ProfilesRoot: URL?

    static let nativeSources: [(path: String, surface: ToolSurface)] = [
        ("antigravity/conversations", .desktop),
        ("antigravity-ide/conversations", .ide),
        ("antigravity-cli/conversations", .cli)
    ]

    func sources() -> [(url: URL, surface: ToolSurface)] {
        var sources = Self.nativeSources.map { (root.appendingPathComponent($0.path, isDirectory: true), $0.surface) }
        guard let profiles = t3ProfilesRoot, Self.realDirectory(profiles),
              let entries = FileManager.default.enumerator(
                at: profiles, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
              ) else { return sources }
        var visited = 0, accepted = 0
        for case let profile as URL in entries {
            visited += 1
            if visited > 1_024 || accepted >= 128 { break }
            guard Self.isProfileName(profile.lastPathComponent), Self.realDirectory(profile) else { continue }
            accepted += 1
            let acp = profile.appendingPathComponent("antigravity-acp", isDirectory: true)
            let conversations = acp.appendingPathComponent("conversations", isDirectory: true)
            guard Self.realDirectory(acp), Self.realDirectory(conversations) else { continue }
            sources.append((conversations, .other))
        }
        return sources
    }

    /// Directory creation may arrive before any database exists. Ignore auth/settings churn.
    func isT3DirectoryEvent(_ url: URL) -> Bool {
        guard let profiles = t3ProfilesRoot?.standardizedFileURL else { return false }
        let path = url.standardizedFileURL
        if path == profiles { return true }
        let parent = path.deletingLastPathComponent()
        if parent == profiles { return Self.isProfileName(path.lastPathComponent) }
        if path.lastPathComponent == "antigravity-acp" {
            return parent.deletingLastPathComponent() == profiles && Self.isProfileName(parent.lastPathComponent)
        }
        if path.lastPathComponent == "conversations", parent.lastPathComponent == "antigravity-acp" {
            let profile = parent.deletingLastPathComponent()
            return profile.deletingLastPathComponent() == profiles && Self.isProfileName(profile.lastPathComponent)
        }
        return false
    }

    private static func isProfileName(_ name: String) -> Bool {
        name.utf8.count == 64 && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func realDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}
