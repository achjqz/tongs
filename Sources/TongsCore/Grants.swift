import CryptoKit
import Foundation

/// A time-limited approval for one agent to use one secret inside one project.
public struct Grant: Codable, Equatable {
    public var secret: String
    public var agent: String
    public var project: String
    public var expires: Date
    public var mac: String = ""

    public init(secret: String, agent: String, project: String, expires: Date) {
        self.secret = secret
        self.agent = agent
        self.project = project
        self.expires = expires
    }

    func message() -> Data {
        Data("\(secret)\u{0}\(agent)\u{0}\(project)\u{0}\(Int(expires.timeIntervalSince1970))".utf8)
    }
}

/// Grants live in a plain JSON file an agent can write to, so each entry is signed with a key
/// kept in the Keychain. An agent can delete grants (harmless) but cannot forge one.
public struct GrantBook {
    public let url: URL
    let key: SymmetricKey

    public init(url: URL, key: SymmetricKey) {
        self.url = url
        self.key = key
    }

    func sign(_ g: Grant) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: g.message(), using: key)).base64EncodedString()
    }

    func isValid(_ g: Grant, now: Date) -> Bool {
        guard g.expires > now, let mac = Data(base64Encoded: g.mac) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: g.message(), using: key)
    }

    public func load(now: Date = Date()) -> [Grant] {
        guard let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder.tongs.decode([Grant].self, from: data) else { return [] }
        return all.filter { isValid($0, now: now) }
    }

    public func covers(secret: String, agent: String, project: String, now: Date = Date()) -> Bool {
        load(now: now).contains { $0.secret == secret && $0.agent == agent && $0.project == project }
    }

    public func add(_ grant: Grant, now: Date = Date()) throws {
        var g = grant
        g.mac = sign(g)
        var all = load(now: now).filter {
            !($0.secret == g.secret && $0.agent == g.agent && $0.project == g.project)
        }
        all.append(g)
        try save(all)
    }

    /// Removes grants matching every non-nil filter; returns how many were removed.
    @discardableResult
    public func revoke(secret: String?, agent: String?, now: Date = Date()) throws -> Int {
        let all = load(now: now)
        let kept = all.filter { g in
            !((secret == nil || g.secret == secret) && (agent == nil || g.agent == agent))
        }
        try save(kept)
        return all.count - kept.count
    }

    func save(_ grants: [Grant]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.tongs.encode(grants).write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    public static var tongs: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    public static var tongs: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
