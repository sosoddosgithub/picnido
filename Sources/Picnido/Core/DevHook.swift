import Foundation

/// Development hooks, readable whether or not the process could be given an environment.
///
/// The `PICNIDO_*` switches scattered around this app are meant to be used from a scripted run, and
/// the runs that matter most — the ones LaunchServices starts, which are the only ones that
/// reproduce what a Finder double-click does — cannot be given environment variables at all:
/// `open --env` is silently ignored as soon as a document argument is also present, `launchctl
/// setenv` needs root, and an app started by `open` inherits nothing from the shell. So every hook
/// also accepts its value from a file named exactly after the variable:
///
///     mkdir -p /tmp/picnido-hook
///     echo 6 > /tmp/picnido-hook/PICNIDO_VIEWER_AUTOCLOSE
///
/// The environment wins where both are present, so a run started from a shell behaves exactly as
/// it always did. With no variable and no file the hook is inert: nothing here changes what an
/// ordinary run does.
enum DevHook {

    static let directory = "/tmp/picnido-hook"

    /// The value of `name` from the environment, else from `<directory>/<name>`, else `nil`.
    static func string(_ name: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { return value }
        guard let raw = try? String(contentsOfFile: "\(directory)/\(name)", encoding: .utf8) else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func double(_ name: String) -> Double? { string(name).flatMap(Double.init) }

    static func isSet(_ name: String) -> Bool { string(name) != nil }
}
