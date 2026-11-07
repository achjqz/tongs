import Foundation

/// Decides whether an agent tool call reaches around tongs to read secrets directly.
/// Input is the PreToolUse JSON that Claude Code and Codex hooks receive on stdin.
public enum Guard {
    static let commandRules: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"\bsecurity\b[^|;&\n]*\b(find-generic-password|find-internet-password|dump-keychain|export)\b"#),
         "reads the macOS Keychain directly"),
        (try! NSRegularExpression(pattern: #"Library/Keychains"#),
         "touches Keychain database files"),
    ]

    /// Returns a reason to block, or nil to allow.
    public static func check(hookInput: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: hookInput) as? [String: Any] else { return nil }
        // Tool names and argument shapes differ between agents, so inspect every string argument.
        var strings: [String] = []
        collect(obj["tool_input"] ?? [:], into: &strings)
        for s in strings {
            let range = NSRange(s.startIndex..., in: s)
            for (re, why) in commandRules where re.firstMatch(in: s, range: range) != nil {
                return "tongs guard: this call \(why). Secrets are stored in tongs; use `tongs run NAME -- <command>` so the value is injected without being printed. `tongs ls` lists what exists."
            }
        }
        return nil
    }

    static func collect(_ v: Any, into out: inout [String]) {
        switch v {
        case let s as String: out.append(s)
        case let a as [Any]: a.forEach { collect($0, into: &out) }
        case let d as [String: Any]: d.values.forEach { collect($0, into: &out) }
        default: break
        }
    }
}
