// Recovered files: categories, incremental scanning of the recup_dir.N
// folders, and the post-processing tools (organize, duplicates, report).
// Foundation and ImageIO only, so everything here is covered by the tests.
import CryptoKit
import Foundation
import ImageIO

// MARK: - Categories

public enum FileCategory: String, CaseIterable, Identifiable, Codable {
    case photo, video, audio, document, archive, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .photo: return "Foto"
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "Documenti"
        case .archive: return "Archivi"
        case .other: return "Altro"
        }
    }

    public var symbol: String {
        switch self {
        case .photo: return "photo.fill"
        case .video: return "film.fill"
        case .audio: return "waveform"
        case .document: return "doc.text.fill"
        case .archive: return "archivebox.fill"
        case .other: return "questionmark.folder.fill"
        }
    }

    private static let map: [String: FileCategory] = {
        var m: [String: FileCategory] = [:]
        let photo = "jpg jpeg png gif bmp tif tiff heic heif webp psd psb crw cr2 cr3 nef nrw orf raf rw2 mrw x3f x3i arw srf sr2 dng pef srw raw jp2 ico icns pcx tga svg xcf rdc cam bpg pct psp oci dpx wdp xv spe kdc dcr 3fr erf mef mos"
        let video = "mov mp4 m4v mpg mpeg mkv avi webm flv wmv asf 3gp 3g2 m2ts mts ts swf ogv vob mxf r3d braw ari dv riff rm rmvb"
        let audio = "mp3 wav flac ogg oga m4a aac wma aif aiff aifc mid midi opus amr ape au caf mka ra wv dsf"
        let document = "pdf doc docx xls xlsx ppt pptx odt ods odp odg rtf txt html htm xml csv md pages numbers key epub tex ps eps one pub vsd wpd sxw sxc indd ai qxd mobi chm djvu"
        let archive = "zip rar 7z gz tgz tar bz2 xz lz lzma zst dmg iso cab arj lzh sit sitx cpio rpm deb jar apk"
        for (list, cat) in [(photo, FileCategory.photo), (video, .video), (audio, .audio), (document, .document), (archive, .archive)] {
            for ext in list.split(separator: " ") { m[String(ext)] = cat }
        }
        return m
    }()

    public static func of(extension ext: String) -> FileCategory {
        map[ext.lowercased()] ?? .other
    }

    /// Extensions whose content ImageIO can decode into a thumbnail.
    public static let decodableImages: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "heic", "webp", "psd", "ico", "icns", "jp2", "tga", "dng", "cr2", "nef", "arw", "orf", "raf", "rw2", "pef", "srw"]
}

// MARK: - Recovered files

public struct RecoveredFile: Identifiable, Hashable {
    public let url: URL
    public let size: Int64
    public let modified: Date
    public var id: URL { url }
    public var name: String { url.lastPathComponent }
    public var ext: String { url.pathExtension.lowercased() }
    public var category: FileCategory { FileCategory.of(extension: ext) }

    public init(url: URL, size: Int64, modified: Date) {
        self.url = url
        self.size = size
        self.modified = modified
    }
}

public enum ResultSort: String, CaseIterable, Identifiable {
    case newest, largest, smallest, name
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .newest: return "Ultimi trovati"
        case .largest: return "Più grandi"
        case .smallest: return "Più piccoli"
        case .name: return "Nome"
        }
    }
}

public enum ResultFilter {
    public static func apply(_ files: [RecoveredFile], category: FileCategory?, query: String, sort: ResultSort) -> [RecoveredFile] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = files.filter { f in
            (category == nil || f.category == category) &&
            (q.isEmpty || f.name.localizedCaseInsensitiveContains(q) || f.ext == q.lowercased())
        }
        switch sort {
        case .newest: return filtered
        case .largest: return filtered.sorted { $0.size > $1.size }
        case .smallest: return filtered.sorted { $0.size < $1.size }
        case .name: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    public static func counts(_ files: [RecoveredFile]) -> [FileCategory: Int] {
        var c: [FileCategory: Int] = [:]
        for f in files { c[f.category, default: 0] += 1 }
        return c
    }
}

/// Files PhotoRec leaves next to the recovered ones.
private let ignoredNames: Set<String> = ["report.xml", ".DS_Store"]

/// Reads the recup_dir.N folders of a session incrementally: PhotoRec fills
/// them in order and a folder holds at most 500 files, so only the last two
/// are listed again at each call.
public final class RecoveryScanner {
    public let sessionDir: URL
    private var closedDirs = Set<String>()
    private var seen = Set<String>()

