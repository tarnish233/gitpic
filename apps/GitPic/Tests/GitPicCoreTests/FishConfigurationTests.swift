import Foundation
import Testing
@testable import GitPicCore

/// Real fish, isolated HOME/XDG directories and a Finder-like PATH. A mock that returned 0 for
/// `fish_add_path` was all 0.21.3 tested; it could not see that the write died with the process.
@Suite("Fish configuration", .enabled(if: CommandLineTool.locateFish(loginShell: nil) != nil))
struct FishConfigurationTests {
    @Test("Cargo's global fish_user_paths does not swallow the persistent write")
    func cargoGlobalScope() throws {
        let fixture = try FishFixture()
        defer { fixture.remove() }
        let startup = "fish_add_path --global --prepend \"$HOME/.cargo/bin\"\n"
        try fixture.startup(startup)
        #expect(fixture.configuration() == .notConfigured)

        try fixture.configure()

        #expect(fixture.configuration() == .configured)
        let fresh = try fixture.run(fixture.fish, ["-l", "-i", "-c",
            "contains -- $argv[1] $PATH", fixture.directory.path])
        #expect(fresh.status == 0, "the write must survive the process that performed it")
        #expect(try fixture.persistedPaths() == [fixture.directory.path],
                "Cargo's temporary entry must not be copied into the universal store")
        #expect(try String(contentsOf: fixture.startupFile, encoding: .utf8) == startup)
    }

    @Test("the manual fish instructions preserve hidden universal entries too")
    func manualInstructions() throws {
        let fixture = try FishFixture()
        defer { fixture.remove() }
        let seed = try fixture.run(fixture.fish, ["-c", "set --universal fish_user_paths /usr/bin /bin"])
        try #require(seed.status == 0)
        try fixture.startup("set --global fish_user_paths \"$HOME/.cargo/bin\"\n")
        var environment = fixture.environment
        environment["PATH"] = fixture.fish.deletingLastPathComponent().path + ":/usr/bin:/bin"
        let script = CommandLineTool.Shell.fish.pathSetUp.lines.joined(separator: "\n")
        for _ in 0..<2 {
            let out = try ChildProcess.run(executable: fixture.fish, args: ["-c", script],
                                           environment: environment, timeout: 8)
            #expect(out.status == 0)
        }
        #expect(try fixture.persistedPaths() == [fixture.directory.path, "/usr/bin", "/bin"])
    }

    @Test("repeated configuration is a successful no-op preserving the universal list")
    func idempotent() throws {
        let fixture = try FishFixture()
        defer { fixture.remove() }
        let seed = try fixture.run(fixture.fish, ["-c", "set --universal fish_user_paths /usr/bin /bin"])
        try #require(seed.status == 0)
        try fixture.configure()
        let variables = fixture.home.appendingPathComponent(".config/fish/fish_variables")
        let once = try Data(contentsOf: variables)

        try fixture.configure()

        #expect(try Data(contentsOf: variables) == once)
        #expect(try fixture.persistedPaths() == [fixture.directory.path, "/usr/bin", "/bin"])
        #expect(fixture.configuration() == .configured)
    }

    @Test("a global shadow cannot overwrite hidden universal entries or fake success")
    func preservesHiddenUniversalPaths() throws {
        let fixture = try FishFixture()
        defer { fixture.remove() }
        let seed = try fixture.run(fixture.fish, ["-c", "set --universal fish_user_paths /usr/bin /bin"])
        try #require(seed.status == 0)
        let startup = "set --global fish_user_paths \"$HOME/.cargo/bin\"\n"
        try fixture.startup(startup)

        #expect(throws: CommandLineTool.Failure.self) { try fixture.configure() }

        #expect(try fixture.persistedPaths() == [fixture.directory.path, "/usr/bin", "/bin"])
        #expect(fixture.configuration() == .notConfigured,
                "the fresh shell's global assignment still shadows the persisted directory")
        #expect(try String(contentsOf: fixture.startupFile, encoding: .utf8) == startup)
    }

    @Test("existing interactive PATH configuration is recognized without fish_user_paths")
    func existingInteractivePath() throws {
        let fixture = try FishFixture()
        defer { fixture.remove() }
        try fixture.startup("""
        if status is-interactive
            set --global --export PATH "$HOME/.local/bin" $PATH
        end
        """)
        #expect(fixture.configuration() == .configured)
        #expect(try fixture.persistedPaths().isEmpty)
    }

    @Test("verification catches a login-interactive startup that overwrites PATH")
    func interactiveOverride() throws {
        let fixture = try FishFixture()
        defer { fixture.remove() }
        try fixture.startup("""
        if status is-login; and status is-interactive
            set --global --export PATH /usr/bin /bin /usr/sbin /sbin
        end
        """)
        do {
            try fixture.configure()
            Issue.record("a persisted but unreachable path was reported as configured")
        } catch let failure as CommandLineTool.Failure {
            #expect(failure.message.contains("覆盖"))
        }
        #expect(try fixture.persistedPaths() == [fixture.directory.path])
        #expect(fixture.configuration() == .notConfigured)
    }

    @Test("filesystem paths stay literal arguments, including shell metacharacters")
    func literalPath() throws {
        let fixture = try FishFixture(directoryName: "space ' \" $HOME; (false) [x]")
        defer { fixture.remove() }
        try fixture.configure()
        #expect(fixture.configuration() == .configured)
        #expect(try fixture.persistedPaths() == [fixture.directory.path])
    }

    @Test("a missing directory is not a successful fish_add_path no-op")
    func missingDirectory() throws {
        let fixture = try FishFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.directory)
        #expect(throws: CommandLineTool.Failure.self) { try fixture.configure() }
        #expect(fixture.configuration() == .notConfigured)
    }

    @Test("a function returning zero without saving anything cannot report success")
    func zeroWithoutPersistence() throws {
        let fixture = try FishFixture()
        defer { fixture.remove() }
        try fixture.startup("function fish_add_path; return 0; end\n")
        #expect(throws: CommandLineTool.Failure.self) { try fixture.configure() }
        #expect(try fixture.persistedPaths().isEmpty)
    }

    @Test("a startup exec cannot substitute its exit status for our command",
           arguments: ["exec /usr/bin/true\n", "exec /usr/bin/false\n"])
    func startupExit(script: String) throws {
        let fixture = try FishFixture()
        defer { fixture.remove() }
        try fixture.startup(script)
        guard case .unknown = fixture.configuration() else {
            Issue.record("a replaced fish process was treated as a completed check")
            return
        }
        #expect(throws: CommandLineTool.Failure.self) { try fixture.configure() }
    }

    @Test("completed PATH answers survive nonfatal startup noise and errors")
    func nonfatalStartupError() throws {
        let fixture = try FishFixture()
        defer { fixture.remove() }
        // Interactive fish can recover from startup errors (and even startup `exit`). A framed
        // answer after recovery is still evidence; stderr alone must not discard that answer.
        try fixture.startup("printf 'startup noise without newline'; false\n")
        #expect(fixture.configuration() == .notConfigured)
        try fixture.configure()
        #expect(fixture.configuration() == .configured)
    }

}

