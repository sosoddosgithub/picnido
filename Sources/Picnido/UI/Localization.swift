import Foundation
import SwiftUI

/// Puts the chosen interface language into a view's environment.
///
/// The scene-level `AppEnvironment` covers every ordinary window, because SwiftUI resolves a
/// `Text("…")` literal against the environment's locale and the scene hands that locale to its
/// window. Two surfaces sit outside that reach, and both were found by running the app with
/// `PICNIDO_LANG=en` — a language with no `.lproj`, so anything that *does* follow the picker comes
/// back as its English source string, and anything that does not comes back in the machine's
/// language. Measured on this machine (Simplified Chinese), so the two failure modes were
/// unmistakable: half of the Scan Folders panel read 查找范围 / 扫描 / 选择前 10 项 while the other
/// half — the strings routed through `localizedString`, which reads `AppState` directly — was
/// English, and the Duplicates panel's title read 重复文件 under an English interface.
///
/// **Sheets.** A `.sheet` is presented in its own window and that window does not inherit the
/// attaching view's `\.locale`, so every literal inside one resolves against the *system* language
/// instead of the picker. The strings that went through `localizedString` were already right, which
/// is what made this look like a half-finished translation rather than a plumbing problem.
///
/// **The viewer.** `ViewerHost` builds its panel by hand (`NSHostingView`), so it gets whatever
/// environment it is given and nothing more — it had `.environment(app)` but no locale.
struct InterfaceLanguage: ViewModifier {
    let language: AppLanguage

    func body(content: Content) -> some View {
        content.environment(\.locale, language.locale)
    }
}

extension View {
    /// Re-applies the chosen interface language to a surface the scene modifier cannot reach —
    /// a sheet's content, or a hand-built hosting view. See `InterfaceLanguage`.
    func interfaceLanguage(_ language: AppLanguage) -> some View {
        modifier(InterfaceLanguage(language: language))
    }
}

/// Looks a key up in the table for the language the user chose in Settings.
///
/// `Text("…")` written as a literal needs none of this. SwiftUI resolves a `LocalizedStringKey`
/// against the environment's locale — which is why the whole interface follows the Settings picker
/// without a single call site changing, and why the locale is applied in `PicnidoApp` rather than
/// written to `AppleLanguages` (see the note on `AppEnvironment`).
///
/// This function exists for the strings SwiftUI cannot see: the ones that arrive as plain
/// `String`s because they come from a model rather than from the source. `LibraryView.title` is the
/// clearest case — the sidebar hands `SidebarRow` the word "All Photos", not a literal, so the
/// compiler types it `String`, SwiftUI treats it as text to display rather than a key to look up,
/// and the row stays English however the picker is set. Same for the sort menu, whose rows are
/// `SortMode.rawValue`, and for the folder headings, which are built from a path.
///
/// Falls back to the key, deliberately. A good half of what goes through here *should not* be
/// translated at all — album names, folder names and tags are the user's own words — and
/// "return the input" means those come out untouched while the rows that do have a translation get
/// one. It costs the occasional false positive: an album somebody named "Edit" would show as 编辑.
/// That is the right side of the trade, because the alternative is an interface that is half
/// English.
///
/// NOTE: not `String(localized:)`, which resolves against `Locale.current` — the machine's
/// language — and so would ignore the picker entirely, which is the one thing this has to honour.
@MainActor
func localizedString(_ key: String) -> String {
    localizedString(key, AppState.shared.language)
}

/// The same lookup against a language the caller supplies.
///
/// Views almost always want the `AppState` overload. This one exists for the status line, which is
/// resolved while drawing and therefore has to take the language it is drawn *in* — see
/// `StatusNote`.
@MainActor
func localizedString(_ key: String, _ language: AppLanguage) -> String {
    guard let table = LocalizationTable.bundle(for: language) else { return key }
    return table.localizedString(forKey: key, value: nil, table: nil)
}

