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

    /// Native dialog with a secure field. Returns nil if the user cancels.
    static func askSecret(title: String, info: String, url: URL?) -> String? {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = info
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "取消")
            if url != nil { alert.addButton(withTitle: "打开获取页面") }
            let field = PasteableSecureField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
            field.placeholderString = "粘贴密钥"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.window.level = .floating
            app.activate(ignoringOtherApps: true)

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty { continue }
                // Don't leave the secret sitting on the clipboard.
                let pb = NSPasteboard.general
                if pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) == value {
                    pb.clearContents()
                }
                return value
            case .alertThirdButtonReturn:
                if let url { NSWorkspace.shared.open(url) }
            default:
                return nil
            }
        }
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

/// An accessory app has no Edit menu, so ⌘V/⌘A would do nothing without this.
final class PasteableSecureField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case "z": return NSApp.sendAction(Selector(("undo:")), to: nil, from: self)
        default: return super.performKeyEquivalent(with: event)
        }
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
