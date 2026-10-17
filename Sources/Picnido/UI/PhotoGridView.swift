import SwiftUI
import AppKit

extension ColorLabel {
    /// The model stays free of SwiftUI; this is the one place the six colours become a `Color`.
    static func swiftUIColor(_ index: Int) -> Color {
        let rgb = rgb(index)
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

/// The grid.
///
/// Two switches from the toolbar reach in here and neither is a mode of the other:
///
/// * **Masonry** (`AppState.masonryLayout`) changes the *layout* — uniform squares, or columns of
///   one width where every picture keeps its own height.
/// * **Folder headings** (`AppState.showFolderHeaders`) changes the *sequence* — one flat list, or
///   the same list cut into runs by folder with a heading above each run.
///
/// All four combinations are drawn, which is why the two questions are answered in separate
/// places below rather than folded into one "layout mode". The headings are a property of the
/// list, so they behave the same whichever layout is showing them.
struct PhotoGridView: View {
    @Environment(AppState.self) private var app
    @State private var lastClickedIndex: Int?

    /// Height of everything in a cell that is not the picture: the caption line, the 5-point gap
    /// above it, and the cell's own padding. The masonry needs it to know how much room a picture
    /// really takes, because the caption is the same height whether or not it has anything to say
    /// (see `PhotoCell.captionLine`).
    private static let cellChrome: CGFloat = 24

    /// The gap between cells, in both layouts.
    private static let gap: CGFloat = 14

    /// The uniform grid's columns — the shape the library has always had.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: app.store.thumbnailSize, maximum: app.store.thumbnailSize * 1.35),
                  spacing: Self.gap)]
    }

    var body: some View {
        // The width is read here rather than inside the scroll view because the masonry needs it
        // to decide how many columns fit, and a `GeometryReader` inside a `ScrollView` has no
        // height to offer — it would collapse to nothing.
        GeometryReader { geo in
            ScrollView {
                if app.store.visiblePhotos.isEmpty {
                    emptyState
                } else {
                    sections(width: geo.size.width)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
    }

    // MARK: The two layouts

    /// The list, cut into folders when the headings are on, drawn with whichever layout is on.
    @ViewBuilder
    private func sections(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups) { group in
                if let path = group.path {
                    FolderHeadingRow(path: path, count: group.photos.count)
                }
                if app.masonryLayout {
                    masonry(group, width: width)
                } else {
                    uniform(group)
                }
            }
        }
        .padding(16)
    }

    /// The grid: every cell the slider's size, in reading order.
    private func uniform(_ group: PhotoGroup) -> some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(Array(group.photos.enumerated()), id: \.element.id) { i, photo in
                PhotoCell(photo: photo, index: group.offset + i, lastClickedIndex: $lastClickedIndex)
            }
        }
    }

    /// The masonry: columns of one width, each picture its own height, dealt to whichever column
    /// is shortest at the moment.
    ///
    /// The dealing is the part that matters. Handing out every Nth picture instead is a line
    /// shorter and leaves the bottom edge of the grid a staircase whenever the shapes are mixed —
    /// and mixed shapes are the entire reason to offer this layout, so the cheap version fails in
    /// exactly the case anyone would turn it on for. Choosing the shortest column costs one pass
    /// over the visible list and keeps the columns within a cell's height of each other.
    ///
    /// Ratio is clamped to 6:1 either way. A panorama would otherwise claim a column for a
    /// screenful, and a stitched vertical scan the same — the clamp costs those two an accurate
    /// height and buys back a grid the other pictures are still visible in.
    private func masonry(_ group: PhotoGroup, width: CGFloat) -> some View {
        let gap = Self.gap
        let target = max(80, app.store.thumbnailSize)
        let usable = max(1, width - 32)                       // the 16-point content padding
        let count = max(1, Int((usable + gap) / (target + gap)))
        let columnWidth = (usable - gap * CGFloat(count - 1)) / CGFloat(count)

        var heights = [CGFloat](repeating: 0, count: count)
        var lanes: [[Lane]] = Array(repeating: [], count: count)
        let limit: CGFloat = 6
        for (i, photo) in group.photos.enumerated() {
            let ratio = max(1 / limit, min(limit, photo.displayAspectRatio))
            let height = (columnWidth / ratio).rounded()
            let shortest = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            lanes[shortest].append(Lane(photo: photo, index: group.offset + i, height: height))
            heights[shortest] += height + Self.cellChrome + gap
        }

        return HStack(alignment: .top, spacing: gap) {
            ForEach(lanes.indices, id: \.self) { lane in
                LazyVStack(spacing: gap) {
                    ForEach(lanes[lane]) { item in
                        PhotoCell(photo: item.photo,
                                  index: item.index,
                                  lastClickedIndex: $lastClickedIndex,
                                  cellSize: CGSize(width: columnWidth, height: item.height))
                    }
                }
                .frame(width: columnWidth)
            }
        }
    }

    /// One picture in one masonry column.
    private struct Lane: Identifiable {
        let photo: PhotoItem
        let index: Int
        let height: CGFloat
        var id: String { photo.id }
    }

    // MARK: The sequence

    /// One run of pictures, with the heading that introduces it when there is one.
    private struct PhotoGroup: Identifiable {
        /// The folder this run came from, or nil for the single heading-less group the grid draws
        /// when the switch is off.
        let path: String?
        let photos: [PhotoItem]
        /// Where this run starts in `visiblePhotos`.
        ///
        /// Shift-click ranges and `GridPrefetch` both count in whole-list indices, so the offset
        /// travels with the group. Recomputing it from the number of cells already drawn would
        /// work until the first time a heading is inserted, and then every range would be short by
        /// the pictures the previous headings did not draw.
        let offset: Int

        var id: String { path ?? "\u{0}" }
    }

    /// The list, cut into folders when the headings are on.
    ///
    /// Cutting, not re-sorting. Groups come in the order their folder first appears in the sorted
    /// list, and inside a group the sort the user chose is untouched — so turning the switch on
    /// inserts headings into the list that is already on screen instead of rearranging it. A
    /// folder whose pictures are scattered through the sort does gather into one block, which is
    /// the point of the switch; but no block jumps ahead of another block's first picture, so the
    /// overall order stays recognisable.
    private var groups: [PhotoGroup] {
        let list = app.store.visiblePhotos
        guard app.showFolderHeaders else {
            return [PhotoGroup(path: nil, photos: list, offset: 0)]
        }
        var order: [String] = []
        var buckets: [String: [PhotoItem]] = [:]
        var start: [String: Int] = [:]
        for (i, photo) in list.enumerated() {
            let key = photo.folder.path
            if buckets[key] == nil {
                order.append(key)
                start[key] = i
            }
            buckets[key, default: []].append(photo)
        }
        return order.map { PhotoGroup(path: $0, photos: buckets[$0] ?? [], offset: start[$0] ?? 0) }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text(localizedString(app.store.photos.isEmpty
                                 ? "Import a folder to start your library"
                                 : "Nothing here"))
                .foregroundStyle(.secondary)
            if app.store.photos.isEmpty {
                Button("Import Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.prompt = "Import"
                    if panel.runModal() == .OK {
                        for u in panel.urls { app.store.addRoot(u) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(60)
    }
}

/// The line the "show folder paths" switch puts above each folder's run of pictures.
///
/// It is a heading *and* a rule. The divider is the half that does the separating the switch
/// promises — the grid can be a wall of pictures with nothing in it to say where one folder
/// stopped and the next began, and a heading without a line above it reads as a caption on the
/// first picture rather than as the start of a section.
///
/// The folder's own name is what the eye needs; the abbreviated full path is there because two
/// folders called `2024` are common and the path is the only thing that tells them apart. It is
/// the part that gets truncated when the window is narrow, and it is truncated in the middle so
/// both ends of the path survive.
private struct FolderHeadingRow: View {
    let path: String
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(count) photos")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .help(path)
        }
        .padding(.top, 20)
        .padding(.bottom, 2)
    }
}

struct PhotoCell: View {
    @Environment(AppState.self) private var app
    let photo: PhotoItem
    let index: Int
    @Binding var lastClickedIndex: Int?

    /// How big this cell draws, when the layout wants to decide rather than the slider.
    ///
    /// The uniform grid leaves it nil and lets `thumbnailSize` govern, which is what it has always
    /// done. The masonry passes the column width it worked out and the height that picture's shape
    /// asks for, because in a masonry the two are no longer the same number — that is the whole
    /// difference between the two layouts.
    var cellSize: CGSize?

    @State private var hovering = false

    private var cellWidth: CGFloat { cellSize?.width ?? CGFloat(app.store.thumbnailSize) }
    private var cellHeight: CGFloat { cellSize?.height ?? CGFloat(app.store.thumbnailSize) }

    private var isSelected: Bool { app.store.selection.contains(photo.id) }
    private var inTray: Bool { app.store.tray.contains(photo.id) }

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topLeading) {
                ThumbnailView(photo: photo, size: cellWidth)
                    .frame(width: cellWidth, height: cellHeight)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                                          lineWidth: isSelected ? 3 : 1)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)

                if photo.starred {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.yellow)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .padding(4)
                }
                if photo.hasEdits {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white, Color.accentColor)
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                if inTray {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white, Color.blue)
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                // The colour label, in the one corner the star, the tray and the edit pencil
                // leave free. A filled square rather than a dot: at 11 points a dot reads as an
                // artefact, and the original used a solid chip too.
                if photo.colorLabel > 0 {
                    let rgb = ColorLabel.rgb(photo.colorLabel)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(red: rgb.0, green: rgb.1, blue: rgb.2))
                        .frame(width: 11, height: 11)
                        .overlay(RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
                        .shadow(color: .black.opacity(0.35), radius: 1)
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .help("\(ColorLabel.name(photo.colorLabel)) label")
                }
                if photo.hidden {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white, Color.gray)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottom) {
                if hovering {
                    HStack(spacing: 8) {
                        Button {
                            app.store.toggleStar(photo.id)
                        } label: {
                            Image(systemName: photo.starred ? "star.fill" : "star")
                                .foregroundStyle(.yellow)
                        }
                        Button {
                            app.store.push(photo.id, .rotate(quarterTurns: -1))
                        } label: { Image(systemName: "rotate.left") }
                        Button {
                            app.store.push(photo.id, .rotate(quarterTurns: 1))
                        } label: { Image(systemName: "rotate.right") }
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 4)
                }
            }

            captionLine
        }
        .padding(3)
        .onAppear { GridPrefetch.warm(from: index, store: app.store) }
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            app.store.selection = [photo.id]
            app.openInViewer(photo.id)
        }
        .onTapGesture {
            handleClick()
        }
        .contextMenu { contextMenu }
        .help("\(photo.fileName)\n\(photo.dimensionsText) · \(photo.created.formatted(date: .abbreviated, time: .shortened))")
    }

    /// The line under the thumbnail, whose content the View menu chooses.
    ///
    /// When the chosen mode has nothing to say about a photo — Caption on an uncaptioned one,
    /// Tags on an untagged one — the line is dropped rather than shown blank, so the grid keeps
    /// its rhythm instead of growing a row of empty gaps.
    @ViewBuilder
    private var captionLine: some View {
        let text = app.captionMode.text(for: photo)
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: cellWidth)
                .foregroundStyle(.secondary)
        } else {
            Color.clear.frame(width: cellWidth, height: 13)
        }
    }

    private func handleClick() {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if app.store.selection.contains(photo.id) {
                app.store.selection.remove(photo.id)
            } else {
                app.store.selection.insert(photo.id)
            }
            lastClickedIndex = index
        } else if flags.contains(.shift), let start = lastClickedIndex {
            let lo = min(start, index), hi = max(start, index)
            let list = app.store.visiblePhotos
            guard hi < list.count else { return }
            app.store.selection = Set(list[lo...hi].map { $0.id })
        } else {
            app.store.selection = [photo.id]
            lastClickedIndex = index
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open in Photo Viewer") { app.openInViewer(photo.id) }
        Button("Edit") { app.startEditing(photo.id) }
        Button("Open in External Editor") { app.openInExternalEditor(photo.url) }
        Divider()
        Button(localizedString(photo.starred ? "Remove Star" : "Add Star")) { app.store.toggleStar(photo.id) }
        Button("Add to Photo Tray") { app.store.addToTray([photo.id]) }
        Menu("Add to Album") {
            ForEach(app.store.albums) { album in
                Button(album.name) { app.store.addToAlbum(album.id, ids: [photo.id]) }
            }
            if app.store.albums.isEmpty {
                Button("New Album…") { app.showNewAlbum = true }
            }
        }
        Menu("Colour Label") {
            Button {
                app.store.setColorLabel(0, ids: targets)
            } label: {
                Label {
                    Text(localizedString(photo.colorLabel == 0 ? "None  ✓" : "None"))
                } icon: {
                    Image(systemName: "square.slash")
                }
            }
            Divider()
            ForEach(ColorLabel.all, id: \.self) { index in
                Button {
                    app.store.setColorLabel(index, ids: targets)
                } label: {
                    Label {
                        Text(localizedString(photo.colorLabel == index
                                             ? "\(ColorLabel.name(index))  ✓"
                                             : ColorLabel.name(index)))
                    } icon: {
                        // A menu cannot draw a row of swatches the way the original's toolbar did,
                        // so each name carries its own colour as its icon.
                        Image(systemName: "square.fill")
                            .foregroundStyle(ColorLabel.swiftUIColor(index))
                    }
                }
            }
        }
        Divider()
        Button(localizedString(photo.hidden ? "Unhide Photo" : "Hide Photo")) {
            app.store.setHidden(!photo.hidden, ids: targets)
        }
        Divider()
        Button("Rotate Left") { app.store.push(photo.id, .rotate(quarterTurns: -1)) }
        Button("Rotate Right") { app.store.push(photo.id, .rotate(quarterTurns: 1)) }
        Button("Flip Horizontal") { app.store.push(photo.id, .flipHorizontal) }
        Menu("Apply Effect to Selection") {
            ForEach(FilterCatalog.effects.prefix(40)) { spec in
                Button(localizedString(spec.label)) { app.applyFilterToSelection(spec.id) }
            }
        }
        Button("Copy All Effects") { app.copyAllEffects(from: photo) }
            .disabled(AppState.transferableSteps(of: photo).isEmpty)
        Button("Paste All Effects") { app.pasteAllEffects(on: targets) }
            .disabled(app.copiedEffects == nil)
        Divider()
        Button("Rename Files…") {
            app.store.selection = Set(targets)
            app.showRename = true
        }
        Button("Adjust Photo Date…") {
            app.store.selection = Set(targets)
            app.showAdjustDate = true
        }
        Divider()
        Button("Export…") { app.showExport = true }
        Button("Properties") { app.showingInspectorFor = photo.id; app.infoPaneVisible = true }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([photo.url])
        }
    }

    /// Batch commands act on the whole selection when the right-clicked photo is part of it —
    /// the same rule every other file browser uses, and the one that makes "select twelve, then
    /// right-click one of them" do the obvious thing.
    private var targets: [String] {
        if app.store.selection.contains(photo.id) { return Array(app.store.selection) }
        return [photo.id]
    }
}

