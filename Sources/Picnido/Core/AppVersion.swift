import Foundation

/// The release number this bundle was built as, read from `Info.plist`.
///
/// Read from the bundle rather than written here on purpose. A version constant in the source is
/// a second copy of the same fact, and when the two drift the one on screen is the wrong one —
/// a window proudly showing 1.1.1 above an app that is 1.2. Keeping `build_app.sh` as the only
/// place a version is typed means the top bar cannot lie.
///
/// Running the bare `.build/release/Picnido` binary has no bundle and therefore no Info.plist;
/// that reports `dev`, which is exactly what a non-release build should look like.
enum AppVersion {

    /// `CFBundleShortVersionString` — the marketing number, e.g. "1.1.1".
    static let short: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    /// `CFBundleVersion` — the build number. Bumped every release even when `short` does not
    /// change, which is what makes two builds of "1.1.1" distinguishable after the fact.
    static let build: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""

    /// What the top of the window shows: "Picnido v1.1.1".
    static let display = "Picnido v\(short)"

    /// Hover text: "Picnido v1.1.1 (build 3)".
    static var detail: String {
        build.isEmpty ? display : "\(display) (build \(build))"
    }
}
