import Darwin
import EvergreenKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
// AppKit refreshes running application records on the main run loop.
RunLoop.main.add(Timer(timeInterval: 3600, repeats: true) { _ in }, forMode: .common)
DispatchQueue.global(qos: .userInitiated).async {
    let result = EvergreenCommandLine.run(arguments)
    FileHandle.standardOutput.write(result.stdout)
    FileHandle.standardError.write(result.stderr)
    exit(result.exitCode)
}
RunLoop.main.run()
