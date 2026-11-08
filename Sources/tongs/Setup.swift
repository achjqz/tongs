import Foundation

/// Wires tongs into an agent: a PreToolUse guard hook plus instructions the agent reads.
/// Dry run by default; `--apply` writes, keeping a one-time `.tongs-backup` of each file it changes.
enum Setup {
    static let instructions = """
    # tongs: using secrets without seeing them

    API keys, tokens and passwords live in the macOS Keychain under `tongs`. You never see a value; you use it by name.

    - `tongs ls` lists the secrets usable in the current project, with their scope and description (never values).
    - `tongs run NAME [NAME...] -- <command>` runs the command with each NAME exported as an environment variable of the same name. Output is scrubbed: a value prints as ‹redacted:NAME›.
      Your shell expands `$NAME` before tongs runs, where it is empty. When the command line itself needs the value, wrap it in single quotes: `tongs run GH_TOKEN -- sh -c 'curl -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/user'`.
    - `tongs request NAME --why "<what it is for>" [--url <https page where the user creates it>] [--global]` when a secret you need doesn't exist. A dialog asks the user to paste it; you only learn that it was stored. Never ask the user to paste a secret into the chat.

    Names and scopes:
    - A secret belongs either to the current project (the git repo's directory name; worktrees count as their main repo) or is global. `tongs run NAME` uses the project's NAME if it has one, otherwise the global NAME; the environment variable is NAME either way.
    - `tongs request` defaults to the current project. Pass `--global` for credentials of the user's own accounts that every project shares (a personal GitHub token, an OpenAI key). The user can still change the scope in the dialog.
    - Name secrets after what the consuming tool expects, usually its documented environment variable (`STRIPE_SECRET_KEY`, `DATABASE_URL`, `GH_TOKEN`). Don't put the project name in NAME; the scope already says that.

    Rules:
    - Never print, echo, write to a file, or transform (base64, rev, hex…) a secret value, and don't run `env`/`printenv` under `tongs run`.
    - Don't read the Keychain with `security` or look for values elsewhere; a guard hook blocks that.
    - The first use of a secret in a project asks the user for Touch ID. If it is declined, stop and tell the user instead of looking for another way.
    - `tongs request` and the first `tongs run` of a secret wait for the user. Give them a long timeout, such as 10 minutes, so the dialog isn't killed while the user is still fetching the key.
    - If the user pastes a secret into the chat anyway, tell them it is now in the transcript and should be rotated, then store the new one with `tongs request`.
    """

    enum Change {
        case write(URL, String)
        case delete(URL)
    }

