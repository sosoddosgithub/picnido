import Foundation
import SQLite3

/// One row of the photo index.
///
/// Everything here is metadata that can be obtained without decoding the image: the file's own
/// stats plus whatever ImageIO reports from the header and EXIF blocks. Once a row exists, a
/// relaunch never has to open the file again unless its modification date moved.
struct IndexedPhoto {
    var path: String
    var dir: String
    var name: String
    var size: Int64
    var mtime: Double
    var btime: Double
    var width: Int
    var height: Int
    var orientation: Int
    var exifJSON: String
    var lat: Double
    var lon: Double
    /// A separate flag, because 0/0 is a legitimate coordinate and `lat != 0` would then throw
    /// away photos taken exactly on the equator or the prime meridian.
    var geoPresent: Bool = false

    var geo: GeoPoint? { geoPresent ? GeoPoint(latitude: lat, longitude: lon) : nil }
}

/// Persistent catalogue of every photo the library knows about.
///
/// Walking a five-hundred-file folder and pulling EXIF out of each one takes seconds, and a
/// photo application that takes seconds to show anything does not feel like a photo
/// application. So the grid is painted from this table instead: a few milliseconds for
/// thousands of rows.
///
/// On launch we read the whole table in one query — a few milliseconds for thousands of rows —
/// and paint the grid from it. A background pass then reconciles against the file system, and
/// only files whose `mtime` moved are re-read.
///
/// SQLite is used through the system library that ships with macOS; there is no dependency to
/// install and the file is a single ordinary file on disk.
final class LibraryIndex {

