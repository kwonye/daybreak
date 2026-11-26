import AppKit
import Foundation

struct ElectronUpdateFeed: Sendable {
    enum Source: Sendable {
        case github(ReleaseRepository)
        case manifest(URL)
    }

    let source: Source
    let channel: String
    let architecture: String

    init?(app: ManagedApp, manifestURL: String? = nil) {
        let bundle = URL(fileURLWithPath: app.path)
        guard app.metadata.hints.contains("electron"), let supported = Bundle(url: bundle)?.executableArchitectures else { return nil }
        #if arch(arm64)
        let architecture = supported.contains(NSNumber(value: NSBundleExecutableArchitectureARM64)) ? "arm64" : "x64"
        #else
        let architecture = "x64"
        #endif
        let cpu = architecture == "arm64" ? NSBundleExecutableArchitectureARM64 : NSBundleExecutableArchitectureX86_64
        guard supported.contains(NSNumber(value: cpu)) else { return nil }
        if let manifestURL {
            guard let url = URL(string: manifestURL) else { return nil }
            self.init(manifestURL: url, architecture: architecture)
            return
        }
        let path = bundle.appendingPathComponent("Contents/Resources/app-update.yml")
        guard canonicalPath(path.path) == path.path,
              let values = try? path.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= 16_384,
              let config = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        self.init(config: config, architecture: architecture)
    }

    private init(source: Source, channel: String, architecture: String) {
        self.source = source
        self.channel = channel
        self.architecture = architecture
    }

    init?(manifestURL: URL, architecture: String) {
        guard ReleaseArtifact.isHTTPS(manifestURL) else { return nil }
        self.init(source: .manifest(manifestURL), channel: "latest", architecture: architecture)
    }

    init?(config: String, architecture: String) {
        guard let fields = ElectronUpdateManifest.configuration(config),
              fields["private"] == nil || fields["private"] == "false" else { return nil }
        let channel = fields["channel"] ?? "latest"
        guard channel.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_-]{0,31}/) != nil else { return nil }
        let source: Source
        switch fields["provider"] {
        case "github":
            guard fields["releaseType"] == nil || fields["releaseType"] == "release",
                  let owner = fields["owner"], let repo = fields["repo"], let repository = ReleaseRepository("\(owner)/\(repo)"),
                  fields["host"] == nil || fields["host"] == "github.com",
                  fields["protocol"] == nil || fields["protocol"] == "https" else { return nil }
            source = .github(repository)
        case "generic":
            guard let value = fields["url"], let url = URL(string: value), ReleaseArtifact.isHTTPS(url),
                  url.query == nil else { return nil }
            source = .manifest(url.appendingPathComponent("\(channel)-mac.yml"))
        default: return nil
        }
        self.init(source: source, channel: channel, architecture: architecture)
    }

    func check() async throws -> PublishedRelease? {
        switch source {
        case .github(let repository):
            guard let release = try await repository.latestStableRelease() else { return nil }
            let manifests = release.assets.filter { $0.name == "\(channel)-mac.yml" }
            guard manifests.count == 1, let asset = manifests.first, let url = repository.assetURL(asset, in: release),
                  let (data, finalURL) = try await downloadManifest(url),
                  ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(finalURL.host ?? ""),
                  let value = String(data: data, encoding: .utf8) else { return nil }
            return offer(from: value, release: release)
        case .manifest(let url):
            guard let (data, finalURL) = try await downloadManifest(url) else { return nil }
            return customOffer(from: data, base: finalURL)
        }
    }

    private func downloadManifest(_ url: URL) async throws -> (Data, URL)? {
        let request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 15)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request, delegate: ReleaseDownloadDelegate())
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let finalURL = response.url, ReleaseArtifact.isHTTPS(finalURL) else { return nil }
        var data = Data()
        for try await byte in stream {
            guard data.count < 262_144 else { return nil }
            data.append(byte)
        }
        return (data, finalURL)
    }

    func offer(from manifest: String, release: ReleaseRepository.Release) -> PublishedRelease? {
        guard case .github(let repository) = source,
              let manifest = ElectronUpdateManifest(manifest),
              ReleaseRepository.compare(release.tag_name, installed: manifest.version) == .orderedSame else { return nil }
        let files = manifest.files.compactMap { file -> (URL, ReleaseArtifact?)? in
            let name = file.path.removingPercentEncoding ?? file.path
            let assets = release.assets.filter { $0.name == name }
            guard assets.count == 1, let asset = assets.first, let url = repository.assetURL(asset, in: release) else { return nil }
            let artifact = if file.sha512 != nil {
                ReleaseArtifact(url: url, sha512: file.sha512, size: file.size)
            } else {
                repository.downloadArtifact(asset, in: release, size: file.size)
            }
            return (url, artifact)
        }
        return offer(version: manifest.version, files: files)
    }

    func customOffer(from data: Data, base: URL) -> PublishedRelease? {
        let decoder = JSONDecoder()
        if let manifest = try? decoder.decode(SquirrelUpdateManifest.self, from: data), let current = manifest.current {
            return squirrelOffer(current, version: manifest.currentRelease, base: base)
        }
        if let target = try? decoder.decode(SquirrelUpdateManifest.Target.self, from: data), let version = target.version {
            return squirrelOffer(target, version: version, base: base)
        }
        guard let string = String(data: data, encoding: .utf8), let manifest = ElectronUpdateManifest(string) else { return nil }
        let files = manifest.files.compactMap { file -> (URL, ReleaseArtifact?)? in
            guard let url = URL(string: file.path, relativeTo: base)?.absoluteURL, ReleaseArtifact.isHTTPS(url) else { return nil }
            return (url, ReleaseArtifact(url: url, sha512: file.sha512, size: file.size))
        }
        return offer(version: manifest.version, files: files)
    }

    private func squirrelOffer(_ target: SquirrelUpdateManifest.Target, version: String, base: URL) -> PublishedRelease? {
        guard ReleaseRepository.compare(version, installed: version) == .orderedSame,
              let url = URL(string: target.url, relativeTo: base)?.absoluteURL, ReleaseArtifact.isHTTPS(url) else { return nil }
        return PublishedRelease(version: version,
                                artifact: ReleaseArtifact(url: url, sha256: target.sha256, format: .zip, size: target.size))
    }

    private func offer(version: String, files: [(url: URL, artifact: ReleaseArtifact?)]) -> PublishedRelease? {
        let compatible = files.filter { file in
            ReleaseArtifact.matchesArchitecture(architecture, filename: file.url.lastPathComponent)
                || !["arm64", "x64"].contains { ReleaseArtifact.matchesArchitecture($0, filename: file.url.lastPathComponent) }
        }
        for format in [ReleaseArtifact.Format.dmg, .zip] {
            let candidates = compatible.filter { $0.url.pathExtension.lowercased() == format.rawValue }
            let exact = candidates.filter { ReleaseArtifact.matchesArchitecture(architecture, filename: $0.url.lastPathComponent) }
            let preferred = exact.isEmpty ? candidates : exact
            if preferred.count == 1, let artifact = preferred.first?.artifact {
                return PublishedRelease(version: version, artifact: artifact)
            }
        }
        guard compatible.contains(where: { ReleaseArtifact.Format(rawValue: $0.url.pathExtension.lowercased()) != nil }) else { return nil }
        return PublishedRelease(version: version, artifact: nil)
    }
}
