import Foundation

/// A folder that turned up during a photo sweep, with the numbers the picker shows.
struct ScannedFolder: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let photoCount: Int
    let totalBytes: Int64
    let sample: URL?
    let inLibrary: Bool

    var name: String { (path as NSString).lastPathComponent }
    var parent: String { (path as NSString).deletingLastPathComponent }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }
}

/// One folder in the scanned hierarchy, with the counts the picker shows in parentheses.
///
/// Groups the scanned folders into a hierarchy, with the counts the picker shows in
/// parentheses. Two numbers matter for a folder, and they are not the same one:
///
/// * `ownCount` — pictures sitting directly in this folder;
/// * `totalCount` — pictures in it *and* everything below it.
///
/// A folder you tick in the picker is added recursively, so the count next to its name has to
/// be `totalCount` or the number would understate what you are about to pull in.
struct ScanNode: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let ownCount: Int
    let ownBytes: Int64
    let totalCount: Int
    let totalBytes: Int64
    let sample: URL?
    let inLibrary: Bool
    let children: [ScanNode]

    var isLeaf: Bool { children.isEmpty }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }

    /// Depth-first flattening, honouring which folders are expanded.
    static func flatten(_ nodes: [ScanNode], expanded: Set<String>, depth: Int = 0) -> [(node: ScanNode, depth: Int)] {
        var out: [(node: ScanNode, depth: Int)] = []
        for node in nodes {
            out.append((node: node, depth: depth))
            if expanded.contains(node.path) {
                out.append(contentsOf: flatten(node.children, expanded: expanded, depth: depth + 1))
            }
        }
        return out
    }

    /// Every node in the subtree, so "select folder" can also show how much it drags in.
    var subtree: [ScanNode] { [self] + children.flatMap(\.subtree) }
}

/// Discovers folders that are full of photos.
///
/// The heavy lifting goes to `fd` (https://github.com/sharkdp/fd) — a multithreaded Rust
/// search tool that walks an entire home directory in about a second. If `fd` is missing we
/// fall back to a `FileManager` walk, so the feature loses speed instead of failing.
enum FolderScanner {

    // MARK: - Engine discovery

    static let fdCandidates: [String] = [
        "/opt/homebrew/bin/fd",
        "/usr/local/bin/fd",
        "/usr/bin/fd",
        NSHomeDirectory() + "/.local/bin/fd",
        NSHomeDirectory() + "/.cargo/bin/fd",
    ]

    static func fdPath() -> String? { cachedFDPath }

    /// Memoised on purpose. `fdVersion()` was being called straight from a SwiftUI `body`
    /// (`ScanFoldersSheet.engineLabel`), so *every* re-render forked an `fd --version`
    /// subprocess and blocked the main thread in `waitUntilExit()` — inside the layout pass.
    /// That re-entrancy is what produced the endless `AttributeGraph: cycle detected` stream
    /// and the stale subviews (a tapped row updated the footer's buttons but not its label).
    /// Resolving once removes both the fork storm and the cycle.
    private static let cachedFDPath: String? = resolveFDPath()

