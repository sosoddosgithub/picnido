import Foundation
import CryptoKit

/// One set of byte-identical files.
///
/// Identity is the digest, not the first path: two different groups can never share a digest, so
/// using it as the `id` keeps SwiftUI from confusing one group with another after a rescan.
struct DuplicateGroup: Identifiable {
    let id: String
    /// Size of one copy, in bytes.
    let size: Int64
    /// Members, oldest first. The first one is the one worth keeping — it is the one that has
    /// been in the library longest, so it is the one most likely to be the original.
    let photos: [PhotoItem]

    var count: Int { photos.count }
    var keeper: PhotoItem? { photos.first }
    /// Bytes freed by keeping exactly one copy.
    var wastedBytes: Int64 { size * Int64(count - 1) }
}

/// Finds byte-identical photos, in two passes.
///
/// Pass one buckets by file size. A file whose size is unique in the library cannot have a
/// byte-identical twin, so it never gets opened — which is what keeps this affordable on a
/// 50 000-photo library, where almost every size occurs exactly once.
///
/// Pass two digests only the survivors. This is exact: it reports files that are identical, not
/// files that merely look alike, so a photo and its 90 %-quality re-export are never called
/// duplicates of each other.
///
/// Deliberately *not* here: deleting anything, and comparing pixel content. Visually-similar-but-
/// not-identical is a different feature (the original never had it either), and deleting is a
/// separate decision with its own confirmation.
enum DuplicateFinder {

    struct Outcome {
        var groups: [DuplicateGroup] = []
        /// Photos that shared a size with at least one other and therefore had to be read.
        var candidates = 0
        var filesRead = 0
        var bytesRead: Int64 = 0
        var unreadable = 0
        var scannedPhotos = 0
        var cancelled = false
        var seconds: Double = 0

        var wastedTotal: Int64 { groups.reduce(0) { $0 + $1.wastedBytes } }
        var duplicateFiles: Int { groups.reduce(0) { $0 + $1.count - 1 } }
    }

    static func find(_ photos: [PhotoItem], cancelled: () -> Bool = { false }) -> Outcome {
        let started = Date()
        var out = Outcome()
        out.scannedPhotos = photos.count

        // Pass one — by size.
        var bySize: [Int64: [PhotoItem]] = [:]
        for photo in photos {
            var size = photo.fileSize
            if size <= 0 {
                // Records written before the size was tracked, or a file that moved since the
                // last scan. One stat call is cheaper than declaring it a non-duplicate.
                let v = try? photo.url.resourceValues(forKeys: [.fileSizeKey])
                size = Int64(v?.fileSize ?? 0)
                if size <= 0 { out.unreadable += 1; continue }
            }
            bySize[size, default: []].append(photo)
        }

        // Pass two — digest anything that is not alone at its size.
        var byDigest: [String: (size: Int64, photos: [PhotoItem])] = [:]
        for (size, bucket) in bySize where bucket.count > 1 {
            if cancelled() { out.cancelled = true; break }
            out.candidates += bucket.count
            for photo in bucket {
                if cancelled() { out.cancelled = true; break }
                guard let digest = sha256(of: photo.url) else {
                    out.unreadable += 1
                    continue
                }
                out.filesRead += 1
                out.bytesRead += size
                byDigest[digest, default: (size, [])].photos.append(photo)
            }
            if out.cancelled { break }
        }

        out.groups = byDigest
            .filter { $0.value.photos.count > 1 }
            .map { digest, entry in
                DuplicateGroup(id: digest,
                               size: entry.size,
                               // Path breaks the tie, and it is not just tidiness: a batch copy
                               // stamps every member with the same creation date, and `sorted`
                               // is not guaranteed stable — "oldest" was pointing at a different
                               // file on every run. Ordering then falls back on what someone
                               // looking at the group would call the original: the shallowest
                               // path first, then the shortest name, so `orca.jpg` beats
                               // `orca-1.jpg` and a file in the folder beats one in `Copies/`.
                               photos: entry.photos.sorted { lhs, rhs in
                                   if lhs.created != rhs.created { return lhs.created < rhs.created }
                                   let ld = lhs.url.pathComponents.count, rd = rhs.url.pathComponents.count
                                   if ld != rd { return ld < rd }
                                   let ln = lhs.url.lastPathComponent.count, rn = rhs.url.lastPathComponent.count
                                   if ln != rn { return ln < rn }
                                   return lhs.url.path < rhs.url.path
                               })
            }
            .sorted { $0.wastedBytes > $1.wastedBytes }
        out.seconds = Date().timeIntervalSince(started)
        return out
    }

    /// Streaming SHA-256 — a 50 MB RAW is read in 1 MB slices rather than all at once, so peak
    /// memory does not depend on the largest file in the library.
    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
