import SwiftUI
import AppKit

struct MainWindow: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 218)
            Divider()
            VStack(spacing: 0) {
                // The ceiling is load-bearing, and it is a ceiling rather than a height on purpose.
                // The bar's own content is about 26 points, but a `VStack` hands its leftover
                // height to whichever child will accept it, and this one will: measured at the
                // window's 1060x680 minimum, the bar claimed 233 of the 680 points and the grid
                // did not begin until a third of the way down the window. Capping it keeps the bar
                // at its natural size and leaves the slack to the grid, which is the surface that
                // should have it. `.fixedSize(vertical:)` does not do this — that was measured too,
                // and the bar stayed at 233.
                TopBarView().frame(maxHeight: 40)
                Divider()
                if app.screen == .edit {
                    EditorView()
                } else {
                    LibraryContent()
                }
            }
            if app.infoPaneVisible && !app.store.selection.isEmpty && app.screen == .library {
                Divider()
                InfoPanel()
                    .frame(width: 268)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Title bar as well as the top bar's right-hand corner: the version is worth being able to
        // read from a screenshot of the window alone, and the two are fed by the same `AppVersion`
        // so they can never disagree.
        .navigationTitle(AppVersion.display)
        // There is deliberately no `.onChange(of: app.viewerID)` here any more. The viewer is
        // opened by `AppState.openInViewer`, the single entry point, so its window no longer
        // depends on this one existing — which is what let a picture double-clicked in the
        // Finder be treated as "something for the library" instead of something to look at.
        .onChange(of: app.showSlideshow) { _, newValue in
            if newValue {
                openWindow(id: "slideshow")
                app.showSlideshow = false
            }
        }
        // Every sheet gets `.interfaceLanguage(app.language)` because a sheet is its own window and
        // does not inherit the locale the scene set — without it these panels come up in the
        // *system* language while the window behind them is in the chosen one. See
        // `InterfaceLanguage` for the measurement.
        .sheet(isPresented: $app.showExport) { ExportSheet().interfaceLanguage(app.language) }
        .sheet(isPresented: $app.showCollage) { CollageSheet().interfaceLanguage(app.language) }
        .sheet(isPresented: $app.showMovie) { MovieSheet().interfaceLanguage(app.language) }
        .sheet(isPresented: $app.showPoster) { PosterSheet().interfaceLanguage(app.language) }
        .sheet(isPresented: $app.showGalleryExport) { GalleryExportSheet().interfaceLanguage(app.language) }
        .sheet(isPresented: $app.showBackup) { BackupSheet().interfaceLanguage(app.language) }
        .sheet(isPresented: $app.showPrint) { PrintSheet().interfaceLanguage(app.language) }
        .sheet(isPresented: $app.showNewAlbum) { NewAlbumSheet().interfaceLanguage(app.language) }
        .sheet(isPresented: $app.showScanFolders) { ScanFoldersSheet().interfaceLanguage(app.language) }
        .sheet(isPresented: $app.showRename) { RenameSheet().interfaceLanguage(app.language) }
        .sheet(isPresented: $app.showAdjustDate) { AdjustDateSheet().interfaceLanguage(app.language) }
        .sheet(isPresented: $app.showShortcuts) { ShortcutsSheet().interfaceLanguage(app.language) }
        .sheet(isPresented: $app.showDuplicates) { DuplicatesSheet().interfaceLanguage(app.language) }
        .background(SettingsOpener())
        // Reports which NSWindow this view is in, so the AppKit side can take the library window
        // off screen when the app was launched only to look at a picture. See `LibraryWindow`.
        .background(LibraryWindowAccessor())
    }
}

/// Hands SwiftUI's `openSettings` action to `AppState`, where code that is not a view can reach
/// it. Nothing visible: this exists purely to capture the environment value while the window is
/// on screen.
private struct SettingsOpener: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(AppState.self) private var app

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { app.openSettingsAction = { openSettings() } }
    }
}

