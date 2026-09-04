import SwiftUI
import GitPicCore

/// What a new release says, and what to do about it.
///
/// A sheet rather than a pane, because it is about one moment: a version was found, here is
/// what is in it, do you want it. Raised by a *manual* check, and by 「查看更新内容」 for one
/// the daily check found — never by the daily check itself, which reports through
/// Notification Center instead of interrupting whatever the window was being used for.
struct UpdateSheet: View {
    @Bindable var model: AppModel
    let report: UpdateReport

    @State private var confirmingInstall = false

    /// The release notes, parsed once per report rather than once per redraw.
    ///
    /// `report.summary` rewrites the body, `UpdateReport.displayMarkdown` rewrites its headings
    /// and `AttributedString(markdown:)` parses the result — and every one of those used to run
    /// inside `body`, which SwiftUI re-evaluates on every observed change. A download emits
    /// hundreds of progress ticks for a five-megabyte image, so the notes were being re-parsed
    /// hundreds of times to produce a value that cannot have changed. `nil` only for the frames
    /// before the `.onChange` below has run, which ``notes`` covers by parsing inline.
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
        // Keyed on the report generation: a check that lands while this sheet is open replaces
        // the report the route was derived from, and notes must follow it without reparsing on
        // every download-progress redraw.
        .onChange(of: model.updateGeneration, initial: true) { _, _ in
            renderedNotes = Self.markdown(UpdateReport.displayMarkdown(report.summary))
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
                    case .selfInstall(let asset, _, _):
                        Button("下载并更新") { confirmingInstall = true }
                            .buttonStyle(.borderedProminent)
                        Text(Self.size(asset.size))
                            .font(.caption).foregroundStyle(.secondary)
                    case .unavailable, .none:
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
            if case .unavailable(let reason) = model.upgradePath {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                    Text("可以到发布页手动下载。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            }
        }
        .padding(16)
        .alert("下载并安装 GitPic \(report.latest)", isPresented: $confirmingInstall) {
            Button("下载并安装") { model.performUpgrade() }
            Button("取消", role: .cancel) {}
        } message: {
            // Everything that can go wrong happens while the window is still here.
            Text("会先下载并校验，全部通过之后才退出并替换，完成后自动重新打开——"
                 + "下载或校验失败的话什么都不会改动。\n\n"
                 + "替换那一步记录在 GitPic-update.log 里；万一失败，原来的版本仍然可用。\n\n"
                 + "校验使用 GitHub 为这个文件公布的 SHA-256。")
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
