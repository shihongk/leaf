// Test helper: send a debug command to a Leaf launched with LEAF_DEBUG=1.
// Usage: swift tools/leafctl.swift <command>
import Foundation
let cmd = CommandLine.arguments.dropFirst().joined(separator: " ")
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("local.leaf.debug"), object: cmd, userInfo: nil, deliverImmediately: true)
