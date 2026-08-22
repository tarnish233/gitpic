import AppKit
import SwiftUI
import GitPicCore

struct AboutPane: View {
    @Bindable var model: AppModel

    /// `nil` when there is no bundle to read it out of — a `swift run` build
    /// rather than a packaged `.app`. Kept optional rather than defaulted so the
    /// note below can tell "no bundle" apart from "the two really disagree";
    /// defaulting them to "dev"/"未知" made an ordinary dev run look like a
    /// mismatched build.
    private var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }
    private var embeddedCLI: String? {
        Bundle.main.infoDictionary?["GitPicEmbeddedCLIVersion"] as? String
    }

    /// The app's own icon, read back out of the bundle.
    ///
    /// `applicationIconName` rather than a resource of its own: the icon is compiled
    /// from `AppIcon.icon` by `actool` at build time (`scripts/build-app.sh`), so the
    /// bundle is the only place it exists and asking for it by name is what keeps
    /// this pane showing the *shipped* icon rather than a second copy that could
    /// drift. `nil` under `swift run`, where there is no bundle to read — the header
    /// then falls back to the name alone rather than to a placeholder box.
    private var appIcon: NSImage? {
        NSImage(named: NSImage.applicationIconName)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 14) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("GitPic")
                    .font(.title2.weight(.semibold))
                Text("把图片传到 GitHub 图床，拿回一条链接。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    var body: some View {
        Form {
            Section { header }
            // Both rows stay even though a real build always makes them agree: the
            // second is read back out of the bundle, so it is the only place that shows
            // what was *actually* packaged rather than what the build intended. Two
            // numbers that differ is the whole signal — the prose that used to spell out
            // each case said nothing the numbers do not.
            Section("版本") {
                LabeledContent("App") { Text(appVersion ?? "dev").monospacedDigit() }
                LabeledContent("gitpic_cli") { Text(embeddedCLI ?? "未知").monospacedDigit() }
            }
            Section("工具位置") {
                LabeledContent("gitpic") {
                    Text(model.tools?.gitpic.path ?? "未找到")
                        .font(.caption).textSelection(.enabled)
                }
                LabeledContent("gh") {
                    Text(model.tools?.gh?.path ?? "未找到")
                        .font(.caption).textSelection(.enabled)
                }
            }
            Section("项目") {
                Text("CLI 与 App 同仓库、同版本发布，凭据只经过 GitHub CLI，配置文件里不存任何密钥。")
                    .font(.caption).foregroundStyle(.secondary)
                Link("github.com/tarnish233/gitpic",
                     destination: URL(string: "https://github.com/tarnish233/gitpic")!)
                    .font(.caption)
            }
            Section("诊断") {
                LabeledContent("日志") {
                    Text(Diagnostics.logURL.path)
                        .font(.caption).textSelection(.enabled)
                }
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.logURL])
                }
                .controlSize(.small)
            }
        }
        .formChrome()
    }
}
