import Foundation

/// Reads and writes the `.picasa.ini` sidecar format that the original Picasa 3.9
/// created next to every folder it managed.  Reading it means libraries that were
/// already curated in Picnido arrive with their stars / captions / tags intact.
enum SidecarINI {

    struct Section {
        var values: [String: String] = [:]
        subscript(key: String) -> String? { values[key] }
    }

    /// folderURL -> (fileName -> values)
    static func read(folder: URL) -> [String: Section] {
        let iniURL = folder.appendingPathComponent(".picasa.ini")
        guard let text = try? String(contentsOf: iniURL, encoding: .utf8) else { return [:] }
        var result: [String: Section] = [:]
        var current: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast())
                if let c = current, result[c] == nil { result[c] = Section() }
                continue
            }
            guard let eq = line.firstIndex(of: "="), let c = current else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            result[c]?.values[key.lowercased()] = value
        }
        return result
    }

    /// Updates just the star / caption / keyword lines, leaving the rest of the file
    /// (including the original app's own filter strings) untouched.
    static func writeStarCaptionTags(folder: URL, fileName: String,
                                     starred: Bool, caption: String, tags: [String]) {
        let iniURL = folder.appendingPathComponent(".picasa.ini")
        var lines: [String] = []
        if let existing = try? String(contentsOf: iniURL, encoding: .utf8) {
            lines = existing.components(separatedBy: .newlines)
        }

        var out: [String] = []
        var inSection = false
        var wroteSection = false
        var pending: [String: String] = [:]
        if starred { pending["star"] = "yes" }
        if !caption.isEmpty { pending["caption"] = caption }
        if !tags.isEmpty { pending["keywords"] = tags.joined(separator: ", ") }

        var i = 0
        func flushSection() {
            for (k, v) in pending.sorted(by: { $0.key < $1.key }) { out.append("\(k)=\(v)") }
            pending.removeAll()
        }

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast())
                if inSection && !wroteSection { flushSection(); wroteSection = true }
                out.append(line)
                inSection = (name == fileName)
                if inSection { wroteSection = false }
            } else if inSection, let eq = line.firstIndex(of: "=") {
                let key = String(line[line.startIndex..<eq]).lowercased()
                if pending.keys.contains(key) {
                    // replaced below by the flush
                } else if !line.isEmpty && !line.hasPrefix(";") {
                    out.append(line)
                }
            } else if !line.isEmpty {
                out.append(line)
            }
            i += 1
        }
        if inSection && !wroteSection { flushSection(); wroteSection = true }
        if !wroteSection && !pending.isEmpty {
            out.append("[\(fileName)]")
            flushSection()
        }

        let text = out.filter { !$0.isEmpty }.joined(separator: "\n") + "\n"
        try? text.write(to: iniURL, atomically: true, encoding: .utf8)
    }
}