    public init(sessionDir: URL) { self.sessionDir = sessionDir }

    /// New files since the previous call, newest folder last.
    public func scanNew() -> [RecoveredFile] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: sessionDir.path) else { return [] }
        let dirs = entries.filter { $0.hasPrefix("recup_dir.") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var found: [RecoveredFile] = []
        for (index, dir) in dirs.enumerated() where !closedDirs.contains(dir) {
            let dirURL = sessionDir.appendingPathComponent(dir)
            guard let names = try? fm.contentsOfDirectory(atPath: dirURL.path) else { continue }
            for name in names.sorted() where !ignoredNames.contains(name) && !name.hasPrefix(".") {
                let key = dir + "/" + name
                if seen.contains(key) { continue }
                let url = dirURL.appendingPathComponent(name)
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true else { continue }
                seen.insert(key)
                found.append(RecoveredFile(url: url, size: Int64(values.fileSize ?? 0),
                                           modified: values.contentModificationDate ?? Date()))
            }
            if index < dirs.count - 2 { closedDirs.insert(dir) }
        }
        return found
    }

    /// Every regular file under the session folder (after organizing too).
    public static func allFiles(in dir: URL) -> [RecoveredFile] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey],
                                    options: [.skipsHiddenFiles]) else { return [] }
        var files: [RecoveredFile] = []
        for case let url as URL in e {
            let name = url.lastPathComponent
            if ignoredNames.contains(name) || ["photorec.log", "photorec.ses", "progress.jsonl", "report.csv"].contains(name) { continue }
            if name.hasPrefix("report-") && name.hasSuffix(".xml") { continue }
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]),
                  v.isRegularFile == true else { continue }
            files.append(RecoveredFile(url: url, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? Date()))
        }
        return files.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }
}

// MARK: - Image metadata

public struct ImageInfo: Equatable {
    public var width: Int?
    public var height: Int?
    public var captureDate: Date?
}

public enum ImageMetadata {
    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    public static func read(_ url: URL) -> ImageInfo {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return ImageInfo() }
        var info = ImageInfo()
        info.width = props[kCGImagePropertyPixelWidth] as? Int
        info.height = props[kCGImagePropertyPixelHeight] as? Int
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let text = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        if let text, let date = exifFormatter.date(from: text) { info.captureDate = date }
        return info
    }
}

// MARK: - Post-processing

public struct OrganizeResult: Equatable {
    public var moved = 0
    public var renamedByDate = 0
}

public enum Organizer {
    /// Unique destination: "name.ext", then "name (2).ext", "name (3).ext"...
    public static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    private static let dateName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    /// Moves the recovered files into "Per tipo/<Categoria>/<ext>" inside the
    /// session folder. Photos with an EXIF capture date can be renamed after
    /// it. Nothing is deleted; empty recup_dir.N folders are removed.
    @discardableResult
    public static func organizeByType(sessionDir: URL, renameByDate: Bool) throws -> OrganizeResult {
        let fm = FileManager.default
        let root = sessionDir.appendingPathComponent("Per tipo")
        var result = OrganizeResult()
        let dirs = (try fm.contentsOfDirectory(atPath: sessionDir.path)).filter { $0.hasPrefix("recup_dir.") }
        for dir in dirs {
            let dirURL = sessionDir.appendingPathComponent(dir)
            for name in try fm.contentsOfDirectory(atPath: dirURL.path) where !ignoredNames.contains(name) && !name.hasPrefix(".") {
                let src = dirURL.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                let ext = src.pathExtension.lowercased()
                let category = FileCategory.of(extension: ext)
                let target = root.appendingPathComponent(category.title).appendingPathComponent(ext.isEmpty ? "senza estensione" : ext)
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                var destName = name
                if renameByDate && category == .photo, let date = ImageMetadata.read(src).captureDate {
                    destName = dateName.string(from: date) + (ext.isEmpty ? "" : "." + ext)
                    result.renamedByDate += 1
                }
                try fm.moveItem(at: src, to: uniqueURL(target.appendingPathComponent(destName)))
                result.moved += 1
            }
            let left = (try? fm.contentsOfDirectory(atPath: dirURL.path)) ?? []
            if left.allSatisfy({ ignoredNames.contains($0) || $0.hasPrefix(".") }) {
                if let report = left.first(where: { $0 == "report.xml" }) {
                    try? fm.moveItem(at: dirURL.appendingPathComponent(report),
                                     to: uniqueURL(sessionDir.appendingPathComponent("report-\(dir).xml")))
                }
                try? fm.removeItem(at: dirURL)
            }
        }
        return result
    }

