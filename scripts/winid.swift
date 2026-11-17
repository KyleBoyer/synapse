// Prints the window id of an app's largest on-screen window.
// Usage: swiftc -O -o /tmp/winid scripts/winid.swift && screencapture -o -l$(/tmp/winid Synapse) shot.png
import CoreGraphics
import Foundation

let name = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
let wins = list.filter { ($0[kCGWindowOwnerName as String] as? String) == name && ($0[kCGWindowLayer as String] as? Int) == 0 }
func area(_ w: [String: Any]) -> Double { let b = w[kCGWindowBounds as String] as! [String: Double]; return b["Width"]! * b["Height"]! }
if let id = wins.max(by: { area($0) < area($1) })?[kCGWindowNumber as String] as? Int { print(id) }
