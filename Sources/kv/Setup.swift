import Foundation

/// Wires kv into an agent: a PreToolUse guard hook plus instructions the agent reads.
/// Dry run by default; `--apply` writes, keeping a one-time `.kv-backup` of each file it changes.
enum Setup {
    static let instructions = """
    # kv: using secrets without seeing them

    API keys, tokens and passwords live in the macOS Keychain under `kv`. You never see a value; you use it by name.

    - `kv ls` lists secret names and descriptions (never values).
    - `kv run NAME [NAME...] -- <command>` runs the command with each NAME exported as an environment variable of the same name. Output is scrubbed: a value prints as ‹redacted:NAME›.
      Your shell expands `$NAME` before kv runs, where it is empty. When the command line itself needs the value, wrap it in single quotes: `kv run GH_TOKEN -- sh -c 'curl -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/user'`.
    - `kv request NAME --why "<what it is for>" [--url <https page where the user creates it>]` when a secret you need doesn't exist. A dialog asks the user to paste it; you only learn that it was stored. Never ask the user to paste a secret into the chat.

    Rules:
    - Never print, echo, write to a file, or transform (base64, rev, hex…) a secret value, and don't run `env`/`printenv` under `kv run`.
    - Don't read the Keychain with `security` or look for values elsewhere; a guard hook blocks that.
    - The first use of a secret in a project asks the user for Touch ID. If it is declined, stop and tell the user instead of looking for another way.
    - If the user pastes a secret into the chat anyway, tell them it is now in the transcript and should be rotated, then store the new one with `kv request`.
    """

    static func main(_ args: ArraySlice<String>) {
        let (pos, opts) = parseOptions(args, flags: [], switches: ["--apply"])
        guard pos.count == 1, ["claude", "codex"].contains(pos[0]) else { fail("usage: kv setup claude|codex [--apply]") }
        let apply = opts["--apply"] != nil
        let kv = executablePath()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let hookCommand = "\(kv) hook"

        var changes: [(URL, String)] = []
        if pos[0] == "claude" {
            let settings = home.appendingPathComponent(".claude/settings.json")
            if let s = withHook(settings, matcher: "Bash|Read|Grep|Glob", command: hookCommand) { changes.append((settings, s)) }
            let skill = home.appendingPathComponent(".claude/skills/kv/SKILL.md")
            let skillText = """
            ---
            name: kv
            description: Use stored API keys, tokens and passwords without seeing them. Use whenever a command needs a credential, or the user mentions a token, API key or password.
            ---

            \(instructions)

            """
            if (try? String(contentsOf: skill, encoding: .utf8)) != skillText { changes.append((skill, skillText)) }
        } else {
            let hooks = home.appendingPathComponent(".codex/hooks.json")
            if let s = withHook(hooks, matcher: ".*", command: hookCommand) { changes.append((hooks, s)) }
            let agents = home.appendingPathComponent(".codex/AGENTS.md")
            if let s = withBlock(agents, block: instructions) { changes.append((agents, s)) }
            // Codex's seatbelt sandbox blocks Keychain, Touch ID, dialogs and local sockets, so kv must
            // run outside it. ls/request can't run arbitrary code, so they're allowed outright; run
            // executes the agent's command unsandboxed, so Codex shows it to the user first.
            let rules = home.appendingPathComponent(".codex/rules/kv.rules")
            let rulesText = ["kv", kv].flatMap { exe in
                [
                    "prefix_rule(pattern=[\"\(exe)\", \"ls\"], decision=\"allow\")",
                    "prefix_rule(pattern=[\"\(exe)\", \"request\"], decision=\"allow\")",
                    "prefix_rule(pattern=[\"\(exe)\", \"run\"], decision=\"prompt\")",
                ]
            }.joined(separator: "\n") + "\n"
            if (try? String(contentsOf: rules, encoding: .utf8)) != rulesText { changes.append((rules, rulesText)) }
        }

        if changes.isEmpty {
            print("\(pos[0]): already set up")
            return
        }
        for (url, content) in changes {
            print(apply ? "write \(url.path)" : "would write \(url.path):")
            if !apply { print(content.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")) }
        }
        guard apply else {
            print("\nRe-run with --apply to make these changes.")
            return
        }
        for (url, content) in changes {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let backup = url.appendingPathExtension("kv-backup")
                if FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: backup.path) {
                    try FileManager.default.copyItem(at: url, to: backup)
                }
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                fail("cannot write \(url.path): \(error.localizedDescription)")
            }
        }
        print(pos[0] == "claude"
              ? "Done. Restart Claude Code sessions to pick up the hook and skill."
              : "Done. Restart Codex; it may ask you to trust the new hook (/hooks), and older builds need `[features] codex_hooks = true` in config.toml.")
    }

    static func executablePath() -> String {
        let p = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let me = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        // Prefer the kv on PATH (e.g. ~/.local/bin/kv) when it is this binary, so the hook
        // keeps working if the checkout's build directory is cleaned or moved.
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/kv"
            if URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path == me { return candidate }
        }
        return me
    }

    /// Returns the new file content, or nil if the hook is already present.
    static func withHook(_ url: URL, matcher: String, command: String) -> String? {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                fail("\(url.path) is not valid JSON; not touching it")
            }
            root = obj
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var pre = hooks["PreToolUse"] as? [[String: Any]] ?? []
        let present = pre.contains { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String) == command }
        }
        if present { return nil }
        pre.append(["matcher": matcher, "hooks": [["type": "command", "command": command]]])
        hooks["PreToolUse"] = pre
        root["hooks"] = hooks
        let data = try! JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Inserts or replaces a marked block in a Markdown file; nil if unchanged.
    static func withBlock(_ url: URL, block: String) -> String? {
        let begin = "<!-- kv:begin -->"
        let end = "<!-- kv:end -->"
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
}
