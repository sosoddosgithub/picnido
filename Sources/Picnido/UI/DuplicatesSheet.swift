import SwiftUI
import AppKit

/// Tools ▸ Show Duplicate Files.
///
/// Reports byte-identical files and nothing else.
///
/// It deliberately cannot delete. There is no delete path anywhere in the library layer today,
/// and adding one that reaches into a user's photo folders from a "find duplicates" panel is
/// precisely the kind of convenience that costs someone an album. Ticked rows are handed to
/// Finder instead, where ⌘⌫ goes through the Trash and Undo works.
struct DuplicatesSheet: View {
    @Environment(AppState.self) private var app

    @State private var outcome: DuplicateFinder.Outcome?
    @State private var running = true
    @State private var picked: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            results
            Divider()
            footer
        }
        .frame(width: 800, height: 600)
        .task { await scan() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Label("Duplicate Files", systemImage: "square.on.square")
                .font(.headline)
            Spacer()
            if running {
                ProgressView().controlSize(.small)
                Text("reading files…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if let o = outcome, !o.groups.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(o.groups) { group in
                        groupView(group)
                    }
                }
                .padding(12)
            }
        } else if running {
            VStack(spacing: 8) {
                ProgressView()
                Text("Comparing \(app.store.photos.count) photos by size, then by content.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 28)).foregroundStyle(.green)
                Text("No byte-identical files in this library.")
                    .font(.headline)
                if let o = outcome {
                    Text(diagnostic(o).text(app.language))
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        }
    }

    private func groupView(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(group.count) copies")
                    .font(.subheadline.weight(.semibold))
                Text("· \(DuplicateFinder.sizeText(group.size)) each")
                    .font(.caption).foregroundStyle(.secondary)
                Text("· \(DuplicateFinder.sizeText(group.wastedBytes)) recoverable")
                    .font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Keep only the oldest") { keepOldest(group) }
                    .controlSize(.small)
                Button("Reveal all") { reveal(group.photos.map(\.url)) }
                    .controlSize(.small)
            }
            ForEach(Array(group.photos.enumerated()), id: \.element.id) { index, photo in
                row(photo, isOldest: index == 0)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.07)))
    }

    private func row(_ photo: PhotoItem, isOldest: Bool) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { picked.contains(photo.id) },
                set: { on in
                    if on { picked.insert(photo.id) } else { picked.remove(photo.id) }
                }))
                .toggleStyle(.checkbox)
                .labelsHidden()

            thumbnail(photo)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(photo.fileName)
                        .font(.system(size: 11))
                        .lineLimit(1).truncationMode(.middle)
                    if isOldest {
                        Text("oldest")
                            .font(.system(size: 9))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.18)))
                    }
                }
                Text(photo.url.deletingLastPathComponent().path)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }

            Spacer(minLength: 8)

            Text(Self.dateFormatter.string(from: photo.created))
                .font(.system(size: 9)).foregroundStyle(.secondary)

            Button { reveal([photo.url]) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Reveal in Finder")
        }
    }

    private func thumbnail(_ photo: PhotoItem) -> some View {
        Group {
            if let cg = ThumbnailCache.shared.imageNow(photo: photo, pixels: 64, transform: nil) {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 34, height: 34)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(summary.text(app.language))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Reveal Selected in Finder") {
                    reveal(picked.sorted().map { URL(fileURLWithPath: $0) })
                }
                .disabled(picked.isEmpty)
                Button("Rescan") { Task { await scan() } }
                    .disabled(running)
                Button("Close") { app.showDuplicates = false }
                    .keyboardShortcut(.defaultAction)
            }
            Text("Nothing is deleted here. Tick the copies you want gone and hand them to Finder — ⌘⌫ there moves them to the Trash, and Undo still works.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func scan() async {
        running = true
        picked = []
        let photos = app.store.photos
        let result = await Task.detached(priority: .userInitiated) {
            DuplicateFinder.find(photos)
        }.value
        outcome = result
        running = false
    }

    /// Ticks every copy except the oldest, which is the same decision the group header offers.
    private func keepOldest(_ group: DuplicateGroup) {
        for photo in group.photos.dropFirst() { picked.insert(photo.id) }
    }

    private func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private var summary: StatusNote {
        guard let o = outcome, !o.groups.isEmpty else {
            return StatusNote(running ? "…" : "Nothing to show.")
        }
        return StatusNote("%lld groups · %lld extra copies · %@ recoverable",
                          [o.groups.count, o.duplicateFiles, DuplicateFinder.sizeText(o.wastedTotal)])
    }

    /// Shown when nothing was found, so "no duplicates" is distinguishable from "did not look".
    private func diagnostic(_ o: DuplicateFinder.Outcome) -> StatusNote {
        var note = StatusNote("Scanned %lld photos.", [o.scannedPhotos])
        note.append(" %lld shared a file size and were compared by content.", [o.candidates])
        if o.unreadable > 0 { note.append(" %lld could not be read.", [o.unreadable]) }
        if o.cancelled { note.append(" The scan was interrupted.") }
        note.append(" Took %.1fs.", [o.seconds])
        return note
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
