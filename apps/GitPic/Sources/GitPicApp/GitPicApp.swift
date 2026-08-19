import AppKit
import SwiftUI
import GitPicCore
import UniformTypeIdentifiers

@main
@MainActor
enum Main {
    /// NSApplication does not retain its delegate, so hold it here.
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        // Menu-bar app: no Dock icon, never becomes the active app. That second
        // part is why NotchDropView must return true from acceptsFirstMouse.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var notch: NotchPanel?
    private var runner: GitpicRunner?
    private var tools: ToolPaths?
    private var format: LinkFormat = .markdown
    private var recent: [ItemResult] = []
    private var mainWindow: NSWindow?

    /// `GITPIC_APP_DRY_RUN=1` records what would be uploaded and skips the network
    /// entirely. Exists so the drag and clipboard plumbing can be verified without
    /// committing anything to the image-host repository.
    ///
    /// Every upload entry point must check this. A dry run that silently uploads
    /// from one path is worse than having no dry-run mode at all.
    private let dryRun = ProcessInfo.processInfo.environment["GITPIC_APP_DRY_RUN"] == "1"

    /// Guards the icon-reset task so a slow earlier report cannot clear a newer one.
    private var feedbackToken = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        resolveTools()

        // The notch drop zone is parked, not deleted: opt in with
        // `defaults write dev.gitpic.app NotchDropZone -bool true`. The panel and
        // the platform constraints it encodes are still in NotchPanel.swift, and
        // docs/macos-app-plan.md §C2 records why its interactive area has to hang
        // below the menu bar.
        if UserDefaults.standard.bool(forKey: "NotchDropZone") {
            let panel = NotchPanel()
            panel.onDrop = { [weak self] urls in self?.upload(paths: urls) }
            panel.show()
            notch = panel
            // The notch lives on one specific screen; re-place it when the display
            // arrangement changes.
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { panel.place() } }
        }
    }

    // MARK: - Tools

    private func resolveTools() {
        let resources = Bundle.main.resourceURL
        guard let paths = ToolDiscovery.resolve(bundleResourceURL: resources) else {
            statusItem.button?.image = Self.icon(symbol: "exclamationmark.triangle.fill")
            Diagnostics.recordLaunch(appVersion: "unknown", tools: nil, ghStatus: nil)
            return
        }
        tools = paths
        let r = GitpicRunner(tools: paths)
        runner = r
        AppModel.shared.attach(runner: r, tools: paths)
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        // Probing gh here costs one spawn at launch and makes the single most
        // confusing failure (no gh under a Finder launch) legible in the log.
        Diagnostics.recordLaunch(appVersion: version, tools: paths,
                                 ghStatus: GHProbe.status(gh: paths.gh))
        Diagnostics.log("  dryRun=\(dryRun)")
    }

    // MARK: - Feedback

    /// Report an outcome without assuming any particular surface exists.
    ///
    /// The notch panel used to be the only place results were shown; with it
    /// parked, the status-item button carries them instead — its icon changes for
    /// a few seconds and its tooltip holds the full message, which is longer than
    /// an icon can say. The notch still gets the update when it is enabled.
    private func report(_ phase: NotchModel.Phase, seconds: TimeInterval = 2.6) {
        notch?.flash(phase, seconds: seconds)

        let symbol: String
        var message: String? = nil
        switch phase {
        case .idle:                 symbol = "photo.on.rectangle.angled"
        case .hovering:             symbol = "arrow.down.circle"
        case .uploading(let n):     symbol = "arrow.up.circle"
                                    message = n == 1 ? "上传中…" : "上传 \(n) 张…"
        case .done(let s):          symbol = "checkmark.circle.fill";        message = s
        case .failed(let s):        symbol = "exclamationmark.triangle.fill"; message = s
        }
        statusItem.button?.image = Self.icon(symbol: symbol)
        statusItem.button?.toolTip = message
        AppModel.shared.statusLine = message

        // An in-progress upload holds its icon until the outcome replaces it.
        if case .uploading = phase { return }
        if case .idle = phase { return }
        feedbackToken += 1
        let token = feedbackToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.feedbackToken == token else { return }
            self.statusItem.button?.image = Self.icon(symbol: "photo.on.rectangle.angled")
            self.statusItem.button?.toolTip = nil
        }
    }

    // MARK: - Status item

    private static func icon(symbol: String) -> NSImage? {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "GitPic")
        img?.isTemplate = true
        return img
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.icon(symbol: "photo.on.rectangle.angled")
        rebuildMenu()
    }

    /// Builds the status-bar menu.
    ///
    /// Every item carries an image on purpose. macOS reserves the icon column
    /// per *section* (the runs between separators), and the system attaches its
    /// own glyph to standard actions such as `terminate:` — so a menu where only
    /// the Quit section has an icon renders that section indented relative to the
    /// others. Giving every item an icon keeps one alignment for the whole menu.
    private static func item(_ title: String, _ symbol: String,
                            _ action: Selector?, key: String = "",
                            modifiers: NSEvent.ModifierFlags? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.image = Self.menuIcon(symbol)
        if let modifiers { mi.keyEquivalentModifierMask = modifiers }
        return mi
    }

    /// The size every menu icon is drawn into. See ``menuIcon(_:)``.
    private static var menuIconSide: CGFloat { (NSFont.menuFont(ofSize: 0).pointSize + 3).rounded() }

    /// A transparent image the size of the icon box.
    ///
    /// AppKit lays a section header out at the *icon* column, so in a menu whose
    /// items carry images the heading ends up around 20 pt to the left of every
    /// title beneath it. Giving the header an empty image of the same size puts its
    /// text in the title column, where it belongs.
    private static func menuIconSpacer() -> NSImage {
        let side = menuIconSide
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in true }
        img.isTemplate = true
        return img
    }

    /// Renders an SF Symbol centred in a box that is the same size for every item.
    ///
    /// Two separate problems, both measured on macOS 26 at 2x:
    ///
    /// 1. `NSMenuItem` draws its image at the image's own size, and SF Symbols have
    ///    per-glyph bounding boxes — the six symbols here came out 21–28 px wide
    ///    and 19–25 px tall. Handing those straight to the menu left the icon
    ///    column ragged and the icon-to-title gap breathing between 7 pt and
    ///    9.5 pt from row to row. One shared canvas fixes the column's left edge,
    ///    width, and gap.
    /// 2. The default `.medium` symbol scale is too heavy for a menu. Finder's own
    ///    File menu has median icon ink of 21x21 px against 25 px-tall text;
    ///    `.medium` at this point size renders 24–29 px, which reads as oversized
    ///    next to the same text. `.small` at the menu font's own point size lands
    ///    on Apple's numbers.
    ///
    /// Both sizes derive from the menu font so the icons keep their proportions if
    /// the system menu font changes; nothing here rescales on its own.
    private static func menuIcon(_ symbol: String) -> NSImage? {
        let body = NSFont.menuFont(ofSize: 0).pointSize
        let config = NSImage.SymbolConfiguration(pointSize: body, weight: .regular,
                                                scale: .small)
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }

        // 16 pt at the default 13 pt menu font: the conventional macOS menu icon
        // box, and large enough that no glyph in this menu is scaled down.
        let side = menuIconSide
        let box = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let natural = glyph.size
            let scale = min(rect.width / natural.width, rect.height / natural.height, 1)
            let size = NSSize(width: natural.width * scale, height: natural.height * scale)
            glyph.draw(in: NSRect(x: rect.midX - size.width / 2,
                                  y: rect.midY - size.height / 2,
                                  width: size.width, height: size.height))
            return true
        }
        // Alpha is all the menu needs: template images are tinted for the item's
        // enabled and highlighted states rather than drawn in their own colour.
        box.isTemplate = true
        return box
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let paste = Self.item("上传剪贴板图片", "doc.on.clipboard",
                              #selector(uploadClipboard), key: "v",
                              modifiers: [.command, .shift])
        paste.target = self
        menu.addItem(paste)

        let pick = Self.item("选择文件上传…", "folder",
                             #selector(pickFiles), key: "o")
        pick.target = self
        menu.addItem(pick)

        menu.addItem(.separator())

        let fmt = Self.item("链接格式", "link", nil)
        let sub = NSMenu()
        for f in LinkFormat.allCases {
            let mi = NSMenuItem(title: f.label, action: #selector(setFormat(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.representedObject = f.rawValue
            mi.state = (f == format) ? .on : .off
            sub.addItem(mi)
        }
        fmt.submenu = sub
        menu.addItem(fmt)

        if !recent.isEmpty {
            menu.addItem(.separator())
            // The real API for this, rather than a disabled item pretending to be
            // a heading: it gets the system's header styling and is skipped by
            // keyboard navigation.
            let header = NSMenuItem.sectionHeader(title: "最近上传")
            header.image = Self.menuIconSpacer()
            menu.addItem(header)
            // One upload carries every link form, so re-copying in a different
            // format never re-uploads.
            for r in recent.prefix(8) {
                let mi = Self.item(r.name + (r.deduped ? "  (已存在)" : ""),
                                   "photo", #selector(copyRecent(_:)))
                mi.target = self
                mi.representedObject = r.id
                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())

        let win = Self.item("打开主窗口…", "macwindow",
                            #selector(openMainWindow), key: ",")
        win.target = self
        menu.addItem(win)

        let doc = Self.item("体检 (doctor)…", "stethoscope", #selector(runDoctor))
        doc.target = self
        menu.addItem(doc)

        menu.addItem(Self.item("退出 GitPic", "power",
                               #selector(NSApplication.terminate(_:)), key: "q"))

        statusItem.menu = menu
    }

    @objc private func setFormat(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let f = LinkFormat(rawValue: raw) else { return }
        format = f
        rebuildMenu()
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let r = recent.first(where: { $0.id == id }) else { return }
        copy(format.snippet(r))
        report(.done(summary: "已复制 \(format.label)"))
    }

    @objc private func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.image]
        // An accessory app has no windows to attach a sheet to, and the panel
        // needs to come forward on its own.
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        upload(paths: p.urls)
    }

    // MARK: - Upload

    private func upload(paths: [URL]) {
        Diagnostics.log("drop received: \(paths.count) item(s) -> "
                        + paths.map(\.lastPathComponent).joined(separator: ", "))
        guard let runner else {
            report(.failed(summary: "找不到 gitpic"))
            return
        }
        if dryRun {
            Diagnostics.log("  DRY RUN: skipping upload")
            report(.done(summary: "DRY RUN 收到 \(paths.count) 个文件"))
            return
        }
        report(.uploading(count: paths.count))
        Task { @MainActor in
            do {
                let env = try await runner.upload(paths: paths)
                self.present(env)
            } catch {
                self.present(error)
            }
        }
    }

    @objc private func uploadClipboard() {
        guard let runner else {
            report(.failed(summary: "找不到 gitpic"))
            return
        }
        // The GUI owns the pasteboard on both ends: `--json` suppresses the CLI's
        // own clipboard write (`src/commands/upload.rs:205` requires Mode::Human),
        // and reading here avoids the `paste` subcommand's arboard dependency
        // entirely.
        guard let data = Self.clipboardPNG() else {
            report(.failed(summary: "剪贴板里没有图片"))
            return
        }
        Diagnostics.log("clipboard upload requested: \(data.count) bytes")
        if dryRun {
            Diagnostics.log("  DRY RUN: skipping upload")
            report(.done(summary: "DRY RUN 收到剪贴板图片 \(data.count) 字节"))
            return
        }
        report(.uploading(count: 1))
        Task { @MainActor in
            do {
                let env = try await runner.upload(pngData: data)
                self.present(env)
            } catch {
                self.present(error)
            }
        }
    }

    private static func clipboardPNG() -> Data? {
        let pb = NSPasteboard.general
        if let png = pb.data(forType: .png) { return png }
        // TIFF is what a screenshot-to-clipboard usually lands as.
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        if let objs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let img = objs.first,
           let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    private func present(_ env: UploadEnvelope) {
        switch env.outcome {
        case .success(let results):
            finish(results, failure: nil)
        case .partial(let results, let err):
            // Partial success is a first-class outcome in this CLI, so it must not
            // be flattened into either "ok" or "failed".
            finish(results, failure: err)
        case .failure(let err):
            reportFailure(err)
        case .malformed(let why):
            report(.failed(summary: "无法解析输出：\(why)"))
        }
    }

    private func finish(_ results: [ItemResult], failure: ErrorBody?) {
        recent = results.reversed() + recent
        rebuildMenu()
        let joined = results.map { format.snippet($0) }.joined(separator: "\n")
        copy(joined)
        if let failure {
            report(.failed(
                summary: "\(results.count) 张成功，之后失败：\(failure.code)"), seconds: 4)
        } else {
            let dd = results.filter(\.deduped).count
            let extra = dd > 0 ? "（\(dd) 张已存在）" : ""
            report(.done(
                summary: results.count == 1 ? "已复制 \(format.label)\(extra)"
                                            : "\(results.count) 张已复制\(extra)"))
        }
    }

    private func reportFailure(_ err: ErrorBody) {
        // CONFIG_MISSING is the one code the GUI must not simply echo: the CLI
        // collapses "gh missing", "gh not logged in", and "gh failed" into it and
        // throws gh's stderr away, so re-probe and say something actionable.
        if let code = GitpicErrorCode(wire: err.code), code.needsToolDiagnosis {
            let status = GHProbe.status(gh: tools?.gh)
            switch status {
            case .notInstalled:
                report(.failed(summary: "找不到 gh，请 brew install gh"), seconds: 5)
            case .notLoggedIn:
                report(.failed(summary: "gh 未登录，请 gh auth login"), seconds: 5)
            case .failed(let detail):
                report(.failed(summary: "gh 异常：\(detail.prefix(60))"), seconds: 5)
            case .ready:
                // gh is fine, so the credential problem is elsewhere — show what
                // the CLI actually said rather than guessing.
                report(.failed(summary: err.message), seconds: 5)
            }
            return
        }
        report(.failed(summary: "\(err.code)：\(err.message)"), seconds: 5)
    }

    private func present(_ error: Error) {
        if case RunFailure.undecodable(let status, let raw) = error {
            report(.failed(
                summary: "gitpic 退出 \(status)，输出无法解析：\(raw.prefix(60))"), seconds: 5)
        } else {
            report(.failed(summary: String(describing: error)), seconds: 5)
        }
    }

    private func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    // MARK: - Doctor

    @objc private func openMainWindow() {
        MainWindowController.show()
    }

    @objc private func runDoctor() {
        guard let runner else { return }
        Task { @MainActor in
            let text: String
            do {
                let r = try await runner.doctor()
                text = Self.describe(r, tools: self.tools)
            } catch {
                text = "doctor 调用失败：\(String(describing: error))"
            }
            let a = NSAlert()
            a.messageText = "GitPic 体检"
            a.informativeText = text
            a.alertStyle = .informational
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    private static func describe(_ r: DoctorReport, tools: ToolPaths?) -> String {
        func mark(_ b: Bool?) -> String {
            guard let b else { return "—" }
            return b ? "✓" : "✗"
        }
        var lines = [
            "配置        \(mark(r.configOK))",
            "凭据有效     \(mark(r.tokenValid))",
            "仓库可写     \(mark(r.repoWritable))",
            "分支保护     \(r.branchProtected == true ? "是" : "否")",
            "凭据来源     \(r.tokenSource ?? "无")",
            "登录账号     \(r.login ?? "—")",
        ]
        lines.append("gitpic      \(tools?.gitpic.path ?? "未找到")")
        lines.append("gh          \(tools?.gh?.path ?? "未找到")")
        if let d = r.detail { lines.append("\n\(d)") }
        if let e = r.error { lines.append("\n\(e.code)：\(e.message)") }
        return lines.joined(separator: "\n")
    }
}