private struct FishFixture {
    let fish: URL
    let home: URL
    let directory: URL
    let environment: [String: String]

    var startupFile: URL { home.appendingPathComponent(".config/fish/conf.d/fixture.fish") }

    init(directoryName: String = ".local/bin") throws {
        fish = try #require(CommandLineTool.locateFish(loginShell: nil))
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitpic-fish-\(UUID().uuidString)")
        directory = home.appendingPathComponent(directoryName)
        for path in [".config/fish/conf.d", ".cargo/bin", directoryName, ".cache", ".local/share"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        environment = [
            "HOME": home.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
            "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb",
        ]
    }

    func startup(_ script: String) throws { try Data(script.utf8).write(to: startupFile) }

    func run(_ executable: URL, _ args: [String]) throws -> ProcessOutcome {
        try ChildProcess.run(executable: executable, args: args, environment: environment, timeout: 8)
    }

    @discardableResult
    func configure() throws -> CommandLineTool.Configured {
        try CommandLineTool.configureFish(fish: fish, directory: directory, run: run)
    }

    func configuration() -> CommandLineTool.ShellConfiguration {
        CommandLineTool.fishPathConfiguration(fish: fish, directory: directory, run: run)
    }

    func persistedPaths() throws -> [String] {
        let out = try run(fish, ["-c", """
            set --erase --global fish_user_paths
            if set --query --universal fish_user_paths
                printf '%s\\n' $fish_user_paths
            end
            """])
        try #require(out.status == 0)
        return String(decoding: out.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

@Suite("Fish subprocess contract")
struct FishProcessContractTests {
    private let fish = URL(fileURLWithPath: "/test/fish")
    private let directory = URL(fileURLWithPath: "/a home/'quoted $PATH'/.local/bin")

    private func answer(_ status: Int32, timedOut: Bool = false) -> ProcessOutcome {
        ProcessOutcome(
            stdout: Data("startup noise\(CommandLineTool.fishResultOpen)\(status)\(CommandLineTool.fishResultClose)\n".utf8),
            stderr: Data(), status: status, timedOut: timedOut)
    }

    @Test("configuration writes explicitly and verifies in a separate login-interactive fish")
    func separateVerification() throws {
        var calls: [[String]] = []
        let result = try CommandLineTool.configureFish(fish: fish, directory: directory) { executable, args in
            #expect(executable == fish)
            calls.append(args)
            return answer(0)
        }
        try #require(calls.count == 2)
        #expect(calls[0].first == "-c")
        #expect(calls[0][1].contains("set --erase --global fish_user_paths"))
        #expect(calls[0][1].contains("fish_add_path --universal --"))
        #expect(Array(calls[1].prefix(3)) == ["-l", "-i", "-c"])
        for call in calls {
            #expect(call.contains("--no-config") == false)
            #expect(call.last == directory.path)
            #expect(call.dropLast().contains(where: { $0.contains(directory.path) }) == false)
        }
        #expect(result == .ranCommand("fish_add_path --universal -- \(directory.path)"))
    }

    @Test("fresh-process verification failure is not a success", arguments: [Int32(1), 2])
    func verificationFailure(status: Int32) {
        var count = 0
        #expect(throws: CommandLineTool.Failure.self) {
            try CommandLineTool.configureFish(fish: fish) { _, _ in
                count += 1
                return answer(count == 1 ? 0 : status)
            }
        }
        #expect(count == 2)
    }

    @Test("timeouts, missing frames, mismatched statuses and spawn failures stay unknown")
    func inconclusiveProbes() {
        let outcomes = [
            answer(0, timedOut: true),
            answer(127),
            ProcessOutcome(stdout: Data(), stderr: Data(), status: 0, timedOut: false),
            ProcessOutcome(stdout: answer(0).stdout, stderr: Data(), status: 1, timedOut: false),
            ProcessOutcome(stdout: Data(), stderr: Data("fixture syntax error".utf8), status: 2, timedOut: false),
        ]
        for outcome in outcomes {
            let configuration = CommandLineTool.fishPathConfiguration(fish: fish) { _, _ in outcome }
            guard case .unknown(let reason) = configuration else {
                Issue.record("inconclusive result became \(configuration)")
                continue
            }
            #expect(reason.isEmpty == false)
            #expect(throws: CommandLineTool.Failure.self) {
                try CommandLineTool.configureFish(fish: fish) { _, _ in outcome }
            }
        }
        let missing = CommandLineTool.fishPathConfiguration(fish: fish) { _, _ in
            throw RunFailure.spawnFailed("fixture fish missing")
        }
        guard case .unknown(let reason) = missing else {
            Issue.record("spawn failure was treated as absent configuration")
            return
        }
        #expect(reason.contains("fixture fish missing"))
    }

    @Test("a completed negative probe stays distinct from a failed probe")
    func conclusiveAbsence() {
        #expect(CommandLineTool.fishPathConfiguration(fish: fish) { _, _ in answer(1) } == .notConfigured)
        #expect(CommandLineTool.fishPathConfiguration(fish: fish) { _, _ in answer(0) } == .configured)
    }
}
