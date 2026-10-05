// Engine-independent logic: format catalog, PhotoRec command line,
// JSON log parsing. Kept free of UI code so it can be tested alone.
import Foundation

// MARK: - File formats

/// One entry of formats.json, generated from the PhotoRec sources.
public struct FormatEntry: Decodable {
    public let id: String
    public let `extension`: String
    public let description: String
    public let enabledByDefault: Bool

    public init(id: String, extension ext: String, description: String, enabledByDefault: Bool) {
        self.id = id
        self.extension = ext
        self.description = description
        self.enabledByDefault = enabledByDefault
    }
}

/// PhotoRec enables formats by extension, so entries sharing an
/// extension are merged into one switch.
public struct FileFormat: Identifiable, Hashable {
    public var id: String { ext }
    public let ext: String
    public let description: String
    public let enabledByDefault: Bool

    public init(ext: String, description: String, enabledByDefault: Bool) {
        self.ext = ext
        self.description = description
        self.enabledByDefault = enabledByDefault
    }

    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        return ext.localizedCaseInsensitiveContains(q) || description.localizedCaseInsensitiveContains(q)
    }
}

public enum FormatCatalog {
    public static func merge(_ entries: [FormatEntry]) -> [FileFormat] {
        var order: [String] = []
        var byExt: [String: (descriptions: [String], enabled: Bool)] = [:]
        for e in entries {
            if byExt[e.extension] == nil {
                order.append(e.extension)
                byExt[e.extension] = ([], false)
            }
            if !e.description.isEmpty && !byExt[e.extension]!.descriptions.contains(e.description) {
                byExt[e.extension]!.descriptions.append(e.description)
            }
            byExt[e.extension]!.enabled = byExt[e.extension]!.enabled || e.enabledByDefault
        }
        return order.map { ext in
            FileFormat(ext: ext, description: byExt[ext]!.descriptions.joined(separator: " / "),
                       enabledByDefault: byExt[ext]!.enabled)
        }.sorted { $0.ext.localizedStandardCompare($1.ext) == .orderedAscending }
    }

    public static func load(from url: URL) throws -> [FileFormat] {
        let data = try Data(contentsOf: url)
        return merge(try JSONDecoder().decode([FormatEntry].self, from: data))
    }

    /// Quick selections, limited to the extensions present in the catalog.
    public static let photoExtensions: Set<String> = [
        "jpg", "png", "gif", "bmp", "tif", "heic", "webp", "psd", "crw", "cr2", "cr3",
        "nef", "orf", "raf", "rw2", "mrw", "x3f", "arw", "dng", "pef", "srw", "raw", "jp2", "ico", "svg",
    ]
    public static let videoExtensions: Set<String> = [
        "mov", "mpg", "mkv", "riff", "avi", "m2ts", "mts", "flv", "wmv", "asf", "3gp", "ts", "mp4", "webm", "swf",
    ]
}

// MARK: - Partitions as seen by PhotoRec

public struct EnginePartition: Identifiable, Hashable {
    public static let wholeDiskOrder = 255
    public let order: Int
    public let offset: UInt64
    public let size: UInt64
    public let description: String
    public let info: String
    public let label: String
    public var id: Int { order }
    public var isWholeDisk: Bool { order == Self.wholeDiskOrder }

    /// File system type, the third column of the PhotoRec partition line.
    public var fileSystem: String {
        let tokens = description.split(separator: " ")
        if isWholeDisk { return "" }
        return tokens.count > 2 ? String(tokens[2]) : ""
    }

    /// ext2/ext3/ext4 benefit from PhotoRec's indirect block handling.
    public var isExtFamily: Bool {
        let text = (fileSystem + " " + info).lowercased()
        return text.contains("ext2") || text.contains("ext3") || text.contains("ext4")
    }

    /// Free space carving needs a file system PhotoRec understands.
    public var supportsFreeSpace: Bool {
        if isWholeDisk || info.isEmpty { return false }
        let text = (fileSystem + " " + info).lowercased()
        return ["fat", "ntfs", "ext2", "ext3", "ext4", "exfat"].contains { text.contains($0) }
    }
}

// MARK: - Recovery settings and the /cmd line

public enum SearchSpace: String, CaseIterable, Identifiable {
    case whole, free
    public var id: String { rawValue }
}

public struct ImageFilters: Equatable {
    public var minWidth: UInt32 = 0
    public var minHeight: UInt32 = 0
    public var minPixels: UInt64 = 0
    public var minBytes: UInt64 = 0
    public init(minWidth: UInt32 = 0, minHeight: UInt32 = 0, minPixels: UInt64 = 0, minBytes: UInt64 = 0) {
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.minPixels = minPixels
        self.minBytes = minBytes
    }
    public var isActive: Bool { minWidth > 0 || minHeight > 0 || minPixels > 0 || minBytes > 0 }
}

