import SwiftUI
import AppKit

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @State private var foldersExpanded = true
    @State private var albumsExpanded = true
    @State private var tagsExpanded = false

    /// Which folders are unfolded in the tree. Roots are seeded open the moment they are added,
    /// so importing a folder immediately shows the subfolders underneath it rather than a single
    /// closed row the user has to discover how to open.
    @State private var expandedFolders: Set<String> = []
    @State private var seededRoots: Set<String> = []
    @State private var seededChildren: Set<String> = []

    /// The sidebar's colours are pinned instead of inherited from `.secondary` / `.tertiary`.
    ///
    /// Those semantic styles resolve to a grey chosen for a *hint*, and against a sidebar
    /// background they land barely one step off it — which is what made the labels hard to
    /// read. `Color.primary` / `Color.primary.opacity(...)` adapt to the appearance (dark
    /// text on a light sidebar, light text on a dark one) and always sit at a known
    /// contrast, so the result is legible in both modes without hard-coding a dark slab that
    /// clashes with the light content area next to it.
    enum Palette {
        static let background = Color(nsColor: .controlBackgroundColor)
        static let stroke = Color.primary.opacity(0.10)
        static let text = Color.primary
        static let dim = Color.primary.opacity(0.68)
        static let faint = Color.primary.opacity(0.45)
        static let header = Color.primary.opacity(0.58)
        static let selection = Color.accentColor.opacity(0.24)
        static let hover = Color.primary.opacity(0.07)
    }

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    // The original keeps "Find Photo Folders" reachable from the folder area of
                    // the sidebar, because that is where the user is looking when they think about
                    // folders. It stays in the File menu as well, but a menu-only command is not
                    // discoverable — it used to be reachable only from there.
                    findFoldersRow

                    sectionHeader("Library", systemImage: "photo.on.rectangle.angled")
                    row(.allPhotos, "All Photos", "photo.stack", count: app.store.photos.count)
                    row(.starred, "Starred", "star.fill", count: app.store.photos.filter { $0.starred }.count)
                    row(.recent, "Recent Changes", "clock.arrow.circlepath",
                        count: app.store.photos.filter { $0.hasEdits }.count)
                    row(.places, "Places", "mappin.and.ellipse", count: app.store.geoPhotos.count)
                    hiddenRow

                    Divider().padding(.vertical, 6)

                    sectionHeader("Colour Labels", systemImage: "paintpalette")
                    ForEach(ColorLabel.all, id: \.self) { index in
                        colorLabelRow(index)
                    }

                    Divider().padding(.vertical, 6)

                    HStack {
                        sectionHeader("Folders", systemImage: "folder")
                        Spacer()
                        Button {
                            addFolder()
                        } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help("Add a folder to the library")
                    }
                    if foldersExpanded {
                        ForEach(FolderNode.flatten(app.store.folderTree, expanded: expandedFolders)) { item in
                            folderRow(item)
                        }
                        if app.store.folderTree.isEmpty {
                            Text("No folders yet")
                                .font(.caption)
                                .foregroundStyle(SidebarView.Palette.faint)
                                .padding(.leading, 24)
                        }
                    }

                    Divider().padding(.vertical, 6)

                    HStack {
                        sectionHeader("Albums", systemImage: "rectangle.stack")
                        Spacer()
                        Button { app.showNewAlbum = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help("Create a new album")
                    }
                    if albumsExpanded {
                        ForEach(app.store.albums) { album in
                            albumRow(album)
                        }
                        if app.store.albums.isEmpty {
                            Text("Drag photos to the tray, then create an album")
                                .font(.caption2)
                                .foregroundStyle(SidebarView.Palette.faint)
                                .padding(.leading, 24)
                                .padding(.trailing, 8)
                        }
                    }

                    Divider().padding(.vertical, 6)

                    HStack {
                        sectionHeader("Tags", systemImage: "tag")
                        Spacer()
                        if !app.store.allTags.isEmpty {
                            Button {
                                tagsExpanded.toggle()
                            } label: {
                                Image(systemName: tagsExpanded ? "chevron.down" : "chevron.right")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    if tagsExpanded {
                        ForEach(app.store.allTags, id: \.self) { tag in
                            tagRow(tag)
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            Divider().overlay(Palette.stroke)
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(Palette.dim)
                Text("\(app.store.photos.count) photos")
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
                Spacer()
                Button {
                    Task { await app.store.rescanAll() }
                } label: { Image(systemName: "arrow.clockwise").foregroundStyle(Palette.dim) }
                    .buttonStyle(.borderless)
                    .help("Rescan all folders")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Palette.background)
        .onAppear { seedExpansion() }
        .onChange(of: app.store.roots.count) { _, _ in seedExpansion() }
        .onChange(of: app.store.folderTree.count) { _, _ in seedExpansion() }
    }

    // MARK: Rows

    /// The one button that is intentionally louder than the rest: it is the entry point to
    /// getting pictures into the library at all.
    private var findFoldersRow: some View {
        Button {
            app.showScanFolders = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                Text("Find Photo Folders…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
        .help("Scan a disk for folders that contain pictures")
    }

    /// A sidebar section heading.
    ///
    /// The heading arrives as a `String` — it is an argument, not a literal — so SwiftUI will not
    /// look it up; `localizedString` does that. The `.uppercased()` stays, and is harmless in the
    /// translated languages: it is a Latin-script convention and neither 图库 nor フォルダ has a
    /// case to change, so the same line produces the right thing in all four tables.
    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.caption)
            Text(localizedString(title).uppercased()).font(.caption2).fontWeight(.semibold)
        }
        .foregroundStyle(Palette.header)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func row(_ view: LibraryView, _ title: String, _ icon: String, count: Int) -> some View {
        SidebarRow(title: title, icon: icon, count: count, selected: app.store.view == view) {
            app.store.view = view
            app.store.selection.removeAll()
        }
    }

    /// Hidden photos: the destination, and the switch that reveals them.
    ///
    /// The two are one row on purpose. "Hidden Photos" as a destination with a separate switch
    /// somewhere in a menu means the row can be clicked and show nothing, which reads as a bug.
    /// Here the count is always honest, and the eye button next to it says how to see them.
    private var hiddenRow: some View {
        let count = app.store.hiddenPhotos.count
        return HStack(spacing: 3) {
            SidebarRow(title: "Hidden", icon: app.store.showHidden ? "eye" : "eye.slash",
                       count: count,
                       selected: app.store.view == .hidden) {
                app.store.showHidden = true
                app.store.view = .hidden
                app.store.selection.removeAll()
            }
            Button {
                app.store.showHidden.toggle()
                if !app.store.showHidden, app.store.view == .hidden { app.store.view = .allPhotos }
            } label: {
                Image(systemName: app.store.showHidden ? "eye.fill" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(app.store.showHidden ? Color.accentColor : Palette.faint)
            }
            .buttonStyle(.borderless)
            .help(localizedString(app.store.showHidden ? "Hide them again" : "Show hidden photos in the library"))
            .disabled(count == 0)
        }
    }

    private func colorLabelRow(_ index: Int) -> some View {
        let count = app.store.colorLabelCount(index)
        return SidebarRow(title: ColorLabel.name(index),
                          icon: "square.fill",
                          iconColor: ColorLabel.swiftUIColor(index),
                          count: count,
                          selected: app.store.view == .colorLabel(index)) {
            app.store.view = .colorLabel(index)
            app.store.selection.removeAll()
        }
    }

    /// One row of the folder tree: disclosure triangle, folder, name, and the number of pictures
    /// inside it including everything nested below.
    private func folderRow(_ item: FolderRow) -> some View {
        let node = item.node
        let url = URL(fileURLWithPath: node.path)
        let isRoot = app.store.roots.contains { $0.path == node.path }
        let isOpen = expandedFolders.contains(node.path)

        return HStack(spacing: 3) {
            // The triangle and the row are separate hit areas on purpose. In the folder scanner a
            // row-wide tap gesture swallowed the triangle's clicks outright — a synthetic click
            // proved it selected the row instead of unfolding it — so the two are siblings here.
            if node.hasChildren {
                Button {
                    if isOpen { expandedFolders.remove(node.path) }
                    else { expandedFolders.insert(node.path) }
                } label: {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.dim)
                        .frame(width: 13, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 13, height: 18)
            }

            SidebarRow(title: node.name,
                       icon: isRoot ? "folder.fill" : "folder",
                       count: node.totalCount,
                       selected: app.store.view == .folder(node.path),
                       trailingAction: isRoot ? {
                           app.store.removeRoot(url)
                       } : nil) {
                app.store.view = .folder(node.path)
                app.store.selection.removeAll()
            }
        }
        .padding(.leading, 4 + CGFloat(item.depth) * 13)
        .padding(.trailing, 6)
        .help(node.path)
    }

    private func albumRow(_ album: Album) -> some View {
        SidebarRow(title: album.name, icon: "rectangle.stack.fill",
                   count: album.members.count,
                   selected: app.store.view == .album(album.id),
                   trailingAction: { app.store.deleteAlbum(album.id) }) {
            app.store.view = .album(album.id)
            app.store.selection.removeAll()
        }
    }

    private func tagRow(_ tag: String) -> some View {
        SidebarRow(title: tag, icon: "number",
                   count: app.store.photos(in: .tag(tag)).count,
                   selected: app.store.view == .tag(tag)) {
            app.store.view = .tag(tag)
            app.store.selection.removeAll()
        }
    }

    /// Opens every root that has not been seen before, one level deep.
    ///
    /// Importing a folder should reveal its contents, not hide them behind a closed disclosure
    /// triangle. Expanding the root *and* its immediate children is what produces the shape the
    /// folder layout implies — `1` with `a`, `b` and `c` written underneath it — without dumping a
    /// hundred nested levels onto the screen at once.
    private func seedExpansion() {
        let tree = app.store.folderTree
        for root in app.store.roots {
            if !seededRoots.contains(root.path) {
                seededRoots.insert(root.path)
                expandedFolders.insert(root.path)
            }
            // The tree is still empty on the very first pass — the scan has not run yet — so the
            // children are seeded later, when the nodes actually arrive.
            guard !seededChildren.contains(root.path) else { continue }
            guard let node = tree.first(where: { $0.path == root.path }), node.hasChildren else { continue }
            seededChildren.insert(root.path)
            for child in node.children { expandedFolders.insert(child.path) }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        if panel.runModal() == .OK {
            for u in panel.urls { app.store.addRoot(u) }
        }
    }
}

struct SidebarRow: View {
    let title: String
    let icon: String
    /// Overrides the icon's tint. Used by the colour-label rows, where the whole point of the
    /// row is the colour — a grey square next to "Red" tells the user nothing.
    var iconColor: Color?
    let count: Int
    let selected: Bool
    var trailingAction: (() -> Void)?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 15)
                .foregroundStyle(iconColor ?? (selected ? Color.accentColor : SidebarView.Palette.dim))
            // One `localizedString` for every row, including the ones built from the user's own
            // words. Folder names, album names and tags have no entry in any table, so they come
            // back exactly as they went in — which is the behaviour wanted, and why the fallback
            // in `localizedString` is "return the key" rather than "return English".
            Text(localizedString(title))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(SidebarView.Palette.text)
            Spacer(minLength: 4)
            if hovering, let trailingAction {
                Button(action: trailingAction) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(SidebarView.Palette.faint)
                }
                .buttonStyle(.borderless)
            } else if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(SidebarView.Palette.dim)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? SidebarView.Palette.selection
                               : (hovering ? SidebarView.Palette.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .padding(.horizontal, 6)
    }
}