    static let shared = LibraryIndex()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "picnido.index", qos: .utility)

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    var path: String { dbPath.path }
    private let dbPath: URL

    init(directory: URL? = nil) {
        let dir = directory ?? LibraryIndex.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("index.db")
        open()
        migrate()
    }

    static func defaultDirectory() -> URL {
        // See `Library.supportDirectory`: whichever of the two is asked first has to do the
        // adoption, or the catalogue is created in an empty directory beside the real one.
        LegacyAdoption.run()
        // PICNIDO_INDEX_DIR lets a scripted run keep its own catalogue, so a measurement pass
        // neither reads nor writes the library the user actually works with.
        if let override = ProcessInfo.processInfo.environment["PICNIDO_INDEX_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Picnido", isDirectory: true)
    }

    // MARK: Setup

    private func open() {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath.path, &handle, flags, nil) == SQLITE_OK else {
            PicnidoAppDelegate.report("[index] unable to open \(dbPath.path): \(lastError)")
            sqlite3_close(handle)
            return
        }
        db = handle
        // WAL keeps the background reconcile pass from blocking reads while the grid is up.
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA temp_store=MEMORY;")
    }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS photos (
            path        TEXT PRIMARY KEY,
            dir         TEXT NOT NULL,
            name        TEXT NOT NULL,
            size        INTEGER NOT NULL DEFAULT 0,
            mtime       REAL    NOT NULL DEFAULT 0,
            btime       REAL    NOT NULL DEFAULT 0,
            width       INTEGER NOT NULL DEFAULT 0,
            height      INTEGER NOT NULL DEFAULT 0,
            orientation INTEGER NOT NULL DEFAULT 1,
            exif        TEXT    NOT NULL DEFAULT '',
            lat         REAL    NOT NULL DEFAULT 0,
            lon         REAL    NOT NULL DEFAULT 0,
            geopresent  INTEGER NOT NULL DEFAULT 0
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS photos_dir ON photos(dir);")
        exec("CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);")
    }

    private var lastError: String {
        guard let db else { return "no handle" }
        return String(cString: sqlite3_errmsg(db))
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            PicnidoAppDelegate.report("[index] sql error: \(message)")
            sqlite3_free(err)
        }
    }

    // MARK: Reading

    /// The whole catalogue. One query, one pass — sub-millisecond for a few thousand rows.
    func loadAll() -> [IndexedPhoto] {
        queue.sync {
            guard let db else { return [] }
            let sql = """
            SELECT path, dir, name, size, mtime, btime, width, height, orientation, exif, lat, lon, geopresent
            FROM photos;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var out: [IndexedPhoto] = []
            out.reserveCapacity(1024)
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(row(from: stmt!))
            }
            return out
        }
    }

    private func row(from stmt: OpaquePointer) -> IndexedPhoto {
        func text(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: c)
        }
        return IndexedPhoto(
            path: text(0),
            dir: text(1),
            name: text(2),
            size: sqlite3_column_int64(stmt, 3),
            mtime: sqlite3_column_double(stmt, 4),
            btime: sqlite3_column_double(stmt, 5),
            width: Int(sqlite3_column_int(stmt, 6)),
            height: Int(sqlite3_column_int(stmt, 7)),
            orientation: Int(sqlite3_column_int(stmt, 8)),
            exifJSON: text(9),
            lat: sqlite3_column_double(stmt, 10),
            lon: sqlite3_column_double(stmt, 11),
            geoPresent: sqlite3_column_int(stmt, 12) != 0
        )
    }

    func count() -> Int {
        queue.sync {
            guard let db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM photos;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    // MARK: Writing

    /// Insert or update in a single transaction. Used by the reconcile pass in batches.
    func upsert(_ rows: [IndexedPhoto]) {
        guard !rows.isEmpty else { return }
        queue.sync {
            guard let db else { return }
            exec("BEGIN IMMEDIATE;")
            let sql = """
            INSERT INTO photos (path, dir, name, size, mtime, btime, width, height, orientation, exif, lat, lon, geopresent)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(path) DO UPDATE SET
                dir=excluded.dir, name=excluded.name, size=excluded.size, mtime=excluded.mtime,
                btime=excluded.btime, width=excluded.width, height=excluded.height,
                orientation=excluded.orientation, exif=excluded.exif,
                lat=excluded.lat, lon=excluded.lon, geopresent=excluded.geopresent;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { exec("COMMIT;"); return }
            for r in rows {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, r.path, -1, Self.transient)
                sqlite3_bind_text(stmt, 2, r.dir, -1, Self.transient)
                sqlite3_bind_text(stmt, 3, r.name, -1, Self.transient)
                sqlite3_bind_int64(stmt, 4, r.size)
                sqlite3_bind_double(stmt, 5, r.mtime)
                sqlite3_bind_double(stmt, 6, r.btime)
                sqlite3_bind_int(stmt, 7, Int32(r.width))
                sqlite3_bind_int(stmt, 8, Int32(r.height))
                sqlite3_bind_int(stmt, 9, Int32(r.orientation))
                sqlite3_bind_text(stmt, 10, r.exifJSON, -1, Self.transient)
                sqlite3_bind_double(stmt, 11, r.lat)
                sqlite3_bind_double(stmt, 12, r.lon)
                sqlite3_bind_int(stmt, 13, r.geoPresent ? 1 : 0)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            exec("COMMIT;")
        }
    }

    func delete(paths: [String]) {
        guard !paths.isEmpty else { return }
        queue.sync {
            guard let db else { return }
            exec("BEGIN IMMEDIATE;")
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM photos WHERE path = ?;", -1, &stmt, nil) == SQLITE_OK else {
                exec("COMMIT;"); return
            }
            for p in paths {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, p, -1, Self.transient)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            exec("COMMIT;")
        }
    }

    /// Removes rows for folders that are no longer in the library at all.
    func deleteOutside(roots: [String]) {
        guard !roots.isEmpty else { return }
        queue.sync {
            guard let db else { return }
            let clause = roots.map { _ in "path LIKE ?" }.joined(separator: " OR ")
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM photos WHERE NOT (\(clause));", -1, &stmt, nil) == SQLITE_OK else { return }
            for (i, r) in roots.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), r + "/%", -1, Self.transient)
            }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    func reset() {
        exec("DELETE FROM photos;")
        exec("VACUUM;")
    }

    func checkpoint() {
        exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }
}
