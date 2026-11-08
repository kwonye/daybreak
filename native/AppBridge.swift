import AppKit
import Foundation

// No Accessibility API, forceTerminate, process signals, or shell evaluation.
func emit(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
func record(_ app: NSRunningApplication) -> [String: Any]? {
    guard !app.isTerminated, let url = app.bundleURL,
          let id = app.bundleIdentifier,
          app.activationPolicy != .prohibited else { return nil }
    return ["bundle_id": id, "name": app.localizedName ?? url.lastPathComponent,
            "path": url.path, "pid": Int(app.processIdentifier),
            "launched": app.launchDate?.timeIntervalSince1970 ?? 0,
            "executable": app.executableURL?.path ?? ""]
}
let args = Array(CommandLine.arguments.dropFirst())
if args == ["inventory"] {
    emit(NSWorkspace.shared.runningApplications.compactMap(record))
} else if args.count == 3 && args[0] == "quit", let pid = Int32(args[1]) {
    guard let app = NSRunningApplication(processIdentifier: pid),
          app.bundleIdentifier == args[2], let path = app.bundleURL?.path,
          !["com.openai.", "org.sparkle-project.Sparkle.", "com.google.GoogleUpdater", "io.tailscale."].contains(where: { args[2].hasPrefix($0) }),
          !path.hasPrefix("/System/"), !path.hasPrefix("/usr/"),
          !path.hasPrefix("/Library/Apple/"), !path.contains("/Contents/") else {
        fputs("Refusing unknown, protected, or mismatched process\n", stderr); exit(2)
    }
    emit(["requested": app.terminate()])
} else {
    fputs("Usage: appbridge inventory | quit PID BUNDLE_ID\n", stderr); exit(2)
}
