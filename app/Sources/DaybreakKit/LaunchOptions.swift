import Foundation

/// Launch arguments used for screenshots/QA. None of them can apply updates:
///   --pane running|whitelist|run|history   initial sidebar item
///   --appearance light|dark                force an appearance
///   --preview                              run a read-only dry run after launch
///   --settings [behavior|engine]           open the Settings window on a tab
///   --snapshot DIR                         render each pane of the app's own windows to PNGs
///                                          in DIR, then quit (in-process; not screen capture)
public struct LaunchOptions: Sendable, Equatable {
    public var pane: String?
    public var appearance: String?
    public var autoPreview = false
    public var openSettings = false
    public var settingsTab: String?
    public var snapshotDirectory: String?

    public init() {}

    public init(arguments: [String]) {
        var index = 1  // skip argv[0]
        func value(after i: Int) -> String? {
            guard i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-") else { return nil }
            return arguments[i + 1]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--pane":
                pane = value(after: index)
                if pane != nil { index += 1 }
            case "--appearance":
                appearance = value(after: index)
                if appearance != nil { index += 1 }
            case "--preview":
                autoPreview = true
            case "--settings":
                openSettings = true
                settingsTab = value(after: index)
                if settingsTab != nil { index += 1 }
            case "--snapshot":
                snapshotDirectory = value(after: index)
                if snapshotDirectory != nil { index += 1 }
            default:
                break  // Ignore AppKit's own arguments such as -NSDocumentRevisionsDebugMode.
            }
            index += 1
        }
    }
}
