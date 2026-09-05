import Darwin
import Foundation

/// The user-owned command-line entry point and shell completions installed by GitPic.app.
///
/// The app links the command instead of copying it, so an in-app update replaces the bundle
/// once and the terminal immediately runs the new embedded CLI. Every path-taking operation
/// accepts its paths explicitly so the ownership and replacement rules can be tested without
/// touching the real home directory.
public enum CommandLineTool {
    public static let link = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/gitpic")

    public enum Status: Sendable, Equatable {
        case notInstalled
        case linked
        case dangling(destination: URL)
        case pointsElsewhere(destination: URL)
        case occupied

        public var label: String {
            switch self {
            case .notInstalled:       "未安装"
            case .linked:             "已安装"
            case .dangling:           "链接已失效"
            case .pointsElsewhere:    "链接指向其他位置"
            case .occupied:           "安装位置已被文件占用"
            }
        }

        public var detail: String {
            switch self {
            case .notInstalled:
                "还没有创建命令行链接。"
            case .linked:
                "终端命令会运行当前 GitPic.app 内置的 gitpic。"
            case .dangling(let destination):
                "现有链接的目标不存在：\(destination.path)"
            case .pointsElsewhere(let destination):
                "现有链接指向：\(destination.path)"
            case .occupied:
                "这个位置是真实文件，不是 GitPic 创建的符号链接。"
            }
        }
    }

    /// Whether the command can be typed, **in one named shell**.
    ///
    /// The shell is part of every verdict rather than context the caller is trusted to remember.
    /// PATH is per-shell configuration, so "reachable" is only ever true of the shell that was
    /// asked: measured on the author's machine, where `$SHELL` is `/bin/zsh` and
    /// `~/.zshrc` exports `~/.local/bin`, while the fish used for actual work had never heard of
    /// that directory and `gitpic` was `Unknown command` there. A bare "终端可直接使用" was true
    /// and useless, which is the worst combination a status row can be.
    public enum Reach: Sendable, Equatable {
        case reachable(shell: URL)
        case shadowed(by: URL, shell: URL)
        case notOnPath(shell: URL)
        case unknown(reason: String)

        /// The shell this verdict is about, if it is about one.
        public var shell: URL? {
            switch self {
            case .reachable(let shell), .notOnPath(let shell): shell
            case .shadowed(_, let shell): shell
            case .unknown: nil
            }
        }

        public var label: String {
            switch self {
            case .reachable(let shell):  "在 \(shell.lastPathComponent) 中可直接使用"
            case .shadowed:              "另一个 gitpic 排在前面"
            case .notOnPath(let shell):  "安装目录不在 \(shell.lastPathComponent) 的 PATH 中"
            case .unknown:               "无法确认终端 PATH"
            }
        }

        public var detail: String {
            switch self {
            case .reachable(let shell):
                "\(shell.path) 会从 \(CommandLineTool.link.path) 找到 gitpic。"
                    + "其他 shell 有各自的 PATH 配置，不受这一条影响。"
            case .shadowed(let path, let shell):
                "\(shell.path) 现在会先运行：\(path.path)"
            case .notOnPath(let shell):
                "把 ~/.local/bin 加到 \(shell.lastPathComponent) 的 PATH 后才能直接输入 gitpic。"
            case .unknown(let reason):
                reason
            }
        }
    }

    public struct SetUp: Sendable, Equatable {
        public let lines: [String]
        public let file: String
        public let why: String

        public init(lines: [String], file: String, why: String) {
            self.lines = lines
            self.file = file
            self.why = why
        }
    }

