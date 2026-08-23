import AppKit
import GitPicCore

/// The Finder right-click entry: 「GitPic 上传至图床」.
///
/// **How this reaches Finder.** The item is declared as an `NSServices` entry in
/// `Info.plist` (written by `scripts/build-app.sh`), and the system routes it to
/// whatever object is set as `NSApp.servicesProvider`. There is no extension bundle
/// and nothing for the user to enable, which is the whole reason this mechanism was
/// chosen over the two that also produce a context-menu item:
///
/// | mechanism | shows up | costs |
/// | --- | --- | --- |
/// | `NSServices` (this) | top level of Finder's context menu | no icon in the menu |
/// | Action extension (`com.apple.services`) | usually under 快速操作, with an icon | a signed extension bundle in `Contents/PlugIns`, which SwiftPM does not build |
/// | `FIFinderSync` | top level, with an icon | the user must switch it on in 系统设置 ▸ 登录项与扩展, and it only fires inside directories the extension registers |
///
/// Both of the icon-bearing options need a real code-signing identity to register
/// reliably, and this project has none (see `docs/macos-app-plan.md` C4 — the
/// bundle is ad-hoc signed). `NSServices` is carried by the app bundle itself, so
/// an ad-hoc signature is no obstacle: Launch Services reads the plist.
///
/// Top-level placement is not a guess. `/Applications/Ghostty.app` declares its two
/// `NSServices` entries the same way and they render at the top level of Finder's
/// context menu on this machine.
///
/// **What it does not do.** It never brings the app forward. The app is
/// `LSUIElement`, a right-click upload is normally a *cold launch*, and stealing
/// focus to say "done" would be worse than the notification that says it — see
/// ``Notifier``, which is this app's only result surface.
@MainActor
final class ServiceProvider: NSObject {

    /// The `NSMessage` value in `Info.plist`, which is the selector name without
    /// its `:userData:error:` tail.
    ///
    /// Lives in `GitPicCore` so a test can pin it together with the `pbs` key it goes
    /// into — see ``FinderServiceStatus/message``. Renaming the method below without
    /// editing the plist leaves a menu item that appears, is clickable, and does
    /// nothing at all; `installServiceProvider()` checks the two agree at launch.
    static var message: String { FinderServiceStatus.message }

    private let upload: ([URL]) -> Void
    private let refuse: (String) -> Void

    /// Closures rather than a reference to `AppDelegate`: the only two things this
    /// object does are hand over a list of images and say why it could not.
    init(upload: @escaping ([URL]) -> Void, refuse: @escaping (String) -> Void) {
        self.upload = upload
        self.refuse = refuse
        super.init()
    }

    /// Invoked by the system when the menu item is chosen.
    ///
    /// The signature is fixed by the Services protocol
    /// (`- (void)msg:(NSPasteboard *)pboard userData:(NSString *)data error:(NSString **)err`),
    /// so the parameter names and types here are not free choices.
    ///
    /// **`error` is deliberately left alone.** Writing to it makes the system
    /// present the string in an alert of its own, on top of the notification this
    /// app posts for the same event — two reports for one click, one of them in a
    /// modal window from an app the user cannot see. Failures go through the same
    /// path every other upload failure uses.
    @objc func uploadImagesToGitPic(_ pasteboard: NSPasteboard,
                                    userData: String?,
                                    error: AutoreleasingUnsafeMutablePointer<NSString>) {
        // Checked here as well as written to `pbs`, and not as redundancy for its own
        // sake. Turning the switch off removes the item from Finder's menu, so in the
        // ordinary case this is unreachable — but that removal depends on the services
        // cache having caught up, and pbs was measured still dispatching to a service
        // whose entry says off. This is what keeps the switch's answer true meanwhile.
        //
        // What it deliberately does *not* defend against: a menu title renamed since
        // the user switched off. That orphans the entry, `FinderServiceStatus.isEnabled`
        // reports on for a missing key by design, so this guard passes too. Nothing here
        // can catch that — only not renaming the title can.
        guard FinderService.isEnabled else {
            Diagnostics.log("service upload ignored: right-click upload is switched off")
            // Not through `refuse`: that ends in `UploadReport.failed`, whose notice title
            // is hard-coded 「GitPic 上传失败」, and a setting being honoured is not an
            // upload failure. Nothing was attempted — say why nothing happened instead.
            AppModel.shared.notify(
                title: "右键上传已关闭",
                body: "可在 GitPic 设置 ▸ 上传 ▸「Finder 右键」里重新打开。")
            return
        }
        // No `.urlReadingContentsConformToTypes` filter, on purpose: reading the
        // whole selection is what lets a non-image be *named* in the refusal
        // instead of vanishing from a filtered array.
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []

        let selection = ImageFilter.partition(urls)
        // `urls.count` is kept even though it equals `images + skipped`, because the two
        // are not redundant when the *bridge* fails: `readObjects(...) as? [URL] ?? []`
        // collapses to empty if any element fails to bridge, and "arrived 0" is the only
        // thing that distinguishes that from Finder sending nothing at all.
        //
        // `userData` arrives as "" rather than nil when the plist carries no
        // `NSUserData` — measured — so an `if let` alone logs a bare `userData=` on every
        // single click. The skipped names go in whole, untruncated: a log is not a
        // notification, which is why this does not reuse `ImageSelection`'s
        // three-and-a-count wording.
        let tag = userData.flatMap { $0.isEmpty ? nil : " userData=\($0)" } ?? ""
        let skipped = selection.skipped.isEmpty ? "" : ", skipped "
            + selection.skipped.map(\.lastPathComponent).joined(separator: ", ")
        Diagnostics.log("service upload requested: \(urls.count) item(s), "
                        + "\(selection.images.count) image(s)\(skipped)\(tag)")
        if let refusal = selection.refusal {
            refuse(refusal)
            return
        }
        // Said out loud, not just logged. The success banner comes from the upload and
        // counts only what it uploaded — 「3 张已复制」 for a selection of ten is exactly
        // the ambiguity `ImageSelection`'s two lists exist to remove. `NSSendFileTypes`
        // matches per pasteboard rather than requiring every file to conform, so a mixed
        // selection is reachable; an extra banner in that rare case beats a count the
        // user cannot reconcile with what they selected.
        if !selection.skipped.isEmpty {
            AppModel.shared.notify(
                title: "跳过 \(selection.skipped.count) 个非图片文件",
                body: selection.skippedSummary)
        }
        upload(selection.images)
    }
}
