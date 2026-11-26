import Foundation

struct AppOutcome {
    enum Phase {
        case preparing, installing, verifying, reopening
    }

    var phase: Phase = .preparing
    var needsApp = false
    var wasCancelled = false

    let bundleID: String
    let name: String
    let path: String
    let before: String
    let beforeBuild: String
    let originalPIDs: [Int]
    let originalLaunches: [Double]
    let isProtected: Bool
    var status: ResultStatus = .planned
    var backend = ""
    var detail = ""
    var after = ""
    var afterBuild = ""
    var updateOutcome = ""
    var newPIDs: [Int] = []
    var verification = ""

    init(app: ManagedApp, status: ResultStatus = .planned, detail: String = "") {
        bundleID = app.bundleID
        name = app.name
        path = app.path
        before = app.metadata.version
        beforeBuild = app.metadata.build
        originalPIDs = app.pids
        originalLaunches = app.processes.map(\.launched)
        isProtected = app.isProtected
        self.status = status
        self.detail = detail
    }

    init(package: BrewPackage?, before: String = "", status: ResultStatus = .planned, detail: String = "") {
        self.init(name: package?.name ?? "Homebrew", bundleID: package?.id ?? "homebrew", before: before,
                  backend: "homebrew", status: status, detail: detail)
    }

    init(name: String, bundleID: String, before: String = "", backend: String = "",
         status: ResultStatus, detail: String) {
        self.bundleID = bundleID
        self.name = name
        path = ""
        self.before = before
        beforeBuild = ""
        originalPIDs = []
        originalLaunches = []
        isProtected = false
        self.backend = backend
        self.status = status
        self.detail = detail
    }

    init(skipping preview: RunResult) {
        bundleID = preview.bundleID
        name = preview.name
        path = preview.path
        before = preview.before
        beforeBuild = preview.beforeBuild
        originalPIDs = preview.oldPIDs
        originalLaunches = preview.originalLaunches
        isProtected = preview.isProtected
        status = .skipped
        detail = "The running instance changed after preview. Preview again to include it."
    }

    var row: [String: Any] {
        ["bundle_id": bundleID, "name": name, "path": path, "status": status.rawValue, "backend": backend, "protected": isProtected,
         "before": before, "after": after, "before_build": beforeBuild,
         "after_build": afterBuild, "update_outcome": updateOutcome, "detail": detail,
         "old_pids": originalPIDs, "original_launches": originalLaunches, "new_pids": newPIDs, "verification": verification]
    }
}

struct UpdateCoordinator {
    let platform: any ApplicationPlatform
    let config: EngineConfiguration
    let backend: (ManagedApp) throws -> UpdateBackend

