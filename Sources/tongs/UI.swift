import AppKit
import Foundation
import LocalAuthentication

/// Human-facing prompts. Everything here runs in-process and exits with the command:
/// there is no resident app.
enum UI {
    /// Touch ID (or login password) with a reason line. macOS renders it as "“tongs” is trying to <reason>".
    static func authenticate(_ reason: String) throws {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            throw TongsError("cannot ask for approval here: \(err?.localizedDescription ?? "unknown error")")
        }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        var failure: Error?
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            ok = success
            failure = error
            sem.signal()
        }
        sem.wait()
        guard ok else { throw TongsError("not approved: \(failure?.localizedDescription ?? "cancelled")") }
    }

    struct Entry {
        let value: String
        let global: Bool
    }

    /// Native panel for pasting a secret. Returns nil if the user cancels.
    static func askSecret(_ info: RequestInfo) -> Entry? {
        // AppKit logs input-method chatter (TSM …) to stderr, which would land in the agent's output.
        let savedStderr = dup(2)
        let devNull = open("/dev/null", O_WRONLY)
        dup2(devNull, 2)
        close(devNull)
        defer {
            dup2(savedStderr, 2)
            close(savedStderr)
        }

        guard let entry = RequestWindow.run(info) else { return nil }
        // Don't leave the secret sitting on the clipboard.
        let pb = NSPasteboard.general
        if pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) == entry.value {
            pb.clearContents()
        }
        return entry
    }

    static func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("退出 tongs", "Quit tongs"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: tr("编辑", "Edit"))
        edit.addItem(withTitle: tr("撤销", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("剪切", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("粘贴", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("全选", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}

enum LAContextProbe {
    static func check() -> (ok: Bool, detail: String) {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            return (false, err?.localizedDescription ?? "unavailable")
        }
        let bio = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return (true, bio ? "Touch ID" : "password only")
    }
}

/// Recognizes a few common token shapes so the agent gets useful feedback without the value.
func describeShape(_ v: String) -> String? {
    let shapes: [(String, String)] = [
        ("github_pat_", "GitHub fine-grained token"), ("ghp_", "GitHub token"), ("gho_", "GitHub OAuth token"),
        ("sk_live_", "Stripe live secret key"), ("sk_test_", "Stripe test secret key"), ("rk_live_", "Stripe restricted key"),
        ("sk-ant-", "Anthropic key"), ("sk-proj-", "OpenAI project key"), ("sk-", "OpenAI-style key"),
        ("AKIA", "AWS access key id"), ("xox", "Slack token"), ("glpat-", "GitLab token"), ("eyJ", "JWT"),
    ]
    return shapes.first { v.hasPrefix($0.0) }?.1
}
