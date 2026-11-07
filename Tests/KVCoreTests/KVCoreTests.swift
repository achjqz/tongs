import CryptoKit
import Foundation
import Testing
@testable import KVCore

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
    let all = try JSONDecoder.kv.decode([Grant].self, from: Data(contentsOf: book.url)) + [forged]
    try JSONEncoder.kv.encode(all).write(to: book.url)
    #expect(!book.covers(secret: "OTHER", agent: "Codex", project: "/p", now: now))
    #expect(book.covers(secret: "GH", agent: "Codex", project: "/p", now: now))
}

@Test func guardBlocksKeychainReads() {
    func check(_ input: [String: Any]) -> String? {
        Guard.check(hookInput: try! JSONSerialization.data(withJSONObject: input))
    }
    #expect(check(["tool_name": "Bash", "tool_input": ["command": "security find-generic-password -s dev.kv.secrets -a GH -w"]]) != nil)
    #expect(check(["tool_name": "Bash", "tool_input": ["command": "security dump-keychain -d"]]) != nil)
    #expect(check(["tool_name": "Read", "tool_input": ["file_path": "/Users/x/Library/Keychains/login.keychain-db"]]) != nil)
    #expect(check(["tool_name": "exec_command", "tool_input": ["cmd": ["bash", "-lc", "security find-internet-password -g"]]]) != nil)
    #expect(check(["tool_name": "Bash", "tool_input": ["command": "kv run GH -- gh pr list"]]) == nil)
    #expect(check(["tool_name": "Bash", "tool_input": ["command": "git log --grep security"]]) == nil)
}
