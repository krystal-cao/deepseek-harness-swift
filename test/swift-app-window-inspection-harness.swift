import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    fputs("usage: swift-app-window-inspection-harness <pid>\n", stderr)
    exit(2)
}

let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[CFString: Any]] ?? []
var found = false
for window in windows {
    guard let ownerPID = window[kCGWindowOwnerPID] as? Int32, ownerPID == pid else { continue }
    found = true
    let owner = window[kCGWindowOwnerName] as? String ?? ""
    let name = window[kCGWindowName] as? String ?? ""
    let layer = window[kCGWindowLayer] as? Int ?? -1
    print("window pid=\(ownerPID) owner=\(owner) name=\(name) layer=\(layer)")
}
if !found {
    print("no-windows pid=\(pid)")
}
