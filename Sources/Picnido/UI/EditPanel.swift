import SwiftUI
import AppKit

struct EditPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            Picker("", selection: $app.editTab) {
                ForEach(AppState.EditTab.allCases) { Text(localizedString($0.tabLabel)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .help(localizedString(app.editTab.help))

            Text(localizedString(app.editTab.help))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            EffectsClipboardBar()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch app.editTab {
                    case .basicFixes: BasicFixesPanel()
                    case .tuning: TuningPanel()
                    default: EffectsPanel(tab: app.editTab)
                    }
                }
                .padding(12)
            }

            Divider()
            EditHistoryView()
            Divider()
            SaveBar()
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

// MARK: - Copy / Paste all effects

/// The original's batch workflow, kept in the editor rather than only in the Edit menu: a menu
/// item is not discoverable, and this is the command that turns a fixed photo into a fixed
/// folder.
struct EffectsClipboardBar: View {
    @Environment(AppState.self) private var app

    private var copySource: PhotoItem? {
        app.editingPhoto ?? app.store.visiblePhotos.first(where: { app.store.selection.contains($0.id) })
    }

    private var copyableCount: Int {
        copySource.map { AppState.transferableSteps(of: $0).count } ?? 0
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if let photo = copySource { app.copyAllEffects(from: photo) }
            } label: {
                Label("Copy Effects", systemImage: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .controlSize(.small)
            .disabled(copyableCount == 0)
            .help("Copy this photo's effects so they can be pasted onto others")

            Button {
                app.pasteAllEffects(on: app.batchTargets)
            } label: {
                Label("Paste Effects", systemImage: "doc.on.clipboard")
                    .font(.system(size: 11))
            }
            .controlSize(.small)
            .disabled(app.copiedEffects == nil || app.batchTargets.isEmpty)
            .help(app.copiedEffects == nil
                  ? localizedString("Nothing copied yet")
                  : localizedFormat("Paste %lld copied effect(s) onto the selection or Photo Tray",
                                    app.copiedEffects?.count ?? 0))

            Spacer(minLength: 2)

            if let from = app.copiedEffectsFrom, let count = app.copiedEffects?.count {
                Text("\(count) from \(from)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

// MARK: - Basic Fixes

struct BasicFixesPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 14) {
            Text("TOOLS").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                toolButton("Crop", "crop", active: isCropActive) {
                    app.activeTool = isCropActive ? .none : .crop(app.currentAspect)
                    app.liveCropRect = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
                }
                toolButton("Straighten", "rotate.right", active: app.activeTool == .straighten) {
                    app.activeTool = app.activeTool == .straighten ? .none : .straighten
                    app.liveStraighten = 0
                }
                toolButton("Red Eye", "eye.trianglebadge.exclamationmark", active: app.activeTool == .redeye) {
                    app.activeTool = app.activeTool == .redeye ? .none : .redeye
                }
                toolButton("Retouch", "bandage", active: app.activeTool == .retouch) {
                    app.activeTool = app.activeTool == .retouch ? .none : .retouch
                }
                toolButton("Text", "textformat", active: app.activeTool == .text) {
                    app.activeTool = app.activeTool == .text ? .none : .text
                }
                toolButton("Neutral Color", "eyedropper", active: app.activeTool == .whitePoint) {
                    app.activeTool = app.activeTool == .whitePoint ? .none : .whitePoint
                }
            }

            if case .crop = app.activeTool {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Aspect ratio", selection: $app.currentAspect) {
                        ForEach(CropAspect.allCases) { Text(localizedString($0.rawValue)).tag($0) }
                    }
                    .controlSize(.small)
                    HStack {
                        Button("Apply Crop") {
                            if let id = app.editingID {
                                app.store.push(id, .crop(rect: app.liveCropRect,
                                                         aspect: app.currentAspect.rawValue))
                            }
                            app.activeTool = .none
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button("Cancel") { app.activeTool = .none }
                            .controlSize(.small)
                    }
                }
            }

            if app.activeTool == .straighten {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Angle").font(.caption)
                        Spacer()
                        Text(String(format: "%.1f°", app.liveStraighten))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Slider(value: $app.liveStraighten, in: -45...45)
                    HStack {
                        Button("Apply") {
                            if let id = app.editingID, abs(app.liveStraighten) > 0.01 {
                                app.store.push(id, .straighten(degrees: app.liveStraighten))
                            }
                            app.liveStraighten = 0
                            app.activeTool = .none
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Cancel") { app.liveStraighten = 0; app.activeTool = .none }
                            .controlSize(.small)
                    }
                }
            }

            if app.activeTool == .redeye || app.activeTool == .retouch {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Brush size").font(.caption)
                    Slider(value: $app.toolRadius, in: 0.004...0.06)
                    Text("Click on the photo to apply. Each click adds one mark to the history.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if app.activeTool == .text {
                TextOverlayEditor()
            }

            Divider()

            Text("ONE-CLICK FIXES").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible())], spacing: 6) {
                oneClick("I'm Feeling Lucky", "wand.and.rays", "enhance")
                oneClick("Auto Contrast", "circle.lefthalf.filled", "autolight")
                oneClick("Auto Color", "drop", "autocolor")
                oneClick("Fill Light", "sun.max", "autobacklight")
            }
        }
    }

    private var isCropActive: Bool {
        if case .crop = app.activeTool { return true }
        return false
    }

    private func toolButton(_ title: String, _ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16))
                Text(localizedString(title)).font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(active ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(active ? Color.accentColor : Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func oneClick(_ title: String, _ icon: String, _ filterID: String) -> some View {
        Button {
            app.applyFilter(filterID)
        } label: {
            HStack {
                Image(systemName: icon)
                Text(localizedString(title))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Text overlay editor

struct TextOverlayEditor: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Text").font(.caption)
            TextField("Your text", text: Binding(
                get: { app.liveText.string },
                set: { app.liveText.string = $0 }))
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Size").font(.caption2)
                Slider(value: Binding(
                    get: { app.liveText.fontSizeRatio },
                    set: { app.liveText.fontSizeRatio = $0 }), in: 0.02...0.3)
                Text("Rotation").font(.caption2)
                Slider(value: Binding(
                    get: { app.liveText.rotationDegrees },
                    set: { app.liveText.rotationDegrees = $0 }), in: -180...180)
            }
            HStack(spacing: 10) {
                ColorPicker("", selection: Binding(
                    get: { Color(red: app.liveText.red, green: app.liveText.green, blue: app.liveText.blue) },
                    set: { c in
                        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
                        app.liveText.red = Double(ns.redComponent)
                        app.liveText.green = Double(ns.greenComponent)
                        app.liveText.blue = Double(ns.blueComponent)
                    }))
                .labelsHidden()
                Picker("Font", selection: Binding(
                    get: { app.liveText.fontName },
                    set: { app.liveText.fontName = $0 })) {
                    ForEach(["Helvetica-Bold", "Helvetica", "Times-Bold", "Courier-Bold",
                             "AvenirNext-Bold", "Georgia-Bold", "Impact"], id: \.self) { Text($0).tag($0) }
                }
                .controlSize(.small)
            }
            Button("Click on the photo to place the text") {
                app.activeTool = .text
            }
            .controlSize(.small)
            .disabled(app.liveText.string.isEmpty)
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Tuning

struct TuningPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 14) {
            Text("TUNABLE").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)

            slider("Fill Light", value: $app.liveTuning.fillLight)
            slider("Highlights", value: $app.liveTuning.highlights)
            slider("Shadows", value: $app.liveTuning.shadows)
            slider("Color Temperature", value: $app.liveTuning.temperature)
            slider("Saturation", value: $app.liveTuning.saturation)

            HStack {
                Button("Apply") {
                    if let id = app.editingID, !app.liveTuning.isIdentity {
                        app.store.push(id, .tuning(app.liveTuning))
                    }
                    app.liveTuning = TuningParams()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(app.liveTuning.isIdentity)
                Button("Reset") { app.liveTuning = TuningParams() }
                    .controlSize(.small)
            }

            Text("Sliders preview live. Apply writes one entry to the edit history.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func slider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(localizedString(title)).font(.caption)
                Spacer()
                Text(String(format: "%+.2f", value.wrappedValue))
                    .font(.caption2).foregroundStyle(.secondary)
                Button {
                    value.wrappedValue = 0
                } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 8)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
            }
            Slider(value: value, in: -1...1)
        }
    }
}

