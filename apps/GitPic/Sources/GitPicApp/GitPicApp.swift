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
    /// Bounded to the same 8 the menu shows. Unbounded growth used to keep every
    /// upload of the session in memory for a status-item that only lists eight.
    private var recent: [ItemResult] = []

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
        Task { await resolveTools() }

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

    /// Locating `gh` and probing `gh auth status` spawn processes and can block
    /// on a login shell. Keep that off the main thread so a hung probe cannot
    /// freeze the menu extra at launch.
    private func resolveTools() async {
        let discovered = await Self.discover(bundleResourceURL: Bundle.main.resourceURL)
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        guard let paths = discovered.0 else {
            statusItem.button?.image = Self.icon(symbol: "exclamationmark.triangle.fill")
            // The model has to be told the search *finished*, not just that there is
            // no runner: until then every pane reads a nil runner as "still looking"
            // and offers no way forward.
            AppModel.shared.toolsUnavailable()
            Diagnostics.recordLaunch(appVersion: version, tools: nil, ghStatus: nil)
            return
        }
        tools = paths
        let r = GitpicRunner(tools: paths)
        runner = r
        AppModel.shared.attach(runner: r, tools: paths)
        // The window can be open before discovery finishes, and the reload it fired
        // on open no-ops while `runner` is nil. Without this the form sits on its
        // placeholder until the user happens to find the retry button.
        Task { await AppModel.shared.reload() }
        // Probing gh here costs one spawn at launch and makes the single most
        // confusing failure (no gh under a Finder launch) legible in the log.
        Diagnostics.recordLaunch(appVersion: version, tools: paths,
                                 ghStatus: discovered.1)
        Diagnostics.log("  dryRun=\(dryRun)")
    }

    /// The one thread discovery is allowed to block.
    ///
    /// `ToolDiscovery.resolve` and `GHProbe.status` both spawn and wait, and
    /// `ChildProcess.run` drains the pipes *on the calling thread*. `Task.detached`
    /// does not come with a thread of its own — it runs on the cooperative pool — so
    /// doing this there parks a cooperative thread for up to 8 s per tool, the one
    /// thing `GitpicRunner`'s gate comment says never to do. Here the pool only ever
    /// waits on the continuation.
    ///
    /// Its own queue rather than `GitpicRunner`'s gate: discovery is not a `gitpic`
    /// invocation and must not queue behind an upload.
    private static let discoveryQueue = DispatchQueue(label: "dev.gitpic.app.discovery")

    private static func discover(bundleResourceURL: URL?) async -> (ToolPaths?, GHStatus?) {
        await withCheckedContinuation { cont in
            discoveryQueue.async {
                let paths = ToolDiscovery.resolve(bundleResourceURL: bundleResourceURL)
                cont.resume(returning: (paths, paths.map { GHProbe.status(gh: $0.gh) }))
            }
        }
    }

    /// What to say when `runner` is nil.
    ///
    /// "找不到 gitpic" while discovery is still running is a lie the user can act on
    /// wrongly — reinstalling a binary that is present and merely not located yet.
    private func missingToolSummary() -> String {
        AppModel.shared.toolState == .resolving
            ? "正在查找 gitpic，请稍候重试"
            : "找不到 gitpic"
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
        AppModel.shared.post(message, from: .upload)

        // Retire any reset still pending before deciding whether to arm a new one:
        // it belongs to an older phase. Skipping this for `.uploading` is what let a
        // 2.6 s reset armed by the *previous* outcome fire mid-upload and wipe
        // "上传中…" — breaking the very invariant the next line states.
        feedbackToken += 1
        // An in-progress upload holds its icon until the outcome replaces it.
        if case .uploading = phase { return }
        if case .idle = phase { return }
        let token = feedbackToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.feedbackToken == token else { return }
            self.statusItem.button?.image = Self.icon(symbol: "photo.on.rectangle.angled")
            self.statusItem.button?.toolTip = nil
            AppModel.shared.clearStatus(message, from: .upload)
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

    /// Builds one status-bar menu item.
    ///
    /// **No key equivalents, deliberately.** A status-bar menu is not in the main
    /// menu chain, and this app is `.accessory` and so never the active app, so a
    /// `keyEquivalent` here fires only while the menu is already open — never from
    /// another app. The menu used to advertise `⌘⇧V`, `⌘O`, `⌘,` and `⌘Q`, which
    /// read as global hotkeys and are not: pressing `⌘⇧V` with another app frontmost
    /// leaves no trace in the log at all (measured). Showing a shortcut the app
    /// cannot honour is worse than showing none. Adding them back means registering
    /// real hotkeys (`RegisterEventHotKey`) first.
    ///
    /// Every item carries an image on purpose. macOS reserves the icon column
    /// per *section* (the runs between separators), and the system attaches its
    /// own glyph to standard actions such as `terminate:` — so a menu where only
    /// the Quit section has an icon renders that section indented relative to the
    /// others. Giving every item an icon keeps one alignment for the whole menu.
    private static func item(_ title: String, _ symbol: String,
                            _ action: Selector?) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.image = Self.menuIcon(symbol)
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
                              #selector(uploadClipboard))
        paste.target = self
        menu.addItem(paste)

        let pick = Self.item("选择文件上传…", "folder", #selector(pickFiles))
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

        let win = Self.item("打开主窗口…", "macwindow", #selector(openMainWindow))
        win.target = self
        menu.addItem(win)

        let doc = Self.item("连通性测试…", "network", #selector(runDoctor))
        doc.target = self
        menu.addItem(doc)

        menu.addItem(Self.item("退出 GitPic", "power",
                               #selector(NSApplication.terminate(_:))))

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
        if copy(format.snippet(r)) {
            report(.done(summary: "已复制 \(format.label)"))
        } else {
            report(.failed(summary: "写剪贴板失败"), seconds: 4)
        }
    }

    @objc private func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.image]
        // Become .regular for the life of the panel, the same way the main window
        // does — an .accessory app cannot own a focused, title-barred window, and
        // that includes a modal panel. `AppActivationPolicy` is reference-counted
        // for exactly this: the panel can hold .regular alongside the main window.
        //
        // This replaces a bare `NSApp.activate(ignoringOtherApps:)`, which is
        // deprecated as of macOS 14 and does not do what its name says any more:
        // under cooperative activation a background app cannot pull itself in front
        // of the active one. What decides it is where the click came from — a real
        // click on the status item grants the app activation rights and the panel
        // comes up in front (confirmed by hand); the same menu item driven
        // programmatically gets no such rights and the panel opens *behind* the
        // frontmost app's windows (measured). So this is the policy that makes the
        // real path work, not a guarantee for every caller.
        AppActivationPolicy.enter()
        defer { AppActivationPolicy.leave() }
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        upload(paths: p.urls)
    }

    // MARK: - Upload

    private func upload(paths: [URL]) {
        Diagnostics.log("drop received: \(paths.count) item(s) -> "
                        + paths.map(\.lastPathComponent).joined(separator: ", "))
        guard let runner else {
            report(.failed(summary: missingToolSummary()), seconds: 5)
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
            report(.failed(summary: missingToolSummary()), seconds: 5)
            return
        }
        // The GUI owns the pasteboard on both ends: `--json` suppresses the CLI's
        // own clipboard write (`src/commands/upload.rs:205` requires Mode::Human),
        // and reading here avoids the `paste` subcommand's arboard dependency
        // entirely.
        guard let offer = Self.clipboardImages() else {
            // Logged, not just flashed. This is the one failure that leaves no
            // other trace — no upload runs, so without a line here the log shows
            // nothing at all and "GitPic 没反应" is undiagnosable.
            let types = NSPasteboard.general.types?.map(\.rawValue).joined(separator: ", ") ?? "none"
            Diagnostics.log("clipboard upload requested: no image on pasteboard; types=[\(types)]")
            report(.failed(summary: "剪贴板里没有图片：复制图片本身或图片文件后再试"), seconds: 5)
            return
        }
        switch offer {
        case .files(let urls):
            // Already on disk, so this is an ordinary file upload — same code path,
            // and the original bytes, extension, and filename all survive.
            upload(paths: urls)
        case .data(let data):
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
    }

    /// What the clipboard is offering, in whichever form it has it.
    private enum ClipboardOffer {
        /// Image files that already exist on disk — what a Finder ⌘C puts on the
        /// pasteboard, and what most file managers and browsers put there too.
        case files([URL])
        /// Loose bitmap data, with no file behind it — a screenshot, or an app that
        /// copied pixels rather than a file.
        case data(Data)
    }

    /// Read whatever image the clipboard holds.
    ///
    /// File URLs are checked **first**, and that ordering is the whole point of
    /// this function: copying an image in Finder puts only `public.file-url` on the
    /// pasteboard — no `.png`, no `.tiff`, and `NSImage` does not read it back
    /// either (measured). A bitmap-only reader therefore reports "剪贴板里没有图片"
    /// for the most ordinary way there is to copy an image on macOS.
    ///
    /// Preferring the file is also the better upload: the original bytes,
    /// extension, and name all survive, instead of every paste landing as a
    /// re-encoded `clipboard.png`.
    private static func clipboardImages() -> ClipboardOffer? {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true,
                      .urlReadingContentsConformToTypes: [UTType.image.identifier]]
        ) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        if let png = pb.data(forType: .png) { return .data(png) }
        // TIFF is what a screenshot-to-clipboard usually lands as.
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return .data(png)
        }
        if let objs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let img = objs.first,
           let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return .data(png)
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
        guard !results.isEmpty else {
            // `ok:true` with an empty result list. Nothing uploaded, so there is
            // nothing to copy — and copying "" would replace whatever the user had
            // on the clipboard with nothing, which is worse than doing nothing.
            report(.failed(summary: failure.map { "\($0.code)：\($0.message)" }
                                    ?? "上传没有返回任何结果"), seconds: 5)
            return
        }
        recent = Array((results.reversed() + recent).prefix(8))
        rebuildMenu()
        Task { await AppModel.shared.reload() }
        let joined = results.map { format.snippet($0) }.joined(separator: "\n")
        let copied = copy(joined)
        if let failure {
            report(.failed(
                summary: "\(results.count) 张成功，之后失败：\(failure.code)"), seconds: 4)
        } else if !copied {
            // The upload is done and the link is real; only the clipboard write
            // failed. Say exactly that instead of reporting a success the user
            // cannot paste.
            report(.failed(summary: "上传成功，但写剪贴板失败。链接在「最近上传」里"), seconds: 6)
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
            let gh = tools?.gh
            Task { @MainActor in
                let status = await Task.detached { GHProbe.status(gh: gh) }.value
                switch status {
                case .notInstalled:
                    self.report(.failed(summary: "找不到 gh，请 brew install gh"), seconds: 5)
                case .notLoggedIn:
                    self.report(.failed(summary: "gh 未登录，请 gh auth login"), seconds: 5)
                case .failed(let detail):
                    self.report(.failed(summary: "gh 异常：\(detail.prefix(60))"), seconds: 5)
                case .ready:
                    // gh is fine, so the credential problem is elsewhere — show what
                    // the CLI actually said rather than guessing.
                    self.report(.failed(summary: err.message), seconds: 5)
                }
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

    /// Write to the clipboard, and say whether it landed.
    ///
    /// The result is not decoration: `setString` can fail, and reporting "已复制"
    /// anyway is worse than not copying — the user pastes stale content and never
    /// learns why.
    @discardableResult
    private func copy(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(s, forType: .string)
    }

    // MARK: - Doctor

    @objc private func openMainWindow() {
        MainWindowController.show()
    }

    @objc private func runDoctor() {
        MainWindowController.show(tab: .host)
        Task { await AppModel.shared.runDoctor() }
    }
}
