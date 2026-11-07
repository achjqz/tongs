import AppKit
import Foundation
import TongsCore

let usage = """
tongs — secrets your AI agents can use without seeing

Names are environment-variable style. A secret is either global (NAME) or belongs to
the current git project (<project>/NAME); NAME resolves to the project one first.

  tongs ls [--all] [--json]                 secrets usable here (never values); --all: every project
  tongs run NAME... -- CMD...               run CMD with each NAME in its environment; output is scrubbed
  tongs request NAME [--why T] [--url U] [--global]
                                         ask the human for a secret in a native dialog
  tongs add NAME [--desc T] [--global]      store a secret yourself (hidden prompt, or stdin)
  tongs rm NAME                             delete a secret (asks for Touch ID)
  tongs grants                              show active approvals
  tongs revoke [NAME] [--agent A]           drop approvals
  tongs log [-n N]                          recent activity
  tongs doctor                              check Keychain / Touch ID / dialog access from here
  tongs setup claude|codex [--apply]        install the guard hook and agent instructions
  tongs hook                                PreToolUse guard (reads hook JSON on stdin)
"""

let grantTTL: TimeInterval = 12 * 3600

func fail(_ message: String, code: Int32 = 1) -> Never {
    warn(message)
    exit(code)
}

func parseKey(_ s: String) -> KeyName {
    guard s != Store.grantKeyAccount, let k = KeyName(s) else {
        fail("invalid name \(s): use an environment-variable style name like GITHUB_TOKEN, optionally project/NAME")
    }
    return k
}

/// NAME → this project's secret if there is one, else the global one. project/NAME is taken as is.
func resolve(_ k: KeyName, for caller: Caller) -> KeyName? {
    if k.scope != nil { return Store.exists(k.key) ? k : nil }
    if let scope = caller.scope {
        let scoped = KeyName(scope: scope, name: k.name)
        if Store.exists(scoped.key) { return scoped }
    }
    return Store.exists(k.key) ? k : nil
}

func scopeLabel(_ k: KeyName) -> String {
    k.scope.map { "项目 \($0)" } ?? "全局"
}

/// Splits `--flag value` options from positional arguments.
func parseOptions(_ args: ArraySlice<String>, flags: Set<String>, switches: Set<String> = []) -> (positional: [String], options: [String: String]) {
    var positional: [String] = []
    var options: [String: String] = [:]
    var it = args.makeIterator()
    while let a = it.next() {
        if switches.contains(a) {
            options[a] = ""
        } else if flags.contains(a) {
            guard let v = it.next() else { fail("\(a) needs a value") }
            options[a] = v
        } else if a.hasPrefix("-") && a.count > 1 {
            fail("unknown option \(a)")
        } else {
            positional.append(a)
        }
    }
    return (positional, options)
}

func grantBook() -> GrantBook {
    do {
        return GrantBook(url: Paths.grants, key: try Store.grantKey())
    } catch {
        fail("\(error)")
    }
}

func shortCommand(_ argv: [String]) -> String {
    let s = argv.joined(separator: " ").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }.joined(separator: " ⏎ ")
    return s.count > 60 ? String(s.prefix(57)) + "…" : s
}

func clip(_ s: String, _ n: Int) -> String {
    s.count > n ? String(s.prefix(n - 1)) + "…" : s
}

/// The Touch ID sheet only shows a line or two after "“tongs”正在尝试", so keep it to who gets what.
/// The full context goes to stderr and the activity log.
func approvalReason(_ keys: [KeyName], caller: Caller) -> String {
    let what = keys.count == 1 ? keys[0].key : "\(keys[0].key) 等 \(keys.count) 项"
    let place = keys.allSatisfy { $0.scope == nil } ? "（\(clip(caller.projectName, 12))）" : ""
    return "向 \(caller.agent) 提供 \(what)\(place)"
}

// MARK: commands