// MARK: - Effects

struct EffectsPanel: View {
    @Environment(AppState.self) private var app
    let tab: AppState.EditTab
    @State private var query = ""

    private var page: [FilterSpec] { FilterCatalog.specs(for: tab) }

    /// Search deliberately spans *every* effects page, not just this one. Someone looking for
    /// "sharpen" does not know or care which of three pages we filed it on, and a search that
    /// silently answers "no results" for something that exists is worse than no search.
    private var filters: [FilterSpec] {
        guard !query.isEmpty else { return page }
        return FilterCatalog.effects.filter { $0.label.lowercased().contains(query.lowercased()) }
    }

    /// Which tab an effect lives on, so a search result can say where it came from.
    private func tabLabel(for spec: FilterSpec) -> String? {
        guard !query.isEmpty, !page.contains(where: { $0.id == spec.id }) else { return nil }
        for candidate in AppState.EditTab.allCases {
            if FilterCatalog.effectPages[candidate]?.contains(spec.id) == true {
                return candidate.tabLabel
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let fid = app.liveEffectID, let spec = FilterCatalog.spec(fid) {
                FilterSlidersView(spec: spec)
                Divider()
            }

            TextField("Search all effects", text: $query)
                .textFieldStyle(.roundedBorder)

            Text(query.isEmpty
                 ? localizedFormat("%lld effects on this tab · %lld in all",
                                   page.count, FilterCatalog.effects.count)
                 : localizedFormat(filters.count == 1 ? "%lld match across all tabs"
                                                      : "%lld matches across all tabs",
                                   filters.count))
                .font(.caption2).foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(filters) { spec in
                    Button {
                        app.applyFilter(spec.id)
                    } label: {
                        VStack(spacing: 2) {
                            Text(localizedString(spec.label))
                                .font(.system(size: 10))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .background(app.liveEffectID == spec.id
                                            ? Color.accentColor.opacity(0.25)
                                            : Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.primary.opacity(0.1)))
                            if let where_ = tabLabel(for: spec) {
                                Text(localizedString(where_))
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(localizedString(spec.tooltip.isEmpty ? spec.label : spec.tooltip))
                }
            }

            if filters.isEmpty, !query.isEmpty {
                Text("No effect matches “\(query)”")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if !app.store.selection.isEmpty {
                Divider()
                Button("Apply selection to tray (\(app.store.tray.count))") {
                    if let fid = app.liveEffectID {
                        app.applyFilterToSelection(fid)
                    }
                }
                .controlSize(.small)
                .disabled(app.store.tray.isEmpty || app.liveEffectID == nil)
            }
        }
    }
}

struct FilterSlidersView: View {
    @Environment(AppState.self) private var app
    let spec: FilterSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localizedString(spec.label)).font(.caption).fontWeight(.semibold)
                Spacer()
                Button {
                    app.liveEffectID = nil
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(spec.sliders.enumerated()), id: \.element.id) { index, slider in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(localizedString(slider.label)).font(.caption2)
                        Spacer()
                        Text(String(format: "%.2f", current(index)))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { current(index) },
                        set: { v in
                            var p = app.liveEffectParams
                            while p.count <= index { p.append(0.5) }
                            p[index] = v
                            app.liveEffectParams = p
                        }), in: 0...1)
                }
            }
            HStack {
                Button("Apply") {
                    if let id = app.editingID, let fid = app.liveEffectID {
                        app.store.push(id, .effect(id: fid, params: app.liveEffectParams))
                    }
                    app.liveEffectID = nil
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Reset to defaults") {
                    app.liveEffectParams = Filters.defaultParams(for: spec.id)
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func current(_ index: Int) -> Double {
        let p = app.liveEffectParams
        return index < p.count ? p[index] : 0.5
    }
}

// MARK: - History

struct EditHistoryView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("EDIT HISTORY").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let id = app.editingID, let photo = app.store.photo(id) {
                    Text("\(photo.stack.count)").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let id = app.editingID, let photo = app.store.photo(id) {
                        ForEach(Array(photo.stack.enumerated().reversed()), id: \.element.id) { index, step in
                            Button {
                                // Truncate history back to (and including) this step
                                app.store.update(id) { item in
                                    let removed = item.stack.suffix(from: index + 1)
                                    item.stack = Array(item.stack.prefix(index + 1))
                                    item.redoStack.append(contentsOf: removed.reversed())
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: index == photo.stack.count - 1 ? "arrow.right.circle.fill" : "circle")
                                        .font(.system(size: 9))
                                        .foregroundStyle(index == photo.stack.count - 1 ? Color.accentColor : .secondary)
                                    Text(step.name).font(.system(size: 11)).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if photo.stack.isEmpty {
                            Text("No edits yet")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 132)
        }
    }
}

// MARK: - Save bar

struct SaveBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button("Save to Disk") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Save a Copy") { saveCopy() }
                    .controlSize(.small)
                Button("Export…") { app.showExport = true }
                    .controlSize(.small)
            }
            HStack(spacing: 6) {
                Button("Print") { app.showPrint = true }
                    .controlSize(.small)
                Button("Email") {
                    if let p = app.editingPhoto { EmailComposer.compose(photos: [p], app: app) }
                }
                .controlSize(.small)
                Button("Slideshow") { app.startSlideshow() }
                    .controlSize(.small)
            }
        }
        .padding(10)
    }

    private func save() {
        guard let photo = app.editingPhoto else { return }
        do {
            try Exporter.saveInPlace(photo: photo, backupOriginals: true)
            app.store.clearEdits(photo.id)
            app.statusText = StatusNote("Saved %@ (original copied to Originals/)", [photo.fileName])
            Task { await app.store.refresh(photo.url) }
        } catch {
            app.statusText = StatusNote("Save failed: %@", [error.localizedDescription])
        }
    }

    private func saveCopy() {
        guard let photo = app.editingPhoto else { return }
        do {
            let url = try Exporter.saveCopy(photo: photo)
            app.statusText = StatusNote("Wrote %@", [url.lastPathComponent])
        } catch {
            app.statusText = StatusNote("Save failed: %@", [error.localizedDescription])
        }
    }
}
