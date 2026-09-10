import Foundation

/// Module-local shadow of Foundation's NSLog. Unqualified `NSLog(...)` calls
/// in this module resolve here first, so upstream files need no edits.
///
/// Why: on a device, NSLog text is `<private>` in `log collect` archives and
/// absent from `devicectl ... --console`, which only carries stdout and
/// stderr. Echoing the line to stdout makes the stream, audio and LiveKit
/// diagnostics readable from a Mac without a debugger attached.
///
/// The same line is appended to `Documents/corvus/console.log`, which can be
/// pulled with `devicectl device copy from --domain-type appDataContainer`
/// while the app keeps running. Attaching a console to the process instead
/// kills the app when the console detaches, and an app killed mid-stream
/// leaves its device session held on the glasses until they are power-cycled.
func NSLog(_ format: String, _ args: CVarArg...) {
  let line = String(format: format, arguments: args)
  Foundation.NSLog("%@", line)
  print(line)
  ConsoleFile.shared.append(line)
}

private final class ConsoleFile: @unchecked Sendable {
  static let shared = ConsoleFile()
  private let queue = DispatchQueue(label: "corvus.console-file")
  private var handle: FileHandle?
  private let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()

  private init() {
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    let dir = docs.appendingPathComponent("corvus", isDirectory: true)
    let url = dir.appendingPathComponent("console.log")
    let previous = dir.appendingPathComponent("console.prev.log")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // One launch per file: the previous launch survives as console.prev.log.
    try? FileManager.default.removeItem(at: previous)
    try? FileManager.default.moveItem(at: url, to: previous)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    handle = try? FileHandle(forWritingTo: url)
  }

  func append(_ line: String) {
    let text = "\(stamp.string(from: Date())) \(line)\n"
    queue.async { [handle] in
      guard let handle, let data = text.data(using: .utf8) else { return }
      handle.write(data)
    }
  }
}
