import Foundation
import Testing
@testable import DaybreakKit

@Suite struct ConfigStoreTests {
    static let sample = """
    {
      "apps": {
        "com.docker.docker": {"allow_workload_interruption": false, "backend": "docker"},
        "com.example.Editor": {"backend": "command", "check": ["/bin/adapter", "check", "{app_path}"]}
      },
      "exclude": ["com.example.Legacy"],
      "future_key": {"nested": [1, 2.5, null, true, "x/y"]},
      "hour": 8,
      "quit_timeout_seconds": 60,
      "sparkle_cli": "/Applications/sparkle.app/Contents/MacOS/sparkle"
    }
    """

    func temporaryStore(contents: String?) throws -> ConfigStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("daybreak-tests-\(UUID().uuidString)/nested", isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        if let contents {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return ConfigStore(url: url)
    }

    func reparse(_ store: ConfigStore) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
    }

    @Test func roundTripPreservesUnknownKeysAndNumberKinds() throws {
        let document = try ConfigDocument.parse(Data(Self.sample.utf8))
        let again = try ConfigDocument.parse(document.serialized())
        #expect(again == document)
        #expect(document.root["hour"] == .int(8))
        guard case .object(let future)? = document.root["future_key"],
              case .array(let nested)? = future["nested"] else {
            Issue.record("future_key lost"); return
        }
        #expect(nested == [.int(1), .double(2.5), .null, .bool(true), .string("x/y")])
    }

    @Test func serializedIsPrettySortedWithTrailingNewline() throws {
        let document = ConfigDocument(root: ["zeta": .int(1), "alpha": .bool(false)])
        let text = String(decoding: try document.serialized(), as: UTF8.self)
        #expect(text.hasSuffix("}\n"))
        #expect(text.contains("\n"))
        let alpha = try #require(text.range(of: "alpha"))
        let zeta = try #require(text.range(of: "zeta"))
        #expect(alpha.lowerBound < zeta.lowerBound)
    }

    @Test func addingWhitelistEntryPreservesEverythingElse() throws {
        let store = try temporaryStore(contents: Self.sample)
        try store.update { try $0.addWhitelistPattern("com.jetbrains.*") }
        let json = try reparse(store)
        #expect(json["whitelist"] as? [String] == ["com.jetbrains.*"])
        #expect(json["exclude"] as? [String] == ["com.example.Legacy"])
        #expect(json["sparkle_cli"] as? String == "/Applications/sparkle.app/Contents/MacOS/sparkle")
        let apps = try #require(json["apps"] as? [String: Any])
        let editor = try #require(apps["com.example.Editor"] as? [String: Any])
        #expect(editor["check"] as? [String] == ["/bin/adapter", "check", "{app_path}"])
        #expect(json["future_key"] != nil)
    }

    @Test func legacyExcludeEntriesAreListedAndRemovable() throws {
        let store = try temporaryStore(contents: Self.sample)
        var entries = try store.load().whitelistEntries()
        #expect(entries == [WhitelistEntry(pattern: "com.example.Legacy", source: .exclude)])

        // Adding an entry that already exists under `exclude` is a no-op.
        var document = try store.load()
        #expect(try document.addWhitelistPattern("com.example.Legacy") == false)

        try store.update { try $0.removeWhitelistPattern("com.example.Legacy") }
        entries = try store.load().whitelistEntries()
        #expect(entries.isEmpty)
        #expect(try reparse(store)["exclude"] as? [String] == [])
    }

    @Test func duplicatesAndWhitespaceAreHandled() throws {
        var document = ConfigDocument()
        #expect(try document.addWhitelistPattern("  com.example.A ") == true)
        #expect(try document.addWhitelistPattern("com.example.A") == false)
        #expect(throws: ConfigError.self) { try document.addWhitelistPattern("   ") }
        #expect(try document.whitelistEntries().map(\.pattern) == ["com.example.A"])
    }

    @Test func missingFileIsCreatedWithPrivateParent() throws {
        let store = try temporaryStore(contents: nil)
        #expect(try store.load() == ConfigDocument())
        try store.update { try $0.addWhitelistPattern("com.example.A") }
        #expect(try reparse(store)["whitelist"] as? [String] == ["com.example.A"])
    }

    @Test func unparseableFileIsNeverOverwritten() throws {
        let broken = "{ \"whitelist\": [\"com.example.A\", }"
        let store = try temporaryStore(contents: broken)
        #expect(throws: ConfigError.self) {
            try store.update { try $0.addWhitelistPattern("com.example.B") }
        }
        #expect(try String(contentsOf: store.url, encoding: .utf8) == broken)
    }

    @Test func nonObjectAndWrongTypesAreRejected() throws {
        #expect(throws: ConfigError.notAnObject) { try ConfigDocument.parse(Data("[1, 2]".utf8)) }
        var document = try ConfigDocument.parse(Data(#"{"whitelist": "com.example.A"}"#.utf8))
        #expect(throws: ConfigError.self) { try document.addWhitelistPattern("com.example.B") }
        #expect(document.root["whitelist"] == .string("com.example.A"))
    }

    @Test func settingsOnlyWriteChangedKeys() throws {
        var document = try ConfigDocument.parse(Data(Self.sample.utf8))
        let original = try document.settings()
        #expect(original.hour == 8)
        #expect(original.timezone == EngineSettings.defaultTimezone)
        var edited = original
        edited.hour = 7
        edited.restartUnmanaged = false
        try document.applySettings(edited, original: original)
        #expect(document.root["hour"] == .int(7))
        #expect(document.root["restart_unmanaged"] == .bool(false))
        #expect(document.root["timezone"] == nil)
        #expect(document.root["restart_current"] == nil)
        #expect(document.root["quit_timeout_seconds"] == .int(60))
    }

    @Test func invalidSettingsAreRejected() throws {
        var document = ConfigDocument()
        var settings = EngineSettings()
        settings.hour = 24
        settings.quitTimeoutSeconds = 0
        settings.timezone = "Mars/Olympus"
        #expect(settings.validationErrors().count == 3)
        #expect(throws: ConfigError.self) { try document.applySettings(settings, original: EngineSettings()) }
        #expect(document.root.isEmpty)
    }

    @Test func restoreReturnsEntryToItsOriginalKey() throws {
        var document = try ConfigDocument.parse(Data(Self.sample.utf8))
        let legacy = WhitelistEntry(pattern: "com.example.Legacy", source: .exclude)
        try document.removeWhitelistPattern(legacy.pattern)
        try document.restoreWhitelistEntry(legacy)
        try document.restoreWhitelistEntry(legacy)  // idempotent
        #expect(try document.stringList("exclude") == ["com.example.Legacy"])
        #expect(try document.stringList("whitelist") == [])
        try document.restoreWhitelistEntry(WhitelistEntry(pattern: "com.jetbrains.*", source: .whitelist))
        #expect(try document.stringList("whitelist") == ["com.jetbrains.*"])
    }
}
