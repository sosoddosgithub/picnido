import Foundation

/// When this process started, so diagnostics can be printed on a single relative clock.
let appStartTime = Date()

/// Lightweight boot-time logger. Appends straight to disk so it survives a hang.
func bootLog(_ message: String) {
    let line = "[\(Date().timeIntervalSince1970)] \(message)\n"
    let path = "/tmp/picnido_boot.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) { handle.write(data) }
        try? handle.close()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
    FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
}
