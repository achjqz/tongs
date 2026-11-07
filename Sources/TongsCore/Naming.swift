import Foundation

/// A stored secret's identity. Global secrets are `NAME`; project secrets are `project/NAME`.
/// Either way the value is injected as the environment variable `NAME`.
public struct KeyName: Equatable, Hashable {
    public let scope: String?
    public let name: String

    public var key: String { scope.map { "\($0)/\(name)" } ?? name }

    public init(scope: String?, name: String) {
        self.scope = scope
        self.name = name
    }

    public init?(_ s: String) {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, let last = parts.last, KeyName.isName(last) else { return nil }
        if parts.count == 2 {
            guard KeyName.isScope(parts[0]) else { return nil }
            scope = parts[0]
        } else {
            scope = nil
        }
        name = last
    }

    public static func isName(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    public static func isScope(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }
}

public enum Project {
    /// Root of the git work tree containing `dir`, or nil outside git. A linked worktree
    /// (agents create these constantly) resolves to its main repository, so it shares the
    /// main repo's project secrets and approvals.
    public static func root(containing dir: String) -> String? {
        var url = URL(fileURLWithPath: dir).standardizedFileURL
        while true {
            let git = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) {
                if !isDir.boolValue,
                   let text = try? String(contentsOf: git, encoding: .utf8),
                   let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                    let gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    let abs = gitdir.hasPrefix("/") ? gitdir : url.appendingPathComponent(gitdir).standardizedFileURL.path
                    if let r = abs.range(of: "/.git/worktrees/") { return String(abs[..<r.lowerBound]) }
                }
                return url.path
            }
            if url.path == "/" { return nil }
            url.deleteLastPathComponent()
        }
    }

    /// The scope name for a project root: its directory name, made safe for a key prefix.
    public static func scope(forRoot root: String) -> String {
        let base = (root as NSString).lastPathComponent
        let cleaned = base.replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "-", options: .regularExpression)
        return KeyName.isScope(cleaned) ? cleaned : "p" + cleaned
    }
}
