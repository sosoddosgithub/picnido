import SwiftUI
import AppKit

/// Settings › File Types.
///
/// Two jobs share one set of checkboxes on purpose. A tick means "this application handles this
/// format": it is what the scanner imports **and** what the "Set as Default Viewer" button will
/// claim. Splitting them would let the app import a format it then refuses to open.
///
/// The bottom half is the part that cannot be faked — the *current* system handler for every
/// format, read back from LaunchServices rather than remembered, so "did that button work?" has
/// an answer that does not depend on trusting this app's own bookkeeping.
///
/// Those reads are done once into `handlers`/`ours` rather than from inside `body`: a
/// LaunchServices query per row per redraw is 41 round-trips each time SwiftUI lays the form out.
struct SettingsFileTypes: View {
    @State private var enabled: Set<String> = EnabledExtensions.current
    /// Extension → name of whatever opens it today. `"—"` means nothing is registered.
    @State private var handlers: [String: String] = [:]
    @State private var ours: Set<String> = []
    @State private var status = StatusNote()
    @State private var failures: [String] = []
    @State private var showHandlers = false
    @State private var busy = false

    private let columns = [GridItem(.adaptive(minimum: 168), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(FileTypeCatalog.families) { family in
                        familySection(family)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            Divider()
            footer
        }
        .onAppear { refreshHandlers() }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Image formats")
                .font(.headline)
            Text("Ticked formats are the ones this app imports — and the ones it is willing to open by double-click. Nothing is claimed until you press the button below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Select All") { setAll(true) }
                    .controlSize(.small)
                Button("Select None") { setAll(false) }
                    .controlSize(.small)
                Button("Reset to Default") {
                    EnabledExtensions.reset()
                    enabled = EnabledExtensions.current
                    status = StatusNote()
                }
                .controlSize(.small)
                Spacer()
                Text("\(enabled.count) of \(FileTypeCatalog.allExtensions.count) ticked")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
            if enabled.isEmpty {
                Text("Nothing is ticked, so the scanner will not import any photos.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func familySection(_ family: FileTypeCatalog.Family) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(localizedString(family.title)).font(.subheadline.weight(.semibold))
                Text("\(family.extensions.count) formats")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Text(localizedString(family.note))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(family.extensions, id: \.self) { ext in
                    row(ext)
                }
            }
        }
    }

    private func row(_ ext: String) -> some View {
        HStack(spacing: 4) {
            Toggle(isOn: Binding(
                get: { enabled.contains(ext) },
                set: { on in
                    if on { enabled.insert(ext) } else { enabled.remove(ext) }
                    EnabledExtensions.set(ext, on: on)
                    status = StatusNote()
                })) {
                Text(ext.uppercased())
                    .font(.system(size: 11, design: .monospaced))
            }
            .toggleStyle(.checkbox)

            if ours.contains(ext) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                    .help("This app already opens .\(ext)")
            }
            if handlers[ext] == "—" {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("macOS has no handler for .\(ext)")
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Task { await claimTicked() }
                } label: {
                    Label(localizedString(busy ? "Setting…" : "Set as Default Viewer"), systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(enabled.isEmpty || busy)

                Button("Show current handlers") {
                    showHandlers.toggle()
                    refreshHandlers()
                }
                .controlSize(.small)

                if DefaultViewer.hasSnapshot {
                    Button("Undo") { undo() }
                        .controlSize(.small)
                        .help("Hand every format back to the application that had it before")
                }

                Button {
                    refreshHandlers()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Re-read from the system")

                Spacer()
            }

            if !status.isEmpty {
                Text(status.resolved)
                    .font(.caption)
                    .foregroundStyle(failures.isEmpty ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showHandlers { handlerTable }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var handlerTable: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Format").frame(width: 60, alignment: .leading)
                Text("Opens with").foregroundStyle(.secondary)
                Spacer()
            }
            .font(.caption.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(FileTypeCatalog.allExtensions, id: \.self) { ext in
                        HStack(spacing: 3) {
                            Text(ext.uppercased())
                                .font(.system(size: 10, design: .monospaced))
                                .frame(width: 60, alignment: .leading)
                            Text(handlers[ext] ?? "…")
                                .font(.system(size: 10))
                                .foregroundStyle(ours.contains(ext) ? Color.primary : Color.secondary)
                            if ours.contains(ext) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 8)).foregroundStyle(.green)
                            }
                            Spacer()
                        }
                    }
                }
            }
            .frame(height: 130)
        }
    }

    // MARK: - Actions

    private func setAll(_ on: Bool) {
        enabled = on ? Set(FileTypeCatalog.allExtensions) : []
        EnabledExtensions.store(enabled)
        status = StatusNote()
    }

    private func refreshHandlers() {
        var map: [String: String] = [:]
        var mine: Set<String> = []
        for ext in FileTypeCatalog.allExtensions {
            map[ext] = DefaultViewer.handlerName(for: ext) ?? "—"
            if DefaultViewer.isSelfHandler(for: ext) { mine.insert(ext) }
        }
        handlers = map
        ours = mine
    }

    private func claimTicked() async {
        DefaultViewer.snapshotIfNeeded()
        busy = true
        defer { busy = false }

        let targets = FileTypeCatalog.allExtensions.filter { enabled.contains($0) }
        var claimed = 0, already = 0
        var refused: [String] = [], unknown: [String] = []
        for ext in targets {
            switch await DefaultViewer.claim(ext) {
            case .set: claimed += 1
            case .already: already += 1
            case .refused: refused.append(ext)
            case .unknown: unknown.append(ext)
            }
        }

        failures = refused + unknown
        // Clause by clause: *which* clauses appear depends on the result, so there is no single
        // sentence to look up. Each clause brings its own separator, which is what lets a language
        // reorder the list — see `StatusNote.Part`.
        var note = StatusNote()
        if claimed > 0 { note.append("claimed %lld", [claimed]) }
        if already > 0 { note.append("; %lld were already yours", [already]) }
        if !refused.isEmpty {
            note.append("; refused %lld: %@",
                        [refused.count, refused.map { $0.uppercased() }.joined(separator: ", ")])
        }
        if !unknown.isEmpty {
            note.append("; no UTI for %@", [unknown.map { $0.uppercased() }.joined(separator: ", ")])
        }
        status = note.isEmpty ? StatusNote("Nothing to do.") : note
        refreshHandlers()
    }

    private func undo() {
        let n = DefaultViewer.restoreSnapshot()
        status = n > 0
            ? StatusNote("Handed %lld formats back to their previous applications.", [n])
            : StatusNote("Nothing to hand back — they are already with their previous applications.")
        refreshHandlers()
    }
}
