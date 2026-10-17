import Foundation
import CoreGraphics

// MARK: - Tuning

/// The five sliders of the Picnido "Tuning" tab (ids 0..3 in finetune / finetune2).
struct TuningParams: Codable, Hashable {
    var fillLight: Double = 0      // 0 ... +1
    var highlights: Double = 0     // -1 ... +1
    var shadows: Double = 0        // -1 ... +1
    var temperature: Double = 0    // -1 (cool) ... +1 (warm)
    var saturation: Double = 0     // -1 ... +1

    var isIdentity: Bool {
        fillLight == 0 && highlights == 0 && shadows == 0 && temperature == 0 && saturation == 0
    }

    static let `default` = TuningParams()
}

// MARK: - Text overlay (Picnido "Text" tool)

struct TextOverlay: Codable, Hashable {
    var string: String = ""
    var fontName: String = "Helvetica-Bold"
    var fontSizeRatio: Double = 0.08    // fraction of image height
    var red: Double = 1
    var green: Double = 1
    var blue: Double = 1
    var alpha: Double = 1
    var x: Double = 0.5                 // normalised centre
    var y: Double = 0.5
    var rotationDegrees: Double = 0
}

// MARK: - Edit operations (a non-destructive, replayable history)

enum EditOp: Codable, Hashable {
    case rotate(quarterTurns: Int)                    // clockwise
    case flipHorizontal
    case flipVertical
    case straighten(degrees: Double)                  // -45 ... +45
    case crop(rect: CGRect, aspect: String)           // normalised, post-straighten space
    case redeye(points: [CGPoint], radius: Double)    // normalised centre + radius / image width
    case retouch(points: [CGPoint], radius: Double)
    case effect(id: String, params: [Double])
    case tuning(TuningParams)
    case text(TextOverlay)
    case whitePoint(point: CGPoint, strength: Double)

    var filterID: String? {
        switch self {
        case .effect(let id, _): return id
        case .rotate: return "rot"
        case .straighten: return "tilt"
        case .crop: return "crop64"
        case .redeye: return "redeye"
        case .retouch: return "retouch"
        case .tuning: return "finetune2"
        case .text: return "text"
        case .whitePoint: return "whitept"
        case .flipHorizontal, .flipVertical: return "rot"
        }
    }

    /// Human readable label, taken from the catalogue whenever possible.
    var displayName: String {
        switch self {
        case .rotate(let q):
            let turns = ((q % 4) + 4) % 4
            return "Rotate \(turns * 90)°"
        case .flipHorizontal: return "Flip Horizontal"
        case .flipVertical: return "Flip Vertical"
        case .straighten(let d): return String(format: "Straighten %.1f°", d)
        case .crop(_, let aspect): return aspect == "Original" ? "Crop" : "Crop \(aspect)"
        case .redeye(let pts, _): return pts.count == 1 ? "Red Eye" : "Red Eye (\(pts.count))"
        case .retouch(let pts, _): return pts.count == 1 ? "Retouch" : "Retouches (\(pts.count))"
        case .effect(let id, _): return FilterCatalog.spec(id)?.label ?? id
        case .tuning(let t): return t.isIdentity ? "Tuning" : "Tuning"
        case .text(let t): return t.string.isEmpty ? "Text" : "Text “\(t.string)”"
        case .whitePoint: return "Neutral Color Picker"
        }
    }

    var isStructural: Bool {
        switch self {
        case .rotate, .flipHorizontal, .flipVertical, .straighten, .crop: return true
        default: return false
        }
    }
}

struct EditStep: Codable, Identifiable, Hashable {
    var id = UUID()
    var op: EditOp
    var enabled: Bool = true

    var name: String { op.displayName }
}

// MARK: - Aspect ratios offered by the original crop tool

enum CropAspect: String, CaseIterable, Identifiable {
    case original = "Original"
    case ratio1x1 = "1:1 (Square)"
    case ratio4x3 = "4:3 (Standard)"
    case ratio3x2 = "3:2 (35mm)"
    case ratio16x9 = "16:9 (Widescreen)"
    case ratio5x7 = "5:7 (5\"x7\")"
    case ratio2x3 = "2:3 (4\"x6\")"
    case ratio8x10 = "4:5 (8\"x10\")"
    case ratio11x17 = "11:17"
    case ratioCdCover = "CD Cover"
    case ratioDvdCover = "DVD Cover"
    case ratioScreen = "Screen"
    case ratioMonitor = "Monitor"
    case ratio5x7Print = "5x7 Print"
    case ratio4x6Print = "4x6 Print"

    var id: String { rawValue }

    /// width / height, nil == keep original
    var value: Double? {
        switch self {
        case .original: return nil
        case .ratio1x1: return 1.0
        case .ratio4x3: return 4.0 / 3.0
        case .ratio3x2: return 3.0 / 2.0
        case .ratio16x9: return 16.0 / 9.0
        case .ratio5x7: return 5.0 / 7.0
        case .ratio2x3: return 2.0 / 3.0
        case .ratio8x10: return 8.0 / 10.0
        case .ratio11x17: return 11.0 / 17.0
        case .ratioCdCover: return 1.0
        case .ratioDvdCover: return 10.0 / 7.0
        case .ratioScreen: return 4.0 / 3.0
        case .ratioMonitor: return 16.0 / 10.0
        case .ratio5x7Print: return 5.0 / 7.0
        case .ratio4x6Print: return 4.0 / 6.0
        }
    }
}
