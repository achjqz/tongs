import Foundation

/// Just enough of a POSIX shell lexer to find the commands a script would run, so the guard
/// judges what executes rather than every string that happens to mention a command.
///
/// It splits on operators and newlines, honours quotes and escapes, skips comments and
/// heredoc bodies, and hands back the scripts it finds inside `$(…)` and backticks (including
/// those in double quotes and unquoted heredocs, where the shell runs them too).
enum Shell {
    struct Parsed {
        var commands: [[String]] = []
        var nested: [String] = []
    }

    static func parse(_ script: String) -> Parsed {
        var out = Parsed()
        var words: [String] = []
        var word = ""
        var inWord = false
        var pendingHeredocs: [(delimiter: String, stripTabs: Bool, expands: Bool)] = []
        let chars = Array(script)
        var i = 0

        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endCommand() {
            endWord()
            if !words.isEmpty { out.commands.append(words) }
            words = []
        }
        /// Text of a balanced `$( … )` starting just after "$(", and the index after ")".
        func substitution(from start: Int) -> (String, Int) {
            var depth = 1
            var j = start
            var quote: Character?
            while j < chars.count {
                let c = chars[j]
                if let q = quote {
                    if c == "\\", q == "\"", j + 1 < chars.count { j += 2; continue }
                    if c == q { quote = nil }
                } else if c == "'" || c == "\"" {
                    quote = c
                } else if c == "\\", j + 1 < chars.count {
                    j += 2; continue
                } else if c == "(" {
                    depth += 1
                } else if c == ")" {
                    depth -= 1
                    if depth == 0 { return (String(chars[start..<j]), j + 1) }
                }
                j += 1
            }
            return (String(chars[start...].prefix(chars.count - start)), chars.count)
        }
        func backtick(from start: Int) -> (String, Int) {
            var j = start
            while j < chars.count, chars[j] != "`" {
                if chars[j] == "\\" { j += 1 }
                j += 1
            }
            return (String(chars[start..<min(j, chars.count)]), min(j + 1, chars.count))
        }
        /// Command substitutions inside text the shell expands (double quotes, unquoted heredocs).
        func expansions(in text: String) {
            // Quotes are literal text here (an apostrophe in prose must not open a string).
            let sub = Shell.parse(text.replacingOccurrences(of: "\"", with: " ").replacingOccurrences(of: "'", with: " "))
            out.nested += sub.nested
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case " ", "\t":
                endWord()
                i += 1
            case "\n":
                endCommand()
                i += 1
                // Heredoc bodies start on the line after their operator.
                for doc in pendingHeredocs {
                    var body = ""
                    while i < chars.count {
                        var j = i
                        while j < chars.count, chars[j] != "\n" { j += 1 }
                        var line = String(chars[i..<j])
                        i = min(j + 1, chars.count)
                        if doc.stripTabs { line = String(line.drop(while: { $0 == "\t" })) }
                        if line == doc.delimiter { break }
                        body += line + "\n"
                    }
                    if doc.expands { expansions(in: body) }
                }
                pendingHeredocs = []
            case ";", "|", "(", ")":
                endCommand()
                i += 1
            case "&":
                // `2>&1` and `&>file` are redirections, not command separators.
                if word.hasSuffix(">") || word.hasSuffix("<") || (i + 1 < chars.count && chars[i + 1] == ">") {
                    word.append(c); inWord = true
                } else {
                    endCommand()
                }
                i += 1
            case "#" where !inWord:
                while i < chars.count, chars[i] != "\n" { i += 1 }
            case "\\":
                if i + 1 < chars.count, chars[i + 1] != "\n" { word.append(chars[i + 1]); inWord = true }
                i += 2
            case "'":
                var j = i + 1
                while j < chars.count, chars[j] != "'" { j += 1 }
                word += String(chars[min(i + 1, chars.count)..<min(j, chars.count)])
                inWord = true
                i = j + 1
            case "\"":
                var j = i + 1
                var text = ""
                while j < chars.count, chars[j] != "\"" {
                    if chars[j] == "\\", j + 1 < chars.count { text.append(chars[j + 1]); j += 2; continue }
                    if chars[j] == "$", j + 1 < chars.count, chars[j + 1] == "(" {
                        let (inner, next) = substitution(from: j + 2)
                        out.nested.append(inner)
                        text += "$(" + inner + ")"
                        j = next
                        continue
                    }
                    if chars[j] == "`" {
                        let (inner, next) = backtick(from: j + 1)
                        out.nested.append(inner)
                        j = next
                        continue
                    }
                    text.append(chars[j])
                    j += 1
                }
                word += text
                inWord = true
                i = j + 1
            case "$" where i + 1 < chars.count && chars[i + 1] == "(":
                let (inner, next) = substitution(from: i + 2)
                out.nested.append(inner)
                word += "$(…)"
                inWord = true
                i = next
            case "`":
                let (inner, next) = backtick(from: i + 1)
                out.nested.append(inner)
                inWord = true
                i = next
            case "<" where i + 1 < chars.count && chars[i + 1] == "<" && !(i + 2 < chars.count && chars[i + 2] == "<"):
                endWord()
                var j = i + 2
                let stripTabs = j < chars.count && chars[j] == "-"
                if stripTabs { j += 1 }
                while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                var delimiter = ""
                var quoted = false
                while j < chars.count, !" \t\n;|&<>()".contains(chars[j]) {
                    if chars[j] == "'" || chars[j] == "\"" || chars[j] == "\\" { quoted = true } else { delimiter.append(chars[j]) }
                    j += 1
                }
                if !delimiter.isEmpty { pendingHeredocs.append((delimiter, stripTabs, !quoted)) }
                i = j
            default:
                word.append(c)
                inWord = true
                i += 1
            }
        }
        endCommand()
        return out
    }
}
