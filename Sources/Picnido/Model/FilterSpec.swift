import Foundation

/// One slider belonging to a filter, as declared in the catalogue.
struct FilterSlider: Codable, Hashable {
    var id: String
    var label: String
    var range: String

    var defaultRange: Double { Double(range) ?? 1.0 }
}

/// One filter, as declared in the catalogue.
struct FilterSpec: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    /// history | soft | oneclick | effect | tool
    var mode: String
    var tooltip: String
    var persist: Bool
    var cursorType: String
    var cursorPersist: Bool
    var sliders: [FilterSlider]

    var hasSliders: Bool { !sliders.isEmpty }
    var isTool: Bool { mode == "tool" || cursorType == "dropper" || cursorType == "puck" }
}

extension FilterCatalog {

    static func spec(_ id: String) -> FilterSpec? {
        all.first { $0.id == id }
    }

    /// The Effects grid, in the exact order Picnido 3.9 presented them.
    static let effectGrid: [String] = [
        // --- Basic one-click fixes (Picnido keeps these on the Basic Fixes tab) ---
        "enhance", "autolight", "autocolor", "autocontrast", "autobacklight",
        "bw", "sepia", "warm", "grain2",
        // --- The classic 3.9 effects row ---
        "unsharp2", "tint", "sat", "radsat", "glow2", "radblur",
        "Vignette", "MuseumMatte", "Polaroid", "Orton", "Lomo", "Holga",
        "Sixties", "CrossProcess", "HDR", "Border", "DropShadow", "Pixelate",
        "QuantizePalette", "Comicize", "Neon", "HeatMap", "FocalZoom", "IR",
        "dir_tint", "Invert", "NightVision", "PencilSketch", "Matte", "TwoTone",
        "Cinemascope", "RoundedEdges", "Soften", "LocalContrast", "Boost",
        // --- The rest of the pipeline: the adjustments the editor exposes through sliders ---
        "gamma", "contrast", "blur", "colortemp", "shadow", "backlight", "ansel",
        "dir_sat", "dir_brite", "dir_sharp", "PicnikTint", "PicnikFocalPixelate",
        "PicnikGrain", "ReanimatedEyeColor", "Whitept"
    ]

    /// Real filters only (mode == effect / oneclick), resolved against the catalogue.
    static var effects: [FilterSpec] {
        effectGrid.compactMap { spec($0) }
    }

    /// Interactive tools (crop, straighten, red eye, retouch, colour pickers).
    static var tools: [FilterSpec] {
        all.filter { $0.isTool || $0.mode == "tool" }
    }

    // MARK: - Splitting the effects across tabs
    //
    // `effectGrid` is one flat list of 59 entries, and the editor used to put all of them on a
    // single tab — with the nine one-click fixes duplicated, since those are already on Basic
    // Fixes. The split below follows what each filter actually *is*, not taste:
    //
    //   * no sliders, a look        -> Effects
    //   * a frame, edge or one-off  -> Effects 2
    //   * has sliders               -> Adjustments
    //
    // The one-click nine are *not* listed here: they are on Basic Fixes, where the original had
    // them, and listing them twice is what made the old single tab feel like a junk drawer.

    /// The four one-click fixes that Basic Fixes already shows as buttons.
    ///
    /// Only these four, not all nine `mode="oneclick"` filters. B&W, Sepia, Warmify, Film Grain
    /// and the second "Auto Contrast" were in the original's *Effects* tab — its first row was
    /// Sharpen / B&W / Sepia / Warmify / Saturation — so they belong on the effects pages and
    /// excluding them would make five effects vanish from the UI entirely.
    static let basicFixGrid: [String] = [
        "enhance", "autolight", "autocolor", "autobacklight"
    ]

    /// Effects with no settings — one click and done. Photographic looks.
    static let lookGrid: [String] = [
        "Vignette", "Polaroid", "Orton", "Lomo", "Holga", "Sixties", "CrossProcess",
        "HDR", "Pixelate", "QuantizePalette", "Comicize", "Neon", "HeatMap", "FocalZoom",
        "IR", "Invert", "NightVision", "PencilSketch", "TwoTone", "Soften",
        "LocalContrast", "Boost", "ansel"
    ]

    /// Frames, edges, and the Picnik-era decorative one-offs.
    static let frameGrid: [String] = [
        "Border", "DropShadow", "MuseumMatte", "Matte", "Cinemascope", "RoundedEdges",
        "PicnikTint", "PicnikFocalPixelate", "PicnikGrain", "ReanimatedEyeColor"
    ]

    /// Effects that are really a row of sliders.
    static let adjustmentGrid: [String] = [
        "unsharp2", "tint", "sat", "radsat", "glow2", "radblur", "dir_tint",
        "gamma", "contrast", "blur", "colortemp", "shadow", "backlight",
        "dir_sat", "dir_brite", "dir_sharp"
    ]

    /// What each of the three effect tabs shows.
    static let effectPages: [AppState.EditTab: [String]] = [
        .effects: lookGrid,
        .effects2: frameGrid,
        .adjustments: adjustmentGrid
    ]

    /// Resolves one tab's ids. Unknown ids are dropped rather than crashing — a catalogue entry
    /// that this build's catalogue does not have is a missing picture, not a fatal error.
    static func specs(for tab: AppState.EditTab) -> [FilterSpec] {
        (effectPages[tab] ?? []).compactMap { spec($0) }
    }

    /// Every id the three effect tabs are responsible for.
    static var pagedEffectIDs: [String] { lookGrid + frameGrid + adjustmentGrid }

    /// Checked by `PICNIDO_EFFECT_PARTITION=1`. Two ways this goes wrong and both are silent:
    /// an id gets listed on two tabs, or an id falls off every tab and simply stops existing.
    /// The four Basic Fixes buttons are expected to be absent — they are already on tab 1.
    static func partitionReport() -> [String] {
        var lines: [String] = []
        let paged = pagedEffectIDs
        let unique = Set(paged)
        if unique.count != paged.count {
            let dupes = Dictionary(grouping: paged, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
            lines.append("DUPLICATED across tabs: \(dupes.joined(separator: ", "))")
        }
        let expected = effectGrid.filter { !basicFixGrid.contains($0) }
        let missing = expected.filter { !unique.contains($0) }
        let extra = paged.filter { !expected.contains($0) }
        if !missing.isEmpty { lines.append("NOT ON ANY TAB: \(missing.joined(separator: ", "))") }
        if !extra.isEmpty { lines.append("ON A TAB BUT NOT IN effectGrid: \(extra.joined(separator: ", "))") }
        if lines.isEmpty { lines.append("clean") }
        lines.append("effectGrid=\(effectGrid.count) basicFix=\(basicFixGrid.count) "
                     + "paged=\(paged.count) (look=\(lookGrid.count) frame=\(frameGrid.count) adj=\(adjustmentGrid.count))")
        let resolved = paged.compactMap { spec($0) }.count
        lines.append("resolved against the catalogue: \(resolved)/\(paged.count)"
                     + (resolved == paged.count ? "" : "  <-- a spec is missing from the catalogue"))
        return lines
    }
}