/// Looks a *format* key up and substitutes, for the few places that need the finished sentence
/// right away rather than at draw time — a view-local `@State` summary, a hand-written `help`.
///
/// Views that only display should prefer `Text("…\(x)…")`, which SwiftUI resolves itself and
/// already follows the environment locale. This exists for the ones it cannot see through: a
/// string assembled in a computed property, a title passed down as a parameter.
@MainActor
func localizedFormat(_ key: String, _ args: CVarArg...) -> String {
    let format = localizedString(key)
    return args.isEmpty ? format : String(format: format, arguments: args)
}

/// A status line kept as a format key plus its arguments, instead of as a finished sentence.
///
/// The top bar holds one of these for most of a session — "24 photos in library" — and that line is
/// built by the model, not by a view. Storing the finished sentence is what made it the one part of
/// the interface that ignored the language picker: `Text(someString)` renders a `String` as text,
/// so there is no key for SwiftUI to look up, and by the time the store had interpolated the count
/// into the sentence there was no key left to recover either.
///
/// Keeping the key means the line is re-resolved every time it is drawn, so switching language in
/// Settings updates it along with everything else rather than leaving the language you just left
/// sitting in the top bar until the next action.
///
/// The keys are *format strings*, not sentences, and that is load-bearing in two ways:
///
///   - They go through `String(format:)`, so counts are `%lld` and text is `%@`. `"%lld photos in
///     library"` is the same spelling SwiftUI derives for `Text("\(n) photos in library")`, which
///     is deliberate: the two paths share one table entry.
///   - `String(format:)` only substitutes, it never reorders, so a language that needs the parts in
///     another order has to put them there in its own entry. That is why the entries read as format
///     strings with `%lld` in them rather than as prose.
///
/// Only `text(_:)` is main-actor isolated. Marking the type itself would isolate the initialisers
/// too, and the stores that build these lines — `LibraryStore` among them — are `@Observable`
/// classes with no isolation of their own, so they could not construct one.
struct StatusNote {
    /// One clause. Several of the summaries below are built by appending clauses — a rename reports
    /// "Renamed 3 files", then ", 2 already had that name", then ", 1 failed" — so a part may be a
    /// fragment that begins with its own separator. Translators should keep that leading
    /// punctuation in their entry.
    struct Part {
        var key: String
        var args: [CVarArg] = []
    }

    private(set) var parts: [Part] = []

    init() {}

    init(_ key: String, _ args: [CVarArg] = []) {
        parts = [Part(key: key, args: args)]
    }

    /// An empty key means "nothing to say", which is how the store clears the line.
    var isEmpty: Bool { parts.allSatisfy { $0.key.isEmpty } }

    mutating func append(_ key: String, _ args: [CVarArg] = []) {
        parts.append(Part(key: key, args: args))
    }

    /// Resolved against the language Settings currently has selected.
    ///
    /// For the views that have no `AppState` in scope — the settings panes are their own scenes.
    /// It reads the same singleton `localizedString(_:)` reads, so there is still one answer.
    @MainActor
    var resolved: String { text(AppState.shared.language) }

    @MainActor
    func text(_ language: AppLanguage) -> String {
        var out = ""
        for part in parts {
            let format = localizedString(part.key, language)
            out += part.args.isEmpty ? format : String(format: format, arguments: part.args)
        }
        return out
    }
}

/// The `.lproj` bundle for a language, opened once each and kept.
///
/// `Bundle(path:)` is not free — it stats the directory and parses the property list behind it —
/// and the sidebar alone asks for a few dozen strings per frame. `NSLocalizedString` caches the
/// *contents* but not the bundle, so without this the cost would be paid per row per redraw.
@MainActor
enum LocalizationTable {
    private static var cache: [String: Bundle] = [:]

    static func bundle(for language: AppLanguage) -> Bundle? {
        if let hit = cache[language.rawValue] { return hit }
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        cache[language.rawValue] = bundle
        return bundle
    }
}
