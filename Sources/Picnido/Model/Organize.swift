import Foundation

// MARK: - Rename Files
//
// Four controls and no token language: one new base name, two optional tick boxes (Date,
// Image resolution) whose values are appended, and a live example line underneath.
//
// There is no find-and-replace, and that is a good design — the thing being edited is a
// *name*, and the preview is what makes a 550-file rename safe to press.

struct RenameRequest {
    /// The new base name, without extension. Empty means "keep the existing base name".
    var base: String = ""
    var includeDate = true
    var includeResolution = false
    /// What the first affected file's number should be, when there is more than one.
    var startNumber = 1

    var trimmedBase: String { base.trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct RenamePlan {
    let from: URL
    let to: URL
    /// True when the destination had to be adjusted because something already sat there.
    let nudged: Bool
}

enum FileOrganizer {

    /// Day-granular, because the date goes into a filename and a timestamp would be hostile.
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH-mm-ss"
        return f
    }()

    /// The name one photo would get, before any collision handling.
    ///
    /// The counter is only added when the batch has more than one file — appending " 01" to a
    /// single rename is noise, and the original did not do it either.
    static func baseName(for photo: PhotoItem, request: RenameRequest,
                         number: Int?, width: Int) -> String {
        var parts: [String] = []
        let typed = request.trimmedBase
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let stem = typed.isEmpty
            ? photo.url.deletingPathExtension().lastPathComponent
            : typed
        parts.append(stem)
        if request.includeDate { parts.append(dayFormatter.string(from: photo.created)) }
        if request.includeResolution, photo.pixelWidth > 0, photo.pixelHeight > 0 {
            parts.append("\(photo.pixelWidth)x\(photo.pixelHeight)")
        }
        var name = parts.joined(separator: " ")
        if let number {
            name += " " + String(format: "%0\(max(1, width))d", number)
        }
        return name
    }

    /// Builds the full plan, resolving collisions against both the file system and the other
    /// names claimed by this same batch.
    ///
    /// The collision rule is "nudge, never overwrite". A rename that silently replaces another
    /// photo is indistinguishable from data loss, so a destination that is already taken gets
    /// " (2)", " (3)" … appended until it is free. Renaming a file onto *itself* is dropped from
    /// the plan rather than performed, so pressing Rename twice is harmless.
    static func plan(_ photos: [PhotoItem], request: RenameRequest) -> [RenamePlan] {
        let count = photos.count
        let width = String(max(1, request.startNumber + count - 1)).count
        let sourcePaths = Set(photos.map { $0.url.standardizedFileURL.path.lowercased() })
        var claimed = Set<String>()
        var out: [RenamePlan] = []

        for (offset, photo) in photos.enumerated() {
            let number = count > 1 ? request.startNumber + offset : nil
            let ext = photo.url.pathExtension
            let dir = photo.url.deletingLastPathComponent()
            var stem = baseName(for: photo, request: request, number: number, width: width)
            let originalStem = stem

            var attempt = 0
            var destination: URL
            var nudged = false
            repeat {
                let suffix = attempt == 0 ? "" : " (\(attempt + 1))"
                let candidate = dir.appendingPathComponent(stem + suffix)
                    .appendingPathExtension(ext)
                destination = candidate
                let key = candidate.standardizedFileURL.path.lowercased()
                let clashesWithDisk = FileManager.default.fileExists(atPath: candidate.path)
                    && !sourcePaths.contains(key)
                let clashesWithBatch = claimed.contains(key)
                if !clashesWithDisk && !clashesWithBatch {
                    nudged = attempt > 0
                    break
                }
                attempt += 1
                if attempt > 999 { stem = originalStem + " copy"; nudged = true; break }
            } while true

            claimed.insert(destination.standardizedFileURL.path.lowercased())
            if destination.standardizedFileURL == photo.url.standardizedFileURL { continue }
            out.append(RenamePlan(from: photo.url, to: destination, nudged: nudged))
        }
        return out
    }

    // MARK: - Adjust Photo Date
    //
    // `runtime/offsettime.fen` again, with its two radio buttons:
    //
    //     <radio name="relative" title="Adjust all photo dates by the amount"/>
    //     <radio name="absolute" title="Set all photos to the same date and time"/>
    //
    // Relative is the one that fixes a wrong time zone or a camera whose clock drifted
    // (shift everything by -3 h); absolute is the one that fixes a single scanned photo.

    enum DateAdjustment {
        case relative(TimeInterval)
        case absolute(Date)
    }

    /// The dates a photo should end up with, given an adjustment. Both the created and the
    /// modified stamp move together — they disagreeing is what makes the "Date Taken" column
    /// disagree with Finder.
    static func adjustedDates(_ photo: PhotoItem, _ adjustment: DateAdjustment) -> (Date, Date) {
        switch adjustment {
        case .relative(let delta):
            return (photo.created.addingTimeInterval(delta),
                    photo.modified.addingTimeInterval(delta))
        case .absolute(let when):
            return (when, when)
        }
    }
}
