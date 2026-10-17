import Foundation
import ImageIO
import CoreGraphics

struct MetadataResult {
    var fileSize: Int64 = 0
    var created: Date = .distantPast
    var modified: Date = .distantPast
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var orientation: Int = 1
    var exif: [String: String] = [:]
    var geo: GeoPoint?
}

enum MetadataReader {

    static func read(url: URL) -> MetadataResult {
        var r = MetadataResult()
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path) {
            r.fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            r.modified = (attrs[.modificationDate] as? Date) ?? .distantPast
            r.created = (attrs[.creationDate] as? Date) ?? r.modified
        }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return r
        }

        r.pixelWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        r.pixelHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        r.orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1

        var exifOut: [String: String] = [:]
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            for (k, v) in exif {
                let key = k as String
                if let s = stringify(v) { exifOut[key] = s }
            }
            if exifOut["DateTimeOriginal"] == nil, let d = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                exifOut["DateTimeOriginal"] = d
            }
            if let d = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let f = DateFormatter()
                f.dateFormat = "yyyy:MM:dd HH:mm:ss"
                if let date = f.date(from: d) { r.created = date }
            }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            for (k, v) in tiff {
                if let s = stringify(v) { exifOut[k as String] = s }
            }
            if exifOut["DateTimeOriginal"] == nil, let d = tiff[kCGImagePropertyTIFFDateTime] as? String {
                let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
                if let date = f.date(from: d) { r.created = date }
            }
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            let lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue
            let lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String
            if let lat, let lon {
                r.geo = GeoPoint(latitude: latRef == "S" ? -lat : lat,
                                 longitude: lonRef == "W" ? -lon : lon)
            }
        }
        if let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            if let caption = iptc[kCGImagePropertyIPTCCaptionAbstract] as? String, !caption.isEmpty {
                exifOut["Caption"] = caption
            }
            if let kw = iptc[kCGImagePropertyIPTCKeywords] as? [String] {
                exifOut["Keywords"] = kw.joined(separator: ", ")
            }
        }
        // Fold in the .picasa.ini filter string if the original app touched the file.
        r.exif = exifOut
        return r
    }

    private static func stringify(_ v: Any) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let a as [Any]:
            return a.compactMap { stringify($0) }.joined(separator: ", ")
        default: return nil
        }
    }

    /// Human-readable EXIF table for the Properties panel, ordered like runtime/properties.xml.
    static let propertyOrder: [String] = [
        "FilePath", "FileSize", "Dimensions", "Make", "Model",
        "DateTimeOriginal", "DateTimeDigitized", "DateTime", "FileDate", "Orientation",
        "Flash", "Lens", "FocalLength", "FocalLengthIn35mmFilm", "ExposureTime",
        "ApertureValue", "FNumber", "SubjectDistance", "ISOSpeedRatings", "WhiteBalance",
        "MeteringMode", "ExposureProgram", "ColorSpace", "Keywords", "GPSLatitude", "GPSLongitude"
    ]
}