public struct RecoveryOptions: Equatable {
    public var enabledFormats: Set<String>
    public var filters = ImageFilters()
    public var searchSpace: SearchSpace = .whole
    public var ext2Mode = false
    /// paranoid_bf: brute force for fragmented JPEG, slower
    public var deepJPEG = false
    public var keepCorrupted = false

    public init(enabledFormats: Set<String>) {
        self.enabledFormats = enabledFormats
    }
}

public enum CommandBuilder {
    /// Builds the PhotoRec /cmd argument. Every keyword is parsed by the
    /// unmodified PhotoRec CLI (src/phcli.c, src/poptions.c).
    public static func command(partitionOrder: Int, options o: RecoveryOptions, catalog: [FileFormat]) -> String {
        var parts: [String] = [String(partitionOrder), "options"]
        parts.append(o.deepJPEG ? "paranoid_bf" : "paranoid")
        if o.keepCorrupted { parts.append("keep_corrupted_file") }
        if o.ext2Mode { parts.append("mode_ext2") }
        if o.filters.minWidth > 0 { parts += ["image_min_width", String(o.filters.minWidth)] }
        if o.filters.minHeight > 0 { parts += ["image_min_height", String(o.filters.minHeight)] }
        if o.filters.minPixels > 0 { parts += ["image_min_pixels", String(o.filters.minPixels)] }
        if o.filters.minBytes > 0 { parts += ["image_min_filesize", String(o.filters.minBytes)] }
        let defaults = Set(catalog.filter(\.enabledByDefault).map(\.ext))
        if o.enabledFormats != defaults {
            parts += ["fileopt", "everything", "disable"]
            for f in catalog where o.enabledFormats.contains(f.ext) {
                parts += [f.ext, "enable"]
            }
        }
        parts.append(o.searchSpace == .free ? "freespace" : "wholespace")
        parts.append("search")
        return parts.joined(separator: ",")
    }
}

// MARK: - JSON log events (/logjson)

public struct ProgressEvent: Equatable {
    public var pass: Int
    public var currentSector: UInt64
    public var totalSectors: UInt64
    public var filesFound: Int
    public var elapsed: String?
    public var estimated: String?
    public var stats: [String: Int]
    public var fraction: Double {
        totalSectors == 0 ? 0 : min(1, Double(currentSector) / Double(totalSectors))
    }
}

public enum EngineEvent: Equatable {
    case partition(EnginePartition)
    case progress(ProgressEvent)
    case completion(totalFiles: Int, elapsed: String?, stats: [String: Int])
    case log(level: String, message: String)
    case diskInfo(readOnly: Bool, size: UInt64)
    case other
}

public enum EventParser {
    static func u64(_ v: Any?) -> UInt64 { (v as? NSNumber)?.uint64Value ?? 0 }
    static func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
    static func stats(_ v: Any?) -> [String: Int] {
        guard let d = v as? [String: Any] else { return [:] }
        return d.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    public static func parse(line: Substring) -> EngineEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "partition":
            return .partition(EnginePartition(order: int(obj["order"]), offset: u64(obj["part_offset"]),
                                              size: u64(obj["part_size"]),
                                              description: obj["description"] as? String ?? "",
                                              info: obj["info"] as? String ?? "",
                                              label: obj["label"] as? String ?? ""))
        case "progress":
            return .progress(ProgressEvent(pass: int(obj["pass"]), currentSector: u64(obj["current_sector"]),
                                           totalSectors: u64(obj["total_sectors"]), filesFound: int(obj["files_found"]),
                                           elapsed: obj["elapsed_time"] as? String,
                                           estimated: obj["estimated_time"] as? String,
                                           stats: stats(obj["file_stats"])))
        case "completion":
            return .completion(totalFiles: int(obj["total_files"]), elapsed: obj["elapsed_time"] as? String,
                               stats: stats(obj["final_stats"]))
        case "log":
            return .log(level: obj["level"] as? String ?? "", message: obj["message"] as? String ?? "")
        case "disk_info":
            return .diskInfo(readOnly: (obj["readonly"] as? Bool) ?? true, size: u64(obj["size_bytes"]))
        default:
            return .other
        }
    }

    public static func parse(text: String) -> [EngineEvent] {
        text.split(separator: "\n").compactMap { parse(line: $0) }
    }
}

/// Reads a growing JSONL file, returning only complete new lines.
public final class JSONLTail {
    public let url: URL
    private var offset: UInt64 = 0
    private var pending = Data()

    public init(url: URL) { self.url = url }

    public func readNew() -> [EngineEvent] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset += UInt64(data.count)
        pending.append(data)
        guard let lastNewline = pending.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let complete = pending[pending.startIndex...lastNewline]
        pending = Data(pending[pending.index(after: lastNewline)...])
        return EventParser.parse(text: String(decoding: complete, as: UTF8.self))
    }
}

// MARK: - Shell helpers

public enum Shell {
    /// POSIX single quote escaping.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escaping for a string literal inside AppleScript.
    public static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
