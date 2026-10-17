import AppKit

// Standalone probe: what Apple Event does LaunchServices deliver when an app is
// launched by double-clicking a picture, and when does it arrive relative to
// applicationDidFinishLaunching? Writes to /tmp/probe/launch.log so a run started
// by `open -a` (which cannot carry environment variables) still leaves a trace.

let logPath = "/tmp/probe/launch.log"

func log(_ s: String) {
    let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
    let line = "\(stamp) \(s)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
}

func fourCC(_ v: UInt32) -> String {
    let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    let s = String(bytes: bytes, encoding: .isoLatin1) ?? "?"
    return "\(s)(0x\(String(v, radix: 16)))"
}

func describe(_ e: NSAppleEventDescriptor?) -> String {
    guard let e else { return "nil" }
    return "class=\(fourCC(e.eventClass)) id=\(fourCC(e.eventID)) items=\(e.numberOfItems) desc=\(e.description.prefix(160))"
}

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    var oappSeen = false
    var odocSeen = false
    var openedFiles: [String] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        let e = NSAppleEventManager.shared().currentAppleEvent
        log("willFinishLaunching  currentAppleEvent=\(describe(e))")
        // Does AppKit tolerate us watching oapp as well?
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOapp(_:replyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenApplication)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let e = NSAppleEventManager.shared().currentAppleEvent
        log("didFinishLaunching   currentAppleEvent=\(describe(e))")
        for delay in [0.05, 0.25, 0.5, 1.0, 1.5, 2.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                log("t+\(delay)  oapp=\(self.oappSeen) odoc=\(self.odocSeen) files=\(self.openedFiles.count)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            log("FINAL oapp=\(self.oappSeen) odoc=\(self.odocSeen) files=\(self.openedFiles)")
            NSApp.terminate(nil)
        }
    }

    @objc func handleOapp(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        oappSeen = true
        log("kAEOpenApplication(oapp) received")
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        odocSeen = true
        openedFiles = filenames
        log("openFiles count=\(filenames.count) \(filenames)")
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        odocSeen = true
        openedFiles = urls.map(\.path)
        log("open(urls:) count=\(urls.count) \(openedFiles)")
    }
}

let app = NSApplication.shared
let delegate = ProbeDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
log("=== probe start pid=\(ProcessInfo.processInfo.processIdentifier) argv=\(CommandLine.arguments) ===")
app.run()