    /// A delimited region of a shell startup file that GitPic owns and nothing else may occupy.
    ///
    /// **This replaces a flat refusal to touch startup files, and the refusal was the weaker
    /// policy.** The app used to print the lines and let the user paste them, enforced by a source
    /// scan asserting no writer existed. The intent behind that rule was "never change someone's
    /// shell configuration behind their back" — but "do nothing" is only one way to satisfy it, and
    /// it satisfied it by handing every user three blocks of manual instructions, one per shell.
    /// An explicit button, a preview of the exact text, a backup of the file as it was before
    /// GitPic ever touched it, and a removal that puts it back, serve the same intent and actually
    /// finish the job. rustup, conda and nvm all take this shape.
    ///
    /// What the app promises instead, and what the tests hold it to:
    ///
    /// - Every byte outside the markers is preserved exactly, including a file with no trailing
    ///   newline and a file whose content sits *after* the block.
    /// - Writing twice replaces the block rather than appending a second one.
    /// - Removal leaves the file byte-identical to what it was before the block existed.
    /// - The first write backs the file up to `<name>.gitpic.bak`, so "before GitPic" is always
    ///   recoverable even if the block is later edited by hand.
    ///
    /// The markers are the whole mechanism, so they are ordinary comments in every shell this
    /// writes for and are matched as whole lines — a marker mentioned inside a heredoc or a string
    /// on a longer line is not a marker.
    public enum ManagedBlock {
        public static let begin = "# >>> gitpic >>>"
        public static let end = "# <<< gitpic <<<"

        /// The line indices of an existing block, markers included, or `nil`.
        ///
        /// Takes the *first* `begin` and the first `end` after it. A file carrying two blocks is
        /// already damaged; touching only the first is the repair that loses least, and the second
        /// stays visible to the reader instead of being silently swallowed.
        static func range(in lines: [String]) -> ClosedRange<Int>? {
            guard let start = lines.firstIndex(where: { $0.trimmed == begin }) else { return nil }
            guard let end = lines[start...].firstIndex(where: { $0.trimmed == Self.end })
            else { return nil }
            return start...end
        }

        public static func present(in text: String) -> Bool {
            range(in: text.splitLines().body) != nil
        }

        /// `text` with `lines` as the block: replacing one that is there, else appended.
        public static func applying(_ lines: [String], to text: String) -> String {
            let split = text.splitLines()
            var body = split.body
            let block = [begin] + lines + [end]
            if let existing = range(in: body) {
                body.replaceSubrange(existing, with: block)
            } else {
                // **Exactly one blank line before an appended block, always — unless the file is
                // empty.** Skipping it when the file already ended blank felt tidier and broke the
                // round trip: `removing` eats one preceding blank unconditionally, so a file ending
                // in a blank line came back one line shorter than it went in. The two have to agree
                // about who owns that line, and "the block always brings its own" is the version
                // that needs no lookahead. Measured by `roundTrip` over a file ending "a\nb\n\n".
                body += (body.isEmpty ? [] : [""]) + block
            }
            return split.rejoin(body)
        }

        /// `text` with the block gone and nothing else altered.
        ///
        /// The blank line `applying` inserted before the block goes with it, so writing and then
        /// removing is a round trip rather than a slow accumulation of empty lines.
        public static func removing(from text: String) -> String {
            let split = text.splitLines()
            var body = split.body
            guard var existing = range(in: body) else { return text }
            if existing.lowerBound > 0, body[existing.lowerBound - 1].trimmed.isEmpty {
                existing = (existing.lowerBound - 1)...existing.upperBound
            }
            body.removeSubrange(existing)
            return split.rejoin(body)
        }
    }

    /// A file's lines plus whether it ended with a newline, so a rejoin is byte-exact.
    ///
    /// Carrying the final-newline flag is what makes `removing(from: applying(x)) == x` hold for a
    /// file that does not end in one — which is not a curiosity: a hand-edited `.zshrc` saved by an
    /// editor that does not add the final newline is exactly the file this must not corrupt.
    struct LineSplit {
        let body: [String]
        let endedWithNewline: Bool

        func rejoin(_ lines: [String]) -> String {
            if lines.isEmpty { return "" }
            let joined = lines.joined(separator: "\n")
            return endedWithNewline ? joined + "\n" : joined
        }
    }

    /// The three completion formats the app owns. This intentionally does not mirror every
    /// shell clap supports; these are the formats with conventional per-user autoload paths.
    public enum Shell: String, CaseIterable, Sendable, Hashable {
        case bash
        case zsh
        case fish

        public func completionURL(home: URL) -> URL {
            switch self {
            case .bash:
                // Do not consult XDG_DATA_HOME here. A Finder-launched app does not inherit it,
                // so doing so would write to ~/.local/share while the user's terminal reads
                // somewhere else. This is bash-completion's own fallback path.
                home.appendingPathComponent(".local/share/bash-completion/completions/gitpic")
            case .zsh:
                home.appendingPathComponent(".zfunc/_gitpic")
            case .fish:
                home.appendingPathComponent(".config/fish/completions/gitpic.fish")
            }
        }

