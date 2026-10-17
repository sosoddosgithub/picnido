import SwiftUI
import AppKit

/// "Find photo folders" — sweep a location for pictures, then let the user tick which
/// folders to pull into the library.
///
/// The search is done by `fd` (see `FolderScanner`); this view collects the parameters and
/// presents the result. The result is a **tree**, because a photo library lives in a
/// hierarchy and ticking a parent has to mean "everything under here".
///
/// The shape follows the job: the left half is a folder tree with tick boxes, the right
/// half offers *Scan Once* / *Scan Always* / *Remove from Library* for whichever folder is
/// selected. The library carries a two-state switch between a folder-tree view and a flat
/// view, which is what the shape toggle below reproduces. Counts read `"%d photos (%s)"` —
/// the first number is how many pictures you are about to pull in, the second is the size.
struct ScanFoldersSheet: View {

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    private enum Origin: String, CaseIterable, Identifiable {
        case pictures = "Pictures"
        case home = "Home"
        case desktop = "Desktop"
        case downloads = "Downloads"
        case custom = "Choose…"
        var id: String { rawValue }
    }

    @State private var origin: Origin = .home
    @State private var customRoot: URL?
    @State private var minSize: Double = 100
    @State private var unitMultiplier: Double = 1024          // KB
    @State private var scanning = false
    @State private var tree: [ScanNode] = []
    @State private var flat: [ScannedFolder] = []
    @State private var treeMode = true
    @State private var expanded = Set<String>()
    @State private var selected = Set<String>()
    @State private var note = ""
    @State private var scannedRootPath = ""

    /// Set **only** by the `PICNIDO_SCAN_AUTORUN` hook. Without it a scripted snapshot would
    /// show a folder tree from one directory while the "Look in" picker still read "Home",
    /// which is a misleading picture of what the panel actually did.
    ///
    /// Read straight from the environment as the state's initial value rather than assigned
    /// in `.task`: a later write did not reliably re-render `controls` (the picker kept
    /// showing "Home" while the list below came from somewhere else), whereas an initial
    /// value is correct on the very first pass.
    @State private var forcedRoot: String? =
        ProcessInfo.processInfo.environment["PICNIDO_SCAN_AUTORUN"].flatMap { $0.isEmpty ? nil : $0 }

    private var engineLabel: String {
        FolderScanner.fdVersion().map { "\($0) · multithreaded" } ?? "built-in scanner (fd not found)"
    }

    private var rootURL: URL? {
        switch origin {
        case .pictures: return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        case .home: return FileManager.default.homeDirectoryForCurrentUser
        case .desktop: return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .downloads: return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .custom: return customRoot
        }
    }

    private var forcedRootPath: URL? {
        forcedRoot.map { URL(fileURLWithPath: $0) }
    }

