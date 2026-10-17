import SwiftUI
import AppKit

struct InfoPanel: View {
    @Environment(AppState.self) private var app
    @State private var showProperties = true
    @State private var newTag = ""

    private var photo: PhotoItem? {
        if let id = app.showingInspectorFor, app.store.selection.contains(id), let p = app.store.photo(id) {
            return p
        }
        if app.store.selection.count == 1, let id = app.store.selection.first {
            return app.store.photo(id)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let photo {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ThumbnailView(photo: photo, size: 150)
                            .frame(width: 150, height: 150)
                            .frame(maxWidth: .infinity)
                            // A shade off the panel rather than the same white, so the picture reads
                            // as sitting in a well. The panel itself is white — see the note on the
                            // panel's own background at the bottom of this view.
                            .background(Color(nsColor: .windowBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.primary.opacity(0.10)))
                            .padding(.top, 10)

                        Button {
                            app.store.toggleStar(photo.id)
                        } label: {
                            // Both branches are `String`s chosen at runtime, so the literal-typed
                            // `Label` initialiser does not apply and the lookup is explicit.
                            Label(localizedString(photo.starred ? "Starred" : "Add Star"),
                                  systemImage: photo.starred ? "star.fill" : "star")
                                .foregroundStyle(photo.starred ? .yellow : .primary)
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                        group("Name") {
                            Text(photo.fileName)
                                .font(.system(size: 11))
                                .textSelection(.enabled)
                        }

                        group("Caption") {
                            TextEditor(text: Binding(
                                get: { photo.caption },
                                set: { app.store.setCaption(photo.id, $0) }))
                                .font(.system(size: 11))
                                .frame(height: 54)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
                        }

                        group("Tags") {
                            FlowTags(tags: photo.tags) { tag in
                                app.store.removeTag(photo.id, tag)
                            }
                            HStack(spacing: 4) {
                                TextField("Add tag", text: $newTag)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11))
                                    .onSubmit {
                                        app.store.addTag(photo.id, newTag)
                                        newTag = ""
                                    }
                                Button {
                                    app.store.addTag(photo.id, newTag)
                                    newTag = ""
                                } label: { Image(systemName: "plus") }
                                    .buttonStyle(.borderless)
                            }
                        }

                        group("Actions") {
                            HStack {
                                Button("Edit") { app.startEditing(photo.id) }
                                Button("View") { app.openInViewer(photo.id) }
                                Button("Export…") { app.showExport = true }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        DisclosureGroup(isExpanded: $showProperties) {
                            VStack(alignment: .leading, spacing: 3) {
                                propertyRow("Path", photo.url.deletingLastPathComponent().path)
                                propertyRow("Dimensions", photo.dimensionsText)
                                propertyRow("File Size", ByteCountFormatter.string(fromByteCount: photo.fileSize, countStyle: .file))
                                propertyRow("Date Taken", photo.created.formatted(date: .abbreviated, time: .shortened))
                                propertyRow("Modified", photo.modified.formatted(date: .abbreviated, time: .shortened))
                                ForEach(sortedExif(photo), id: \.0) { k, v in
                                    propertyRow(k, v)
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Text("Properties").font(.caption).fontWeight(.semibold)
                        }

                        if photo.hasEdits {
                            group("Edit History") {
                                ForEach(photo.stack) { step in
                                    HStack(spacing: 5) {
                                        Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.secondary)
                                        Text(localizedString(step.name)).font(.system(size: 10))
                                        Spacer()
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "info.circle").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(app.store.selection.count > 1
                         ? localizedFormat("%lld photos selected", app.store.selection.count)
                         : localizedString("Select a photo"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if app.store.selection.count > 1 {
                        Text("Use the Edit menu to apply an effect to the whole selection.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            }
        }
        // The panel used to be `underPageBackgroundColor`, which on this system is a mid grey
        // (measured rgb(159,159,159)) — the colour AppKit reserves for the area *behind* a page,
        // never for a surface that holds content. Against the white sidebar and the near-white
        // grid, a 268-point column of it read as a dead panel bolted to the side of the window.
        // It is now the same surface as the sidebar, which is what an inspector should be: one
        // more pane of the window, separated by the dividers that are already there.
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localizedString(title).uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// One line of the properties list.
    ///
    /// Only the *key* is looked up. The value is the data — a path, a pixel count, a date, an EXIF
    /// reading — and translating it would not be translation but corruption. The EXIF keys are
    /// named by the camera's own specification and have no entries in any table, so they pass
    /// through the same lookup untouched.
    private func propertyRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(localizedString(key)).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value).font(.system(size: 10)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sortedExif(_ photo: PhotoItem) -> [(String, String)] {
        let preferred = MetadataReader.propertyOrder
        var out: [(String, String)] = []
        for key in preferred {
            if let v = photo.exif[key] { out.append((key, v)) }
        }
        for (k, v) in photo.exif.sorted(by: { $0.key < $1.key }) where !preferred.contains(k) {
            out.append((k, v))
        }
        return Array(out.prefix(40))
    }
}

struct FlowTags: View {
    let tags: [String]
    let onRemove: (String) -> Void

    var body: some View {
        if tags.isEmpty {
            Text("No tags").font(.system(size: 10)).foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 4) {
                        Text("#\(tag)").font(.system(size: 10))
                        Spacer()
                        Button { onRemove(tag) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