    func handle(_ app: ManagedApp, apply: Bool, revalidateSelection: Bool = false,
                confirmedUpdate: UpdateCheck? = nil) -> AppOutcome {
        if let reason = app.protectionReason {
            return AppOutcome(app: app, status: .excluded, detail: reason)
        }
        if config.whitelisted(app.bundleID) {
            return AppOutcome(app: app, status: .excluded, detail: "Whitelisted by configuration")
        }
        if app.bundleID == "com.docker.docker", config.apps[app.bundleID]?["allow_workload_interruption"]?.boolValue != true {
            return AppOutcome(app: app, status: .blocked,
                              detail: "Docker restart can interrupt containers; enable allow_workload_interruption")
        }

        var result = AppOutcome(app: app)
        var recoveryNeeded = false
        var installStarted = false
        var signer: String?
        do {
            let backend = try backend(app)
            result.backend = backend.kind.rawValue
            if backend.kind == .restart && !config.restartUnmanaged {
                result.status = .unsupported
                result.detail = "No supported updater. Evergreen leaves this app running."
                return result
            }
            guard apply else {
                result.detail = backend.kind == .restart
                    ? "Restart only. Evergreen has no supported updater for this app."
                    : "Check for updates and relaunch as needed."
                return result
            }
            guard try platform.current(app).contains(where: { row in
                app.processes.contains { $0.pid == row.pid && $0.launched == row.launched }
            }) else {
                result.status = .skipped
                result.detail = "App stopped after inventory; not reopened"
                return result
            }
            let check = try confirmedUpdate ?? backend.check(app)
            if confirmedUpdate != nil && check.state != .available {
                result.status = check.state == .current ? .current : .deferred
                result.detail = check.state == .current ? "Already up to date." : "Couldn’t confirm an update."
                return result
            }
            if check.state == .unknown && !config.restartUnmanaged {
                result.status = .unsupported
                result.detail = "Update availability is unknown. Evergreen leaves this app running."
                return result
            }
            if check.state == .current && !app.stale && !config.restartCurrent {
                result.status = .current
                result.detail = check.detail
                return result
            }

            let started = Date()
            if check.state == .available { signer = try platform.signer(app) }
            if revalidateSelection, try !app.stillMatches(platform.current(app)) {
                return AppOutcome(app: app, status: .skipped, detail: "The running instance changed after preview. Preview again to include it.")
            }
            if !backend.managesLifecycle, try !platform.quit(app) {
                result.status = .deferred
                result.detail = "Quit refused or save prompt unresolved; no forced quit or update"
                return result
            }
            recoveryNeeded = true
            if let signer {
                installStarted = true
                result.phase = .installing
                if let outcome = try backend.apply(app) {
                    result.updateOutcome = outcome.outcome
                    result.detail = outcome.detail
                }
                result.phase = .verifying
                try platform.checkSignature(app, expectedTeam: signer)
            }
            result.phase = .reopening
            if try platform.current(app).contains(where: { app.pids.contains($0.pid) }), try !platform.quit(app) {
                result.status = .deferred
                result.detail = "Update attempted but original process has not exited"
                return result
            }
            if try platform.current(app).isEmpty { try platform.relaunch(app) }
            let (metadata, pids) = try platform.verify(app, since: started, target: check.target)
            result.after = metadata.version
            result.afterBuild = metadata.build
            result.newPIDs = pids
            result.verification = "Fresh primary PID and launch time, verified executable path, and installed bundle version (not in-memory version introspection)"
            try backend.verifyHealth()

            let changed = (metadata.version, metadata.build, metadata.fingerprint)
                != (app.metadata.version, app.metadata.build, app.metadata.fingerprint)
            if check.state == .unknown {
                result.status = .restartOnlyUnverified
                result.detail = "Staged updates may have applied; latest-version availability is unknown"
            } else if result.updateOutcome == "no_update" {
                result.status = .checkedAndRelaunched
                result.detail += "; app relaunched and verified, no upgrade claimed"
            } else if changed {
                result.status = .updatedAndRelaunched
            } else {
                result.status = .checkedAndRelaunched
                result.detail = "Updater completed; installed version unchanged. Not proof of latest available release"
            }
            return result
        } catch is CancellationError {
            result.status = .deferred
            result.wasCancelled = true
            result.detail = "Update authorization was cancelled."
        } catch is UpdateRequiresApp {
            result.status = .deferred
            result.needsApp = true
            result.detail = UpdateRequiresApp().localizedDescription
        } catch let timeout as UpdaterTimeout {
            result.status = .uncertain
            result.detail = timeout.localizedDescription
            if installStarted {
                recoveryNeeded = false
                result.detail += "; no reopen/retry attempted while installer outcome is unknown"
            }
        } catch {
            result.status = .failed
            result.detail = error.localizedDescription
        }

        if recoveryNeeded {
            do {
                if try platform.current(app).isEmpty {
                    if installStarted, let signer { try platform.checkSignature(app, expectedTeam: signer) }
                    try platform.relaunch(app)
                    result.detail += "; reopen requested after incomplete update"
                }
            } catch {
                result.detail += "; reopen failed: \(error.localizedDescription)"
            }
        }
        return result
    }
}
