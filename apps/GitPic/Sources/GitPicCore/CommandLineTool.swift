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

    public enum Reach: Sendable, Equatable {
        case reachable
        case shadowed(by: URL)
        case notOnPath
        case unknown(reason: String)

        public var label: String {
            switch self {
            case .reachable:  "终端可直接使用"
            case .shadowed:   "另一个 gitpic 排在前面"
            case .notOnPath:  "安装目录不在 PATH 中"
            case .unknown:    "无法确认终端 PATH"
            }
        }

        public var detail: String {
            switch self {
            case .reachable:
                "登录 shell 会从 \(CommandLineTool.link.path) 找到 gitpic。"
            case .shadowed(let path):
                "登录 shell 现在会先运行：\(path.path)"
            case .notOnPath:
                "把 ~/.local/bin 加到登录 shell 的 PATH 后才能直接输入 gitpic。"
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
    }

    public enum Failure: Error, Sendable, Equatable {
        case executableMissing(path: String)
        case occupied(path: String)
        case pointsElsewhere(path: String, destination: String)
        case notOwned(path: String)
        case missingCompletion(shell: Shell)
        case emptyCompletion(shell: Shell)
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
    public static func reach(of link: URL, probe: ToolDiscovery.ShellProbe) -> Reach {
        if let path = probe.path {
            return samePath(path, link) ? .reachable : .shadowed(by: path)
        }
        if probe.conclusive { return .notOnPath }
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
