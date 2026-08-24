import SwiftUI
import GitPicCore

/// What a new release says, and the two ways to act on it.
///
/// A sheet rather than a pane, because it is about one moment: a version was found, here is
/// what is in it, do you want it. Raised by a *manual* check, and by 「查看更新内容」 for one
/// the daily check found — never by the daily check itself, which reports through
/// Notification Center instead of interrupting whatever the window was being used for.
struct UpdateSheet: View {
    @Bindable var model: AppModel
    let report: UpdateReport

    @State private var confirmingUpgrade = false
    @State private var confirmingInstall = false

    /// The release notes, parsed once per report rather than once per redraw.
    ///
    /// `report.summary` rewrites the body, `UpdateReport.displayMarkdown` rewrites its headings
    /// and `AttributedString(markdown:)` parses the result — and every one of those used to run
    /// inside `body`, which SwiftUI re-evaluates on every observed change. A download emits
    /// hundreds of progress ticks for a five-megabyte image, so the notes were being re-parsed
    /// hundreds of times to produce a value that cannot have changed. `nil` only for the frames
    /// before the `.task` below has run, which ``notes`` covers by parsing inline.
    @State private var renderedNotes: AttributedString?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            notes
            Divider()
            actions
        }
        .frame(width: 480, height: 420)
        // Asked when the sheet appears rather than at launch: it spawns `brew list`, which
        // is up to 20 s of somebody else's process, and nothing before this moment needs
        // the answer. It also needs the completed report, because which route is available
        // depends on what the release published.
        //
        // Keyed on the report generation, not on appearance alone: a check that lands while
        // this sheet is open replaces the report the route was derived from, and a route
        // computed from the previous one may name an asset this release does not have. See
        // `AppModel.updateGeneration`.
        .task(id: model.updateGeneration) {
            renderedNotes = Self.markdown(UpdateReport.displayMarkdown(report.summary))
            await model.resolveUpgradePath()
        }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GitPic \(report.latest) 可以更新了")
                .font(.title3.weight(.semibold))
            Text("当前版本 \(report.current)")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    /// The release notes, scrollable and selectable.
    ///
    /// `report.summary` rather than `report.notes`: the Release body repeats its own title
    /// as a leading heading and ends with `## `-level install instructions for someone who
    /// downloaded the DMG, and this reader is neither — see ``UpdateReport/summary``.
    ///
    /// Rendered through `AttributedString` with `.inlineOnlyPreservingWhitespace`, which
    /// keeps line breaks and `- ` bullets as written while resolving inline syntax. See
    /// ``UpdateReport/displayMarkdown(_:)`` for why the headings are rewritten before they
    /// get here, and why the full parser is not an option. Parsed into ``renderedNotes`` rather
    /// than here, with a one-off inline parse as the fallback for the frames before the `.task`
    /// has run — so the first render is correct and the next few hundred are free.
    @ViewBuilder private var notes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let name = report.name {
                    Text(name).font(.headline)
                }
                let rendered = renderedNotes
                    ?? Self.markdown(UpdateReport.displayMarkdown(report.summary))
                if rendered.characters.isEmpty {
                    Text("这个版本没有附更新说明。")
                        .foregroundStyle(.secondary)
                } else {
                    Text(rendered)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = model.updateFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            // While an install is running the buttons are replaced rather than disabled: the
            // only thing worth offering mid-download is stopping it.
            if let progress = model.downloadProgress {
                installProgress(progress)
            } else {
                HStack(spacing: 8) {
                    switch model.upgradePath {
                    case .homebrew:
                        Button("立即更新") { confirmingUpgrade = true }
                            .buttonStyle(.borderedProminent)
                    case .selfInstall(let asset, _, _):
                        Button("下载并更新") { confirmingInstall = true }
                            .buttonStyle(.borderedProminent)
                        Text(Self.size(asset.size))
                            .font(.caption).foregroundStyle(.secondary)
                    case .unavailable, .none:
                        // No button at all rather than a disabled one: neither path can work
                        // here, and a greyed-out control with a tooltip is a worse answer than
                        // the one route that does.
                        EmptyView()
                    }
                    Button("打开发布页") {
                        if let url = URL(string: report.url) { NSWorkspace.shared.open(url) }
                    }
                    Spacer()
                    Button("稍后") { model.updateSheetPresented = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
            if model.upgradePath == nil, model.downloadProgress == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在确认升级方式…").font(.caption).foregroundStyle(.secondary)
                }
            } else if case .unavailable(let reason, _) = model.upgradePath {
                // The reason, not a guess at it. This line used to say 「不是用 Homebrew 装的，
                // 或者机器上没有 brew」 for every failure — which was already wrong for a
                // bundle brew manages at a path this app is not running from, and is wrong in
                // more ways now that "the directory cannot be written" and "the release has no
                // verifiable image" are also possible.
                VStack(alignment: .leading, spacing: 4) {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                    Text("可以到发布页手动下载，或在终端运行 `brew upgrade --cask gitpic`。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            }
        }
        .padding(16)
        .alert("升级前需要退出 GitPic", isPresented: $confirmingUpgrade) {
            Button("退出并升级") { model.performUpgrade() }
            Button("取消", role: .cancel) {}
        } message: {
            // Says exactly what is about to happen, because all of it is visible and some
            // of it is alarming: the window closes, the menu-bar icon disappears for the
            // length of a download, and the app comes back on its own.
            Text("Homebrew 不能替换正在运行的 App，所以 GitPic 会先退出，"
                 + "升级完成后自动重新打开。这期间菜单栏图标会消失。\n\n"
                 + "升级过程记录在 GitPic-update.log 里；万一失败，原来的版本仍然可用。")
        }
        .alert("下载并安装 GitPic \(report.latest)", isPresented: $confirmingInstall) {
            Button("下载并安装") { model.performUpgrade() }
            Button("取消", role: .cancel) {}
        } message: {
            // The order matters and is stated, because it is what makes this safe: everything
            // that can go wrong happens while the window is still here.
            Text("这份 GitPic 不是 Homebrew 装的，所以由 GitPic 自己安装更新。\n\n"
                 + "会先下载并校验，全部通过之后才退出并替换，完成后自动重新打开——"
                 + "下载或校验失败的话什么都不会改动。\n\n"
                 + "校验用的是 GitHub 为这个文件公布的 SHA-256，和 Homebrew 验证 cask 的方式相同。")
        }
    }

    /// The download's own bar, plus the one action that makes sense while it runs.
    ///
    /// **取消 is live for the whole of this row**, and that is a fix rather than an oversight.
    /// It used to be `.disabled(model.installing)`, which switched it off at the last byte —
    /// before the hashing, the mount, the version check and the copy, every one of which stops
    /// when asked. And with 稍后 gone from this branch there was no `.cancelAction` anywhere on
    /// the sheet, so a running download could not be dismissed even by Escape. It carries the
    /// shortcut now: Escape stops the install, the row goes back to buttons, and a second Escape
    /// closes the sheet. Two presses to leave, rather than a dialog that ignores the key.
    @ViewBuilder private func installProgress(_ progress: SelfUpdate.Progress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if model.installing {
                    // Past the last byte: hashing, mounting, checking the version, verifying
                    // the signature, copying. Indeterminate because none of it reports a
                    // fraction.
                    ProgressView().controlSize(.small)
                    Text("正在校验并安装…").font(.caption).foregroundStyle(.secondary)
                } else if let fraction = progress.fraction {
                    ProgressView(value: fraction).frame(maxWidth: .infinity)
                } else {
                    // No size to measure against at all — the release did not report one and
                    // neither did the response.
                    ProgressView().controlSize(.small)
                    Text("正在下载…").font(.caption).foregroundStyle(.secondary)
                }
                Button("取消") { model.cancelInstall() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            if !model.installing, progress.fraction != nil, let total = progress.total {
                Text("已下载 \(Self.size(progress.received)) / \(Self.size(total))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    /// "4.8 MB". `ByteCountFormatter`'s file style, which is what Finder shows.
    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
