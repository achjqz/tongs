import Foundation

/// Decides whether an agent tool call reaches around tongs to read or tamper with secrets.
/// Input is the PreToolUse JSON that Claude Code and Codex hooks receive on stdin.
///
/// Shell input is parsed and only commands that would actually run are judged, so a script
/// that merely mentions `security` (an echo, a quoted heredoc, a grep pattern) passes.
public enum Guard {
    static let readSubcommands: Set<String> = [
        "find-generic-password", "find-internet-password", "dump-keychain", "export",
    ]
    /// Adding, overwriting or deleting items needs no password prompt for items in the login
    /// keychain, so an agent could silently delete a secret or swap in a value of its choosing.
    static let modifySubcommands: Set<String> = [
        "add-generic-password", "add-internet-password",
        "delete-generic-password", "delete-internet-password", "delete-keychain",
        "set-generic-password-partition-list", "set-internet-password-partition-list", "set-key-partition-list",
    ]
    static let wrappers: Set<String> = ["sudo", "env", "command", "exec", "nohup", "time", "nice", "caffeinate", "xargs"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
    static let inlineInterpreters: Set<String> = ["python", "python3", "ruby", "perl", "node", "osascript", "swift"]
    static let printers: Set<String> = ["echo", "printf"]
    /// Shell words that can precede a command in the same simple command (`while security …; do`).
    static let keywords: Set<String> = ["if", "then", "elif", "else", "while", "until", "do", "!", "{", "}"]

    public enum Finding: Equatable {
        case read
        case modify
        case keychainFiles
    }

    /// Returns a reason to block, or nil to allow.
    public static func check(hookInput: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: hookInput) as? [String: Any],
              let input = obj["tool_input"] as? [String: Any] else { return nil }
        return findings(toolName: obj["tool_name"] as? String ?? "", input: input).first.map(message)
    }

    public static func findings(toolName: String, input: [String: Any]) -> [Finding] {
        // File tools: only the path they touch matters (a Grep *pattern* is just text).
        for key in ["file_path", "path", "notebook_path"] {
            if let p = input[key] as? String, touchesKeychainFiles(p) { return [.keychainFiles] }
        }
        if toolName == "Glob", let p = input["pattern"] as? String, touchesKeychainFiles(p) { return [.keychainFiles] }

        // Shell tools: a script string (Claude Code's Bash) or an argv array (Codex exec).
        for key in ["command", "cmd"] {
            if let script = input[key] as? String { return scan(script: script, depth: 0) }
            if let argv = input[key] as? [String] { return scan(argv: argv, depth: 0) }
        }
        return []
    }

    static func message(_ f: Finding) -> String {
        let how = "Secrets are stored in tongs: use `tongs run NAME -- <command>` to use one, `tongs request NAME` to add or replace one, `tongs ls` to see what exists."
        switch f {
        case .read: return "tongs guard: this call reads the macOS Keychain directly. \(how)"
        case .modify: return "tongs guard: this call adds, changes or deletes Keychain items directly. \(how) Deleting is `tongs rm NAME`, which asks the user."
        case .keychainFiles: return "tongs guard: this call touches the Keychain database files. \(how)"
        }
    }

    static func touchesKeychainFiles(_ s: String) -> Bool {
        s.contains("Library/Keychains")
    }

    static func scan(script: String, depth: Int) -> [Finding] {
        guard depth < 8 else { return [] }
        let parsed = Shell.parse(script)
        var found = parsed.commands.flatMap { scan(argv: $0, depth: depth) }
        for inner in parsed.nested { found += scan(script: inner, depth: depth + 1) }
        return found
    }

    static func scan(argv full: [String], depth: Int) -> [Finding] {
        guard depth < 8 else { return [] }
        let argv = unwrap(full)
        guard let first = argv.first else { return [] }
        let exe = (first as NSString).lastPathComponent
        let args = Array(argv.dropFirst())
        var found: [Finding] = []

        if exe == "security", let sub = args.first(where: { !$0.hasPrefix("-") }) {
            if readSubcommands.contains(sub) { found.append(.read) }
            if modifySubcommands.contains(sub) { found.append(.modify) }
        }
        if shells.contains(exe), let script = inlineScript(args, flag: "c") {
            found += scan(script: script, depth: depth + 1)
        }
        if exe == "eval" {
            found += scan(script: args.joined(separator: " "), depth: depth + 1)
        }
        if inlineInterpreters.contains(exe) || exe.hasPrefix("python") {
            // Can't parse another language; judge inline code by the words it contains.
            for code in args where code.contains("security") {
                let words = Set(code.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted))
                if !words.isDisjoint(with: readSubcommands) { found.append(.read) }
                if !words.isDisjoint(with: modifySubcommands) { found.append(.modify) }
            }
        }
        if !printers.contains(exe), args.contains(where: touchesKeychainFiles) {
            found.append(.keychainFiles)
        }
        return found
    }

    /// Strips leading `NAME=value` assignments and wrapper commands (sudo, env, `tongs run … --`).
    static func unwrap(_ argv: [String]) -> [String] {
        var a = argv[...]
        while let w = a.first {
            if w.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil || keywords.contains(w) {
                a = a.dropFirst()
            } else if wrappers.contains((w as NSString).lastPathComponent) {
                a = a.dropFirst()
                // Wrapper options, including the ones that take a value.
                while let o = a.first, o.hasPrefix("-") || o.contains("=") {
                    a = a.dropFirst()
                    if ["-u", "-g", "-n", "-C", "-I", "-P"].contains(o) { a = a.dropFirst() }
                }
            } else if (w as NSString).lastPathComponent == "tongs", a.dropFirst().first == "run",
                      let sep = a.firstIndex(of: "--") {
                a = a[(sep + 1)...]
            } else {
                break
            }
        }
        return Array(a)
    }

    /// The script passed to `sh -c`, `bash -lc`, `zsh -ec` and the like.
    static func inlineScript(_ args: [String], flag: Character) -> String? {
        var it = args.makeIterator()
        while let a = it.next() {
            guard a.hasPrefix("-"), !a.hasPrefix("--") else { return nil }
            if a.dropFirst().contains(flag) { return it.next() }
        }
        return nil
    }
}
