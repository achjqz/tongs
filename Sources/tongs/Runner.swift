import Darwin
import Foundation
import TongsCore

/// Spawns the command with secrets in its environment and pipes its stdout/stderr
/// through a Scrubber. Returns the child's exit code (128+signal if it was killed).
enum Runner {
    static func run(_ argv: [String], env extra: [String: String], scrub secrets: [(name: String, value: String)]) -> Int32 {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extra { env[k] = v }

        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            warn("pipe: \(String(cString: strerror(errno)))")
            return 127
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        for fd in outPipe + errPipe { posix_spawn_file_actions_addclose(&actions, fd) }

        // tongs ignores ^C so it can keep draining output while the child decides how to exit;
        // the child gets default dispositions back.
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for s in [SIGINT, SIGQUIT, SIGPIPE, SIGTERM, SIGHUP] { sigaddset(&defaults, s) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        signal(SIGINT, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)

        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawnp(&pid, argv[0], &actions, &attr, cArgs, cEnv)
        close(outPipe[1])
        close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            warn("cannot run \(argv[0]): \(String(cString: strerror(rc)))")
            return 127
        }

        var forwarders: [DispatchSourceSignal] = []
        for s in [SIGTERM, SIGHUP] {
            signal(s, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: s, queue: .global())
            src.setEventHandler { kill(pid, s) }
            src.resume()
            forwarders.append(src)
        }

        let group = DispatchGroup()
        for (from, to) in [(outPipe[0], Int32(1)), (errPipe[0], Int32(2))] {
            group.enter()
            let scrubber = Scrubber(secrets: secrets)
            Thread {
                pump(from, to: to, scrubber)
                group.leave()
            }.start()
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        group.wait()
        forwarders.forEach { $0.cancel() }

        let sig = status & 0x7f
        return sig == 0 ? (status >> 8) & 0xff : 128 + sig
    }

    static func pump(_ fd: Int32, to out: Int32, _ scrubber: Scrubber) {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                writeAll(out, scrubber.feed(Array(buf[0..<n])))
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        writeAll(out, scrubber.finish())
        close(fd)
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var off = 0
        while off < bytes.count {
            let w = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if w > 0 {
                off += w
            } else if w < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}