func cmdList(_ args: ArraySlice<String>) {
    let (_, opts) = parseOptions(args, flags: [], switches: ["--json", "--all"])
    let caller = Caller.current()
    var items: [SecretInfo]
    do { items = try Store.list() } catch { fail("\(error)") }
    if opts["--all"] == nil {
        // This project's secrets first, then the global ones.
        items = items.filter { $0.id.scope == nil || $0.id.scope == caller.scope }
            .sorted { ($0.id.scope == nil ? 1 : 0, $0.id.name) < ($1.id.scope == nil ? 1 : 0, $1.id.name) }
    }
    // A global secret is shadowed here when this project has its own of the same name.
    let projectNames = Set(items.filter { $0.id.scope != nil && $0.id.scope == caller.scope }.map(\.id.name))
    func shadowed(_ i: SecretInfo) -> Bool { i.id.scope == nil && projectNames.contains(i.id.name) }

    if opts["--json"] != nil {
        let arr: [[String: Any]] = items.map {
            ["name": $0.id.name, "key": $0.id.key, "scope": $0.id.scope ?? NSNull(),
             "description": $0.desc, "usableHere": !shadowed($0) && ($0.id.scope == nil || $0.id.scope == caller.scope)]
        }
        let data = try! JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        return
    }
    if items.isEmpty {
        print("(no secrets here yet — `tongs request NAME --why ...` or `tongs add NAME`)")
        return
    }
    let nameWidth = max(items.map { (opts["--all"] != nil ? $0.id.key : $0.id.name).count }.max() ?? 0, 4)
    let scopeWidth = max(items.map { scopeLabel($0.id).count }.max() ?? 0, 2)
    for i in items {
        let name = opts["--all"] != nil ? i.id.key : i.id.name
        var line = name.padding(toLength: nameWidth + 2, withPad: " ", startingAt: 0)
            + scopeLabel(i.id).padding(toLength: scopeWidth + 2, withPad: " ", startingAt: 0)
            + i.desc
        if shadowed(i) { line += "（此项目里被项目密钥覆盖）" }
        print(line)
    }
}

func cmdAdd(_ args: ArraySlice<String>) {
    let (pos, opts) = parseOptions(args, flags: ["--desc"], switches: ["--global"])
    guard pos.count == 1 else { fail("usage: tongs add NAME [--desc TEXT] [--global]") }
    let caller = Caller.current()
    var id = parseKey(pos[0])
    if id.scope == nil, opts["--global"] == nil, let scope = caller.scope {
        id = KeyName(scope: scope, name: id.name)
    }
    var value: String
    if isatty(0) != 0 {
        var buf = [CChar](repeating: 0, count: 8192)
        guard let p = readpassphrase("\(id.key) (hidden): ", &buf, buf.count, RPP_ECHO_OFF) else { fail("no input") }
        value = String(cString: p)
    } else {
        value = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }
    value = value.trimmingCharacters(in: .newlines)
    guard !value.isEmpty else { fail("empty value, nothing stored") }
    do { try Store.set(id.key, value: Data(value.utf8), desc: opts["--desc"]) } catch { fail("\(error)") }
    ActivityLog.record("add", caller: caller, secrets: [id.key])
    print("stored \(id.key) (\(scopeLabel(id)))")
}

func cmdRequest(_ args: ArraySlice<String>) {
    let (pos, opts) = parseOptions(args, flags: ["--why", "--url", "--desc"], switches: ["--global"])
    guard pos.count == 1 else { fail("usage: tongs request NAME [--why TEXT] [--url URL] [--desc TEXT] [--global]") }
    let caller = Caller.current()
    let asked = parseKey(pos[0])
    let why = opts["--why"]
    var url: URL?
    if let u = opts["--url"] {
        guard let parsed = URL(string: u), parsed.scheme == "https" else { fail("--url must be an https URL") }
        url = parsed
    }

    // The user picks the scope in the dialog unless the name already fixes it.
    let pickScope = asked.scope == nil ? caller.scope : nil
    let existing = [pickScope.map { KeyName(scope: $0, name: asked.name) }, asked].compactMap { $0 }.filter { Store.exists($0.key) }
    let info = RequestInfo(agent: caller.agent, name: asked.key, project: caller.projectName, why: why, url: url,
                           scopeProject: pickScope, defaultGlobal: opts["--global"] != nil,
                           replaces: existing.map(\.key))

    guard let entry = UI.askSecret(info) else {
        ActivityLog.record("request-declined", caller: caller, secrets: [asked.key])
        fail("the user declined to provide \(asked.name)")
    }
    let id = asked.scope != nil || entry.global || pickScope == nil ? asked : KeyName(scope: pickScope, name: asked.name)
    do { try Store.set(id.key, value: Data(entry.value.utf8), desc: opts["--desc"] ?? why) } catch { fail("\(error)") }
    ActivityLog.record("request", caller: caller, secrets: [id.key])
    let shape = describeShape(entry.value).map { ", looks like a \($0)" } ?? ""
    print("stored \(id.key) (\(scopeLabel(id)), \(entry.value.count) chars\(shape)). Use it with: tongs run \(id.name) -- <command>")
}

