import AppKit
import Foundation
import LocalAuthentication

/// Human-facing prompts. Everything here runs in-process and exits with the command:
/// there is no resident app.
enum UI {
    /// Touch ID (or login password) with a reason line. macOS renders it as "“kv” is trying to <reason>".
    static func authenticate(_ reason: String) throws {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            throw KVError("cannot ask for approval here: \(err?.localizedDescription ?? "unknown error")")
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
        guard ok else { throw KVError("not approved: \(failure?.localizedDescription ?? "cancelled")") }
    }

    struct Entry {
        let value: String
        let global: Bool
    }

    /// Native dialog for pasting a secret. `project` adds a scope picker (this project vs all
    /// projects); without it the secret is global. Returns nil if the user cancels.
    static func askSecret(title: String, info: String, url: URL?, project: String?, defaultGlobal: Bool) -> Entry? {
        // AppKit logs input-method chatter (TSM …) to stderr, which would land in the agent's output.
        let savedStderr = dup(2)
        let devNull = open("/dev/null", O_WRONLY)
        dup2(devNull, 2)
        close(devNull)
        defer {
            dup2(savedStderr, 2)
            close(savedStderr)
        }

        let app = NSApplication.shared
        // A regular app (Dock icon, ⌘-Tab, Edit menu) so the dialog can be left and come back to,
        // and so clipboard tools that synthesize ⌘V reach it.
        app.setActivationPolicy(.regular)
        app.mainMenu = makeMenu()

        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = info
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "取消")
            if url != nil { alert.addButton(withTitle: "打开获取页面") }

            let field = SecretCaptureField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
            var popup: NSPopUpButton?
            if let project {
                let p = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 26), pullsDown: false)
                p.addItems(withTitles: ["仅项目 \(project) 可用", "所有项目可用（全局）"])
                p.selectItem(at: defaultGlobal ? 1 : 0)
                popup = p
                let stack = NSStackView(views: [field, p])
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 8
                stack.frame = NSRect(x: 0, y: 0, width: 380, height: 58)
                alert.accessoryView = stack
            } else {
                alert.accessoryView = field
            }
            alert.window.initialFirstResponder = field

            // Cooperative activation: comes forward unless the user is busy in another app,
            // in which case the Dock icon bounces until they switch over.
            app.activate()
            let nudge = Timer(timeInterval: 0.5, repeats: false) { _ in
                if !app.isActive { app.requestUserAttention(.criticalRequest) }
            }
            RunLoop.main.add(nudge, forMode: .modalPanel)

            let response = alert.runModal()
            nudge.invalidate()
            switch response {
            case .alertFirstButtonReturn:
                let value = field.secret.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty { continue }
                // Don't leave the secret sitting on the clipboard.
                let pb = NSPasteboard.general
                if pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) == value {
                    pb.clearContents()
                }
                return Entry(value: value, global: project == nil || popup?.indexOfSelectedItem == 1)
            case .alertThirdButtonReturn:
                if let url { NSWorkspace.shared.open(url) }
            default:
                return nil
            }
        }
    }

    static func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 kv", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}

/// Plain text field that swaps whatever is pasted or typed for a masked summary.
/// Not an NSSecureTextField on purpose: that turns on Secure Event Input, which blocks global
/// hotkeys such as a clipboard manager's ⌥V. The value arrives via the clipboard anyway.
final class SecretCaptureField: NSTextField, NSTextFieldDelegate {
    private(set) var secret = ""
    private var shown = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
        placeholderString = "粘贴密钥（⌘V，或用剪贴板历史 ⌥V）"
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func controlTextDidChange(_ notification: Notification) {
        let text = stringValue
        if text.isEmpty {
            secret = ""
        } else if !shown.isEmpty, text.hasPrefix(shown) {
            secret += text.dropFirst(shown.count)          // typed or pasted after the summary
        } else if !shown.isEmpty, shown.hasPrefix(text) {
            secret = ""                                     // backspace clears the whole value
        } else {
            secret = text                                   // fresh paste, or replaced a selection
        }
        shown = secret.isEmpty ? "" : mask(secret)
        stringValue = shown
    }

    func mask(_ v: String) -> String {
        let kind = describeShape(v).map { " · \($0)" } ?? ""
        return String(repeating: "•", count: min(v.count, 16)) + "  \(v.count) 个字符\(kind)"
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
        ("sk-ant-", "Anthropic key"), ("sk-proj-", "OpenAI project key"), ("sk-", "OpenAI-style key"),
        ("AKIA", "AWS access key id"), ("xox", "Slack token"), ("glpat-", "GitLab token"), ("eyJ", "JWT"),
    ]
    return shapes.first { v.hasPrefix($0.0) }?.1
}
