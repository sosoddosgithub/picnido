import SwiftUI
import AppKit

// MARK: - Rename Files
//
// Four controls, control for control: how many are selected, one new base
// name, a Date and an Image resolution checkbox, and an "Example:" line. The example is the
// important part — it is what makes renaming five hundred files a decision you can check before
// you make it.

struct RenameSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var request = RenameRequest()
    @State private var startNumber = 1
    @State private var confirming = false

    private var photos: [PhotoItem] {
        app.store.selection.compactMap { app.store.photo($0) }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    private var plan: [RenamePlan] {
        FileOrganizer.plan(photos, request: request)
    }

    private var nudgedCount: Int { plan.filter(\.nudged).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(photos.count) file\(photos.count == 1 ? "" : "s") selected for rename.")
                .font(.headline)

            if photos.isEmpty {
                Text("Select photos in the library first.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Please enter a new name for these files:")
                    TextField("New name", text: $request.base)
                        .textFieldStyle(.roundedBorder)
                    Text("Leave it blank to keep each file's current name and only add the parts below.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                HStack(spacing: 18) {
                    Toggle("Date", isOn: $request.includeDate)
                    Toggle("Image resolution", isOn: $request.includeResolution)
                }

                if photos.count > 1 {
                    HStack(spacing: 8) {
                        Text("Number from")
                        TextField("", value: $startNumber, format: .number)
                            .frame(width: 64)
                            .textFieldStyle(.roundedBorder)
                        Text("(appended when more than one file is renamed)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Example:").font(.caption).foregroundStyle(.secondary)
                    ForEach(plan.prefix(4), id: \.from.path) { step in
                        HStack(spacing: 6) {
                            Text(step.from.lastPathComponent)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                            Text(step.to.lastPathComponent)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if plan.isEmpty {
                        Text("Nothing would change.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if plan.count > 4 {
                        Text("…and \(plan.count - 4) more.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                if nudgedCount > 0 {
                    Label("\(nudgedCount) name\(nudgedCount == 1 ? " is" : "s are") already taken — “ (2)” is appended rather than overwriting",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Label("Files are renamed inside their own folder. Nothing is moved, and nothing is overwritten.",
                      systemImage: "lock.shield")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirming
                       ? localizedString("Renaming…")
                       : localizedFormat(plan.count == 1 ? "Rename %lld file" : "Rename %lld files",
                                         plan.count)) {
                    confirming = true
                    let outcome = app.store.applyRename(plan)
                    app.statusText = outcome.summary
                    confirming = false
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.isEmpty || confirming)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear { request.base = "" }
    }
}

// MARK: - Adjust Photo Date
//
// `runtime/offsettime.fen` again: current date, new date, and two radio buttons —
// "Adjust all photo dates by the amount" / "Set all photos to the same date and time".
//
// The relative mode works by *example*: you type what the first photo's date should be, and the
// difference between that and what it currently says becomes the offset applied to the whole
// selection. That is the original's behaviour, and it is the right one — nobody knows that their
// camera was 4 hours 37 minutes out, but everybody knows the birthday party was on the 12th.

struct AdjustDateSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case relative = "Adjust all photo dates by the amount"
        case absolute = "Set all photos to the same date and time"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .relative
    @State private var newDate = Date()

    private var photos: [PhotoItem] {
        app.store.selection.compactMap { app.store.photo($0) }
            .sorted { $0.created < $1.created }
    }

    private var reference: PhotoItem? { photos.first }

    private var delta: TimeInterval {
        guard let reference else { return 0 }
        return newDate.timeIntervalSince(reference.created)
    }

    private var adjustment: FileOrganizer.DateAdjustment {
        mode == .relative ? .relative(delta) : .absolute(newDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(photos.count) photo\(photos.count == 1 ? "" : "s") selected")
                .font(.headline)

            if photos.isEmpty {
                Text("Select photos in the library first.").foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    if let reference {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Current photo date").font(.caption).foregroundStyle(.secondary)
                            Text(reference.created.formatted(date: .long, time: .shortened))
                                .font(.system(size: 12, design: .monospaced))
                            Text(reference.fileName)
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: 200, alignment: .leading)
                        }
                    }
                    Divider().frame(height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("New photo date").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            DatePicker("", selection: $newDate, displayedComponents: .date)
                                .labelsHidden()
                            DatePicker("", selection: $newDate, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Mode.allCases) { candidate in
                        RadioButton(title: candidate.rawValue, selected: mode == candidate) {
                            mode = candidate
                        }
                    }
                }

                Group {
                    if mode == .relative {
                        let sign = delta < 0 ? "−" : "+"
                        let magnitude = Self.magnitude(abs(delta))
                        Label("Every selected photo moves by \(sign)\(magnitude)",
                              systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(delta == 0 ? .secondary : .primary)
                    } else {
                        Label("Every selected photo is set to \(newDate.formatted(date: .abbreviated, time: .shortened))",
                              systemImage: "clock.badge.checkmark")
                            .font(.caption)
                    }
                }

                Text("This changes the file's creation and modification dates. Running the opposite adjustment puts them back.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    let result = app.store.adjustDates(ids: Array(app.store.selection), adjustment)
                    var note = StatusNote("Adjusted the date on %lld photo\(result.ok == 1 ? "" : "s")", [result.ok])
                    if result.failed > 0 { note.append(", %lld failed", [result.failed]) }
                    app.statusText = note
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(photos.isEmpty || (mode == .relative && delta == 0))
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear { newDate = reference?.created ?? Date() }
    }

    static func magnitude(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days) day\(days == 1 ? "" : "s")") }
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 || parts.isEmpty { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }
}

/// A plain radio button. SwiftUI's `Picker` with `.radioGroup` only exists on iOS, and a
/// `.pickerStyle(.radioGroup)` on macOS leaves no room for the long sentence-length labels the
/// original used — which are, in this dialog, the entire explanation of what the mode does.
struct RadioButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.6), lineWidth: 1)
                        .frame(width: 13, height: 13)
                    if selected {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    }
                }
                Text(localizedString(title)).font(.system(size: 12))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Keyboard shortcuts
//
// Two lists, because they answer two different questions. "In this application" is what actually
// works when you press the keys. "In the original app" is read from the key map that shipped
// inside `Picnido3i18n.dll` — 51 commands, with the ones this application implements marked, so
// the gap is visible instead of guessed at.

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// This application's own commands, kept next to the code that defines them.
    private let ours: [(String, String, String)] = [
        ("⌘⇧F", "Find Photo Folders…", "Scan a disk for folders containing pictures"),
        ("⌘⇧I", "Import Folder…", "Add a folder to the library"),
        ("⌘1", "Library", "Back to the grid"),
        ("⌘2", "Edit Photo", "Open the selected photo in the editor"),
        ("⌘↩", "Photo Viewer", "Full-screen viewer for the selected photo"),
        ("⌘⇧E", "Export…", "Export the selection or the Photo Tray"),
        ("⌘P", "Print…", "Print the selection"),
        ("⌘Z", "Undo Edit", "Undo the last edit step"),
        ("⌘⇧Z", "Redo Edit", "Redo the last undone step"),
        ("⌘T", "Add to Photo Tray", "Hold the selection in the tray"),
        ("⌘F", "Search", "Filter the grid by name, caption or tag"),
        ("F2", "Rename Files…", "Rename the selection"),
        ("⇧⌘D", "Adjust Photo Date…", "Shift or set the date taken"),
        ("⇧⌘C", "Copy All Effects", "Copy the effects of the photo being edited"),
        ("⇧⌘V", "Paste All Effects", "Put them on the selection or the Photo Tray"),
        ("⌥⌘H", "Hide Photo", "Hide the selection without deleting it"),
        ("⇧⌘H", "Show Hidden", "Reveal hidden photos"),
        ("⇧⌘E", "Email…", "Mail the selection"),
        ("⌘/", "Keyboard Shortcuts", "This window"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("In this application", rows: ours.map { ($0.0, $0.1, $0.2) })
                }
                .padding(.vertical, 14)
            }
        }
        .frame(width: 560, height: 560)
    }

    private func section(_ title: String, rows: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizedString(title))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 4)
            ForEach(rows, id: \.1) { row in
                HStack(spacing: 10) {
                    Text(row.0)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 74, alignment: .leading)
                    Text(row.1).font(.system(size: 11))
                    Spacer(minLength: 4)
                    Text(row.2)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 3)
            }
        }
    }
}

