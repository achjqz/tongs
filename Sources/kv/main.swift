import AppKit
import Foundation
import KVCore

let usage = """
kv — secrets your AI agents can use without seeing

  kv ls [--json]                         list secret names (never values)
  kv run NAME... -- CMD...               run CMD with each NAME in its environment; output is scrubbed
  kv request NAME [--why T] [--url U]    ask the human for a secret in a native dialog
  kv add NAME [--desc T]                 store a secret yourself (hidden prompt, or stdin)
  kv rm NAME                             delete a secret (asks for Touch ID)
  kv grants                              show active approvals
  kv revoke [NAME] [--agent A]           drop approvals
  kv log [-n N]                          recent activity
  kv doctor                              check Keychain / Touch ID / dialog access from here
  kv setup claude|codex [--apply]        install the guard hook and agent instructions
  kv hook                                PreToolUse guard (reads hook JSON on stdin)
"""

let grantTTL: TimeInterval = 12 * 3600

func fail(_ message: String, code: Int32 = 1) -> Never {
    warn(message)
    exit(code)
}

func checkName(_ name: String) {
    guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
          name != Store.grantKeyAccount else {
        fail("invalid name \(name): use an environment-variable style name like GITHUB_TOKEN")
    }
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
    let s = argv.joined(separator: " ")
    return s.count > 60 ? String(s.prefix(57)) + "…" : s
}

// MARK: commands

func cmdList(_ args: ArraySlice<String>) {
    let (_, opts) = parseOptions(args, flags: [], switches: ["--json"])
    let items: [SecretInfo]
    do { items = try Store.list() } catch { fail("\(error)") }
    if opts["--json"] != nil {
        let arr = items.map { ["name": $0.name, "description": $0.desc] }
        let data = try! JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        return
    }
    if items.isEmpty {
        print("(no secrets yet — `kv request NAME --why ...` or `kv add NAME`)")
        return
    }
    let width = max(items.map(\.name.count).max() ?? 0, 4)
    for i in items {
        print(i.name.padding(toLength: width + 2, withPad: " ", startingAt: 0) + i.desc)
    }
}

func cmdAdd(_ args: ArraySlice<String>) {
    let (pos, opts) = parseOptions(args, flags: ["--desc"])
    guard pos.count == 1 else { fail("usage: kv add NAME [--desc TEXT]") }
    let name = pos[0]
    checkName(name)
    var value: String
    if isatty(0) != 0 {
        var buf = [CChar](repeating: 0, count: 8192)
        guard let p = readpassphrase("\(name) (hidden): ", &buf, buf.count, RPP_ECHO_OFF) else { fail("no input") }
        value = String(cString: p)
    } else {
        value = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }
    value = value.trimmingCharacters(in: .newlines)
    guard !value.isEmpty else { fail("empty value, nothing stored") }
    do { try Store.set(name, value: Data(value.utf8), desc: opts["--desc"]) } catch { fail("\(error)") }
    ActivityLog.record("add", caller: .current(), secrets: [name])
    print("stored \(name)")
}

func cmdRequest(_ args: ArraySlice<String>) {
    let (pos, opts) = parseOptions(args, flags: ["--why", "--url", "--desc"])
    guard pos.count == 1 else { fail("usage: kv request NAME [--why TEXT] [--url URL] [--desc TEXT]") }
    let name = pos[0]
    checkName(name)
    let caller = Caller.current()
    let why = opts["--why"]
    var url: URL?
    if let u = opts["--url"] {
        guard let parsed = URL(string: u), parsed.scheme == "https" else { fail("--url must be an https URL") }
        url = parsed
    }
    var info = "项目：\(caller.projectName)\n"
    if let why { info += "用途：\(why)\n" }
    if Store.exists(name) { info += "⚠️ 已存在同名密钥，保存将替换它。\n" }
    info += "\n值只存入本机钥匙串，不会返回给 \(caller.agent)。"

    guard let value = UI.askSecret(title: "\(caller.agent) 请求密钥 \(name)", info: info, url: url) else {
        ActivityLog.record("request-declined", caller: caller, secrets: [name])
        fail("the user declined to provide \(name)")
    }
    do { try Store.set(name, value: Data(value.utf8), desc: opts["--desc"] ?? why) } catch { fail("\(error)") }
    ActivityLog.record("request", caller: caller, secrets: [name])
    let shape = describeShape(value).map { ", looks like a \($0)" } ?? ""
    print("stored \(name) (\(value.count) chars\(shape)). Use it with: kv run \(name) -- <command>")
}

