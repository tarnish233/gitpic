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
        // Menu-bar app: no Dock icon, never becomes the active app — which is why the
        // open panel has to borrow `.regular` for its lifetime; see `pickFiles()`.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var runner: GitpicRunner?
    private var tools: ToolPaths?

    /// What the menu-bar icon is saying: idle, uploading, or unavailable.
    ///
    /// Mutate this and let `refreshIcon()` draw; nothing else may assign
    /// `statusItem.button?.image`. `didSet` skips the redraw when the value did
    /// not change — overlapping uploads share `.uploading`, so a second start
    /// or a first finish must not flicker the same glyph.
    private var statusIcon: StatusIcon = .idle {
        didSet { if statusIcon != oldValue { refreshIcon() } }
    }
    /// Bounded to the same 8 the menu shows. Unbounded growth used to keep every
    /// upload of the session in memory for a status-item that only lists eight.
    ///
    /// `UploadedLink` rather than `ItemResult`: both addresses are resolved when the
    /// upload lands, so re-copying in another form later cannot follow a target the
    /// upload never used.
    private var recent: [UploadedLink] = []

    /// `GITPIC_APP_DRY_RUN=1` records what would be uploaded and skips the network
    /// entirely. Exists so the file-picker and clipboard plumbing can be verified without
    /// committing anything to the image-host repository.
    ///
    /// Every upload entry point must check this. A dry run that silently uploads
    /// from one path is worse than having no dry-run mode at all.
    private let dryRun = ProcessInfo.processInfo.environment["GITPIC_APP_DRY_RUN"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything can open a window: without a main menu the standard
        // shortcuts are dead inside it — see `MainMenu`.
        MainMenu.install()
        setUpStatusItem()
        // The menu's checkmarks are derived from the config, so they have to be
        // redrawn whenever it changes — including when the change came from the
        // window's 保存 two panes away.
        AppModel.shared.onConfigChange = { [weak self] in self?.rebuildMenu() }
        Task { await resolveTools() }
        // Ask at launch rather than at the first upload: the prompt is a modal
        // interruption, and the moment a result is ready is the worst time to
        // discover the app cannot show it.
        Task { await Notifier.authorize() }
        // Build the settings window now, while nothing is waiting on it — see
        // `SettingsWindowController.prewarm()`. In its own turn of the main loop, so
        // the status item is on screen first: the icon is what the user is waiting
        // for at launch, and this is ~150ms they would otherwise wait for it.
        Task { @MainActor in SettingsWindowController.prewarm() }
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
            statusIcon = .unavailable
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

    /// `GHProbe.status` spawns and waits. Same queue as `discover`, same reason:
    /// never `Task.detached` — that parks a cooperative thread for up to 8 s.
    private static func probeGH(gh: URL?) async -> GHStatus {
        await withCheckedContinuation { cont in
            discoveryQueue.async {
                cont.resume(returning: GHProbe.status(gh: gh))
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

    /// Log an outcome and post its notification, if any.
    ///
    /// Does not touch the menu-bar icon. Overlapping uploads share one glyph, so
    /// a last-writer-wins assignment here would idle it while a later upload was
    /// still queued. `beginUpload` / `endUpload` own that count. Copies never
    /// come through here either — they are not uploads, and a failed copy must
    /// not banner as 「GitPic 上传失败」.
    private func report(_ report: UploadReport) {
        switch report {
        case .started(let n):
            Diagnostics.log("upload started: \(n) file(s)")
        case .succeeded(let summary), .failed(let summary):
            Diagnostics.log("upload outcome: \(summary)")
        }
        if let notice = report.notice { Notifier.post(notice) }
    }

    /// Icon lifecycle is a refcount, not `report()`. Overlapping uploads share
    /// `.uploading`; the glyph returns to rest only when the last one ends.
    private var uploadsInFlight = 0

    private func beginUpload() {
        uploadsInFlight += 1
        statusIcon = .uploading
    }

    private func endUpload() {
        uploadsInFlight = max(0, uploadsInFlight - 1)
        if uploadsInFlight == 0 {
            statusIcon = restingState
        }
    }

    /// What the icon goes back to once nothing is in flight.
    ///
    /// Not `.idle` unconditionally. With `gitpic` missing, a failed upload used
    /// to reset the glyph to idle — so the warning the missing tool put in the
    /// menu bar was erased by the failure it caused, and nothing set it back.
    ///
    /// Read off `AppModel.toolState` rather than kept as a flag here: that is
    /// already the app's answer to "was the tool found", and two copies of it
    /// could disagree. `.resolving` counts as idle on purpose — a failure
    /// reported while discovery is still running is not evidence the tool is
    /// absent, and discovery is the only thing that decides that.
    private var restingState: StatusIcon {
        AppModel.shared.toolState == .missing ? .unavailable : .idle
    }

    // MARK: - Status item

    private static func icon(symbol: String) -> NSImage? {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "GitPic")
        img?.isTemplate = true
        return img
    }

    /// Draw whatever ``statusIcon`` currently says.
    ///
    /// Keeps the previous glyph if the symbol will not resolve, rather than assigning
    /// `nil` and leaving a blank gap in the menu bar where the app's only affordance
    /// used to be. All three symbols do resolve — each checked through
    /// `NSImage(systemSymbolName:)` on macOS 26.5 — so this guards against a future
    /// rename, and is not a live fallback.
    private func refreshIcon() {
        guard let image = Self.icon(symbol: statusIcon.symbol) else { return }
        statusItem?.button?.image = image
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshIcon()
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

    /// One radio group: every case of one dimension, the current one checked.
    ///
    /// Generic over the dimension so the two groups cannot drift apart in how they
    /// mark the selection or carry it back — the value travels as its `rawValue`,
    /// which is the same string the config file and the CLI flags use.
    private static func radioMenu<T: RawRepresentable & Equatable>(
        _ cases: [T], current: T, label: KeyPath<T, String>,
        target: AnyObject, action: Selector
    ) -> NSMenu where T.RawValue == String {
        let menu = NSMenu()
        for c in cases {
            let mi = NSMenuItem(title: c[keyPath: label], action: action,
                                keyEquivalent: "")
            mi.target = target
            mi.representedObject = c.rawValue
            mi.state = (c == current) ? .on : .off
            menu.addItem(mi)
        }
        return menu
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let paste = Self.item("上传剪贴板图片", "doc.on.clipboard",
                              #selector(uploadClipboard))
        paste.target = self
        menu.addItem(paste)

        let pick = Self.item("选择文件上传", "folder", #selector(pickFiles))
        pick.target = self
        menu.addItem(pick)

        menu.addItem(.separator())

        // Two dimensions, two sibling submenus — because that is what they are. A
        // snippet's syntax and the host it addresses are chosen independently, and
        // the single four-entry "链接格式" menu these replace could not express half
        // the grid: Markdown pointing at the raw URL had no entry at all.
        let form = AppModel.shared.linkForm

        let syntax = Self.item("链接格式", "chevron.left.forwardslash.chevron.right", nil)
        syntax.submenu = Self.radioMenu(LinkSyntax.allCases, current: form.syntax,
                                        label: \.label, target: self,
                                        action: #selector(setSyntax(_:)))
        menu.addItem(syntax)

        let target = Self.item("图片地址", "link", nil)
        target.submenu = Self.radioMenu(LinkTarget.allCases, current: form.target,
                                        label: \.detailedLabel, target: self,
                                        action: #selector(setTarget(_:)))
        menu.addItem(target)

        if !recent.isEmpty {
            menu.addItem(.separator())
            // The real API for this, rather than a disabled item pretending to be
            // a heading: it gets the system's header styling and is skipped by
            // keyboard navigation.
            let header = NSMenuItem.sectionHeader(title: "最近上传")
            header.image = Self.menuIconSpacer()
            menu.addItem(header)
            // One upload carries both addresses, so re-copying in a different
            // form never re-uploads.
            for r in recent.prefix(8) {
                let mi = Self.item(r.name + (r.deduped ? "  (已存在)" : ""),
                                   "photo", #selector(copyRecent(_:)))
                mi.target = self
                mi.representedObject = r.id
                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())

        // 设置, not 主窗口: this window *is* the settings window — the only place the
        // app edits the config file — and naming it after its shape ("a window") said
        // nothing about what clicking it does. `gearshape` replaces `macwindow` for
        // the same reason.
        let settings = Self.item("打开设置", "gearshape", #selector(openSettings))
        settings.target = self
        menu.addItem(settings)

        let doc = Self.item("连通性测试", "network", #selector(runDoctor))
        doc.target = self
        menu.addItem(doc)

        menu.addItem(Self.item("退出 GitPic", "power",
                               #selector(NSApplication.terminate(_:))))

        statusItem.menu = menu
    }

    /// Both of these write the config file, and the menu redraws from what landed
    /// rather than from what was clicked — `AppModel.onConfigChange` calls
    /// `rebuildMenu()` after the reload, so a write that fails leaves the checkmark
    /// where it was instead of claiming a change the file never took.
    @objc private func setSyntax(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let s = LinkSyntax(rawValue: raw) else { return }
        var form = AppModel.shared.linkForm
        form.syntax = s
        Task { await AppModel.shared.writeLinkForm(form) }
    }

    @objc private func setTarget(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let t = LinkTarget(rawValue: raw) else { return }
        var form = AppModel.shared.linkForm
        form.target = t
        Task { await AppModel.shared.writeLinkForm(form) }
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let r = recent.first(where: { $0.id == id }) else { return }
        let form = AppModel.shared.linkForm
        // A missing snippet is a missing *address*, not a missing upload: only the
        // CDN form can be absent. Say which address is missing and why — the two
        // causes have different fixes, and one of them is a config value only the
        // user can change — instead of copying the other under the label they picked.
        guard let text = r.snippet(form) else {
            AppModel.shared.notify(title: "复制失败",
                                   body: r.unavailable(form.target)?.message
                                         ?? "没有 \(form.target.label) 链接")
            return
        }
        if copy(text) {
            AppModel.shared.notify(title: "GitPic", body: "已复制 \(form.label)")
        } else {
            AppModel.shared.notify(title: "写剪贴板失败", body: r.name)
        }
    }

    @objc private func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.image]
        // Become .regular for the life of the panel, the same way the settings window
        // does — an .accessory app cannot own a focused, title-barred window, and
        // that includes a modal panel. `AppActivationPolicy` is reference-counted
        // for exactly this: the panel can hold .regular alongside the settings window.
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
        Diagnostics.log("upload requested: \(paths.count) item(s) -> "
                        + paths.map(\.lastPathComponent).joined(separator: ", "))
        guard let runner else {
            report(.failed(summary: missingToolSummary()))
            return
        }
        if dryRun {
            Diagnostics.log("  DRY RUN: skipping upload")
            report(.succeeded(summary: "DRY RUN 收到 \(paths.count) 个文件"))
            return
        }
        beginUpload()
        report(.started(count: paths.count))
        Task { @MainActor in
            defer { endUpload() }
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
            report(.failed(summary: missingToolSummary()))
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
            report(.failed(summary: "剪贴板里没有图片：复制图片本身或图片文件后再试"))
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
                report(.succeeded(summary: "DRY RUN 收到剪贴板图片 \(data.count) 字节"))
                return
            }
            beginUpload()
            report(.started(count: 1))
            Task { @MainActor in
                defer { endUpload() }
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
        // Copy before reporting, because what became of the clipboard is one of the
        // things the wording depends on. An empty result list skips the copy: an
        // `ok:true` envelope with no results uploaded nothing, and copying "" would
        // replace whatever the user had on the clipboard with nothing.
        var clipboard = ClipboardOutcome.suppressed
        var form = AppModel.shared.linkForm
        let config = AppModel.shared.savedConfig
        if !results.isEmpty {
            // Resolve both addresses now, against the config that was in force when
            // the files landed — see `UploadedLink`.
            let links = results.map { UploadedLink($0, config: config) }
            // Only the CDN address can be missing — with no config to build it from,
            // or on a branch jsDelivr cannot address. Falling back to raw keeps a
            // live link on the clipboard rather than none, and `form` is corrected so
            // the report names the address actually copied.
            if links.contains(where: { $0.url(form.target) == nil }) {
                form.target = .raw
            }
            // `upload.auto_copy` — the same key the CLI reads, so the switch in 设置
            // now means one thing on both surfaces instead of being labelled 仅 CLI.
            //
            // The copy still happens *here* rather than in the CLI, and that is not a
            // workaround: the app invokes `--json`, and JSON mode never touches the
            // clipboard by design (a `gitpic upload --json` inside someone's script
            // must not overwrite what they had on it — `upload.rs` gates the write on
            // `Mode::Human`, which also excludes `--quiet`). Honouring the key on this
            // side is what makes the two agree without giving machine mode a side
            // effect it should not have.
            //
            // Default `true` when the config could not be read, matching the CLI's
            // own default for a file that is missing.
            if config?.upload.autoCopy ?? true {
                let text = links.compactMap { $0.snippet(form) }.joined(separator: "\n")
                clipboard = copy(text) ? .written : .failed
            }
            recent = Array((links.reversed() + recent).prefix(8))
            rebuildMenu()
            Task { await AppModel.shared.reload() }
        }
        report(UploadPresentation.report(results: results, failure: failure,
                                        clipboard: clipboard, form: form))
    }

    private func reportFailure(_ err: ErrorBody) {
        // CONFIG_MISSING is the one code the GUI must not simply echo: the CLI
        // collapses "gh missing", "gh not logged in", and "gh failed" into it and
        // throws gh's stderr away, so re-probe and say something actionable.
        if let code = GitpicErrorCode(wire: err.code), code.needsToolDiagnosis {
            let gh = tools?.gh
            // Probe off the main actor; do not `report(.failed)` — that would
            // banner a second time if a first report is ever added, and today
            // there is none. `present` returns, `defer { endUpload() }` clears
            // the icon, then this notifies with the diagnosed string.
            Task { @MainActor in
                let status = await Self.probeGH(gh: gh)
                let summary: String
                switch status {
                case .notInstalled:
                    summary = "找不到 gh，请 brew install gh"
                case .notLoggedIn:
                    summary = "gh 未登录，请 gh auth login"
                case .failed(let detail):
                    summary = "gh 异常：\(detail.prefix(60))"
                case .ready:
                    // gh is fine, so the credential problem is elsewhere — show what
                    // the CLI actually said rather than guessing.
                    summary = err.message
                }
                AppModel.shared.notify(title: "GitPic 上传失败", body: summary)
            }
            return
        }
        report(.failed(summary: "\(err.code)：\(err.message)"))
    }

    private func present(_ error: Error) {
        if case RunFailure.undecodable(let status, let raw) = error {
            report(.failed(
                summary: "gitpic 退出 \(status)，输出无法解析：\(raw.prefix(60))"))
        } else {
            report(.failed(summary: String(describing: error)))
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

    // MARK: - Settings

    /// Internal, not private: `MainMenu` names these selectors from another file.
    @objc func openSettings() {
        SettingsWindowController.show()
    }

    @objc func openAbout() {
        SettingsWindowController.show(tab: .about)
    }

    // MARK: - Doctor

    @objc private func runDoctor() {
        SettingsWindowController.show(tab: .host)
        Task { await AppModel.shared.runDoctor() }
    }
}
