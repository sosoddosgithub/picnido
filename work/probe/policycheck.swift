import AppKit

// Reads the activation policy of the running Picnido out of the window server, from outside the
// process. This is the only honest way to answer "is there a Dock icon?" without looking at the
// Dock: `.regular` means there is one, `.accessory` means there is not.

let names: [NSApplication.ActivationPolicy: String] = [
    .regular: "regular (Dock icon YES)",
    .accessory: "accessory (Dock icon NO)",
    .prohibited: "prohibited (no UI at all)",
]

let targets = CommandLine.arguments.count > 1 ? Array(CommandLine.arguments.dropFirst())
                                              : ["app.picnido.mac"]

for id in targets {
    let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == id }
    if apps.isEmpty {
        print("\(id): 未在运行")
        continue
    }
    for app in apps {
        let policy = names[app.activationPolicy] ?? "unknown(\(app.activationPolicy.rawValue))"
        print("\(id): pid=\(app.processIdentifier) policy=\(policy) active=\(app.isActive) hidden=\(app.isHidden) name=\(app.localizedName ?? "?")")
    }
}
