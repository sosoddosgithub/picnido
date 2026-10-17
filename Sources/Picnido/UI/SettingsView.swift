import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppState.self) private var app

    @AppStorage("backupOriginalsOnSave") private var backupOriginals = true
    @AppStorage("defaultExportWidth") private var defaultExportWidth = 1600
    @AppStorage("defaultJPEGQuality") private var defaultQuality = 0.9
    @AppStorage("jpegQualityOnSave") private var saveQuality = 0.95
    @AppStorage("slideshowInterval") private var slideshowInterval = 3.0
    @AppStorage("slideshowLoop") private var slideshowLoop = true
    @AppStorage("slideshowKenBurns") private var kenBurns = true
    @AppStorage("thumbnailRefreshOnLaunch") private var refreshOnLaunch = true
    @AppStorage("originalFolderName") private var originalsFolder = "Originals"

    /// Which tab is showing. Bound rather than implicit so a scripted run can open straight to
    /// the tab under test (`PICNIDO_SETTINGS_TAB=fileTypes`) instead of needing a click.
    @State private var tab: String =
        ProcessInfo.processInfo.environment["PICNIDO_SETTINGS_TAB"] ?? "editing"

    var body: some View {
        TabView(selection: $tab) {
            Form {
                Toggle("Keep a copy of the original in an “\(originalsFolder)” sub-folder when saving",
                       isOn: $backupOriginals)
                Text("Matches the original behaviour: editing a photo never destroys the source file.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("JPEG quality on save")
                    Slider(value: $saveQuality, in: 0.5...1.0)
                    Text("\(Int(saveQuality * 100))%").frame(width: 44, alignment: .trailing)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Editing", systemImage: "slider.horizontal.3") }
            .tag("editing")

            Form {
                HStack {
                    Text("Default export size")
                    Slider(value: Binding(
                        get: { Double(defaultExportWidth) },
                        set: { defaultExportWidth = Int($0) }), in: 480...4000, step: 20)
                    Text("\(defaultExportWidth) px").frame(width: 70, alignment: .trailing)
                }
                HStack {
                    Text("Default quality")
                    Slider(value: $defaultQuality, in: 0.4...1.0)
                    Text("\(Int(defaultQuality * 100))%").frame(width: 44, alignment: .trailing)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            .tag("export")

            Form {
                HStack {
                    Text("Slide duration")
                    Slider(value: $slideshowInterval, in: 1...15)
                    Text(String(format: "%.1fs", slideshowInterval)).frame(width: 44, alignment: .trailing)
                }
                Toggle("Repeat slideshow", isOn: $slideshowLoop)
                Toggle("Ken Burns (slow pan and zoom)", isOn: $kenBurns)
            }
            .formStyle(.grouped)
            .tabItem { Label("Slideshow", systemImage: "play.rectangle") }
            .tag("slideshow")

            Form {
                // The language sits first because it is the setting that changes what every other
                // row in this window says. The names in the picker are each language's own name
                // for itself and are deliberately not translated — see `AppLanguage.name`.
                Picker("Interface language", selection: Binding(
                    get: { app.language },
                    set: { app.language = $0 })) {
                    ForEach(AppLanguage.allCases) { Text($0.name).tag($0) }
                }
                Text("Takes effect at once — there is no need to relaunch.")
                    .font(.caption).foregroundStyle(.secondary)

                Divider()

                Toggle("Rescan watched folders when the app opens", isOn: $refreshOnLaunch)
                HStack {
                    Text("Library location")
                    Text(LibraryStore.documentURL.path)
                        .font(.system(size: 11))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([LibraryStore.documentURL])
                    }
                    .controlSize(.small)
                }
                HStack {
                    Text("Watched folders")
                    Text("\(app.store.roots.count)").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Library", systemImage: "photo.on.rectangle.angled") }
            .tag("library")

            SettingsFileTypes()
                .tabItem { Label("File Types", systemImage: "doc.text.image") }
                .tag("fileTypes")
        }
        .padding(12)
        .onAppear {
            app.slideshowInterval = slideshowInterval
            app.slideshowLoop = slideshowLoop
            app.slideshowKenBurns = kenBurns
        }
        .onChange(of: slideshowInterval) { _, v in app.slideshowInterval = v }
        .onChange(of: slideshowLoop) { _, v in app.slideshowLoop = v }
        .onChange(of: kenBurns) { _, v in app.slideshowKenBurns = v }
    }
}