        /// Whether this shell configures PATH by a file the app can manage, or by a command.
        ///
        /// fish is the odd one and it is the *better* one: `fish_add_path` records a universal
        /// variable, so nothing has to be appended to a startup file at all and running it twice
        /// changes nothing. zsh and bash have no equivalent — PATH there comes from a startup file
        /// or from nowhere — which is why those two get a managed block.
        public var startupFile: String? {
            switch self {
            case .zsh:  ".zshrc"
            case .bash: ".bash_profile"
            case .fish: nil
            }
        }

        public func startupFileURL(home: URL) -> URL? {
            startupFile.map(home.appendingPathComponent)
        }

        /// What GitPic writes between its markers for this shell.
        ///
        /// `needsPath` is false when the directory is already on that shell's PATH by some other
        /// route, so the block does not add a duplicate entry to a PATH the user already curated.
        ///
        /// **zsh gets a `compdef` branch rather than a second `compinit`.** The block is appended,
        /// so it lands *after* whatever a plugin manager did — and oh-my-zsh runs `compinit` at
        /// `.zshrc:83` on the author's machine, long before the end of the file. Adding `~/.zfunc`
        /// to `fpath` there is too late to be scanned. Re-running `compinit` does work and is what
        /// the old manual instructions told people to paste, at the cost of a second full scan of
        /// every directory in `fpath` on each shell start. Registering just this one completion
        /// when `compdef` already exists costs nothing and is measured to work; the `compinit`
        /// branch remains for a bare zsh where nothing has run it.
        public func managedLines(needsPath: Bool) -> [String] {
            let path = needsPath ? ["export PATH=\"$HOME/.local/bin:$PATH\""] : []
            switch self {
            case .zsh:
                return path + [
                    "fpath=(~/.zfunc $fpath)",
                    "if (( $+functions[compdef] )); then",
                    "  autoload -Uz _gitpic && compdef _gitpic gitpic",
                    "else",
                    "  autoload -Uz compinit && compinit",
                    "fi",
                ]
            case .bash:
                // bash-completion v2 autoloads from this directory on demand, but only once it has
                // itself been sourced — macOS ships bash 3.2 with no bash-completion at all, so the
                // guard is what keeps this line harmless on a machine that never installed it.
                return path + [
                    "[[ -r \"$HOME/.local/share/bash-completion/completions/gitpic\" ]] &&",
                    "  . \"$HOME/.local/share/bash-completion/completions/gitpic\"",
                ]
            case .fish:
                return path
            }
        }

        /// Shell startup edits the user must make themselves. GitPic never writes an rc file.
        public var setUp: SetUp? {
            switch self {
            case .zsh:
                SetUp(
                    lines: [
                        "fpath=(~/.zfunc $fpath)",
                        "autoload -Uz compinit && compinit",
                    ],
                    file: "~/.zshrc",
                    why: "zsh 只会从 fpath 加载补全；把 ~/.zfunc 加进去后才能找到 _gitpic。")
            case .bash, .fish:
                nil
            }
        }

        /// How to put `~/.local/bin` on *this* shell's PATH.
        ///
        /// Separate from ``setUp``, which is about loading completions, because the two are
        /// independent and conflating them hid a real gap: fish needs no completion setup at all
        /// and so returned `nil`, while its PATH is configured entirely separately from every
        /// other shell's — a fish user reading "no setup needed" got a command they could not run.
        ///
        /// fish gets `fish_add_path` rather than a `config.fish` line because it sets a universal
        /// variable, so it persists without editing a file and without being applied twice. It
        /// needs fish 3.2 or newer; older fish wants `set -U fish_user_paths ~/.local/bin
        /// $fish_user_paths`, which is not offered here because the line that works on a current
        /// fish is the one worth putting in front of somebody.
        public var pathSetUp: SetUp {
            switch self {
            case .zsh:
                SetUp(
                    lines: ["export PATH=\"$HOME/.local/bin:$PATH\""],
                    file: "~/.zshrc",
                    why: "zsh 交互式启动只读 ~/.zshrc。")
            case .bash:
                SetUp(
                    lines: ["export PATH=\"$HOME/.local/bin:$PATH\""],
                    file: "~/.bash_profile",
                    why: "bash 登录时读 ~/.bash_profile。")
            case .fish:
                SetUp(
                    lines: ["fish_add_path ~/.local/bin"],
                    file: "（不用改文件，运行一次即可）",
                    why: "fish 不读其他 shell 的配置；fish_add_path 写的是 universal 变量，跨会话持久。")
            }
        }

