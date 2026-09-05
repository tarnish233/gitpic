import Foundation

extension CommandLineTool {
    // Framed output proves our command ran. Startup can exec another process before -c ever runs;
    // its exit status alone used to turn both that case and a transient write into success.
    static let fishResultOpen = "__gitpic_fish_result_7b91__"
    static let fishResultClose = "__gitpic_fish_end_7b91__"

    /// Persist first, then check both the saved value and the PATH of a *new* interactive login
    /// fish. Never use --no-config here: modern fish disables universal-variable persistence in
    /// that mode. Ordinary `fish -c` DOES read startup configuration, unlike the old comment.
    ///
    /// Cargo's `fish_add_path --global` is the measured failure. Merely adding --universal is
    /// insufficient: fish_add_path builds its new list from the visible (possibly global) value,
    /// which can overwrite a hidden, curated universal list. Erase ONLY the child's global shadow
    /// first; fish then updates the original universal list, preserving its entries and order.
    @discardableResult
    public static func configureFish(
        fish: URL,
        directory: URL = link.deletingLastPathComponent(),
        run: (URL, [String]) throws -> ProcessOutcome = runFish
    ) throws -> Configured {
        let written = try fishCommand(
            fish: fish, directory: directory, interactive: false,
            script: """
            set --erase --global fish_user_paths
            fish_add_path --universal -- "$argv[1]"
            set -l gitpic_result $status
            if test $gitpic_result -le 1
                set --query --universal fish_user_paths; and contains -- "$argv[1]" $fish_user_paths
                set gitpic_result $status
            end
            """, run: run)
        // fish_add_path returns 1 for an idempotent no-op as well as for a missing directory.
        // The script checks the resulting value instead of confusing those two outcomes.
        guard written == 0 else {
            throw fishFailure(fish, "未能保存安装目录。请检查目录是否存在及 fish 配置目录的写入权限。")
        }

        let verified = try fishCommand(
            fish: fish, directory: directory, interactive: true, allowedStatuses: [0, 1, 2],
            script: """
            contains -- "$argv[1]" $PATH
            set -l gitpic_result $status
            if test $gitpic_result -ne 0
                set gitpic_result 2
            end
            set --erase --global fish_user_paths
            if not set --query --universal fish_user_paths; or not contains -- "$argv[1]" $fish_user_paths
                set gitpic_result 1
            end
            """, run: run)
        switch verified {
        case 0:
            return .ranCommand("fish_add_path --universal -- \(directory.path)")
        case 1:
            throw fishFailure(fish, "新启动的 fish 没有读到持久配置。请检查 fish 配置目录的写入权限或启动配置。")
        case 2:
            throw fishFailure(fish, "已保存持久配置，但新启动的 fish 的 PATH 中仍没有安装目录。"
                + "请检查启动配置是否覆盖了 fish_user_paths 或 PATH；GitPic 没有改动启动文件。")
        default:
            throw fishFailure(fish, "验证返回了无法识别的状态 \(verified)。")
        }
    }

    /// PATH, not just fish_user_paths: an existing user configuration may already provide it.
    /// Probe a login AND interactive session so `status is-interactive` guards are exercised.
    public static func fishPathConfiguration(
        fish: URL,
        directory: URL = link.deletingLastPathComponent(),
        run: (URL, [String]) throws -> ProcessOutcome = runFish
    ) -> ShellConfiguration {
        do {
            let result = try fishCommand(
                fish: fish, directory: directory, interactive: true,
                script: """
                contains -- "$argv[1]" $PATH
                set -l gitpic_result $status
                """, run: run)
            switch result {
            case 0: return .configured
            case 1: return .notConfigured
            default: throw fishFailure(fish, "PATH 检查返回状态 \(result)。")
            }
        } catch let failure as Failure {
            return .unknown(reason: failure.message)
        } catch {
            return .unknown(reason: "无法检查 fish：\(error.localizedDescription)")
        }
    }

    /// Blocking by design, like ChildProcess: the app must call this on its probe queue.
    public static func runFish(_ executable: URL, _ args: [String]) throws -> ProcessOutcome {
        try ChildProcess.run(executable: executable, args: args, timeout: 8)
    }

    public static func locateFish(loginShell: URL?) -> URL? {
        if let loginShell, loginShell.lastPathComponent == "fish",
           FileManager.default.isExecutableFile(atPath: loginShell.path) { return loginShell }
        return ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/opt/local/bin/fish"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private static func fishCommand(
        fish: URL, directory: URL, interactive: Bool, allowedStatuses: Set<Int32> = [0, 1],
        script: String,
        run: (URL, [String]) throws -> ProcessOutcome
    ) throws -> Int32 {
        let framed = script + """

        builtin printf '\\n\(fishResultOpen)%s\(fishResultClose)\\n' $gitpic_result
        exit $gitpic_result
        """
        // Never interpolate a filesystem path into shell source. Spaces, quotes, semicolons,
        // dollar signs and parentheses in a home directory must remain one literal argument.
        let args = (interactive ? ["-l", "-i"] : [])
            + ["-c", framed, directory.standardizedFileURL.path]
        let out: ProcessOutcome
        do {
            out = try run(fish, args)
        } catch RunFailure.spawnFailed(let reason) {
            throw fishFailure(fish, "无法启动 fish：\(reason)")
        } catch {
            throw fishFailure(fish, "无法启动 fish：\(error.localizedDescription)")
        }
        if out.timedOut { throw fishFailure(fish, "fish 在 8 秒内没有完成操作，请检查启动配置是否卡住。") }
        let stdout = String(decoding: out.stdout, as: UTF8.self)
        guard let open = stdout.range(of: fishResultOpen, options: .backwards),
              let close = stdout.range(of: fishResultClose, range: open.upperBound..<stdout.endIndex),
              let result = Int32(stdout[open.upperBound..<close.lowerBound]),
              allowedStatuses.contains(result), result == out.status else {
            let stderr = String(decoding: out.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw fishFailure(fish, "fish 没有完成验证命令（退出状态 \(out.status)）。"
                + "请检查启动配置是否报错或提前退出。"
                + (stderr.isEmpty ? "" : "\n" + String(stderr.prefix(1200))))
        }
        return result
    }

    private static func fishFailure(_ fish: URL, _ reason: String) -> Failure {
        .fileSystem(operation: "配置或检查 fish 的 PATH", path: fish.path, reason: reason)
    }
}
