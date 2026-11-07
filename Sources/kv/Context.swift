import Darwin
import Foundation

/// Who is asking (best effort, display and grant scoping only) and for which project.
struct Caller {
    let agent: String
    let project: String

    var projectName: String { (project as NSString).lastPathComponent }

    static func current() -> Caller {
        Caller(agent: detectAgent(), project: projectRoot(FileManager.default.currentDirectoryPath))
    }

    static func detectAgent() -> String {
        var pid = getppid()
        for _ in 0..<32 where pid > 1 {
            if let path = processPath(pid)?.lowercased() {
                if path.contains("/claude.app/") || path.hasSuffix("/claude") { return "Claude Code" }
                if path.contains("codex") { return "Codex" }
                if path.contains("cursor") { return "Cursor" }
                if path.contains("gemini") { return "Gemini CLI" }
            }
            guard let parent = parentPID(pid) else { break }
            pid = parent
        }
        // Sandboxes can hide other processes; fall back to the env vars agents set.
        let env = ProcessInfo.processInfo.environment
        if env["CLAUDECODE"] == "1" { return "Claude Code" }
        if env["CODEX_SANDBOX"] != nil { return "Codex" }
        return "Terminal"
    }

    static func processPath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Nearest enclosing git work tree, else the directory itself.
    static func projectRoot(_ dir: String) -> String {
        var url = URL(fileURLWithPath: dir).standardizedFileURL
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            url.deleteLastPathComponent()
        }
        return dir
    }
}

enum Paths {
    static var stateDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kv", isDirectory: true)
    }
    static var grants: URL { stateDir.appendingPathComponent("grants.json") }
    static var log: URL { stateDir.appendingPathComponent("log.jsonl") }
}

/// Append-only activity log. Never contains values.
enum ActivityLog {
    static func record(_ event: String, caller: Caller, secrets: [String], command: [String]? = nil, exit: Int32? = nil) {
        var entry: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "event": event,
            "agent": caller.agent,
            "project": caller.project,
            "secrets": secrets,
        ]
        if let command { entry["command"] = command }
        if let exit { entry["exit"] = exit }
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        do {
            try FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: Paths.log.path) {
                FileManager.default.createFile(atPath: Paths.log.path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: Paths.log)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
        } catch {
            warn("could not write activity log (\(error.localizedDescription))")
        }
    }
}

func warn(_ s: String) {
    FileHandle.standardError.write(Data("kv: \(s)\n".utf8))
}