        /// Whether this shell looks like one the person actually uses, judged only from files.
        ///
        /// Deliberately a file check and not a probe. The reason to look at all is that PATH is
        /// per-shell, so the app has to say *something* about shells it did not measure — and
        /// spawning each of them costs up to 8 seconds apiece for an answer nobody asked for.
        /// What this cannot tell is whether that shell's PATH is *already* right, so what it
        /// feeds is a statement of fact ("this shell configures PATH separately, here is its
        /// line"), never a warning that something is wrong.
        public func looksInUse(home: URL) -> Bool {
            let candidates: [String]
            switch self {
            case .zsh:  candidates = [".zshrc", ".zprofile"]
            case .bash: candidates = [".bash_profile", ".bashrc"]
            case .fish: candidates = [".config/fish"]
            }
            return candidates.contains {
                FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path)
            }
        }

        /// The shell whose name is `path`'s last component, if it is one of ours.
        public static func named(_ path: URL) -> Shell? {
            Shell(rawValue: path.lastPathComponent)
        }
    }

    /// Shells that look in use, are not the one already measured, and therefore need their own
    /// PATH entry — each with the line that adds it.
    ///
    /// `measured` is skipped because its verdict is on screen already; a second line telling the
    /// user to configure the shell just reported as working is noise. A shell this does not
    /// recognise (`nu`, `elvish`, a login shell at an unusual path) yields nothing rather than a
    /// guess: the app installs completions for three shells and speaks about those three.
    public static func otherShellsNeedingPath(
        measured: URL?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [(shell: Shell, setUp: SetUp)] {
        let already = measured.flatMap(Shell.named)
        return Shell.allCases
            .filter { $0 != already && $0.looksInUse(home: home) }
            .map { ($0, $0.pathSetUp) }
    }

    public enum Failure: Error, Sendable, Equatable {
        case executableMissing(path: String)
        case occupied(path: String)
        case pointsElsewhere(path: String, destination: String)
        case notOwned(path: String)
        case missingCompletion(shell: Shell)
        case emptyCompletion(shell: Shell)
        /// A shell whose PATH is not configured by a file the app can write.
        case notFileConfigured(shell: Shell)
        case fileSystem(operation: String, path: String, reason: String)

        public var message: String {
            switch self {
            case .executableMissing(let path):
                "找不到可执行的内置 gitpic：\(path)"
            case .occupied(let path):
                "不会覆盖 \(path)：那里是真实文件，不是符号链接。"
            case .pointsElsewhere(let path, let destination):
                "不会改写 \(path)：它现在指向 \(destination)。"
            case .notOwned(let path):
                "不会移除 \(path)：它不是指向当前 GitPic.app 的链接。"
            case .missingCompletion(let shell):
                "缺少 \(shell.rawValue) 补全文本，什么都没有移除。"
            case .emptyCompletion(let shell):
                "gitpic 没有生成 \(shell.rawValue) 补全，什么都没有写入。"
            case .notFileConfigured(let shell):
                "\(shell.rawValue) 的 PATH 不是由启动文件配置的，没有可写入的块。"
            case .fileSystem(let operation, let path, let reason):
                "\(operation)失败（\(path)）：\(reason)"
            }
        }
    }

    public enum CompletionRemoval: Sendable, Equatable {
        case absent
        case removed
        case preserved
    }

    public struct Removal: Sendable, Equatable {
        public let linkRemoved: Bool
        public let completions: [Shell: CompletionRemoval]

        public var preserved: [Shell] {
            Shell.allCases.filter { completions[$0] == .preserved }
        }
    }

    /// Inspect the link itself with `lstat`, then inspect its destination separately.
    /// `FileManager.fileExists` alone follows a symlink and cannot distinguish a missing link
    /// from a dangling one.
    public static func status(of link: URL, expecting executable: URL) -> Status {
        switch isSymbolicLink(link) {
        case nil:
            return .notInstalled
        case false:
            return .occupied
        case true:
            break
        }
        guard let written = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        else { return .occupied }

        let destination = resolvedDestination(written, from: link)
        if samePath(destination, executable) {
            return FileManager.default.isExecutableFile(atPath: executable.path)
                ? .linked
                : .dangling(destination: destination)
        }
        return FileManager.default.fileExists(atPath: destination.path)
            ? .pointsElsewhere(destination: destination)
            : .dangling(destination: destination)
    }

    /// Interpret one login-shell probe without resolving the path it printed. The unresolved
    /// path is the fact that matters: it says which PATH entry wins, including a symlink.
    /// What configuring one shell did.
    public enum Configured: Sendable, Equatable {
        /// The block was written or rewritten.
        case wrote(file: String, lines: [String])
        /// Already exactly right; nothing was touched.
        case unchanged(file: String)
        /// fish takes a command instead of a file.
        case ranCommand(String)
    }

    /// Write GitPic's managed block into one shell's startup file, backing the file up first.
    ///
    /// The backup is written **only when there was no block yet**, so `<name>.gitpic.bak` always
    /// means "this file before GitPic ever touched it" — the version worth having. Backing up on
    /// every write would overwrite that with a copy that already contains our block, which is the
    /// one state a backup is useless in.
    ///
    /// The write itself is atomic, so an interrupted save cannot leave a half-written `.zshrc` —
    /// a file that would break every new shell the user opens, including the one they would need
    /// to repair it.
    @discardableResult
    public static func configure(
        _ shell: Shell,
        needsPath: Bool,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Configured {
        guard let file = shell.startupFileURL(home: home), let name = shell.startupFile else {
            throw Failure.notFileConfigured(shell: shell)
        }
        let lines = shell.managedLines(needsPath: needsPath)
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let updated = ManagedBlock.applying(lines, to: existing)
        if updated == existing { return .unchanged(file: name) }

        do {
            if !ManagedBlock.present(in: existing),
               FileManager.default.fileExists(atPath: file.path) {
                let backup = file.appendingPathExtension("gitpic.bak")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try Data(existing.utf8).write(to: backup, options: .atomic)
                }
            }
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(updated.utf8).write(to: file, options: .atomic)
        } catch {
            throw fileFailure("写入 \(name)", at: file, error: error)
        }
        return .wrote(file: name, lines: lines)
    }

    /// Take GitPic's block back out of one shell's startup file, leaving everything else alone.
    ///
    /// The backup is deliberately *not* deleted. It is the only copy of the file from before the
    /// app touched it, and a removal is exactly when someone might want it.
    @discardableResult
    public static func unconfigure(
        _ shell: Shell,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Bool {
        guard let file = shell.startupFileURL(home: home), let name = shell.startupFile,
              let existing = try? String(contentsOf: file, encoding: .utf8),
              ManagedBlock.present(in: existing)
        else { return false }
        do {
            try Data(ManagedBlock.removing(from: existing).utf8).write(to: file, options: .atomic)
        } catch {
            throw fileFailure("清理 \(name)", at: file, error: error)
        }
        return true
    }

    /// Whether GitPic's block is currently in this shell's startup file.
    public static func isConfigured(
        _ shell: Shell,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard let file = shell.startupFileURL(home: home),
              let text = try? String(contentsOf: file, encoding: .utf8)
        else { return false }
        return ManagedBlock.present(in: text)
    }

    /// Whether this shell's own startup files already put the install directory on PATH.
    ///
    /// A text search, not a probe: the question is only "would adding our line create a duplicate",
    /// and for that a mention is enough evidence. Getting it wrong in either direction is cheap —
    /// a missed mention adds a redundant PATH entry, a false one omits a line the user can still
    /// add — whereas asking each shell costs up to 8 seconds apiece.
    ///
    /// Every file that shell reads is searched, not just the one the block goes in: the author's
    /// own `~/.local/bin` export sits in `.zshrc` while Homebrew's `PATH` arrives from `.zprofile`,
    /// and a block written to `.zshrc` that ignored `.zprofile` would duplicate whatever lives
    /// there.
    public static func pathAlreadyConfigured(
        _ shell: Shell,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let files: [String]
        switch shell {
        case .zsh:  files = [".zshrc", ".zprofile", ".zshenv"]
        case .bash: files = [".bash_profile", ".bashrc", ".profile"]
        case .fish: files = [".config/fish/config.fish"]
        }
        return files.contains { name in
            guard let text = try? String(
                contentsOf: home.appendingPathComponent(name), encoding: .utf8)
            else { return false }
            // Outside our own block: a mention *inside* it is this app's work, not the user's, so
            // counting it would make a rewrite decide the line is no longer needed and drop it.
            return ManagedBlock.removing(from: text).contains(".local/bin")
        }
    }

    /// Ask fish to record the install directory, using fish's own idempotent API.
    ///
    /// `fish_add_path` writes a *universal variable*, so nothing is appended to a startup file and
    /// running it twice changes nothing — which is why fish needs no managed block and gets a
    /// button that simply works. `run` is injected so the decision and the spawn can be tested
    /// apart, the same seam `install(rename:)` uses.
    @discardableResult
    public static func configureFish(
        fish: URL,
        directory: URL = link.deletingLastPathComponent(),
        run: (URL, [String]) throws -> Int32 = defaultRun
    ) throws -> Configured {
        let command = "fish_add_path \(directory.path)"
        let status = try run(fish, ["-c", command])
        guard status == 0 else {
            throw Failure.fileSystem(
                operation: "配置 fish 的 PATH", path: fish.path,
                reason: "fish 以状态 \(status) 退出")
        }
        return .ranCommand(command)
    }

    /// Whether fish's universal variables already carry the install directory.
    public static func fishPathConfigured(
        fish: URL,
        directory: URL = link.deletingLastPathComponent(),
        run: (URL, [String]) throws -> Int32 = defaultRun
    ) -> Bool {
        let probe = "contains \(directory.path) $fish_user_paths"
        return (try? run(fish, ["-c", probe])) == 0
    }

    /// Where fish is, if it is anywhere the app can find without a shell.
    ///
    /// The two Homebrew prefixes and `/usr/local/bin` — fish is not shipped with macOS, so a
    /// package manager put it there. Falls back to the login shell when that is fish itself.
    public static func locateFish(loginShell: URL?) -> URL? {
        if let loginShell, loginShell.lastPathComponent == "fish" { return loginShell }
        return ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/opt/local/bin/fish"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public static func defaultRun(_ executable: URL, _ args: [String]) throws -> Int32 {
        try ChildProcess.run(executable: executable, args: args, timeout: 8).status
    }

    public static func reach(of link: URL, probe: ToolDiscovery.ShellProbe) -> Reach {
        // A probe that cannot even name the shell it asked has nothing to attribute a verdict to,
        // so it is `unknown` regardless of what it found.
        guard let shell = probe.shell else {
            return .unknown(reason: probe.reason ?? "无法确定登录 shell。")
        }
        if let path = probe.path {
            return samePath(path, link) ? .reachable(shell: shell) : .shadowed(by: path, shell: shell)
        }
        if probe.conclusive { return .notOnPath(shell: shell) }
        return .unknown(reason: probe.reason ?? "登录 shell 没有给出可判断的结果。")
    }

    /// Atomically install or replace the command-line link.
    public static func install(
        at link: URL = link,
        pointingTo executable: URL,
        replacing: Bool = false
    ) throws {
        try install(at: link, pointingTo: executable, replacing: replacing,
                    rename: atomicRename)
    }

    /// Internal seam used to assert that the old entry still exists until `rename(2)` runs.
    static func install(
        at link: URL,
        pointingTo executable: URL,
        replacing: Bool,
        rename: (URL, URL) throws -> Void
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Failure.executableMissing(path: executable.path)
        }

        switch status(of: link, expecting: executable) {
        case .linked:
            return
        case .occupied where !replacing:
            throw Failure.occupied(path: link.path)
        case .pointsElsewhere(let destination) where !replacing:
            throw Failure.pointsElsewhere(path: link.path, destination: destination.path)
        case .notInstalled, .dangling, .occupied, .pointsElsewhere:
            break
        }

        let directory = link.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw fileFailure("创建命令目录", at: directory, error: error)
        }

        let temporary = directory.appendingPathComponent(".gitpic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createSymbolicLink(
                at: temporary, withDestinationURL: executable)
        } catch {
            throw fileFailure("创建临时命令链接", at: temporary, error: error)
        }
        try rename(temporary, link)
    }

    public static func writeCompletion(
        _ contents: Data,
        for shell: Shell,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        guard !contents.isEmpty else { throw Failure.emptyCompletion(shell: shell) }
        let destination = shell.completionURL(home: home)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: destination, options: .atomic)
        } catch {
            throw fileFailure("写入 \(shell.rawValue) 补全", at: destination, error: error)
        }
    }

    public static func completionsExist(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        Shell.allCases.allSatisfy {
            FileManager.default.isReadableFile(atPath: $0.completionURL(home: home).path)
        }
    }

    public static func completionMatches(
        _ contents: Data,
        for shell: Shell,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        (try? Data(contentsOf: shell.completionURL(home: home))) == contents
    }

    /// Remove the command link and only those completion files that still match what the app
    /// generates. A user-edited completion is left in place and reported as preserved.
    public static func remove(
        at link: URL = link,
        expecting executable: URL,
        completions: [Shell: Data],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Removal {
        for shell in Shell.allCases where completions[shell] == nil {
            throw Failure.missingCompletion(shell: shell)
        }

        let linkRemoved: Bool
        switch status(of: link, expecting: executable) {
        case .linked:
            do {
                try FileManager.default.removeItem(at: link)
                linkRemoved = true
            } catch {
                throw fileFailure("移除命令行链接", at: link, error: error)
            }
        case .notInstalled:
            linkRemoved = false
        case .dangling, .pointsElsewhere, .occupied:
            throw Failure.notOwned(path: link.path)
        }

        var actions: [Shell: CompletionRemoval] = [:]
        for shell in Shell.allCases {
            let destination = shell.completionURL(home: home)
            guard FileManager.default.fileExists(atPath: destination.path) else {
                actions[shell] = .absent
                continue
            }
            guard let generated = completions[shell],
                  completionMatches(generated, for: shell, home: home)
            else {
                actions[shell] = .preserved
                continue
            }
            do {
                try FileManager.default.removeItem(at: destination)
                actions[shell] = .removed
            } catch {
                throw fileFailure("移除 \(shell.rawValue) 补全", at: destination, error: error)
            }
        }
        return Removal(linkRemoved: linkRemoved, completions: actions)
    }

    private static func resolvedDestination(_ written: String, from link: URL) -> URL {
        let url = written.hasPrefix("/")
            ? URL(fileURLWithPath: written)
            : URL(fileURLWithPath: written, relativeTo: link.deletingLastPathComponent())
        return url.standardizedFileURL
    }

    private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    /// `nil` means no directory entry, `true` a symlink, `false` anything else or an error
    /// that must be treated conservatively as occupied.
    private static func isSymbolicLink(_ url: URL) -> Bool? {
        var information = stat()
        let result = url.path.withCString { Darwin.lstat($0, &information) }
        if result == 0 { return information.st_mode & S_IFMT == S_IFLNK }
        return errno == ENOENT ? nil : false
    }

    private static func atomicRename(_ source: URL, _ destination: URL) throws {
        let result = source.path.withCString { old in
            destination.path.withCString { new in Darwin.rename(old, new) }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            throw Failure.fileSystem(
                operation: "安装命令行链接", path: destination.path, reason: reason)
        }
    }

    private static func fileFailure(_ operation: String, at url: URL, error: Error) -> Failure {
        .fileSystem(
            operation: operation,
            path: url.path,
            reason: (error as NSError).localizedDescription)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }

    /// Split for editing while keeping enough to put the file back exactly.
    ///
    /// An empty file yields no lines rather than one empty line, so appending a block to it does
    /// not produce a leading blank.
    func splitLines() -> CommandLineTool.LineSplit {
        let ended = hasSuffix("\n")
        var body = components(separatedBy: "\n")
        if ended { body.removeLast() }
        // Only a genuinely empty string has no lines. `"\n"` has one empty line, and collapsing
        // the two together lost the difference — a file holding a single newline came back empty.
        if isEmpty { body = [] }
        return CommandLineTool.LineSplit(body: body, endedWithNewline: ended)
    }
}