func cmdRun(_ args: ArraySlice<String>) {
    guard let sep = args.firstIndex(of: "--") else { fail("usage: tongs run NAME... -- CMD...") }
    let asked = args[args.startIndex..<sep].map(parseKey)
    let argv = Array(args[(sep + 1)...])
    guard !asked.isEmpty, !argv.isEmpty else { fail("usage: tongs run NAME... -- CMD...") }
    guard Set(asked.map(\.name)).count == asked.count else { fail("each environment variable name can only be given once") }

    let caller = Caller.current()
    var keys: [KeyName] = []
    for k in asked {
        guard let r = resolve(k, for: caller) else {
            fail("no secret \(k.key) for \(caller.projectName) (see `tongs ls`). Ask the user with: tongs request \(k.name) --why \"...\"")
        }
        keys.append(r)
    }

    let book = grantBook()
    let unapproved = keys.filter { !book.covers(secret: $0.key, agent: caller.agent, project: caller.project) }
    if !unapproved.isEmpty {
        warn("waiting for Touch ID: \(caller.agent) in \(caller.projectName) wants \(unapproved.map(\.key).joined(separator: ", ")) for `\(shortCommand(argv))` (approval lasts 12h)")
        do {
            try UI.authenticate(approvalReason(unapproved, caller: caller))
        } catch {
            ActivityLog.record("denied", caller: caller, secrets: unapproved.map(\.key), command: argv)
            fail("\(error)")
        }
        let expires = Date().addingTimeInterval(grantTTL)
        for k in unapproved {
            do {
                try book.add(Grant(secret: k.key, agent: caller.agent, project: caller.project, expires: expires))
            } catch {
                warn("approved for this run only; could not save the approval (\(error.localizedDescription))")
                break
            }
        }
    }

    var env: [String: String] = [:]
    var secrets: [(name: String, value: String)] = []
    for k in keys {
        do {
            let v = String(decoding: try Store.get(k.key), as: UTF8.self)
            env[k.name] = v
            secrets.append((k.name, v))
        } catch {
            fail("\(error)")
        }
    }
    let code = Runner.run(argv, env: env, scrub: secrets)
    ActivityLog.record("run", caller: caller, secrets: keys.map(\.key), command: argv, exit: code)
    exit(code)
}

func cmdRemove(_ args: ArraySlice<String>) {
    guard args.count == 1, let arg = args.first else { fail("usage: tongs rm NAME") }
    let caller = Caller.current()
    guard let id = resolve(parseKey(arg), for: caller) else { fail("no secret \(arg) for \(caller.projectName)") }
    do {
        try UI.authenticate("删除密钥 \(id.key)")
        try Store.delete(id.key)
        _ = try? grantBook().revoke(secret: id.key, agent: nil)
    } catch {
        fail("\(error)")
    }
    ActivityLog.record("rm", caller: caller, secrets: [id.key])
    print("deleted \(id.key)")
}

func cmdGrants() {
    let grants = grantBook().load()
    if grants.isEmpty { print("(no active approvals)"); return }
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm"
    for g in grants.sorted(by: { $0.expires < $1.expires }) {
        print("\(g.secret)\t\(g.agent)\t\(g.project)\tuntil \(f.string(from: g.expires))")
    }
}

