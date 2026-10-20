// Prints the window number of the largest on-screen window owned by a process.
// Usage: window-id <pid>
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: window-id <pid>\n".utf8))
    exit(2)
}

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let candidates = windows.filter { window in
    (window[kCGWindowOwnerPID as String] as? Int) == pid && (window[kCGWindowLayer as String] as? Int) == 0
}

func area(_ window: [String: Any]) -> Double {
    guard let bounds = window[kCGWindowBounds as String] as? [String: Double] else { return 0 }
    return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
}

guard let largest = candidates.max(by: { area($0) < area($1) }), let number = largest[kCGWindowNumber as String] as? Int else {
    exit(1)
}
print(number)
