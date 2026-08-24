import AppKit
import SwiftUI
import GitPicCore

/// The image host: who the uploads go as, which repository they land in, and a
/// read-only connectivity test against both.
struct HostPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            account

            ConfigGate(model: model, repairs: true) { draft in
                Section("图床仓库") {
                    // Chosen, never typed. Typing `owner/name` only invited three
                    // failures the list rules out: a misspelling that surfaces as a bare
                    // 404, a repository the credential cannot reach, and a branch
                    // guessed as `main` when GitHub's default is `master`.
                    if case .loggedIn = model.auth {
                        repoPicker
                        branchPicker(draft.github.branch.wrappedValue)
                        // Below both rows, not between them: 仓库 and 分支 are one
                        // choice read two ways, and the notes above say "the button
                        // below".
                        Button("刷新仓库列表") {
                            Task {
                                await model.loadRepos()
                                await model.loadBranches()
                            }
                        }
                        .controlSize(.small)
                        .disabled(model.reposLoading || model.branchesLoading)
                    } else {
                        Text("登录后这里会列出可以上传的仓库。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                // No standing "这些还没写入配置文件，要按保存" note here. It restated the
                // toolbar: 保存 is present on every config pane whether or not anything is
                // dirty, and its tooltip already names the keys waiting to be written. The
                // one case where the instruction is genuinely needed — nothing configured
                // at all — still says it, in `unconfiguredHint` below. The same note's
                // other half, that picking a repository moves 分支 to that repository's
                // default, went with it: the picker above visibly changes when it happens.

                // An empty target is not self-explanatory, and it is reachable two
                // ways: a machine where nobody has picked a repository yet (a missing
                // file reads back as the CLI's defaults, not as an error), and one
                // that just used 备份并重建 above. Neither said what to do next, and
                // 保存 is no longer a button sitting at the bottom of the window where
                // an empty value could be seen next to it.
                if isUnconfigured(draft.wrappedValue) {
                    Section {
                        Label("还没配置图床", systemImage: "exclamationmark.circle")
                        Text(unconfiguredHint)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                // Only after a rebuild, and it outlives the failure that caused it on
                // purpose: `ConfigTrouble` disappears the moment the read succeeds, so
                // if this hint lived there the backup's name would vanish at exactly
                // the moment the user needs to go read values out of it.
                if let backup = model.configBackup {
                    Section {
                        Label("旧配置已备份", systemImage: "arrow.uturn.backward.circle")
                        Text("原文件是 \(backup.lastPathComponent)，就在同一个目录里。"
                             + "图床仓库要重新选一次，旧值可以从它里面查。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("在 Finder 中显示备份") {
                            NSWorkspace.shared.activateFileViewerSelecting([backup])
                        }
                        .controlSize(.small)
                    }
                }
            }

            connectivity
        }
        .formChrome()
        // Only when nothing is known yet. Every other transition — login, logout,
        // cancel — sets the state itself, and re-probing on each appearance would spend
        // a network round trip every time the user switches panes.
        .task {
            if case .unknown = model.auth { await model.refreshAuth() }
        }
    }

    // MARK: - Account

    @ViewBuilder
    private var account: some View {
        Section("账号") {
            switch model.auth {
            case .unknown, .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    // Two different waits, and telling them apart is the difference
                    // between "a second" and "something is wrong": discovery can shell
                    // out to a login shell for up to 8 s, and the window is up before
                    // it finishes.
                    Text(model.toolState == .resolving ? "正在查找 gitpic…" : "检查登录状态…")
                        .foregroundStyle(.secondary)
                }

            // No description under the label, deliberately. What was here was the CLI's
            // own `no GitHub credential: run \`gitpic auth login\`` — telling someone to
            // run a command while the button that does it sits directly below — plus a
            // paragraph about `public_repo` being enough for jsDelivr. The label says the
            // state and the button says the action; the scope is a fact about the login
            // this pane does not have to teach before performing it.
            //
            // The dropped `detail` cost nothing measurable: its only non-CLI value was
            // 「登录已取消」 from `cancelLogin()`, which that method already overwrites a
            // moment later by calling `refreshAuth()`, so it was a flash on the way to
            // the CLI's own answer rather than a message anyone could read.
            case .loggedOut:
                Label("还没登录", systemImage: "person.crop.circle.badge.questionmark")
                Button("使用 GitHub 登录") { model.beginLogin() }
                    .disabled(model.toolState != .ready)

            case let .awaitingCode(userCode, url):
                Label("在浏览器里输入这个码", systemImage: "keyboard")
                // Selectable and monospaced: the user has to retype it into a browser,
                // and a code they cannot copy is a code they will mistype.
                Text(userCode)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Text(url.absoluteString)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("打开浏览器") { NSWorkspace.shared.open(url) }
                    // Through the shared writer, which is the one that does not throw
                    // the result away.
                    Button("复制代码") {
                        if !Clipboard.write(userCode) {
                            model.notify(title: "写剪贴板失败",
                                         body: "一次性代码没有复制，请手动输入")
                        }
                    }
                    // Not cosmetic: cancelling terminates the CLI, which would
                    // otherwise keep polling GitHub until the code expires.
                    Button("取消") { model.cancelLogin() }
                }
                .controlSize(.small)

            case let .loggedIn(login, expiresAt):
                LabeledContent("已登录") {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(login ?? "—")
                    }
                }
                if let expiresAt {
                    // Normally absent — gitpic's own app has token expiration off — so
                    // when it does appear it is worth showing rather than hiding.
                    LabeledContent("过期时间") {
                        Text(expiresAt).font(.caption).foregroundStyle(.orange)
                    }
                }
                HStack {
                    Button("退出登录") { Task { await model.logout() } }
                    Button("重新登录") { model.beginLogin() }
                }
                .controlSize(.small)
                .disabled(model.loginInFlight)

            case .broken(let detail):
                Label("凭据有问题", systemImage: "exclamationmark.triangle.fill")
                Text(detail)
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                HStack {
                    Button("重新登录") { model.beginLogin() }
                    Button("再检查一次") { Task { await model.refreshAuth() } }
                }
                .controlSize(.small)
                .disabled(model.loginInFlight)
            }
        }
    }

    // MARK: - Repository picker

    @ViewBuilder
    private var repoPicker: some View {
        // `nil` stays representable, and it is not a "custom" option any more — it is
        // the state where the configured repository is not one the list contains: a
        // truncated listing, a repository whose access was revoked, or a config written
        // before this credential. Snapping the form onto whichever row happens to be
        // first would quietly retarget the uploads.
        let selection = Binding<RepoCandidate?>(
            get: { model.selectedRepo },
            set: { if let repo = $0 { model.chooseRepo(repo) } })

        Picker("仓库", selection: selection) {
            if model.selectedRepo == nil {
                Text(unmatchedLabel).tag(RepoCandidate?.none)
            }
            ForEach(model.repos) { repo in
                Text(label(for: repo)).tag(RepoCandidate?.some(repo))
            }
        }
        .disabled(model.repos.isEmpty)

        if let failure = model.reposFailure {
            Text("仓库列表读不到：\(failure)\n没有列表就没法选 —— "
                 + "确认网络后按下面的按钮重试，或者在终端跑 "
                 + "`gitpic config set github.repo owner/name`。")
                .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        } else if model.repos.isEmpty && !model.reposLoading {
            // Empty and "all private" look identical from here: a `public_repo` token
            // is not shown private repositories at all.
            Text("没有可以上传的仓库。图床是私有仓库的话，要用 "
                 + "`gitpic auth login --scope repo` 重新登录 —— "
                 + "默认的 public_repo 看不到私有仓库。")
                .font(.caption).foregroundStyle(.secondary)
        } else if let omitted = omittedNote {
            Text(omitted).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The branch picker.
    ///
    /// A list rather than a text field for the same reason the repository is: the
    /// Contents API writes into an *existing* ref and will not create one, so the set of
    /// values this may legally hold is exactly the repository's branches — and GitHub
    /// answers a missing ref with 404, indistinguishable from a missing repository. A
    /// typed branch name therefore fails in the one way that explains nothing.
    ///
    /// Takes the draft's branch as a parameter rather than reading it back out of the
    /// model, so the row still names the configured branch while a listing is in flight
    /// or after one failed — the value is what an upload will use either way.
    @ViewBuilder
    private func branchPicker(_ current: String) -> some View {
        // Only while the listing genuinely describes this repository. Otherwise the
        // previous repository's branches would be offered for as long as the new request
        // takes, and this picker writes whatever it is handed.
        if model.branchesMatchDraft, !model.branches.isEmpty {
            let selection = Binding<BranchCandidate?>(
                get: { model.selectedBranch },
                set: { if let branch = $0 { model.chooseBranch(branch) } })
            Picker("分支", selection: selection) {
                if model.selectedBranch == nil {
                    // A branch that is configured and no longer exists. Named rather
                    // than blanked: this is what every upload is currently targeting,
                    // and the user has to see it before replacing it.
                    Text("\(current)（不在列表中）").tag(BranchCandidate?.none)
                }
                ForEach(model.branches) { branch in
                    Text(branch.protected ? "\(branch.name)（受保护）" : branch.name)
                        .tag(BranchCandidate?.some(branch))
                }
            }
            if model.selectedBranch == nil {
                Text("配置里的 `\(current)` 不在这个仓库的分支里 —— 上传会撞上一个不存在的 ref。"
                     + "从上面选一个。")
                    .font(.caption).foregroundStyle(.orange)
            } else if !model.branchesComplete {
                Text("分支太多，列表被截断。要用没列出来的那个，在终端跑 "
                     + "`gitpic config set github.branch <名字>`。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            // No usable listing: still show what an upload will target, because that
            // fact does not depend on whether the list loaded.
            LabeledContent("分支") {
                Text(current).foregroundStyle(.secondary)
            }
            if let failure = model.branchesFailure {
                Text("分支列表读不到：\(failure)\n上传仍然会用 `\(current)`。"
                     + "确认网络后按下面的按钮重试。")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            } else if model.repositoryHasNoBranches {
                // Not a failure, and not something to fix: the Contents API creates the
                // ref on the first write. Said out loud because the row silently stops
                // being a picker otherwise, which reads like something went wrong.
                Text("这个仓库还没有 commit，所以没有分支可选。第一次上传会创建 `\(current)`。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.branchesLoading {
                Text("读取分支…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Why a repository the user expects might not be in the list.
    ///
    /// The only question a choose-only picker can leave someone stuck on, so both
    /// reasons are said rather than left to be guessed at.
    private var omittedNote: String? {
        var reasons: [String] = []
        if model.skippedRepos > 0 {
            reasons.append("\(model.skippedRepos) 个没有写权限")
        }
        if !model.reposComplete {
            reasons.append("仓库太多，列表被截断")
        }
        guard !reasons.isEmpty else { return nil }
        return "没列出来的：\(reasons.joined(separator: "；"))。"
    }

    /// What to call the configured repository when the list does not contain it.
    private var unmatchedLabel: String {
        if model.reposLoading { return "读取中…" }
        guard let github = model.draft?.github,
              !github.owner.isEmpty, !github.repo.isEmpty
        else { return "尚未选择" }
        // Named rather than blanked: this is a target that may well still work, and the
        // user has to be able to see what it is before replacing it.
        return "\(github.owner)/\(github.repo)（不在列表中）"
    }

    /// `owner/name`, plus the one remaining thing that changes how it behaves.
    private func label(for repo: RepoCandidate) -> String {
        // Read-only repositories are filtered out upstream, so the only mark left is
        // the one that changes which link form works: jsDelivr serves public
        // repositories only.
        repo.isPrivate ? "\(repo.spec)（私有）" : repo.spec
    }

    private var unconfiguredHint: String {
        if case .loggedIn = model.auth {
            return "在上面的下拉里选一个仓库，再按右上角的「保存」。"
        }
        return "先在上面登录 GitHub，登录后这里会列出可选的仓库。"
    }

    // MARK: - Connectivity

    @ViewBuilder
    private var connectivity: some View {
        Section("连通性") {
            // The button leads, and everything below it belongs to the button: the
            // report it produced, why it could not run, or — before it has been pressed
            // — what pressing it will do. Ordered this way because the three states are
            // mutually exclusive, so anything placed above the button would move it up
            // and down the pane as the state changed.
            Button("连通性测试") { Task { await model.runDoctor() } }
                .controlSize(.small)
                .disabled(model.busy || model.toolState != .ready)
            if let d = model.lastDoctor {
                LabeledContent("配置") { mark(d.configOK) }
                LabeledContent("凭据有效") { mark(d.tokenValid) }
                LabeledContent("仓库可写") { mark(d.repoWritable) }
                LabeledContent("分支保护") { Text(d.branchProtected == true ? "是" : "否") }
                LabeledContent("登录账号") { Text(d.login ?? "—").foregroundStyle(.secondary) }
                if let e = d.error {
                    Text("\(e.code)：\(e.message)")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else if let failure = model.doctorFailure {
                // The test could not be run at all — distinct from a report that
                // came back unhealthy, which is the branch above. This used to go
                // to the status line at the bottom of the window, two panes away
                // from the button that caused it.
                Text("测试没跑起来：\(failure)")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            } else {
                // Says what the button will do before it is pressed. The three
                // probes behind it are all GET (`/user`, the repo, the branch),
                // so this is safe to run against a real image host at any time.
                Text("测试只读取 GitHub 上的账号、仓库权限和分支，不会写入任何东西。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Whether this config could not upload anything yet.
    ///
    /// Either half missing is enough: `require_target` in `src/config.rs` refuses an
    /// empty owner and an empty repo alike, so a half-filled form is exactly as
    /// unusable as a blank one and must not look settled.
    private func isUnconfigured(_ c: GitpicConfig) -> Bool {
        c.github.owner.trimmingCharacters(in: .whitespaces).isEmpty
            || c.github.repo.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func mark(_ b: Bool?) -> some View {
        Group {
            switch b {
            case true:  Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case false: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case nil:   Text("—").foregroundStyle(.secondary)
            }
        }
    }
}
