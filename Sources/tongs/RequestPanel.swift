import AppKit
import ScreenCaptureKit
import SwiftUI

/// What the panel shows. Built by `tongs request`; never contains a value.
struct RequestInfo {
    var agent: String
    var name: String
    var project: String
    var why: String?
    var url: URL?
    /// Scope picker: the project a secret can be limited to, or nil for global-only.
    var scopeProject: String?
    var defaultGlobal: Bool
    var replaces: [String]
}

/// Holds the pasted value and what the field displays instead of it.
final class SecretInput: ObservableObject {
    @Published private(set) var shown = ""
    @Published var global: Bool
    private(set) var secret = ""

    init(global: Bool) { self.global = global }

    /// The text field reports its new text here. Whatever is pasted or typed is captured and
    /// replaced by dots, so the value is never drawn.
    func update(_ text: String) {
        if text.isEmpty {
            secret = ""
        } else if !shown.isEmpty, text.hasPrefix(shown) {
            secret += text.dropFirst(shown.count)          // typed or pasted after the dots
        } else if !shown.isEmpty, shown.hasPrefix(text) {
            secret = ""                                     // backspace clears the whole value
        } else {
            secret = text                                   // fresh paste, or replaced a selection
        }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        shown = trimmed.isEmpty ? "" : String(repeating: "•", count: min(trimmed.count, 14))
    }

    func clear() { update("") }

    var value: String { secret.trimmingCharacters(in: .whitespacesAndNewlines) }

    var summary: String {
        let kind = describeShape(value).map { " · \($0)" } ?? ""
        return tr("\(value.count) 个字符\(kind)", "\(value.count) characters\(kind)")
    }
}