    private var rows: [(node: ScanNode, depth: Int)] {
        ScanNode.flatten(tree, expanded: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controls
            Divider()
            resultsArea
            Divider()
            footer
        }
        .frame(width: 720, height: 660)
        // Regression hook: PICNIDO_SCAN_AUTORUN=<dir> sweeps that folder straight away
        // (PICNIDO_SCAN_EXPAND also opens every node), so a scripted snapshot can capture the
        // tree without a human pressing Scan. It bypasses the "Look in" picker on purpose —
        // driving `origin` would trip the picker's own onChange handler.
        .task {
            // Before anything else, so the sweep below uses the library's real floor and the
            // field is showing it by the time the first result row appears.
            adoptStoredFloor()
            let env = ProcessInfo.processInfo.environment
            guard let dir = env["PICNIDO_SCAN_AUTORUN"], !dir.isEmpty,
                  tree.isEmpty, !scanning else {
                log("[scan] autorun skipped (env=\(env["PICNIDO_SCAN_AUTORUN"] ?? "nil"))")
                return
            }
            log("[scan] autorun root=\(dir)")
            customRoot = URL(fileURLWithPath: dir)
            startScan(rootOverride: URL(fileURLWithPath: dir))
        }
  }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Find Photo Folders")
                .font(.headline)
            Text("Sweeps a location for pictures, then shows the folder tree they live in.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Image(systemName: FolderScanner.fdPath() != nil ? "bolt.fill" : "tortoise.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(FolderScanner.fdPath() != nil ? .green : .orange)
                Text("Search engine: \(engineLabel)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Look in")
                    .frame(width: 74, alignment: .leading)
                if let forcedRoot {
                    // The autorun hook swept this folder directly, so show *it* rather than
                    // the picker's untouched default.
                    Text(URL(fileURLWithPath: forcedRoot).lastPathComponent)
                        .frame(width: 140, alignment: .leading)
                        .lineLimit(1)
                } else {
                    Picker("", selection: $origin) {
                        ForEach(Origin.allCases) { Text(localizedString($0.rawValue)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                Spacer()
                if let root = forcedRootPath ?? rootURL {
                    Text(root.path)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 10) {
                Text("Ignore under")
                    .frame(width: 74, alignment: .leading)
                TextField("", value: $minSize, format: .number)
                    .frame(width: 66)
                    .multilineTextAlignment(.trailing)
                // The conversion lives in the picker's own setter rather than in an
                // `onChange(of: unitMultiplier)`. That observer fires *after* the state change
                // settles, so `adoptStoredFloor()` — which sets the unit and the value together —
                // had its freshly-converted value converted a second time: "2 MB" became
                // "2 KB" became 0.0, the field went blank-ish, and the sweep ran with no floor
                // at all. A binding setter only runs for a real click, so programmatic writes
                // pass through untouched.
                Picker("", selection: unitSelection) {
                    Text("KB").tag(1024.0)
                    Text("MB").tag(1_048_576.0)
                }
                .labelsHidden()
                .frame(width: 66)

                // A slider as well as a field: the useful range is "none" to a few megabytes, it
                // is a quantity you judge by eye rather than type, and dragging it is how you
                // discover where the junk pictures stop and the real ones start.
                //
                // No `step:` argument. SwiftUI draws a tick mark per step on macOS, and these
                // ranges run to 204 steps — the track rendered as a grey striped bar. The
                // snapping is done on write instead, which gives the same granularity with a
                // clean rail.
                Slider(value: snappedMinSize)
                    .frame(width: 168)
                    .help("Pictures smaller than this are left out of the library, not just out of this list")

                Text(localizedString(minSize <= 0 ? "no limit — every picture is kept" : "smaller pictures are skipped"))
                    .font(.caption)
                    .foregroundStyle(minSize <= 0 ? .tertiary : .secondary)
                    .frame(width: 168, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                Button { startScan() } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                        .frame(width: 76)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(scanning || rootURL == nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onChange(of: origin) { _, newValue in
            if newValue == .custom, customRoot == nil { pickCustomRoot() }
        }
    }

    /// Changing the unit keeps the *meaning*: switching 100 KB to "MB" must not silently turn the
    /// floor into 100 MB.
    private var unitSelection: Binding<Double> {
        Binding(
            get: { unitMultiplier },
            set: { new in
                guard new > 0, new != unitMultiplier else { return }
                let old = unitMultiplier
                unitMultiplier = new
                minSize = min(sizeSliderMax, (minSize * old / new * 10).rounded() / 10)
            }
        )
    }

    /// The slider writes through here so the value stays on the current unit's grid. See the
    /// comment on the `Slider` itself for why this is not a `step:` argument.
    private var snappedMinSize: Binding<Double> {
        Binding(
            get: { min(minSize, sizeSliderMax) },
            set: { raw in
                let s = sizeSliderStep
                minSize = min(sizeSliderMax, max(0, (raw / s).rounded() * s))
            }
        )
    }

    /// Slider range follows the unit: 0–2 MB in KB steps, 0–64 MB in MB steps. It never shrinks
    /// below the value in the field, so a floor restored from the library or typed by hand is
    /// always somewhere the thumb can actually sit.
    private var sizeSliderMax: Double {
        let nominal: Double = unitMultiplier >= 1_048_576 ? 64 : 2048
        return max(nominal, minSize.rounded(.up))
    }
    private var sizeSliderStep: Double { unitMultiplier >= 1_048_576 ? 0.5 : 10 }

    /// Shows whatever floor the library is already using, so the panel does not present a
    /// default that would quietly contradict the library the moment "Add" is pressed.
    private func adoptStoredFloor() {
        let stored = app.store.minPhotoBytes
        guard stored > 0 else { return }
        if stored >= 1_048_576 {
            unitMultiplier = 1_048_576
            minSize = (Double(stored) / 1_048_576 * 10).rounded() / 10
        } else {
            unitMultiplier = 1024
            minSize = Double(stored) / 1024
        }
    }

    // MARK: - Results

    private var resultsArea: some View {
        VStack(spacing: 0) {
            if !tree.isEmpty {
                shapeBar
                Divider()
            }
            Group {
                if scanning {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Sweeping \(rootURL?.lastPathComponent ?? "")…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tree.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 34))
                            .foregroundStyle(.tertiary)
                        Text(localizedString(note.isEmpty ? "Press Scan to look for folders full of photos." : note))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if treeMode {
                    List {
                        ForEach(rows, id: \.node.id) { entry in
                            nodeRow(entry.node, depth: entry.depth)
                        }
                    }
                    .listStyle(.inset)
                } else {
                    List(flat) { folder in
                        flatRow(folder)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Tree / flat — the two shapes the folder list can take.
    private var shapeBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $treeMode) {
                Label("Folder tree", systemImage: "list.bullet.indent").tag(true)
                Label("Flat", systemImage: "list.bullet").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            Spacer()

            if treeMode {
                Button("Expand All") { expanded = Set(tree.flatMap(\.subtree).map(\.path)) }
                Button("Collapse All") { expanded.removeAll() }
            }

            Text("\(tree.reduce(0) { $0 + $1.totalCount }) photos in \(tree.count) top-level folders")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Rows

    private func nodeRow(_ node: ScanNode, depth: Int) -> some View {
        HStack(spacing: 8) {
            checkBox(node.path)

            // The disclosure triangle. It used to be a `Button` while the whole row carried
            // `.contentShape(Rectangle()).onTapGesture { toggle }` — a synthetic click proof
            // showed the row gesture swallowing the hit: clicking dead centre on the triangle
            // ticked the checkbox instead of opening the branch. The triangle and the select
            // region now occupy disjoint areas, so neither can steal the other's click.
            Group {
                if node.isLeaf {
                    Color.clear
                } else {
                    Image(systemName: expanded.contains(node.path) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 16)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleExpanded(node.path) }
                }
            }
            .frame(width: 12)

            // Everything from here rightwards selects the folder.
            HStack(spacing: 8) {
                ScanThumb(url: node.sample)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Image(systemName: node.isLeaf ? "folder" : "folder.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(node.name)
                            .font(.system(size: 13, weight: node.isLeaf ? .regular : .medium))
                            .lineLimit(1)
                        if node.inLibrary {
                            Text("in library")
                                .font(.system(size: 9))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if depth == 0 {
                        Text(scannedRootPath)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                // The count in parentheses — the original's `"%d photos (%s)"`, minus the path.
                Text("(\(node.totalCount))")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()

                if !node.isLeaf, node.ownCount > 0 {
                    Text("· \(node.ownCount) here")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }

                Text(node.sizeText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 62, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(node.path) }
        }
        .padding(.vertical, 2)
        .padding(.leading, CGFloat(depth) * 16)
    }

    /// Hand-drawn checkbox. A `Toggle(isOn:)` bound to `selected` did not repaint when the
    /// row's tap gesture changed the very same set — the footer updated while every box stayed
    /// visually empty. Reading `selected` inline removes the binding cache from the picture.
    private func checkBox(_ path: String) -> some View {
        let on = selected.contains(path)
        return Image(systemName: on ? "checkmark.square.fill" : "square")
            .font(.system(size: 15))
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .onTapGesture { toggle(path) }
    }

    private func toggleExpanded(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }

    private func flatRow(_ folder: ScannedFolder) -> some View {
        HStack(spacing: 8) {
            checkBox(folder.path)

            // Same split as `nodeRow`: the select region starts to the right of the box, so a
            // click on the box cannot be double-counted by the row's own tap gesture.
            HStack(spacing: 10) {
                ScanThumb(url: folder.sample)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(folder.name)
                            .font(.system(size: 13, weight: .medium))
                        if folder.inLibrary {
                            Text("in library")
                                .font(.system(size: 9))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(folder.parent)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Text("(\(folder.photoCount))")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()

                Text(folder.sizeText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 62, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(folder.path) }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(summary.text(app.language))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Button("Select Top 10") {
                let top = (treeMode ? tree.map(\.path) : flat.map(\.path))
                    .filter { !selected.contains($0) }
                selected = Set(top.prefix(10))
            }
            .disabled(tree.isEmpty)

            Button("Clear") { selected.removeAll() }
                .disabled(selected.isEmpty)

            Button("Cancel") { dismiss() }

            Button(addTitle.text(app.language)) { addSelected() }
                .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summary: StatusNote {
        if scanning { return StatusNote("Scanning…") }
        if tree.isEmpty { return StatusNote("No results yet") }
        var note = StatusNote("%lld selected · %lld photos will be added",
                              [selected.count, photosToAdd])
        if minBytes > 0 { note.append(" · under %@ ignored", [LibraryStore.sizeText(minBytes)]) }
        return note
    }

    /// Folders are added recursively, so a selected parent swallows its selected children —
    /// counting both would double the number the footer promises.
    private var effectiveSelection: [String] {
        let paths = selected.sorted()
        return paths.filter { candidate in
            !paths.contains { other in
                other != candidate && candidate.hasPrefix(other + "/")
            }
        }
    }

    private var photosToAdd: Int {
        let nodes = tree.flatMap(\.subtree).filter { effectiveSelection.contains($0.path) }
        return nodes.reduce(0) { $0 + $1.totalCount }
    }

    private var addTitle: StatusNote {
        let n = effectiveSelection.count
        return n == 0
            ? StatusNote("Add Folders")
            : StatusNote("Add %lld Folder\(n == 1 ? "" : "s")", [n])
    }

    // MARK: - Actions

    private func toggle(_ path: String) {
        if selected.contains(path) { selected.remove(path) } else { selected.insert(path) }
    }

    private func pickCustomRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Search Here"
        panel.message = "Pick the folder to sweep for pictures"
        if panel.runModal() == .OK, let url = panel.urls.first {
            customRoot = url
        } else {
            origin = .home
        }
    }

    /// The size floor, in bytes. One definition, so the sweep and the import cannot drift apart.
    private var minBytes: Int64 { Int64(max(0, minSize) * unitMultiplier) }

    private func startScan(rootOverride: URL? = nil) {
        guard let root = rootOverride ?? rootURL else { return }
        let bytes = minBytes
        // Never let someone sweep a whole volume by accident.
        guard root.path != "/" else {
            note = "Pick a folder below the volume root — sweeping the whole disk would take a long time."
            return
        }

        scanning = true
        tree = []
        flat = []
        selected = []
        expanded = []
        note = ""

        let existing = Set(app.store.roots.map { $0.standardizedFileURL.path })
        let started = Date()
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                () -> (tree: [ScanNode], flat: [ScannedFolder]) in
                (FolderScanner.scanTree(root: root, minBytes: bytes, existingRoots: existing),
                 FolderScanner.scan(root: root, minBytes: bytes, existingRoots: existing))
            }.value

            let elapsed = Date().timeIntervalSince(started)
            tree = result.tree
            flat = result.flat
            scannedRootPath = root.path
            scanning = false
            // PICNIDO_SCAN_EXPAND=1 opens every branch. Done here rather than in an
            // `onChange(of: tree.count)` on the view: that observer silently never fired
            // (the state write landed inside an AttributeGraph cycle), so the snapshot
            // always showed a collapsed tree.
            if ProcessInfo.processInfo.environment["PICNIDO_SCAN_EXPAND"] != nil {
                let open = Set(result.tree.flatMap(\.subtree).filter { !$0.isLeaf }.map(\.path))
                expanded = open
                log("[scan] expanded \(open.count) nodes of \(result.tree.count) roots")
            }
            if result.tree.isEmpty {
                note = "Nothing matched. Try lowering the size threshold or picking another location."
            } else {
                app.statusText = StatusNote("Scan found %lld folders in %.2fs (%@)",
                                            [result.tree.count, elapsed, engineLabel])
            }
            // PICNIDO_SCAN_SHEET_DUMP=1 — print the tree this panel actually built, so the skip
            // rules can be checked as text instead of by reading a screenshot of the list.
            // (Named apart from `PICNIDO_SCAN_DUMP`, which is the headless sweep hook and takes a
            // directory, not a flag.)
            if ProcessInfo.processInfo.environment["PICNIDO_SCAN_SHEET_DUMP"] != nil {
                func walk(_ nodes: [ScanNode], _ depth: Int) -> String {
                    var text = ""
                    for node in nodes {
                        text += String(repeating: "    ", count: depth)
                            + "\(node.name) (\(node.totalCount)) own=\(node.ownCount)  \(node.path)\n"
                        text += walk(node.children, depth + 1)
                    }
                    return text
                }
                log("--- sweep tree root=\(root.path) floor=\(bytes) ---")
                log(walk(result.tree, 0))
                log("--- end sweep tree (\(result.tree.flatMap(\.subtree).count) nodes) ---")
            }
        }
    }

    private func addSelected() {
        let chosen = effectiveSelection
        // The floor goes into the library, not just into this panel. The panel has always
        // promised "(24)" next to a folder while the import took all three hundred files in it;
        // the number shown and the number added are now produced by the same rule.
        app.store.applyMinPhotoBytes(minBytes)
        for path in chosen {
            app.store.addRoot(URL(fileURLWithPath: path))
        }
        var note = StatusNote("Added %lld folder\(chosen.count == 1 ? "" : "s") from the scan", [chosen.count])
        if minBytes > 0 { note.append(" (ignoring anything under %@)", [LibraryStore.sizeText(minBytes)]) }
        app.statusText = note
        dismiss()
    }
}

/// Diagnostics-only channel shared by the scan hooks; harmless in normal use.
private func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Tiny async thumbnail for a scanned folder's sample photo.
private struct ScanThumb: View {
    let url: URL?
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            guard let url else { image = nil; return }
            let target = url
            image = await Task.detached(priority: .utility) { () -> CGImage? in
                ImageEngine.shared.thumbnailNow(for: PhotoItem(url: target), displaySize: 34)
            }.value
        }
    }
}