func cmdRun(_ args: ArraySlice<String>) {
    guard let sep = args.firstIndex(of: "--") else { fail("usage: kv run NAME... -- CMD...") }
    let names = Array(args[args.startIndex..<sep])
    let argv = Array(args[(sep + 1)...])
    guard !names.isEmpty, !argv.isEmpty else { fail("usage: kv run NAME... -- CMD...") }
    names.forEach(checkName)
    let missing = names.filter { !Store.exists($0) }
    guard missing.isEmpty else {
        fail("no secret named \(missing.joined(separator: ", ")). Ask the user with: kv request \(missing[0]) --why \"...\"")
    }

    let caller = Caller.current()
    let book = grantBook()
    let unapproved = names.filter { !book.covers(secret: $0, agent: caller.agent, project: caller.project) }
    if !unapproved.isEmpty {
        let reason = "允许 \(caller.agent) 在 \(caller.projectName) 中使用 \(unapproved.joined(separator: "、")) 运行「\(shortCommand(argv))」（12 小时内不再询问）"
        do {
            try UI.authenticate(reason)
        } catch {
            ActivityLog.record("denied", caller: caller, secrets: unapproved, command: argv)
            fail("\(error)")
        }
        let expires = Date().addingTimeInterval(grantTTL)
        for n in unapproved {
            do {
                try book.add(Grant(secret: n, agent: caller.agent, project: caller.project, expires: expires))
            } catch {
                warn("approved for this run only; could not save the approval (\(error.localizedDescription))")
                break
            }
        }
    }

    var env: [String: String] = [:]
    var secrets: [(name: String, value: String)] = []
    for n in names {
        do {
            let v = String(decoding: try Store.get(n), as: UTF8.self)
            env[n] = v
            secrets.append((n, v))
        } catch {
            fail("\(error)")
        }
    }
    let code = Runner.run(argv, env: env, scrub: secrets)
    ActivityLog.record("run", caller: caller, secrets: names, command: argv, exit: code)
    exit(code)
}

func cmdRemove(_ args: ArraySlice<String>) {
    guard args.count == 1, let name = args.first else { fail("usage: kv rm NAME") }
    checkName(name)
    guard Store.exists(name) else { fail("no secret named \(name)") }
    let caller = Caller.current()
    do {
        try UI.authenticate("删除密钥 \(name)（由 \(caller.agent) 发起）")
        try Store.delete(name)
        _ = try? grantBook().revoke(secret: name, agent: nil)
    } catch {
        fail("\(error)")
    }
    ActivityLog.record("rm", caller: caller, secrets: [name])
    print("deleted \(name)")
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
    guard pos.count <= 1 else { fail("usage: kv revoke [NAME] [--agent AGENT]") }
    do {
        let n = try grantBook().revoke(secret: pos.first, agent: opts["--agent"])
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
    print("caller: \(caller.agent), project \(caller.project)")
    print("service: \(Store.service)")

    let probe = "__kv_doctor__"
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
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    if !FileManager.default.isExecutableFile(atPath: p.executableURL!.path) {
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
    }
    p.arguments = ["__gui-probe"]
    p.standardError = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    do {
        try p.run()
        p.waitUntilExit()
        row(p.terminationStatus == 0, "native dialog (kv request) can be shown", p.terminationStatus == 0 ? "" : "exit \(p.terminationStatus)")
    } catch {
        row(false, "native dialog (kv request) can be shown", error.localizedDescription)
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