/// Lazily loaded thumbnail.
///
/// Three things changed when the library grew to five hundred photos:
///
/// * The decode no longer happens here. It goes through `ThumbnailCache`, which keeps a disk copy
///   of every thumbnail it has ever produced, so the second launch is a folder read instead of a
///   re-decode of the whole library.
/// * A memory hit is taken synchronously, so cells that scroll back into view paint on the first
///   frame instead of flashing a placeholder.
/// * Each cell warms the eighty photos behind it as it appears (`GridPrefetch`). Scrolling then
///   walks into a cache that is already populated rather than racing the decoder — which is the
///   difference between "the thumbnails can't keep up" and "the thumbnails are just there".
struct ThumbnailView: View {
    let photo: PhotoItem
    let size: CGFloat

    @State private var image: CGImage?
    /// Set the moment an animation frame arrives. The still-image path checks it before writing
    /// `image`, because both run when a cell appears and the still decode can easily finish
    /// second — it reads the disk, while the animation may already have a frame in hand.
    @State private var animated = false
    @State private var animation: AnimationHub.Token?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .clipped()
        .task(id: taskID) { await load() }
        .onAppear { startAnimation() }
        .onDisappear { stopAnimation() }
        .onChange(of: photo.id) { _, _ in
            stopAnimation()
            animated = false
            startAnimation()
        }
    }

    /// Reload when the file itself changes, not merely when the view is recycled.
    private var taskID: String {
        "\(photo.id)|\(photo.stack.count)|\(Int(photo.modified.timeIntervalSince1970))|\(Int(size))"
    }

    /// Animated files get their frames from the hub instead of from a decode of their own.
    ///
    /// The hub answers nil for everything that does not move, which is almost everything, so the
    /// still path below stays the only path for a normal library. Note that `animated` is not
    /// reset here: a cell that scrolls out and back gets the hub's last frame immediately, and
    /// that frame is a better thing to show than a reload of the still.
    @MainActor
    private func startAnimation() {
        guard animation == nil else { return }
        animation = AnimationHub.shared.subscribe(photo, priority: .visible) { frame in
            animated = true
            image = frame
        }
    }

    @MainActor
    private func stopAnimation() {
        animation?.cancel()
        animation = nil
    }

    @MainActor
    private func load() async {
        let started = Date()
        if let hit = ImageEngine.shared.cachedThumbnail(for: photo, displaySize: size) {
            if !animated { image = hit }
            Self.logLatency(photo, size, Date().timeIntervalSince(started) * 1000, cached: true)
            return
        }
        let p = photo
        let s = size
        let loaded: CGImage? = await withCheckedContinuation { continuation in
            ImageEngine.shared.thumbnail(for: p, displaySize: s, priority: .visible) { img in
                continuation.resume(returning: img)
            }
        }
        guard !Task.isCancelled else { return }
        if let loaded, !animated { image = loaded }
        Self.logLatency(photo, size, Date().timeIntervalSince(started) * 1000, cached: false)
    }

    /// `PICNIDO_THUMB_LATENCY=1` — how long a grid cell waited between asking for its picture and
    /// having it. This is the number "the cache cannot keep up when I scroll" is actually about:
    /// queue depth and decode counts describe the machinery, but only this describes the wait.
    nonisolated static func logLatency(_ photo: PhotoItem, _ size: CGFloat, _ ms: Double, cached: Bool) {
        guard ProcessInfo.processInfo.environment["PICNIDO_THUMB_LATENCY"] != nil else { return }
        PicnidoAppDelegate.report(String(format: "[thumb] +%.1fs %@ %@ %.0fsize %.0f ms%@",
                                        Date().timeIntervalSince(appStartTime),
                                        photo.url.lastPathComponent,
                                        cached ? "cached" : "decode",
                                        size, ms, ms > 50 ? "  <-- SLOW" : ""))
    }
}