    /// Identical files (same size, then same SHA-256): every copy after the
    /// first goes to "Duplicati". Returns the number of files moved.
    @discardableResult
    public static func moveDuplicates(sessionDir: URL) throws -> Int {
        let fm = FileManager.default
        let dupDir = sessionDir.appendingPathComponent("Duplicati")
        let files = RecoveryScanner.allFiles(in: sessionDir).filter { !$0.url.path.hasPrefix(dupDir.path + "/") }
        var bySize: [Int64: [RecoveredFile]] = [:]
        for f in files where f.size > 0 { bySize[f.size, default: []].append(f) }
        var moved = 0
        for group in bySize.values where group.count > 1 {
            var firstByHash: [String: URL] = [:]
            for f in group {
                guard let digest = sha256(f.url) else { continue }
                if firstByHash[digest] == nil {
                    firstByHash[digest] = f.url
                } else {
                    try fm.createDirectory(at: dupDir, withIntermediateDirectories: true)
                    try fm.moveItem(at: f.url, to: uniqueURL(dupDir.appendingPathComponent(f.name)))
                    moved += 1
                }
            }
        }
        return moved
    }

    static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// CSV report: one row per file, comma separated, RFC 4180 quoting.
    public static func csvReport(files: [RecoveredFile], relativeTo base: URL) -> String {
        func q(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        let iso = ISO8601DateFormatter()
        var lines = ["file,percorso,categoria,estensione,byte,larghezza,altezza,data_scatto"]
        for f in files {
            let rel = f.url.path.hasPrefix(base.path + "/") ? String(f.url.path.dropFirst(base.path.count + 1)) : f.url.path
            var w = "", h = "", d = ""
            if f.category == .photo {
                let info = ImageMetadata.read(f.url)
                w = info.width.map(String.init) ?? ""
                h = info.height.map(String.init) ?? ""
                d = info.captureDate.map { iso.string(from: $0) } ?? ""
            }
            lines.append([q(f.name), q(rel), f.category.title, f.ext, String(f.size), w, h, d].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Read speed

/// Smoothed read speed from the progress events (sector, time).
public struct SpeedMeter {
    private var last: (sector: UInt64, time: Date)?
    public private(set) var bytesPerSecond: Double = 0
    private let alpha = 0.3

    public init() {}

    public mutating func add(sector: UInt64, sectorSize: UInt64, at time: Date) {
        defer { if last == nil || time.timeIntervalSince(last!.time) >= 0.25 || sector < last!.sector { last = (sector, time) } }
        guard let last else { return }
        // Samples too close in time give meaningless rates (a resumed run
        // jumps millions of sectors at once): wait for a real interval.
        let dt = time.timeIntervalSince(last.time)
        guard dt >= 0.25 else { return }
        // The engine goes back on purpose (fragmented files): ignore those steps.
        guard sector >= last.sector else { return }
        let rate = Double(sector - last.sector) * Double(sectorSize) / dt
        bytesPerSecond = bytesPerSecond == 0 ? rate : alpha * rate + (1 - alpha) * bytesPerSecond
    }
}

// MARK: - History

public struct HistoryEntry: Codable, Identifiable, Equatable {
    public var id: String { path }
    public var path: String
    public var sourceName: String
    public var date: Date
    public var totalFiles: Int
    public var completed: Bool

    public init(path: String, sourceName: String, date: Date, totalFiles: Int, completed: Bool) {
        self.path = path
        self.sourceName = sourceName
        self.date = date
        self.totalFiles = totalFiles
        self.completed = completed
    }

    /// Newest first, one entry per folder, at most `limit`.
    public static func upsert(_ entry: HistoryEntry, into list: [HistoryEntry], limit: Int = 30) -> [HistoryEntry] {
        var out = list.filter { $0.path != entry.path }
        out.insert(entry, at: 0)
        return Array(out.prefix(limit))
    }
}
