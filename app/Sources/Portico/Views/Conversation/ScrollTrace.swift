import Foundation

/// v0.26.1 field diagnostic for jumpy scrolling: off unless the file
/// `scroll-trace` exists in the app's home (the folder the gateway's state
/// lives in), then one line per scroll reading and per move the app makes
/// itself, with why, appended to `scroll-trace.log` there.
/// No message text is written, only ids, offsets and reasons.
@MainActor
enum ScrollTrace {
    private static let directory = GatewaySupervisor.resolveHome().url
    static let enabled = FileManager.default.fileExists(atPath: directory.appendingPathComponent("scroll-trace").path)
    private static let start = Date()
    private static let handle: FileHandle? = {
        guard enabled else { return nil }
        let url = directory.appendingPathComponent("scroll-trace.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    static func note(_ line: @autoclosure () -> String) {
        guard enabled, let handle else { return }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        handle.write(Data("\(ms) \(line())\n".utf8))
    }
}
