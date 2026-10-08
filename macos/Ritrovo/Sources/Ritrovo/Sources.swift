// Recovery sources: physical disks from diskutil, or disk image files.
import Foundation
import RitrovoCore

struct RecoverySource: Identifiable, Hashable {
    enum Kind: Hashable { case disk(isInternal: Bool), image }
    let id: String
    let name: String
    let detail: String
    let size: Int64
    let kind: Kind
    /// Path handed to PhotoRec: raw device (faster) or image file.
    let target: String
    /// Whole disk identifier, used to warn when saving on the same disk.
    let diskIdentifier: String?

    var needsAdmin: Bool { !FileManager.default.isReadableFile(atPath: target) }
    var symbol: String {
        switch kind {
        case .disk(let isInternal): return isInternal ? "internaldrive" : "externaldrive"
        case .image: return "opticaldiscdrive"
        }
    }

    static func image(_ url: URL) -> RecoverySource {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return RecoverySource(id: "image:" + url.path, name: url.lastPathComponent, detail: url.deletingLastPathComponent().path,
                              size: size, kind: .image, target: url.path, diskIdentifier: nil)
    }
}

enum DiskService {
    private static func plist(_ args: [String]) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Physical disks only: PhotoRec reads the raw device, APFS
    /// containers and volumes are views of the same blocks.
    static func physicalDisks() -> [RecoverySource] {
        guard let list = plist(["list", "-plist", "physical"]),
              let disks = list["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        return disks.compactMap { disk in
            guard let ident = disk["DeviceIdentifier"] as? String else { return nil }
            let info = plist(["info", "-plist", ident]) ?? [:]
            let isInternal = (info["Internal"] as? Bool) ?? false
            let media = (info["MediaName"] as? String) ?? ident
            let size = (disk["Size"] as? NSNumber)?.int64Value ?? 0
            let volumes = ((disk["Partitions"] as? [[String: Any]]) ?? []).compactMap { $0["VolumeName"] as? String }
            let detail = volumes.isEmpty ? ident : ident + " · " + volumes.joined(separator: ", ")
            return RecoverySource(id: "disk:" + ident, name: media, detail: detail, size: size,
                                  kind: .disk(isInternal: isInternal), target: "/dev/r" + ident, diskIdentifier: ident)
        }
    }

    /// Whole disk holding a path, e.g. "disk3" for a volume on disk3s1.
    /// APFS volumes live on a synthesized disk: follow it to the physical store.
    static func physicalDisk(of url: URL) -> String? {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return nil }
        let from = withUnsafeBytes(of: fs.f_mntfromname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard from.hasPrefix("/dev/") else { return nil }
        let device = String(from.dropFirst(5))
        guard let info = plist(["info", "-plist", device]) else { return nil }
        if let stores = info["APFSPhysicalStores"] as? [[String: Any]],
           let store = stores.first?["APFSPhysicalStore"] as? String,
           let storeInfo = plist(["info", "-plist", store]) {
            return storeInfo["ParentWholeDisk"] as? String
        }
        return info["ParentWholeDisk"] as? String
    }
}

extension DiskService {
    static func eject(_ identifier: String) -> String? { DiskTools.eject(identifier) }
    static func freeSpace(at url: URL) -> Int64? { DiskTools.freeSpace(at: url) }
}