    private static func resolveFDPath() -> String? {
        for candidate in fdCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let env = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in env.split(separator: ":") {
            let p = "\(dir)/fd"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// e.g. "fd 10.5.0", or nil when we are on the built-in walker. Resolved once — see above.
    static func fdVersion() -> String? { cachedFDVersion }

    private static let cachedFDVersion: String? = {
        guard let fd = cachedFDPath else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: fd)
        proc.arguments = ["--version"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }()

    // MARK: - Noise filter

    /// Directory names skipped at any depth — `~/Library` and `…/node_modules` alike.
    static let skipNames: [String] = [
        "Library", ".Trash", "node_modules", ".git", ".svn", ".hg", ".build",
        "Pods", "DerivedData", "__pycache__", ".venv", "venv", "Caches",
        ".npm", ".cargo", ".rustup", ".cache", "index-v5",
        "Photos Library.photoslibrary", "Containers", "Group Containers",
        // Program trees that happen to be full of images. A sweep of the Desktop turned up a
        // WordPress backup and offered its theme assets as a "photo folder" — those icons are
        // 1 KB apiece and nobody wants them in a picture library. Only names that cannot
        // plausibly be somebody's album are listed here.
        "wp-content", "wp-includes", "wp-admin", "site-packages",
        // Second pass, from re-sweeping the same Desktop now that the size floor is enforced:
        // what survived the floor were the *large* images inside program trees. These three names
        // are build/package artefacts and are never an album:
        //   `_internal`       — PyInstaller's output, e.g. a bundled mitmproxy's static assets
        //   `Assets.xcassets` — Xcode asset catalog; `AppIcon.appiconset` is a 1024px app icon
        //   `__MACOSX`        — the resource fork a zip leaves behind
        "_internal", "Assets.xcassets", "__MACOSX",
    ]

    /// Bundles are opaque; nothing inside them belongs in a photo library.
    ///
    /// `.*` covers every dotted entry, which is the cheapest possible rule for "not a photo
    /// album": a user's pictures never live in `~/.hanako`, `~/.config` or `~/.cache`. Without
    /// it, `--hidden` (needed so that a folder the user *did* pick is not silently skipped)
    /// also walks every application's private data directory.
    static let skipGlobs: [String] = [
        ".*",
        "*.app", "*.photoslibrary", "*.framework", "*.bundle", "*.xcodeproj",
        "*.tmp", "node_modules", ".git",
    ]

    // MARK: - Scan

    static func scan(root: URL, minBytes: Int64, existingRoots: Set<String>) -> [ScannedFolder] {
        let files: [URL]
        if let fd = fdPath() {
            files = runFD(executable: fd, root: root, minBytes: minBytes)
        } else {
            files = walk(root: root, minBytes: minBytes)
        }
        return group(files, existingRoots: existingRoots)
    }

    /// Same sweep, arranged as a hierarchy rooted at `root`.
    ///
    /// `fd` only reports files, so the folder tree is rebuilt from the directories those
    /// files landed in — which is what makes the picker able to offer a parent folder (and
    /// everything under it) rather than only the exact leaf directories that hold pictures.
    static func scanTree(root: URL, minBytes: Int64, existingRoots: Set<String>) -> [ScanNode] {
        let folders = scan(root: root, minBytes: minBytes, existingRoots: existingRoots)
        return tree(from: folders, rootPath: root.standardizedFileURL.path, existingRoots: existingRoots)
    }

    // MARK: - Hierarchy

    /// Folds a flat list of photo-bearing directories into a tree, aggregating counts upward.
    static func tree(from folders: [ScannedFolder], rootPath: String,
                     existingRoots: Set<String>) -> [ScanNode] {
        final class Box {
            let name: String
            let path: String
            var ownCount = 0
            var ownBytes: Int64 = 0
            var sample: URL?
            var children: [String: Box] = [:]
            init(name: String, path: String) { self.name = name; self.path = path }
        }

        let rootBox = Box(name: (rootPath as NSString).lastPathComponent, path: rootPath)

        for folder in folders {
            let relative = folder.path.hasPrefix(rootPath)
                ? String(folder.path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : folder.path
            guard !relative.isEmpty else {
                rootBox.ownCount += folder.photoCount
                rootBox.ownBytes += folder.totalBytes
                if rootBox.sample == nil { rootBox.sample = folder.sample }
                continue
            }

            var node = rootBox
            var walked = rootPath
            for part in relative.split(separator: "/") {
                walked += "/" + part
                if let existing = node.children[String(part)] {
                    node = existing
                } else {
                    let child = Box(name: String(part), path: walked)
                    node.children[String(part)] = child
                    node = child
                }
            }
            node.ownCount += folder.photoCount
            node.ownBytes += folder.totalBytes
            if node.sample == nil { node.sample = folder.sample }
        }

        func materialise(_ box: Box) -> ScanNode {
            let kids = box.children.values
                .map(materialise)
                .sorted { a, b in
                    if a.totalCount != b.totalCount { return a.totalCount > b.totalCount }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            let total = box.ownCount + kids.reduce(0) { $0 + $1.totalCount }
            let bytes = box.ownBytes + kids.reduce(Int64(0)) { $0 + $1.totalBytes }
            let sample = box.sample ?? kids.compactMap(\.sample).first
            let dir = box.path
            return ScanNode(path: box.path,
                            name: box.name,
                            ownCount: box.ownCount,
                            ownBytes: box.ownBytes,
                            totalCount: total,
                            totalBytes: bytes,
                            sample: sample,
                            inLibrary: existingRoots.contains { dir == $0 || dir.hasPrefix($0 + "/") },
                            children: kids)
        }

        return rootBox.children.values
            .map(materialise)
            .sorted { a, b in
                if a.totalCount != b.totalCount { return a.totalCount > b.totalCount }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    // MARK: - fd engine

    private static func runFD(executable: String, root: URL, minBytes: Int64) -> [URL] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)

        var args = [".", root.path, "--type", "f", "--absolute-path",
                    "--hidden", "--no-ignore", "--color", "never"]
        for ext in LibraryStore.imageExtensions.sorted() {
            args.append(contentsOf: ["-e", ext])
        }
        for name in skipNames {
            args.append(contentsOf: ["--exclude", name])
        }
        for glob in skipGlobs {
            args.append(contentsOf: ["--exclude", glob])
        }
        if minBytes > 0 {
            // `k` in fd's `--size` is 1000 bytes, not 1024, so a raw division let files up to
            // 2.3% under the threshold through — the setting said 100 KB and fd accepted 100,024
            // bytes. Rounding up keeps the promise exact.
            args.append(contentsOf: ["--size", "+\((minBytes + 999) / 1000)k"])
        }

        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard !data.isEmpty else { return [] }

        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0)) }
    }

    // MARK: - Built-in fallback

    private static func walk(root: URL, minBytes: Int64) -> [URL] {
        var found: [URL] = []
        // Hoisted out of the loop: `imageExtensions` reads `UserDefaults`, and this walk asks
        // once per file.
        let allowed = LibraryStore.imageExtensions
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let en = FileManager.default.enumerator(at: root,
                                                     includingPropertiesForKeys: Array(keys),
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var visited = 0
        while let next = en.nextObject() {
            guard let url = next as? URL else { continue }
            visited += 1
            if visited > 400_000 { break }

            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                // Same two rules the `fd` engine is given, so the fallback and the fast path
                // agree about what a photo folder is.
                if skipNames.contains(url.lastPathComponent) || url.lastPathComponent.hasPrefix(".") {
                    en.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            guard allowed.contains(url.pathExtension.lowercased()) else { continue }
            if minBytes > 0, Int64(values?.fileSize ?? 0) < minBytes { continue }
            found.append(url)
        }
        return found
    }

    // MARK: - Grouping

    private static func group(_ files: [URL], existingRoots: Set<String>) -> [ScannedFolder] {
        var buckets: [String: (count: Int, bytes: Int64, sample: URL?)] = [:]
        for url in files {
            let dir = url.deletingLastPathComponent().path
            var bucket = buckets[dir] ?? (0, 0, url)
            bucket.count += 1
            bucket.bytes += byteSize(of: url)
            if bucket.sample == nil { bucket.sample = url }
            buckets[dir] = bucket
        }

        return buckets.map { dir, bucket in
            ScannedFolder(path: dir,
                          photoCount: bucket.count,
                          totalBytes: bucket.bytes,
                          sample: bucket.sample,
                          inLibrary: existingRoots.contains { dir == $0 || dir.hasPrefix($0 + "/") })
        }
        .sorted { a, b in
            if a.photoCount != b.photoCount { return a.photoCount > b.photoCount }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
    }

    private static func byteSize(of url: URL) -> Int64 {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Int64(bytes)
    }
}
