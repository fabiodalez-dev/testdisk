// Disk events and small diskutil helpers.
import DiskArbitration
import Foundation

/// Calls back when a disk appears or disappears (card reader, USB drive),
/// coalesced so a disk with many partitions refreshes the list once.
public final class DiskWatcher {
    private var session: DASession?
    private let onChange: () -> Void
    private var pending: DispatchWorkItem?
    private let debounce: TimeInterval

    public init(debounce: TimeInterval = 1.0, onChange: @escaping () -> Void) {
        self.debounce = debounce
        self.onChange = onChange
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: DADiskAppearedCallback = { _, ctx in
            guard let ctx else { return }
            Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue().changed()
        }
        DARegisterDiskAppearedCallback(session, nil, callback, context)
        DARegisterDiskDisappearedCallback(session, nil, callback, context)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        if let session { DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) }
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}

public enum DiskTools {
    /// Unmounts and ejects a whole disk, like the Finder eject button.
    public static func eject(_ identifier: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["eject", identifier]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return "diskutil non avviato" }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return p.terminationStatus == 0 ? nil : out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Free space usable on the volume of a folder.
    public static func freeSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let v = values?.volumeAvailableCapacityForImportantUsage, v > 0 { return v }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}
