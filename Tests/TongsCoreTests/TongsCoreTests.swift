import CryptoKit
import Foundation
import Testing
@testable import TongsCore

func scrub(_ chunks: [String], secrets: [(name: String, value: String)]) -> String {
    let s = Scrubber(secrets: secrets)
    var out: [UInt8] = []
    for c in chunks { out += s.feed(Array(c.utf8)) }
    out += s.finish()
    return String(decoding: out, as: UTF8.self)
}

let token = "ghp_abcDEF1234567890xyz"

@Test func rawValue() {
    #expect(scrub(["token is \(token)!"], secrets: [("GH", token)]) == "token is ‹redacted:GH›!")
}

@Test func splitAcrossChunks() {
    let line = "Authorization: Bearer \(token)\n"
    for cut in 1..<line.count {
        let i = line.index(line.startIndex, offsetBy: cut)
        let out = scrub([String(line[..<i]), String(line[i...])], secrets: [("GH", token)])
        #expect(out == "Authorization: Bearer ‹redacted:GH›\n", "cut at \(cut)")
    }
}

@Test func byteAtATime() {
    let text = "a\(token)b\(token)c"
    #expect(scrub(text.map(String.init), secrets: [("GH", token)]) == "a‹redacted:GH›b‹redacted:GH›c")
}

@Test func partialPrefixIsReleasedAtEnd() {
    #expect(scrub(["prompt> ghp_ab"], secrets: [("GH", token)]) == "prompt> ghp_ab")
}

@Test func basicAuthHeaderIsCaught() {
    // curl -v prints "Authorization: Basic base64(user:token)"
    for user in ["x", "ab", "bot-user"] {
        let header = Data("\(user):\(token)".utf8).base64EncodedString()
        let out = scrub(["Authorization: Basic \(header)"], secrets: [("GH", token)])
        #expect(out.contains("‹redacted:GH›"), "user \(user): \(out)")
        let leftover = out.replacingOccurrences(of: "Authorization: Basic ", with: "")
            .components(separatedBy: "‹redacted:GH›").joined()
        // What survives is the encoded "user:" prefix plus at most a couple of boundary
        // characters on each side of the redaction, never a run of the token itself.
        let prefixChars = (4 * (user.count + 1)) / 3
        #expect(leftover.count <= prefixChars + 4, "user \(user) leaves \(leftover)")
    }
}

@Test func percentEncoded() {
    let pw = "p@ss/word+with=chars"
    let enc = pw.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    #expect(scrub(["postgres://u:\(enc)@db"], secrets: [("PW", pw)]).contains("‹redacted:PW›"))
}

@Test func shortValuesOnlyRaw() {
    #expect(Scrubber.variants(of: "abcd") == ["abcd"])
    #expect(Scrubber.variants(of: "abc").isEmpty)
}

@Test func grantsAreSignedAndExpire() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let book = GrantBook(url: dir.appendingPathComponent("grants.json"), key: SymmetricKey(size: .bits256))
    let now = Date()
    try book.add(Grant(secret: "GH", agent: "Codex", project: "/p", expires: now.addingTimeInterval(60)), now: now)
    #expect(book.covers(secret: "GH", agent: "Codex", project: "/p", now: now))
    #expect(!book.covers(secret: "GH", agent: "Claude Code", project: "/p", now: now))
    #expect(!book.covers(secret: "GH", agent: "Codex", project: "/p", now: now.addingTimeInterval(120)))

    // A grant written by someone without the key is ignored.
    var forged = Grant(secret: "OTHER", agent: "Codex", project: "/p", expires: now.addingTimeInterval(60))
    forged.mac = Data(repeating: 1, count: 32).base64EncodedString()
    let all = try JSONDecoder.tongs.decode([Grant].self, from: Data(contentsOf: book.url)) + [forged]
    try JSONEncoder.tongs.encode(all).write(to: book.url)
    #expect(!book.covers(secret: "OTHER", agent: "Codex", project: "/p", now: now))
    #expect(book.covers(secret: "GH", agent: "Codex", project: "/p", now: now))
}

@Test func keyNames() {
    #expect(KeyName("GH_TOKEN") == KeyName(scope: nil, name: "GH_TOKEN"))
    #expect(KeyName("shop/STRIPE_KEY") == KeyName(scope: "shop", name: "STRIPE_KEY"))
    #expect(KeyName("shop/STRIPE_KEY")?.key == "shop/STRIPE_KEY")
    #expect(KeyName("my.app-2/X") != nil)
    for bad in ["1ABC", "a/b/C", "/X", "shop/", "sh op/X", "X-Y", ""] {
        #expect(KeyName(bad) == nil, "\(bad)")
    }
}

