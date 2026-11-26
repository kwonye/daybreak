import Foundation

public struct BrewPackage: Hashable, Sendable {
    public enum Kind: String, Sendable { case formula, cask }

    public let name: String
    public let kind: Kind

    var id: String { "brew:\(kind.rawValue):\(name)" }
    var offerID: String {
        kind == .cask ? "brew:cask:" + (name.split(separator: "/").last.map(String.init) ?? name) : id
    }
    var flag: String { "--" + kind.rawValue }

    init?(name: String, kind: Kind) {
        guard name.wholeMatch(of: /(?:[a-zA-Z0-9][a-zA-Z0-9_.-]*\/[a-zA-Z0-9][a-zA-Z0-9_.-]*\/)?[a-z0-9][a-z0-9@+_.-]*/) != nil
        else { return nil }
        self.name = name
        self.kind = kind
    }
}

struct BrewPackages: Sendable {
    struct Installed: Sendable {
        let package: BrewPackage
        let versions: [String]
        let pinned: Bool
        let canUpgrade: Bool
        var version: String { versions.joined(separator: ", ") }
    }

    struct Offer: Sendable {
        let version: String
        let pinned: Bool
    }

    let executable: String
    let process: UpdaterProcess

    func installed() throws -> [BrewPackage: Installed] {
        let data = try json(["info", "--json=v2", "--installed"])
        let formulae = try rows(data, for: "formulae").compactMap { row -> Installed? in
            guard let name = (row["full_name"] ?? row["name"]) as? String,
                  let package = BrewPackage(name: name, kind: .formula),
                  let versions = row["installed"] as? [[String: Any]] else { return nil }
            return Installed(package: package, versions: versions.compactMap { $0["version"] as? String }.sorted(),
                             pinned: row["pinned"] as? Bool == true, canUpgrade: true)
        }
        let casks = try rows(data, for: "casks").compactMap { row -> Installed? in
            guard let name = (row["full_token"] ?? row["token"]) as? String,
                  let package = BrewPackage(name: name, kind: .cask), let version = row["installed"] as? String else { return nil }
            let artifacts = (row["artifacts"] as? [[String: Any]]) ?? []
            let standalone = ["binary", "font", "manpage", "bash_completion", "zsh_completion", "fish_completion", "zap"]
            let canUpgrade = !artifacts.isEmpty && artifacts.allSatisfy { artifact in
                artifact.keys.allSatisfy { standalone.contains($0) || $0 == "target" }
            }
            return Installed(package: package, versions: [version], pinned: row["pinned"] as? Bool == true, canUpgrade: canUpgrade)
        }
        return Dictionary((formulae + casks).filter { !$0.versions.isEmpty }.map { ($0.package, $0) },
                          uniquingKeysWith: { first, _ in first })
    }

    func outdated() throws -> [String: Offer] {
        let data = try json(["outdated", "--json=v2"])
        let lists: [(BrewPackage.Kind, [[String: Any]])] = [
            (.formula, try rows(data, for: "formulae")), (.cask, try rows(data, for: "casks")),
        ]
        return Dictionary(lists.flatMap { kind, entries in
            entries.compactMap { row -> (String, Offer)? in
                guard let name = row["name"] as? String, let package = BrewPackage(name: name, kind: kind),
                      let version = row["current_version"] as? String, !version.isEmpty else { return nil }
                return (package.offerID, Offer(version: version, pinned: row["pinned"] as? Bool == true))
            }
        }, uniquingKeysWith: { first, _ in first })
    }

    func upgrade(_ package: BrewPackage) throws {
        let flags = package.kind == .cask ? ["--no-quit"] : []
        let command = ["/usr/bin/env", "HOMEBREW_NO_ASK=1", "HOMEBREW_NO_AUTO_UPDATE=1", executable, "upgrade", package.flag]
        _ = try process.checked(command + flags + [package.name], 900)
    }

    private func json(_ arguments: [String]) throws -> [String: Any] {
        let output = try process.checked([executable] + arguments, 180)
        guard let decoded = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
            throw EngineFailure("Homebrew returned invalid package data.")
        }
        return decoded
    }

    private func rows(_ data: [String: Any], for key: String) throws -> [[String: Any]] {
        guard let entries = data[key] as? [[String: Any]] else {
            throw EngineFailure("Homebrew returned an incomplete package list.")
        }
        return entries
    }
}
