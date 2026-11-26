import Foundation
import os
import Testing
@testable import EvergreenKit

struct BrewPackagesTests {
    @Test func readsFormulaeAndCasksWithoutLosingTheirPackageType() throws {
        let process = UpdaterProcess { arguments, _ in
            #expect(arguments == ["/brew", "info", "--json=v2", "--installed"])
            return ProcessOutput(exitCode: 0, stdout: Data("""
            {
              "formulae": [{"name":"example", "installed":[{"version":"1.0"}], "pinned":true}],
              "casks": [
                {"token":"example","full_token":"vendor/tools/example","installed":"2.0","artifacts":[{"font":["Example.ttf"]}]},
                {"token":"example-app","installed":"3.0","artifacts":[{"app":["Example.app"]}]},
                {"token":"example-pkg","installed":"4.0","artifacts":[{"pkg":["Example.pkg"]}]}
              ]
            }
            """.utf8), stderr: Data())
        }
        let brew = BrewPackages(executable: "/brew", process: process)
        let installed = try brew.installed()
        let formula = try #require(BrewPackage(name: "example", kind: .formula))
        let font = try #require(BrewPackage(name: "vendor/tools/example", kind: .cask))
        let app = try #require(BrewPackage(name: "example-app", kind: .cask))
        let installer = try #require(BrewPackage(name: "example-pkg", kind: .cask))
        #expect(installed[formula]?.pinned == true)
        #expect(installed[font]?.canUpgrade == true)
        #expect(font.offerID == "brew:cask:example")
        #expect(installed[app]?.canUpgrade == false)
        #expect(installed[installer]?.canUpgrade == false)
        #expect(BrewPackage(name: "--force", kind: .formula) == nil)
    }

    @Test(arguments: [true, false])
    func scopedFormulaUpgradeRequiresInstalledVersionToChange(installsOffer: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let executable = root.appendingPathComponent("brew")
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let config = root.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: config)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let version = OSAllocatedUnfairLock(initialState: "1.0")
        let commands = OSAllocatedUnfairLock(initialState: [[String]]())
        let runner = UpdaterProcess(searchPath: root.path) { arguments, _ in
            let output: String
            switch arguments {
            case [executable.path, "--caskroom"]:
                output = root.appendingPathComponent("Caskroom").path
            case [executable.path, "info", "--json=v2", "--installed"]:
                let installed = version.withLock { $0 }
                output = #"{"formulae":[{"name":"example","installed":[{"version":"\#(installed)"}]}],"casks":[]}"#
            case [executable.path, "outdated", "--json=v2"]:
                output = #"{"formulae":[{"name":"example","current_version":"2.0","pinned":false}],"casks":[]}"#
            default:
                commands.withLock { $0.append(arguments) }
                if installsOffer { version.withLock { $0 = "2.0" } }
                output = ""
            }
            return ProcessOutput(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
        }
        let package = try #require(BrewPackage(name: "example", kind: .formula))
        let item = UpdateItem(name: package.name, bundleID: nil, path: nil, brewPackage: package,
                              installedVersion: "1.0", isRunning: false, isMacAppStoreApp: false, repository: nil,
                              status: .available, action: .install, offeredVersion: "2.0")
        let catalog = try UpdateCatalog(configURL: config, stateDirectory: state, process: runner)
        if installsOffer {
            let result = try await catalog.install(item)
            #expect(result.status == .current)
            #expect(result.installedVersion == "2.0")
        } else {
            await #expect(throws: EngineFailure.self) { try await catalog.install(item) }
        }
        #expect(commands.withLock { $0 } == [
            ["/usr/bin/env", "HOMEBREW_NO_ASK=1", "HOMEBREW_NO_AUTO_UPDATE=1", executable.path, "upgrade", "--formula", "example"]
        ])
        let report = try JSONDecoder().decode(RunReport.self, from: NativeState(directory: state).status())
        #expect(report.results.first?.status == (installsOffer ? .updated : .failed))
    }
}
