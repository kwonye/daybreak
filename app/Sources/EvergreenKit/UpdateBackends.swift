import Foundation

struct UpdateCheck {
    enum State: String { case available, current, unknown }
    let state: State
    var target = ""
    var detail = ""
    var requiresUserAction = false
}

struct UpdateRequiresApp: LocalizedError {
    var errorDescription: String? { "Open the app to finish updating." }
}

struct UpdateBackend: Sendable {
    enum Kind: String, Sendable {
        case restart = "restart-only"
        case sparkle
        case homebrew
        case appStore = "app-store"
        case docker
        case google
        case microsoft
        case command
        case release
    }

    let kind: Kind
    let process: UpdaterProcess
    var executable = ""
    var identifier = ""
    var checkArguments: [String] = []
    var applyArguments: [String] = []
    var preventVendorQuit = false
    var sparkleProbeFeed: URL?
    var interactiveInstallation = false
    var stagedRelease: StagedRelease?

    var managesLifecycle: Bool { kind == .docker }

    func check(_ app: ManagedApp, interactiveCatalog: Bool = false) throws -> UpdateCheck {
        switch kind {
        case .release:
            return stagedRelease.map { UpdateCheck(state: .available, target: $0.version) } ?? UpdateCheck(state: .unknown)
        case .restart:
            return UpdateCheck(state: .unknown, detail: "No supported updater configured; restart may apply a staged update")
        case .sparkle:
            var arguments = [executable, app.path, "--probe", "--user-agent-name", "Evergreen"]
            if let sparkleProbeFeed { arguments += ["--feed-url", sparkleProbeFeed.absoluteString] }
            let result = try process.run(arguments, 120)
            switch result.exitCode {
            case 0 where sparkleProbeFeed != nil:
                return UpdateCheck(state: .available, detail: "Open the app to update.", requiresUserAction: true)
            case 0: return UpdateCheck(state: .available, detail: "Sparkle found an update")
            case 2 where interactiveCatalog:
                return UpdateCheck(state: .available, detail: "Open the app to review this upgrade.", requiresUserAction: true)
            case 4: return UpdateCheck(state: .current, detail: "Sparkle reports no update")
            default: throw EngineFailure("Sparkle probe exited \(result.exitCode); needs attention")
            }
        case .homebrew:
            let output = try process.checked([executable, "outdated", "--cask", "--json=v2", identifier], 180)
            let data = try object(output)
            guard let casks = data["casks"] as? [[String: Any]] else {
                throw EngineFailure("Homebrew returned an invalid cask list")
            }
            let token = identifier.split(separator: "/").last.map(String.init)
            let listed = casks.contains { $0["name"] as? String == token && $0["pinned"] as? Bool != true }
            return UpdateCheck(state: listed ? .available : .current, detail: "Homebrew cask catalog result")
        case .appStore:
            let output = try process.checked([executable, "outdated"], 180)
            let listed = output.split(whereSeparator: \.isNewline).contains {
                $0.split(whereSeparator: \.isWhitespace).first == identifier[...]
            }
            return UpdateCheck(state: listed ? .available : .current,
                               detail: listed ? "mas reports an update" : "mas did not list this app as outdated")
        case .docker:
            return UpdateCheck(state: .available, detail: "Request native check/apply; availability unknown until finished")
        case .microsoft:
            return UpdateCheck(state: .unknown)
        case .google:
            var contents = URL(fileURLWithPath: executable)
            for _ in 0..<5 { contents.deleteLastPathComponent() }
            guard isFile(executable), isFile(contents.appendingPathComponent("MacOS/GoogleUpdater").path) else {
                throw EngineFailure("Existing user-scope Google updater/helper missing")
            }
            let output = try process.checked([executable, "--print-tickets", "--productid", app.bundleID, "--user-store"], 60)
            guard let product = Self.field(#"(?m)^\s*productID=(.+)$"#, in: output),
                  product.trimmingCharacters(in: .whitespaces).lowercased() == app.bundleID.lowercased(),
                  Self.field(#"(?m)^\s*xc=<[^\n]* path=(.*)>$"#, in: output) == app.path,
                  Self.field(#"(?m)^\s*version=(.+)$"#, in: output) != nil else {
                throw EngineFailure("Google registration does not match this app path")
            }
            return UpdateCheck(state: .available, detail: "Scoped native check/apply; availability unknown until finished")
        case .command:
            let output = try process.checked(expand(checkArguments, app: app), 180)
            let data = try object(output)
            guard let raw = data["state"] as? String, let state = UpdateCheck.State(rawValue: raw) else {
                throw EngineFailure("Adapter returned an invalid state")
            }
            guard let target = (data["target_version"] ?? "") as? String, state != .available || !target.isEmpty else {
                throw EngineFailure("Available adapter update must include target_version")
            }
            return UpdateCheck(state: state, target: target)
        }
    }

    /// Returns Sparkle's explicit outcome when available. Other commands expose only exit status.
    func apply(_ app: ManagedApp) throws -> (outcome: String, detail: String)? {
        switch kind {
        case .release:
            guard let stagedRelease else { throw UpdateRequiresApp() }
            try stagedRelease.install(over: app)
            return ("completed", "Installed verified release.")
        case .restart: break
        case .sparkle:
            guard sparkleProbeFeed == nil else { throw EngineFailure("Open the app to update.") }
            var arguments = [executable, app.path, "--check-immediately", "--user-agent-name", "Evergreen"]
            if interactiveInstallation { arguments.append("--interactive") }
            let result = try process.run(arguments, 900)
            switch result.exitCode {
            case 0: return ("completed", "")
            case 3 where interactiveInstallation, 8 where interactiveInstallation: throw UpdateRequiresApp()
            case 4: return ("no_update", "No update was offered at install time")
            case 5 where interactiveInstallation: throw CancellationError()
            default: throw EngineFailure("Sparkle install exited \(result.exitCode); needs attention")
            }
        case .homebrew:
            if interactiveInstallation, let package = BrewPackage(name: identifier, kind: .cask) {
                try BrewPackages(executable: executable, process: process).upgrade(package)
            } else {
                let flags = preventVendorQuit ? ["--no-quit"] : []
                _ = try process.checked([executable, "upgrade", "--cask"] + flags + [identifier], 900)
            }
        case .appStore:
            _ = try process.checked([executable, "update", identifier], 900)
        case .docker:
            _ = try process.checked([executable, "desktop", "update", "--quiet"], 1200)
        case .google:
            _ = try check(app)
            _ = try process.checked([executable, "--install", "--productid", app.bundleID, "--user-store"], 900)
        case .microsoft:
            _ = try process.checked([executable, "--install", "--apps", identifier, "--wait", "840"], 900)
        case .command:
            _ = try process.checked(expand(applyArguments, app: app), 900)
        }
        return nil
    }

    func verifyHealth() throws {
        guard kind == .docker else { return }
        let until = DispatchTime.now() + 90
        repeat {
            let output = try process.run([executable, "info", "--format", "{{.ServerVersion}}"], 10)
            if output.exitCode == 0, !String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            Thread.sleep(forTimeInterval: 1)
        } while DispatchTime.now() < until
        throw EngineFailure("Docker GUI relaunched but engine did not become ready")
    }

    private func expand(_ arguments: [String], app: ManagedApp) -> [String] {
        arguments.map {
            $0.replacingOccurrences(of: "{app_path}", with: app.path)
                .replacingOccurrences(of: "{bundle_id}", with: app.bundleID)
        }
    }

    private func object(_ output: String) throws -> [String: Any] {
        guard let decoded = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
            throw EngineFailure("Updater returned invalid JSON")
        }
        return decoded
    }

    static func field(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

struct BackendRegistry: Sendable {
    let process: UpdaterProcess
    let config: EngineConfiguration
    let brew: String?
    let casks: [String: String]
    let includeBundledSparkle: Bool

    private var sparkleCLI: String? {
        if let configured = config.sparkleCLI, !configured.isEmpty { return configured }
        guard includeBundledSparkle else { return nil }
        let bundle = Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
        let bundled = bundle?.appendingPathComponent("Helpers/sparkle.app/Contents/MacOS/sparkle").path
        return bundled.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    init(process: UpdaterProcess, config: EngineConfiguration, includeBundledSparkle: Bool = false) {
        self.process = process
        self.config = config
        self.includeBundledSparkle = includeBundledSparkle
        brew = process.executable(named: "brew")
        casks = brew.map { Self.installedCasks(brew: $0, process: includeBundledSparkle ? process : nil) } ?? [:]
    }

    func backend(for app: ManagedApp) throws -> UpdateBackend {
        let spec = config.apps[app.bundleID] ?? [:]
        let kind = spec["backend"]?.stringValue
        let automatic = kind?.isEmpty != false
        let executable = spec["executable"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if kind == "command" {
            return UpdateBackend(kind: .command, process: process, checkArguments: try argv("check", spec: spec),
                                 applyArguments: try argv("apply", spec: spec))
        }
        // Dynamic or app-specific feeds need the app's own updater. An explicit
        // configuration remains available for those bundles.
        let preferSparkle = !includeBundledSparkle || (casks[app.path] == nil && hasPublicSparkleFeed(app))
        if kind == "sparkle" || (automatic && preferSparkle && app.metadata.hints.contains("sparkle") && sparkleCLI != nil) {
            guard let command = executable ?? sparkleCLI, isFile(command) else {
                throw EngineFailure("Official Sparkle CLI not configured or missing")
            }
            return UpdateBackend(kind: .sparkle, process: process, executable: command)
        }
        if kind == "homebrew" || (automatic && casks[app.path] != nil) {
            guard let brew, let token = casks[app.path],
                  spec["cask"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }).map({ $0 == token }) ?? true else {
                throw EngineFailure("Exact app path is not an installed Homebrew cask")
            }
            guard BrewPackage(name: token, kind: .cask) != nil else {
                throw EngineFailure("Invalid Homebrew cask token")
            }
            return UpdateBackend(kind: .homebrew, process: process, executable: brew, identifier: token)
        }
        if kind == "app-store" {
            guard let command = executable ?? process.executable(named: "mas"), app.metadata.hints.contains("app-store") else {
                throw EngineFailure("mas missing or app has no App Store receipt")
            }
            let id = spec["app_id"]?.stringValue ?? spec["app_id"]?.intValue.map(String.init) ?? ""
            guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                throw EngineFailure("App Store ID must be numeric")
            }
            return UpdateBackend(kind: .appStore, process: process, executable: command, identifier: id)
        }
        if kind == "docker" {
            guard app.bundleID == "com.docker.docker", spec["allow_workload_interruption"]?.boolValue == true else {
                throw EngineFailure("Docker workload interruption must be explicitly enabled")
            }
            return UpdateBackend(kind: .docker, process: process, executable: app.path + "/Contents/Resources/bin/docker")
        }
        if kind == "google" || (automatic && app.bundleID == "com.google.Chrome") {
            guard app.bundleID == "com.google.Chrome" else { throw EngineFailure("Google adapter currently supports Chrome only") }
            let defaultPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support/Google/GoogleUpdater/Current/GoogleUpdater.app/Contents/Helpers/GoogleSoftwareUpdate.bundle/Contents/Helpers/ksadmin").path
            let command = executable ?? defaultPath
            if isFile(command) { return UpdateBackend(kind: .google, process: process, executable: command) }
            if kind != nil { throw EngineFailure("Existing user-scope Google updater helper missing") }
        } else if let kind, kind != "restart-only" {
            throw EngineFailure("Unknown backend: \(kind)")
        }
        return UpdateBackend(kind: .restart, process: process)
    }

    func catalogProbe(for app: ManagedApp) -> UpdateBackend? {
        guard app.bundleID == "com.openai.codex", app.metadata.hints.contains("sparkle"),
              let executable = sparkleCLI, isFile(executable),
              let architectures = Bundle(path: app.path)?.executableArchitectures,
              let feed = Self.chatGPTFeed(architectures: architectures) else { return nil }
        return UpdateBackend(kind: .sparkle, process: process, executable: executable, sparkleProbeFeed: feed)
    }

    // ChatGPT chooses its feed in code. Use the published feeds for its installed architectures.
    static func chatGPTFeed(architectures: [NSNumber]) -> URL? {
        let suffix: String
        if architectures.contains(NSNumber(value: NSBundleExecutableArchitectureARM64)) {
            suffix = ""
        } else if architectures.contains(NSNumber(value: NSBundleExecutableArchitectureX86_64)) {
            suffix = "-x64"
        } else {
            return nil
        }
        return URL(string: "https://persistent.oaistatic.com/codex-app-prod/appcast\(suffix).xml")
    }

    private func hasPublicSparkleFeed(_ app: ManagedApp) -> Bool {
        guard app.metadata.hints.contains("sparkle"),
              let value = try? BundleMetadata.info(app.path)["SUFeedURL"] as? String,
              let url = URL(string: value) else { return false }
        return url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    private func argv(_ key: String, spec: [String: JSONValue]) throws -> [String] {
        guard let items = spec[key]?.arrayValue, !items.isEmpty else {
            throw EngineFailure("\(key) must be a nonempty argv array")
        }
        let args = try items.map {
            guard let string = $0.stringValue, !string.isEmpty, !string.contains("\0") else {
                throw EngineFailure("\(key) must be a nonempty argv array")
            }
            return string
        }
        guard args[0].hasPrefix("/") else { throw EngineFailure("\(key) executable must be an absolute path") }
        return args
    }

    static func installedCasks(brew: String, process: UpdaterProcess?) -> [String: String] {
        let base = URL(fileURLWithPath: brew).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let prefix = base.lastPathComponent == "Homebrew" ? base.deletingLastPathComponent() : base
        let reported = try? process?.checked([brew, "--caskroom"], 15).trimmingCharacters(in: .whitespacesAndNewlines)
        let root = reported.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? prefix.appendingPathComponent("Caskroom")
        func children(_ url: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.path < $1.path }
        }
        var casks: [String: Set<String>] = [:]
        for cask in children(root) {
            let metadata = children(cask.appendingPathComponent(".metadata")).flatMap(children)
            for version in metadata {
                for file in children(version.appendingPathComponent("Casks")) where file.pathExtension == "json" {
                    guard let raw = try? Data(contentsOf: file),
                          let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                          let artifacts = object["artifacts"] as? [[String: Any]] else { continue }
                    for artifact in artifacts {
                        guard let app = artifact["app"] as? [Any], let name = app.first as? String else { continue }
                        let options = app.dropFirst().first as? [String: Any]
                        let destination = options?["target"] as? String ?? artifact["target"] as? String ?? name
                        let path = destination.hasPrefix("/") ? destination : "/Applications/" + destination
                        let token = object["full_token"] as? String ?? cask.lastPathComponent
                        casks[path, default: []].insert(token)
                    }
                }
            }
        }
        return casks.compactMapValues { $0.count == 1 ? $0.first : nil }
    }
}