/// Keeps the area just behind the scroll position warm.
///
/// Driven from each cell's `onAppear` rather than from scroll-offset observation: `LazyVGrid`
/// materialises cells roughly in reading order, so the cell that has just appeared is a good
/// enough anchor for "what is about to be needed", and this works on every macOS version the app
/// supports (the `onScrollTargetVisibilityChange` family is macOS 15 and newer).
enum GridPrefetch {
    /// How many photos ahead of the anchor to warm.
    static let ahead = 80

    static func warm(from index: Int, store: LibraryStore) {
        let list = store.visiblePhotos
        guard index >= 0, index < list.count else { return }
        let upper = min(list.count, index + ahead)
        let slice = Array(list[index..<upper])
        ImageEngine.shared.prefetch(photos: slice, displaySize: store.thumbnailSize)
    }
}

// MARK: - Photo tray

struct PhotoTrayView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "tray.full")
                    Text("Photo Tray")
                        .font(.caption).fontWeight(.semibold)
                }
                Text("\(app.store.tray.count) held")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 84, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(app.store.trayPhotos) { p in
                        ThumbnailView(photo: p, size: 52)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.15)))
                            .onTapGesture { app.store.removeFromTray([p.id]) }
                            .help("Click to remove from tray")
                    }
                    if app.store.tray.isEmpty {
                        Text("Select photos and press ⌘T to hold them here")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 6)
                    }
                }
                .padding(.vertical, 3)
            }

            Spacer(minLength: 4)

            Menu {
                Button("Create Album from Tray…") { app.showNewAlbum = true }
                Button("Apply Effect to Tray") { app.editTab = .effects }
                Button("Export Tray…") { app.showExport = true }
                Divider()
                Button("Empty Tray") { app.store.clearTray() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 26)
            .disabled(app.store.tray.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(height: 68)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
