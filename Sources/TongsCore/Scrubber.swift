import Foundation

/// Streaming redactor: replaces every known form of a secret in a byte stream with
/// `‹redacted:NAME›`. Bytes that might be the start of a secret split across reads are
/// held back until the next chunk (or end of stream) decides them, so output stays live
/// except right where a partial match is pending.
public final class Scrubber {
    struct Pattern {
        let bytes: [UInt8]
        let marker: [UInt8]
    }

    private let patterns: [Pattern]
    private let byFirstByte: [UInt8: [Int]]
    private var pending: [UInt8] = []

    public init(secrets: [(name: String, value: String)]) {
        var list: [Pattern] = []
        for (name, value) in secrets {
            let marker = Array("‹redacted:\(name)›".utf8)
            for v in Scrubber.variants(of: value) {
                list.append(Pattern(bytes: Array(v.utf8), marker: marker))
            }
        }
        // Longest first so a raw value wins over one of its own substrings.
        list.sort { $0.bytes.count > $1.bytes.count }
        var index: [UInt8: [Int]] = [:]
        for (i, p) in list.enumerated() { index[p.bytes[0], default: []].append(i) }
        patterns = list
        byFirstByte = index
    }

    /// Raw value plus the encodings a command is likely to echo it in.
    /// Derived forms are only used for values long enough that a false hit is implausible.
    public static func variants(of value: String) -> [String] {
        var out: Set<String> = []
        let bytes = Array(value.utf8)
        if bytes.count >= 4 { out.insert(value) }
        guard bytes.count >= 8 else { return Array(out) }

        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        if let pe = value.addingPercentEncoding(withAllowedCharacters: unreserved), pe != value {
            out.insert(pe)
        }

        // Base64 of the value embedded at any offset (e.g. inside "user:token" for Basic auth):
        // for each of the 3 byte alignments keep only the characters fully determined by the value.
        for k in 0..<3 {
            let data = Data(repeating: 0, count: k) + Data(bytes)
            let enc = Array(data.base64EncodedString().utf8)
            let start = (4 * k + 2) / 3              // ceil(4k/3)
            let end = (8 * data.count - 6) / 6      // last char whose 6 bits lie inside the data
            guard end - start + 1 >= 8 else { continue }
            let core = String(decoding: enc[start...end], as: UTF8.self)
            out.insert(core)
            out.insert(core.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_"))
        }
        return Array(out)
    }

    public func feed(_ chunk: [UInt8]) -> [UInt8] {
        pending += chunk
        return drain(final: false)
    }

    public func finish() -> [UInt8] {
        drain(final: true)
    }

    private func drain(final: Bool) -> [UInt8] {
        let buf = pending
        let n = buf.count
        var out: [UInt8] = []
        out.reserveCapacity(n)
        var i = 0
        scan: while i < n {
            if let candidates = byFirstByte[buf[i]] {
                var partial = false
                for c in candidates {
                    let pat = patterns[c].bytes
                    let avail = n - i
                    if avail >= pat.count {
                        if buf[i..<(i + pat.count)].elementsEqual(pat) {
                            out += patterns[c].marker
                            i += pat.count
                            continue scan
                        }
                    } else if !final, buf[i..<n].elementsEqual(pat[0..<avail]) {
                        partial = true
                    }
                }
                if partial {
                    pending = Array(buf[i...])
                    return out
                }
            }
            out.append(buf[i])
            i += 1
        }
        pending = []
        return out
    }
}