@Test func projectRootFollowsWorktrees() throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    let main = tmp.appendingPathComponent("shop")
    let sub = main.appendingPathComponent("src/app")
    try fm.createDirectory(at: main.appendingPathComponent(".git/worktrees/feat"), withIntermediateDirectories: true)
    try fm.createDirectory(at: sub, withIntermediateDirectories: true)
    let wt = tmp.appendingPathComponent("agents/worktrees/feat-x")
    try fm.createDirectory(at: wt.appendingPathComponent("lib"), withIntermediateDirectories: true)
    try "gitdir: \(main.path)/.git/worktrees/feat\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    let lone = tmp.appendingPathComponent("not-a-repo")
    try fm.createDirectory(at: lone, withIntermediateDirectories: true)

    #expect(Project.root(containing: sub.path) == main.path)
    #expect(Project.root(containing: wt.appendingPathComponent("lib").path) == main.path)
    #expect(Project.root(containing: lone.path) == nil)
    #expect(Project.scope(forRoot: main.path) == "shop")
    #expect(Project.scope(forRoot: "/x/My Project") == "My-Project")
    #expect(Project.scope(forRoot: "/x/.dotfiles") == "p.dotfiles")
}

func bash(_ command: String) -> [Guard.Finding] {
    Guard.findings(toolName: "Bash", input: ["command": command])
}

@Test(arguments: [
    ("security find-generic-password -s dev.tongs.secrets -a GH -w", Guard.Finding.read),
    ("security dump-keychain -d", .read),
    ("/usr/bin/security -q find-internet-password -g", .read),
    ("FOO=1 sudo -u me security find-generic-password -w", .read),
    ("cd /tmp && security find-generic-password -w | pbcopy", .read),
    ("echo $(security find-generic-password -w)", .read),
    ("echo \"token: $(security find-generic-password -w)\"", .read),
    ("x=`security find-generic-password -w`", .read),
    ("bash -lc 'security find-generic-password -w'", .read),
    ("eval \"security find-generic-password -w\"", .read),
    ("tongs run GH -- security find-generic-password -s x -w", .read),
    ("cat <<EOF\nvalue: $(security find-generic-password -w)\nEOF", .read),
    ("python3 -c \"import os; os.system('security find-generic-password -w')\"", .read),
    ("osascript -e 'do shell script \"security dump-keychain\"'", .read),
    ("security delete-generic-password -s dev.tongs.secrets -a GH", .modify),
    ("security add-generic-password -U -s dev.tongs.secrets -a GH -w evil", .modify),
    ("security set-generic-password-partition-list -S apple-tool: -s dev.tongs.secrets", .modify),
    ("while security delete-generic-password -s dev.tongs.secrets; do :; done", .modify),
    ("cp ~/Library/Keychains/login.keychain-db /tmp/k", .keychainFiles),
])
func guardBlocks(command: String, expected: Guard.Finding) {
    #expect(bash(command).contains(expected), "\(command)")
}

@Test(arguments: [
    "tongs run GH -- gh pr list",
    "git log --grep security",
    "grep -rn 'find-generic-password' Sources",
    "echo \"security find-generic-password is blocked\"",
    "printf '%s\\n' ~/Library/Keychains",
    "git commit -m 'block security delete-generic-password'",
    "cat > notes.md <<'EOF'\nUse security find-generic-password -w? No.\nKeychain files live in ~/Library/Keychains.\nEOF",
    "cat > notes.md <<EOF\nIt's fine to mention security dump-keychain in prose.\nEOF",
    "security find-certificate -c 'Apple Development'",
    "security list-keychains",
    "ls -la # security dump-keychain",
    "make test 2>&1 | tail",
])
func guardAllows(command: String) {
    #expect(bash(command).isEmpty, "\(command)")
}

@Test func guardToolShapes() {
    func check(_ input: [String: Any]) -> String? {
        Guard.check(hookInput: try! JSONSerialization.data(withJSONObject: input))
    }
    #expect(check(["tool_name": "Read", "tool_input": ["file_path": "/Users/x/Library/Keychains/login.keychain-db"]]) != nil)
    #expect(check(["tool_name": "Glob", "tool_input": ["pattern": "~/Library/Keychains/**"]]) != nil)
    #expect(check(["tool_name": "Grep", "tool_input": ["pattern": "Library/Keychains", "path": "."]]) == nil)
    #expect(check(["tool_name": "exec_command", "tool_input": ["cmd": ["bash", "-lc", "security delete-internet-password -s x"]]]) != nil)
    #expect(check(["tool_name": "exec_command", "tool_input": ["cmd": ["security", "find-generic-password", "-w"]]]) != nil)
    #expect(check(["tool_name": "Write", "tool_input": ["file_path": "notes.md", "content": "security dump-keychain"]]) == nil)
}