struct RequestPanel: View {
    let info: RequestInfo
    @ObservedObject var input: SecretInput
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            details
            field
            if let project = info.scopeProject { scopePicker(project) }
            footer
        }
        .padding(24)
        .frame(width: 440)
        .cardBackground(cornerRadius: RequestWindow.cornerRadius)
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(
                    LinearGradient(colors: [Color(red: 1.0, green: 0.62, blue: 0.2), Color(red: 0.95, green: 0.33, blue: 0.27)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .rect(cornerRadius: 14, style: .continuous))
                .shadow(color: .orange.opacity(0.35), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(tr("\(info.agent) 请求一个密钥", "\(info.agent) is asking for a secret"))
                    .font(.system(size: 17, weight: .semibold))
                Text(info.name)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.fill.tertiary, in: .capsule)
                    .textSelection(.enabled)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(tr("项目 \(info.project)", "Project \(info.project)"), systemImage: "folder")
            if let why = info.why { Label(why, systemImage: "text.bubble") }
            if !info.replaces.isEmpty {
                Label(tr("已有 \(info.replaces.joined(separator: "、"))，同一范围下保存会替换",
                         "Saving replaces \(info.replaces.joined(separator: ", ")) in the same scope"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .labelStyle(DetailLabelStyle())
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: input.shown.isEmpty ? "lock" : "lock.fill")
                .foregroundStyle(input.shown.isEmpty ? Color.secondary : Color.accentColor)
                .frame(width: 16)
            TextField(tr("粘贴密钥", "Paste the secret"),
                      text: Binding(get: { input.shown }, set: { input.update($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .focused($fieldFocused)
                .onSubmit { if !input.value.isEmpty { onSave() } }
            if !input.shown.isEmpty {
                Text(input.summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button(action: input.clear) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(tr("清空", "Clear"))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.fill.quaternary, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(fieldFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: fieldFocused ? 2 : 1)
        )
        .animation(.easeOut(duration: 0.15), value: fieldFocused)
    }

    private func scopePicker(_ project: String) -> some View {
        HStack {
            Label(tr("可用范围", "Available to"), systemImage: "square.stack.3d.up")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .labelStyle(DetailLabelStyle())
            Spacer()
            Picker(tr("可用范围", "Available to"), selection: $input.global) {
                Text(tr("仅项目 \(project)", "Project \(project) only")).tag(false)
                Text(tr("所有项目", "All projects")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .fixedSize()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let url = info.url {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label(tr("去获取", "Get one"), systemImage: "arrow.up.right")
                    }
                    .secondaryButtonStyle()
                    .help(url.absoluteString)
                }
                Spacer()
                Button(tr("取消", "Cancel"), action: onCancel)
                    .secondaryButtonStyle()
                    .keyboardShortcut(.cancelAction)
                Button(tr("保存", "Save"), action: onSave)
                    .primaryButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(input.value.isEmpty)
            }
            .controlSize(.large)
            Label(tr("只存入这台 Mac 的钥匙串，\(info.agent) 拿不到值",
                     "Stored only in this Mac's Keychain. \(info.agent) never sees the value."), systemImage: "lock.shield")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}

struct DetailLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.frame(width: 16)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Liquid Glass on macOS 26+, system materials before that. `TONGS_UI_PREVIEW=legacy` forces the
/// fallback so it can be checked on a newer Mac.
enum UIStyle {
    static var glass: Bool {
        if #available(macOS 26, *) {
            return !(ProcessInfo.processInfo.environment["TONGS_UI_PREVIEW"] ?? "").contains("legacy")
        }
        return false
    }
}

extension View {
    /// The card itself. The fallback window already supplies the blur, so only an edge is drawn here.
    @ViewBuilder func cardBackground(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26, *), UIStyle.glass {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        }
    }

    @ViewBuilder func primaryButtonStyle() -> some View {
        if #available(macOS 26, *), UIStyle.glass { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }

    @ViewBuilder func secondaryButtonStyle() -> some View {
        if #available(macOS 26, *), UIStyle.glass { buttonStyle(.glass) } else { buttonStyle(.bordered) }
    }
}

/// Borderless so the glass card is the whole window; borderless windows refuse key status by default.
final class GlassWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum RequestWindow {
    static let cornerRadius: CGFloat = 30

    /// Shows the panel modally; returns the entry, or nil if cancelled.
    static func run(_ info: RequestInfo) -> UI.Entry? {
        let app = NSApplication.shared
        // A regular app (Dock icon, ⌘-Tab, Edit menu) so the panel can be left and come back to,
        // and so clipboard tools that synthesize ⌘V reach it.
        app.setActivationPolicy(.regular)
        app.mainMenu = UI.makeMenu()
        app.applicationIconImage = appIcon()

        let input = SecretInput(global: info.defaultGlobal)
        let window = GlassWindow(contentRect: .zero, styleMask: [.borderless, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        let panel = RequestPanel(info: info, input: input,
                                 onSave: { app.stopModal(withCode: .OK) },
                                 onCancel: { app.stopModal(withCode: .cancel) })
        // Previews are captured without taking focus from the user, so draw controls as active.
        let previewing = ProcessInfo.processInfo.environment["TONGS_UI_PREVIEW"] != nil
        let host = NSHostingView(rootView: previewing
                                 ? AnyView(panel.environment(\.controlActiveState, .key))
                                 : AnyView(panel))
        if UIStyle.glass {
            window.contentView = host
        } else {
            // Before Liquid Glass: a behind-window blur, rounded like the card.
            let blur = NSVisualEffectView()
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.maskImage = roundedMask(cornerRadius)
            host.translatesAutoresizingMaskIntoConstraints = false
            blur.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
                host.topAnchor.constraint(equalTo: blur.topAnchor),
                host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            ])
            window.contentView = blur
        }
        window.setContentSize(host.fittingSize)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.title = "tongs"
        window.center()
        // The shadow is computed from the content's alpha; recompute once the glass card has drawn
        // so it follows the rounded corners instead of the window rectangle.
        for delay in [0.1, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { window.invalidateShadow() }
        }

        if let snapshot = ProcessInfo.processInfo.environment["TONGS_UI_PREVIEW"] {
            preview(window, input: input, mode: snapshot)
        }
        if let mode = ProcessInfo.processInfo.environment["TONGS_UI_PREVIEW"], mode.contains("snap=") {
            // Never take focus (or the user's keystrokes) just to take a picture; preview() exits
            // once the capture is written.
            app.setActivationPolicy(.accessory)
            window.orderFrontRegardless()
            app.run()
        }

        // Cooperative activation: comes forward unless the user is busy in another app,
        // in which case the Dock icon bounces until they switch over.
        app.activate()
        window.makeKeyAndOrderFront(nil)
        let nudge = Timer(timeInterval: 0.5, repeats: false) { _ in
            if !app.isActive { app.requestUserAttention(.criticalRequest) }
        }
        RunLoop.main.add(nudge, forMode: .modalPanel)

        let response = app.runModal(for: window)
        nudge.invalidate()
        window.orderOut(nil)
        guard response == .OK, !input.value.isEmpty else { return nil }
        return UI.Entry(value: input.value, global: info.scopeProject == nil || input.global)
    }

    /// Development aid: `TONGS_UI_PREVIEW=filled,dark,snap=/tmp/x.png` pre-fills a fake value, forces an
    /// appearance, and writes a capture of the panel (a process may capture its own windows
    /// without Screen Recording permission), then exits.
    static func preview(_ window: NSWindow, input: SecretInput, mode: String) {
        if mode.contains("filled") { input.update("sk_live_" + String(repeating: "x", count: 99)) }
        if mode.contains("dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if mode.contains("light") { NSApp.appearance = NSAppearance(named: .aqua) }
        guard let snap = mode.split(separator: ",").first(where: { $0.hasPrefix("snap=") })?.dropFirst(5) else { return }
        let path = String(snap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Task {
                do {
                    let content = try await SCShareableContent.currentProcess
                    guard let w = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                        throw TongsError("own window not found")
                    }
                    let config = SCStreamConfiguration()
                    config.width = Int(window.frame.width * 2)
                    config.height = Int(window.frame.height * 2)
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: config)
                    let rep = NSBitmapImageRep(cgImage: image)
                    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
                    print("saved \(path)")
                } catch {
                    print("snapshot failed: \(error)")
                }
                fflush(stdout)
                exit(0)
            }
        }
    }

    /// A stretchable rounded-rect mask; the supported way to round a behind-window blur
    /// (layer corner radius leaves the blur and the window shadow rectangular).
    static func roundedMask(_ r: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }

    /// Dock icon while the panel is up: the same key glyph as the header.
    static func appIcon() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 50, dy: 50), xRadius: 92, yRadius: 92)
            NSGradient(starting: NSColor(red: 1.0, green: 0.62, blue: 0.2, alpha: 1),
                       ending: NSColor(red: 0.95, green: 0.33, blue: 0.27, alpha: 1))?.draw(in: shape, angle: -45)
            let config = NSImage.SymbolConfiguration(pointSize: 220, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let key = NSImage(systemSymbolName: "key.horizontal.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = key.size
                key.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
    }
}