func cmdRevoke(_ args: ArraySlice<String>) {
    let (pos, opts) = parseOptions(args, flags: ["--agent"])
    guard pos.count <= 1 else { fail("usage: tongs revoke [NAME] [--agent AGENT]") }
    var secret = pos.first
    if let s = secret, let r = resolve(parseKey(s), for: .current()) { secret = r.key }
    do {
        let n = try grantBook().revoke(secret: secret, agent: opts["--agent"])
        print("revoked \(n) approval(s)")
    } catch {
        fail("\(error)")
    }
}

func cmdLog(_ args: ArraySlice<String>) {
    let (_, opts) = parseOptions(args, flags: ["-n"])
    let limit = Int(opts["-n"] ?? "20") ?? 20
    guard let text = try? String(contentsOf: Paths.log, encoding: .utf8) else { print("(no activity yet)"); return }
    let parse = ISO8601DateFormatter()
    let show = DateFormatter()
    show.dateFormat = "MM-dd HH:mm:ss"
    for line in text.split(separator: "\n").suffix(limit) {
        guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
        let time = parse.date(from: o["time"] as? String ?? "").map(show.string(from:)) ?? "?"
        let project = ((o["project"] as? String ?? "") as NSString).lastPathComponent
        let secrets = (o["secrets"] as? [String] ?? []).joined(separator: ",")
        var s = "\(time)  \(o["event"] ?? "")  \(o["agent"] ?? "")  \(project)  \(secrets)"
        if let cmd = o["command"] as? [String] { s += "  $ \(shortCommand(cmd))" }
        if let code = o["exit"] { s += "  → \(code)" }
        print(s)
    }
}

func cmdHook() {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    if let reason = Guard.check(hookInput: input) {
        FileHandle.standardError.write(Data((reason + "\n").utf8))
        exit(2)   // both Claude Code and Codex treat exit 2 as "block, and show stderr to the model"
    }
}

func cmdDoctor() {
    func row(_ ok: Bool, _ what: String, _ detail: String = "") {
        print("\(ok ? "✓" : "✗") \(what)\(detail.isEmpty ? "" : " — \(detail)")")
    }
    let caller = Caller.current()
    print("caller: \(caller.agent), project \(caller.project), scope \(caller.scope ?? "(none: global only)")")
    print("service: \(Store.service)")

    let probe = "__tongs_doctor__"
    do {
        try Store.set(probe, value: Data("probe".utf8), desc: nil)
        let back = try Store.get(probe)
        try Store.delete(probe)
        row(back == Data("probe".utf8), "Keychain read/write")
    } catch {
        row(false, "Keychain read/write", "\(error)")
    }

    let ctx = LAContextProbe.check()
    row(ctx.ok, "Touch ID / password approval available", ctx.detail)

    do {
        try FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
        let t = Paths.stateDir.appendingPathComponent(".doctor")
        try Data().write(to: t)
        try FileManager.default.removeItem(at: t)
        row(true, "state dir writable", Paths.stateDir.path)
    } catch {
        row(false, "state dir writable", "approvals can't be remembered and the log is lost here (\(error.localizedDescription))")
    }

    // Opening a window can abort the process when WindowServer is unreachable, so probe in a child.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    p.arguments = ["__gui-probe"]
    p.standardError = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    do {
        try p.run()
        p.waitUntilExit()
        row(p.terminationStatus == 0, "native dialog (tongs request) can be shown", p.terminationStatus == 0 ? "" : "exit \(p.terminationStatus)")
    } catch {
        row(false, "native dialog (tongs request) can be shown", error.localizedDescription)
    }
}

func guiProbe() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    exit(NSScreen.screens.isEmpty ? 3 : 0)
}

// MARK: dispatch

let args = CommandLine.arguments.dropFirst()
guard let command = args.first else {
    print(usage)
    exit(0)
}
let rest = args.dropFirst()
switch command {
case "ls", "list": cmdList(rest)
case "add": cmdAdd(rest)
case "request": cmdRequest(rest)
case "run": cmdRun(rest)
case "rm": cmdRemove(rest)
case "grants": cmdGrants()
case "revoke": cmdRevoke(rest)
case "log": cmdLog(rest)
case "hook": cmdHook()
case "doctor": cmdDoctor()
case "setup": Setup.main(rest)
case "__gui-probe": guiProbe()
case "help", "-h", "--help": print(usage)
default: fail("unknown command \(command)\n\n\(usage)")
}
