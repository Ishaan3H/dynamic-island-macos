import Foundation
import os

/// Lightweight tracing. An agent app has no window to print into, so run it as
/// `DI_DEBUG=1 DynamicIsland.app/Contents/MacOS/DynamicIsland` to follow along in
/// a terminal, or read it back with:
///
///     log stream --predicate 'subsystem == "com.qwerty.dynamicisland"'
enum Log {
    private static let logger = Logger(subsystem: "com.qwerty.dynamicisland", category: "island")
    private static let echoToStdout = ProcessInfo.processInfo.environment["DI_DEBUG"] == "1"

    static func debug(_ message: @autoclosure () -> String) {
        let text = message()
        logger.debug("\(text, privacy: .public)")
        if echoToStdout {
            print("[island] \(text)")
            fflush(stdout)
        }
    }
}