// MARK: - Top bar (the blue bar in the original)

struct TopBarView: View {
    @Environment(AppState.self) private var app
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 10) {
            Button {
                app.returnToLibrary()
            } label: {
                Label("Library", systemImage: "square.grid.2x2")
            }
            .buttonStyle(.bordered)
            .disabled(app.screen == .library)

            Button {
                if let id = app.store.selection.first { app.startEditing(id) }
            } label: {
                Label("Edit", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .disabled(app.store.selection.isEmpty)

            Divider().frame(height: 18)

            Button {
                if let id = app.store.selection.first { app.openInViewer(id) }
            } label: {
                Label("View", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.bordered)
            .disabled(app.store.selection.isEmpty)

            Menu {
                Button("Collage…") { app.showCollage = true }
                Button("Movie…") { app.showMovie = true }
                Button("Poster…") { app.showPoster = true }
                Button("Slideshow") { app.startSlideshow() }
            } label: {
                Label("Create", systemImage: "wand.and.stars")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                Button("Export…") { app.showExport = true }
                Button("Export as HTML Gallery…") { app.showGalleryExport = true }
                Button("Email…") { EmailComposer.compose(photos: app.exportTargets, app: app) }
                Button("Back Up…") { app.showBackup = true }
                Divider()
                Button("Print…") { app.showPrint = true }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()
            searchField

            if app.store.isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(app.store.scanProgress.text(app.language)).font(.caption).foregroundStyle(.secondary)
                }
            } else if !app.statusText.isEmpty || !app.store.statusMessage.isEmpty {
                // Resolved here, while drawing, rather than stored as a finished sentence — that
                // is what lets this line follow the language picker like the rest of the window.
                Text((app.statusText.isEmpty ? app.store.statusMessage : app.statusText).text(app.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if app.screen == .edit, let id = app.editingID, let photo = app.store.photo(id) {
                HStack(spacing: 6) {
                    Button { app.store.undo(id) } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(photo.stack.isEmpty)
                    Button { app.store.redo(id) } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(photo.redoStack.isEmpty)
                    Button("Clear Edits") { app.store.clearEdits(id) }
                        .disabled(photo.stack.isEmpty)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // The release number, at the very top of the window where it can be read off without
            // opening a menu. `AppVersion` reads it from the bundle, so this cannot drift from
            // what `build_app.sh` stamped into Info.plist — a literal here would be a second copy
            // of the version, and the copy that goes stale is the one on screen.
            Text(AppVersion.display)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .fixedSize()
                .help(AppVersion.detail)
                .padding(.leading, 6)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// The library search box.
    ///
    /// `LibraryStore.searchText` and its filtering have existed since the beginning, but nothing
    /// ever bound to it — the field was never built. A model property that no view writes is a
    /// feature that does not exist, however complete the filter behind it looks.
    @ViewBuilder
    private var searchField: some View {
        @Bindable var app = app
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search name, caption, tag", text: Binding(
                get: { app.store.searchText },
                set: { app.store.searchText = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 168)
                .focused($searchFocused)
            if !app.store.searchText.isEmpty {
                Button {
                    app.store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .onChange(of: app.focusSearchRequest) { _, _ in searchFocused = true }
    }
}

// MARK: - Library content = grid + tray

struct LibraryContent: View {
    @Environment(AppState.self) private var app
    @State private var showDateFilter = false

    var body: some View {
        @Bindable var store = app.store
        @Bindable var app = app
        VStack(spacing: 0) {
            // Spacing 6 rather than the usual 8, and the row's edge padding 8 rather than 12, for
            // one reason: the width budget. This row carries ten controls and two labels, and at
            // the window's 1060-point minimum it is over-subscribed in Japanese and Korean — the
            // CJK words are simply wider than the English ones they replaced. Measured at 1060 pt
            // with the sidebar open, Japanese had ~26 pt of slack left after the layout switches
            // were added, which is exactly the width of "日付"; it lost the word while English kept
            // "Dates". Shaving two points off the spacing and four off each edge buys back ~30 pt
            // and no control changes size or meaning — the alternative was a control that says
            // nothing in two of four languages. Re-measure with `work/verify_minwindow_cjk.sh`
            // before widening anything here again.
            HStack(spacing: 6) {
                // `view.title` is a `String` off the model, so it needs the explicit lookup —
                // which is also what keeps a folder view showing the folder's own name, since a
                // path has no entry in any table and comes back untouched.
                Text(localizedString(app.store.view.title))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // A floor as well as a priority. `layoutPriority` alone decides who wins when
                    // the row is over-subscribed, and what it produced here was a title squeezed
                    // to nothing at the window's 1060-point minimum — a row that reads "24 items"
                    // with no indication of what the 24 are. The floor is "All…" wide, so the
                    // worst case is a truncated label rather than an absent one.
                    .frame(minWidth: 54, alignment: .leading)
                    // The view's name is the one label on this row that cannot be guessed from a
                    // glyph, so it is the one that gets to keep its width. With both side panels
                    // open the row has about 550 points for a row of controls that wants more, and
                    // something has to give: "Dates" losing its word is a smaller loss than
                    // "All Photos" losing its name.
                    .layoutPriority(1)
                Text("\(app.store.visiblePhotos.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // Both labels are pinned to one line. Without the pin they wrap, and a wrapped
                    // label does not just look wrong — it makes the row taller, so the toolbar
                    // grows to three stacked lines ("18 / ite / ms") and pushes the grid down.
                    // A truncated label is the honest failure here: the window is too narrow for
                    // everything, and the row should stay one row regardless.
                    .lineLimit(1)
                    .fixedSize()
                if app.store.hiddenPhotos.count > 0 {
                    Label("\(app.store.hiddenPhotos.count) hidden", systemImage: "eye.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .help("Hidden photos — View ▸ Show Hidden to see them")
                }

                Spacer(minLength: 6)

                Button {
                    showDateFilter.toggle()
                } label: {
                    Label(localizedString(dateFilterTitle), systemImage: app.store.hasDateFilter
                          ? "calendar.badge.clock" : "calendar")
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(app.store.hasDateFilter ? Color.accentColor : Color.secondary)
                .help("Limit the grid to a date range")
                .popover(isPresented: $showDateFilter, arrowEdge: .bottom) {
                    // A popover is its own window too, same reason as the sheets above.
                    DateRangeFilterPopover().interfaceLanguage(app.language)
                }

                Menu {
                    ForEach(CaptionMode.allCases) { mode in
                        Button {
                            app.captionMode = mode
                        } label: {
                            // The tick is appended rather than baked into the key: "Caption  ✓"
                            // would need six more entries per language, and the tick is not a word.
                            Text(localizedString(mode.rawValue)
                                 + (app.captionMode == mode ? "  ✓" : ""))
                        }
                    }
                } label: {
                    Label("Caption", systemImage: "textformat")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("What to print under each thumbnail")

                Toggle(isOn: $store.starredOnly) {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }
                .toggleStyle(.button)
                .help("Show only starred photos")

                Picker("Sort", selection: $store.sort) {
                    // `rawValue` is a `String`, so the menu rows need the lookup too — without it
                    // the picker would sit in a toolbar that is otherwise Chinese, offering
                    // "Date Taken".
                    ForEach(SortMode.allCases) { Text(localizedString($0.rawValue)).tag($0) }
                }
                .frame(width: 88)
                .controlSize(.small)

                Button {
                    store.ascending.toggle()
                } label: {
                    Image(systemName: store.ascending ? "arrow.up" : "arrow.down")
                }
                .help("Toggle sort direction")

                Slider(value: $store.thumbnailSize, in: 80...360)
                    .frame(width: 62)
                    .help("Thumbnail size")

                // The two layout switches. Both are drawn as plain buttons so the pressed state
                // is the whole feedback — a checkbox and its word would cost the row about eighty
                // points it does not have, and this row is the one place in the window where the
                // width budget is already the binding constraint (see the note on the title
                // above). The word each one would have carried lives in its tooltip instead.
                Toggle(isOn: $app.masonryLayout) {
                    Image(systemName: "rectangle.grid.2x2")
                }
                .toggleStyle(.button)
                .help("Masonry layout — columns of one width, each photo its own height")

                Toggle(isOn: $app.showFolderHeaders) {
                    Image(systemName: "folder")
                }
                .toggleStyle(.button)
                .help("Show folder paths — a heading above each folder's photos")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)

            Divider()

            PhotoGridView()

            Divider()
            PhotoTrayView()
        }
    }

    private var dateFilterTitle: String {
        guard app.store.hasDateFilter else { return "Dates" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        switch (app.store.dateFrom, app.store.dateTo) {
        case (let from?, let to?): return "\(f.string(from: from)) – \(f.string(from: to))"
        case (let from?, nil): return "after \(f.string(from: from))"
        case (nil, let to?): return "before \(f.string(from: to))"
        default: return "Dates"
        }
    }
}

/// The date-range popover.
///
/// Two date pickers and a Clear button — the original's `View ▸ Search for ▸ Date` had a long
/// list of relative ranges ("Last 7 days", "This year"…); those are one button each here and
/// cost nothing, so they are offered alongside the two absolute fields.
struct DateRangeFilterPopover: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var store = app.store
        VStack(alignment: .leading, spacing: 10) {
            Text("Show photos taken between").font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Toggle("From", isOn: Binding(
                    get: { store.dateFrom != nil },
                    set: { store.dateFrom = $0 ? (store.dateFrom ?? store.dateSpan?.lowerBound ?? Date()) : nil }))
                .toggleStyle(.checkbox)
                DatePicker("", selection: Binding(
                    get: { store.dateFrom ?? store.dateSpan?.lowerBound ?? Date() },
                    set: { store.dateFrom = $0 }),
                           displayedComponents: .date)
                .labelsHidden()
                .disabled(store.dateFrom == nil)
            }

            HStack(spacing: 6) {
                Toggle("To", isOn: Binding(
                    get: { store.dateTo != nil },
                    set: { store.dateTo = $0 ? (store.dateTo ?? Date()) : nil }))
                .toggleStyle(.checkbox)
                DatePicker("", selection: Binding(
                    get: { store.dateTo ?? Date() },
                    set: { store.dateTo = $0 }),
                           displayedComponents: .date)
                .labelsHidden()
                .disabled(store.dateTo == nil)
            }

            Divider()

            Text("Or a fixed range").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                quickRange("7 days", days: 7)
                quickRange("30 days", days: 30)
                quickRange("This year", days: nil)
            }

            Divider()

            HStack {
                Text(matchText).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    store.dateFrom = nil
                    store.dateTo = nil
                }
                .controlSize(.small)
                .disabled(!store.hasDateFilter)
            }
        }
        .padding(12)
        .frame(width: 288)
    }

    private var matchText: String {
        let total = app.store.photos.count
        let shown = app.store.visiblePhotos.count
        return localizedFormat("%lld of %lld photos match the current filters", shown, total)
    }

    /// A relative range only ever sets the *from* end, which is what "last 7 days" means when
    /// you are looking at a library whose newest photo might be a year old.
    private func quickRange(_ title: String, days: Int?) -> some View {
        Button(localizedString(title)) {
            if let days {
                app.store.dateFrom = Calendar.current.date(byAdding: .day, value: -days, to: Date())
                app.store.dateTo = nil
            } else {
                let year = Calendar.current.component(.year, from: Date())
                app.store.dateFrom = Calendar.current.date(from: DateComponents(year: year, month: 1, day: 1))
                app.store.dateTo = nil
            }
        }
        .controlSize(.small)
    }
}
