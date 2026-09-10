import Foundation

/// Module-local shadow of Foundation's NSLog. Unqualified `NSLog(...)` calls
/// in this module resolve here first, so upstream files need no edits.
///
/// Why: on a device, NSLog text is `<private>` in `log collect` archives and
/// absent from `devicectl ... --console`, which only carries stdout and
/// stderr. Echoing the line to stdout makes the stream, audio and LiveKit
/// diagnostics readable from a Mac without a debugger attached.
func NSLog(_ format: String, _ args: CVarArg...) {
  let line = String(format: format, arguments: args)
  Foundation.NSLog("%@", line)
  print(line)
}