    static func main(_ args: ArraySlice<String>) {
        let (pos, opts) = parseOptions(args, flags: [], switches: ["--apply", "--remove"])
        guard pos.count == 1, ["claude", "codex"].contains(pos[0]) else {
            fail("usage: tongs setup claude|codex [--remove] [--apply]")
        }
        let apply = opts["--apply"] != nil
        let remove = opts["--remove"] != nil
        let changes = pos[0] == "claude" ? claude(remove: remove) : codex(remove: remove)

        if changes.isEmpty {
            print("\(pos[0]): \(remove ? "nothing to remove" : "already set up")")
            return
        }
        for change in changes {
            switch change {
            case let .write(url, content):
                print(apply ? "write \(url.path)" : "would write \(url.path):")
                if !apply { print(content.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")) }
            case let .delete(url):
                print(apply ? "delete \(url.path)" : "would delete \(url.path)")
            }
        }
        guard apply else {
            print("\nRe-run with --apply to make these changes.")
            return
        }
        let fm = FileManager.default
        for change in changes {
            do {
                switch change {
                case let .write(url, content):
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let backup = url.appendingPathExtension("tongs-backup")
                    if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
                        try fm.copyItem(at: url, to: backup)
                    }
                    try content.write(to: url, atomically: true, encoding: .utf8)
                case let .delete(url):
                    try fm.removeItem(at: url)
                }
            } catch {
                fail("cannot change files: \(error.localizedDescription)")
            }
        }
        if remove {
            print("Done. Restart \(pos[0] == "claude" ? "Claude Code sessions" : "Codex") to drop the hook. Stored secrets are untouched.")
        } else {
            print(pos[0] == "claude"
                  ? "Done. Restart Claude Code sessions to pick up the hook and skill."
                  : "Done. Restart Codex; it may ask you to trust the new hook (/hooks), and older builds need `[features] codex_hooks = true` in config.toml.")
        }
    }

    static var home: URL {
        ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
    }

    static func claude(remove: Bool) -> [Change] {
        let settings = home.appendingPathComponent(".claude/settings.json")
        let skillDir = home.appendingPathComponent(".claude/skills/tongs")
        var changes: [Change] = []
        if remove {
            if let s = withoutHook(settings) { changes.append(.write(settings, s)) }
            if FileManager.default.fileExists(atPath: skillDir.path) { changes.append(.delete(skillDir)) }
            return changes
        }
        if let s = withHook(settings, matcher: "Bash|Read|Grep|Glob", command: "\(executablePath()) hook") {
            changes.append(.write(settings, s))
        }
        let skill = skillDir.appendingPathComponent("SKILL.md")
        let skillText = """
        ---
        name: tongs
        description: Use stored API keys, tokens and passwords without seeing them. Use whenever a command needs a credential, or the user mentions a token, API key or password.
        ---

        \(instructions)

        """
        if (try? String(contentsOf: skill, encoding: .utf8)) != skillText { changes.append(.write(skill, skillText)) }
        return changes
    }

    static func codex(remove: Bool) -> [Change] {
        let hooks = home.appendingPathComponent(".codex/hooks.json")
        let agents = home.appendingPathComponent(".codex/AGENTS.md")
        let rules = home.appendingPathComponent(".codex/rules/tongs.rules")
        var changes: [Change] = []
        if remove {
            if let s = withoutHook(hooks) { changes.append(s.isEmpty ? .delete(hooks) : .write(hooks, s)) }
            if let s = withoutBlock(agents) { changes.append(.write(agents, s)) }
            if FileManager.default.fileExists(atPath: rules.path) { changes.append(.delete(rules)) }
            return changes
        }
        let exe = executablePath()
        if let s = withHook(hooks, matcher: ".*", command: "\(exe) hook") { changes.append(.write(hooks, s)) }
        if let s = withBlock(agents, block: instructions) { changes.append(.write(agents, s)) }
        // Codex's seatbelt sandbox blocks Keychain, Touch ID, dialogs and local sockets, so tongs must
        // run outside it. ls/request can't run arbitrary code, so they're allowed outright; run
        // executes the agent's command unsandboxed, so Codex shows it to the user first.
        let rulesText = ["tongs", exe].flatMap { e in
            [
                "prefix_rule(pattern=[\"\(e)\", \"ls\"], decision=\"allow\")",
                "prefix_rule(pattern=[\"\(e)\", \"request\"], decision=\"allow\")",
                "prefix_rule(pattern=[\"\(e)\", \"run\"], decision=\"prompt\")",
            ]
        }.joined(separator: "\n") + "\n"
        if (try? String(contentsOf: rules, encoding: .utf8)) != rulesText { changes.append(.write(rules, rulesText)) }
        return changes
    }

    static func executablePath() -> String {
        let p = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let me = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        // Prefer the tongs on PATH (e.g. ~/.local/bin/tongs) when it is this binary, so the hook
        // keeps working if the checkout's build directory is cleaned or moved.
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/tongs"
            if URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path == me { return candidate }
        }
        return me
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fail("\(url.path) is not valid JSON; not touching it")
        }
        return obj
    }

    static func renderJSON(_ root: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func isTongsHook(_ command: String?) -> Bool {
        guard let command else { return false }
        return command == "tongs hook" || command.hasSuffix("/tongs hook")
    }

    /// Returns the new file content, or nil if the hook is already present.
    static func withHook(_ url: URL, matcher: String, command: String) -> String? {
        var root = readJSON(url) ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var pre = hooks["PreToolUse"] as? [[String: Any]] ?? []
        let present = pre.contains { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String) == command }
        }
        if present { return nil }
        pre.append(["matcher": matcher, "hooks": [["type": "command", "command": command]]])
        hooks["PreToolUse"] = pre
        root["hooks"] = hooks
        return renderJSON(root)
    }

    /// Drops every tongs hook (wherever the binary lived); nil if there was none, "" if the file
    /// would be left with nothing in it.
    static func withoutHook(_ url: URL) -> String? {
        guard var root = readJSON(url), var hooks = root["hooks"] as? [String: Any],
              let pre = hooks["PreToolUse"] as? [[String: Any]] else { return nil }
        var changed = false
        let kept: [[String: Any]] = pre.compactMap { entry in
            var e = entry
            let list = entry["hooks"] as? [[String: Any]] ?? []
            let rest = list.filter { !isTongsHook($0["command"] as? String) }
            if rest.count == list.count { return entry }
            changed = true
            if rest.isEmpty { return nil }
            e["hooks"] = rest
            return e
        }
        guard changed else { return nil }
        if kept.isEmpty { hooks.removeValue(forKey: "PreToolUse") } else { hooks["PreToolUse"] = kept }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return root.isEmpty ? "" : renderJSON(root)
    }

    static let blockBegin = "<!-- tongs:begin -->"
    static let blockEnd = "<!-- tongs:end -->"

    /// Inserts or replaces a marked block in a Markdown file; nil if unchanged.
    static func withBlock(_ url: URL, block: String) -> String? {
        let begin = blockBegin
        let end = blockEnd
        let wrapped = "\(begin)\n\(block)\n\(end)"
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let next: String
        if let b = current.range(of: begin), let e = current.range(of: end, range: b.upperBound..<current.endIndex) {
            next = current.replacingCharacters(in: b.lowerBound..<e.upperBound, with: wrapped)
        } else {
            next = current.isEmpty ? wrapped + "\n" : current + (current.hasSuffix("\n") ? "\n" : "\n\n") + wrapped + "\n"
        }
        return next == current ? nil : next
    }

    /// Removes the marked block and the blank line before it; nil if there is none.
    static func withoutBlock(_ url: URL) -> String? {
        guard let current = try? String(contentsOf: url, encoding: .utf8),
              let b = current.range(of: blockBegin),
              let e = current.range(of: blockEnd, range: b.upperBound..<current.endIndex) else { return nil }
        var end = e.upperBound
        if end < current.endIndex, current[end] == "\n" { end = current.index(after: end) }
        var start = b.lowerBound
        while start > current.startIndex, current[current.index(before: start)] == "\n",
              current[..<start].hasSuffix("\n\n") { start = current.index(before: start) }
        return current.replacingCharacters(in: start..<end, with: "")
    }
}
