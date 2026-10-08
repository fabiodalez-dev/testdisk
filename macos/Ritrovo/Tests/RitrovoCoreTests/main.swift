// Plain test runner: XCTest is not available with the Command Line Tools alone.
// swift run RitrovoCoreTests
import Foundation
import ImageIO
import RitrovoCore
import UniformTypeIdentifiers

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL line \(line): \(message)")
    }
}

let catalog = FormatCatalog.merge([
    FormatEntry(id: "jpg", extension: "jpg", description: "JPG picture", enabledByDefault: true),
    FormatEntry(id: "png", extension: "png", description: "PNG", enabledByDefault: true),
    FormatEntry(id: "fat", extension: "fat", description: "FAT subdirectory", enabledByDefault: false),
    FormatEntry(id: "fat2", extension: "fat", description: "FAT boot", enabledByDefault: true),
    FormatEntry(id: "7z", extension: "7z", description: "7zip archive", enabledByDefault: true),
])
check(catalog.count == 4, "duplicate extensions merged")
check(catalog.first { $0.ext == "fat" }?.enabledByDefault == true, "merged entry enabled if any is")
check(catalog.first { $0.ext == "jpg" }?.matches("picture") == true, "search by description")
check(catalog.first { $0.ext == "jpg" }?.matches("JP") == true, "search by extension, case insensitive")

// Defaults: no fileopt section
var opts = RecoveryOptions(enabledFormats: Set(catalog.filter(\.enabledByDefault).map(\.ext)))
check(CommandBuilder.command(partitionOrder: 1, options: opts, catalog: catalog) == "1,options,paranoid,wholespace,search",
      "default command: \(CommandBuilder.command(partitionOrder: 1, options: opts, catalog: catalog))")

opts.enabledFormats = ["jpg", "7z"]
opts.filters = ImageFilters(minWidth: 640, minHeight: 480, minPixels: 0, minBytes: 10000)
opts.searchSpace = .free
opts.ext2Mode = true
opts.validation = .bruteForce
opts.keepCorrupted = true
let cmd = CommandBuilder.command(partitionOrder: 255, options: opts, catalog: catalog)
check(cmd == "255,options,paranoid_bf,keep_corrupted_file,mode_ext2,image_min_width,640,image_min_height,480,image_min_filesize,10000,fileopt,everything,disable,7z,enable,jpg,enable,freespace,search",
      "full command: \(cmd)")

var expert = RecoveryOptions(enabledFormats: Set(catalog.filter(\.enabledByDefault).map(\.ext)))
expert.partitionTable = .gpt
expert.geometry = Geometry(heads: 255, sectors: 63, sectorSize: 4096)
expert.validation = .off
expert.lowMemory = true
expert.blockSize = 4096
expert.ext2Group = 3
expert.unformatFAT = true
let ecmd = CommandBuilder.command(partitionOrder: 2, options: expert, catalog: catalog)
check(ecmd == "partition_gpt,2,geometry,H,255,S,63,N,4096,options,paranoid_no,lowmem,blocksize,4096,ext2_group,3,wholespace,search,status=unformat",
      "expert command: \(ecmd)")
check(CommandBuilder.probeCommand(options: expert) == "partition_gpt", "probe with table type")
check(CommandBuilder.probeCommand(options: opts) == "", "probe auto")

// JSON events, as written by src/json_log.c
let log = """
{"timestamp":"t","type":"partition","order":255,"part_offset":0,"part_size":41943040,"description":"     No partition             0   0  1     5  25 20      81920 [Whole disk]","info":"","label":"Whole disk"}
{"timestamp":"t","type":"partition","order":1,"part_offset":512,"part_size":41942528,"description":" 1 P FAT32                    0   0  2     5  25 20      81919 [TEST]","info":"FAT32, blocksize=512","label":"TEST"}
{"timestamp":"t","type":"progress","pass":1,"current_sector":500,"total_sectors":1000,"files_found":7,"elapsed_time":"0h00m03s","file_stats":{"jpg":5,"png":2}}
{"timestamp":"t","type":"completion","total_files":9,"final_stats":{"jpg":7,"png":2}}
"""
let events = EventParser.parse(text: log)
check(events.count == 4, "4 events")
if case .partition(let p) = events[0] {
    check(p.isWholeDisk && !p.supportsFreeSpace, "whole disk")
} else { check(false, "partition 0") }
if case .partition(let p) = events[1] {
    check(p.order == 1 && p.fileSystem == "FAT32" && p.label == "TEST" && p.supportsFreeSpace && !p.isExtFamily, "FAT32 partition")
} else { check(false, "partition 1") }
if case .progress(let p) = events[2] {
    check(p.fraction == 0.5 && p.filesFound == 7 && p.stats["jpg"] == 5, "progress")
} else { check(false, "progress") }
if case .completion(let total, _, let stats) = events[3] {
    check(total == 9 && stats["png"] == 2, "completion")
} else { check(false, "completion") }

// Incremental reading: a partial line waits for its end
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ritrovo-tail-\(UUID().uuidString).jsonl")
let first = "{\"type\":\"progress\",\"pass\":0,\"current_sector\":1,\"total_sectors\":4,\"files_found\":0}\n{\"type\":\"progr"
try! first.write(to: tmp, atomically: false, encoding: .utf8)
let tail = JSONLTail(url: tmp)
check(tail.readNew().count == 1, "only the complete line")
let handle = try! FileHandle(forWritingTo: tmp)
handle.seekToEndOfFile()
handle.write("ess\",\"pass\":0,\"current_sector\":2,\"total_sectors\":4,\"files_found\":1}\n".data(using: .utf8)!)
try! handle.close()
let second = tail.readNew()
check(second.count == 1, "partial line completed")
if case .progress(let p)? = second.first { check(p.currentSector == 2, "second progress") }
try? FileManager.default.removeItem(at: tmp)

check(Shell.quote("a'b c") == "'a'\\''b c'", "shell quote")
check(Shell.appleScriptString("say \"hi\" \\") == "\"say \\\"hi\\\" \\\\\"", "applescript string")


// MARK: - Categories and filters
check(FileCategory.of(extension: "JPG") == .photo, "jpg photo")
check(FileCategory.of(extension: "mov") == .video, "mov video")
check(FileCategory.of(extension: "wav") == .audio, "wav audio")
check(FileCategory.of(extension: "pdf") == .document, "pdf document")
check(FileCategory.of(extension: "zip") == .archive, "zip archive")
check(FileCategory.of(extension: "xyz") == .other, "unknown other")
check(FileFormat(ext: "riff", description: "", enabledByDefault: true).category == .video, "riff format grouped with video")

let now = Date()
let sample = [
    RecoveredFile(url: URL(fileURLWithPath: "/x/f1.jpg"), size: 500, modified: now),
    RecoveredFile(url: URL(fileURLWithPath: "/x/f2.mov"), size: 9000, modified: now),
    RecoveredFile(url: URL(fileURLWithPath: "/x/f3.png"), size: 100, modified: now),
    RecoveredFile(url: URL(fileURLWithPath: "/x/a4.pdf"), size: 2000, modified: now),
]
check(ResultFilter.apply(sample, category: .photo, query: "", sort: .largest).map(\.name) == ["f1.jpg", "f3.png"], "filter photo + largest")
check(ResultFilter.apply(sample, category: nil, query: "pdf", sort: .newest).map(\.name) == ["a4.pdf"], "search by extension")
check(ResultFilter.apply(sample, category: nil, query: "", sort: .name).first?.name == "a4.pdf", "sort by name")
check(ResultFilter.counts(sample)[.photo] == 2 && ResultFilter.counts(sample)[.video] == 1, "counts")

// MARK: - Scanner, organizer, duplicates, report on a temporary session
let fm = FileManager.default
let session = fm.temporaryDirectory.appendingPathComponent("ritrovo-test-\(UUID().uuidString)")
let d1 = session.appendingPathComponent("recup_dir.1")
try! fm.createDirectory(at: d1, withIntermediateDirectories: true)

func writeJPEG(_ url: URL, date: String?) {
    let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    var props: [CFString: Any] = [:]
    if let date { props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: date] }
    CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
    CGImageDestinationFinalize(dest)
}
writeJPEG(d1.appendingPathComponent("f0001.jpg"), date: "2021:07:14 18:30:05")
writeJPEG(d1.appendingPathComponent("f0002.jpg"), date: nil)
try! Data("same content".utf8).write(to: d1.appendingPathComponent("f0003.txt"))
try! Data("<xml/>".utf8).write(to: d1.appendingPathComponent("report.xml"))

let scanner = RecoveryScanner(sessionDir: session)
let firstScan = scanner.scanNew()
check(firstScan.count == 3, "scanner finds 3 files, report.xml ignored (\(firstScan.count))")
check(scanner.scanNew().isEmpty, "second scan without changes is empty")
let d2 = session.appendingPathComponent("recup_dir.2")
try! fm.createDirectory(at: d2, withIntermediateDirectories: true)
try! Data("same content".utf8).write(to: d2.appendingPathComponent("f0500.txt"))
try! Data("other".utf8).write(to: d2.appendingPathComponent("f0501.txt"))
check(scanner.scanNew().map(\.name) == ["f0500.txt", "f0501.txt"], "scanner picks new folder")

let info = ImageMetadata.read(d1.appendingPathComponent("f0001.jpg"))
check(info.width == 40 && info.height == 30 && info.captureDate != nil, "EXIF read: \(info)")

check(try! Organizer.moveDuplicates(sessionDir: session) == 1, "one duplicate moved")
check(fm.fileExists(atPath: session.appendingPathComponent("Duplicati").path), "Duplicati folder")

let organized = try! Organizer.organizeByType(sessionDir: session, renameByDate: true)
check(organized.moved == 4 && organized.renamedByDate == 1, "organize: \(organized)")
let photoDir = session.appendingPathComponent("Per tipo/Foto/jpg")
let photos = (try? fm.contentsOfDirectory(atPath: photoDir.path).sorted()) ?? []
check(photos == ["2021-07-14 18.30.05.jpg", "f0002.jpg"], "photos renamed by date: \(photos)")
check(!fm.fileExists(atPath: d1.path) && !fm.fileExists(atPath: d2.path), "empty recup_dir removed")
check(fm.fileExists(atPath: session.appendingPathComponent("report-recup_dir.1.xml").path), "report.xml kept")
check(Organizer.uniqueURL(photoDir.appendingPathComponent("f0002.jpg")).lastPathComponent == "f0002 (2).jpg", "unique name")

let all = RecoveryScanner.allFiles(in: session)
check(all.count == 5, "all files after organizing: \(all.count)")
let csv = Organizer.csvReport(files: all, relativeTo: session)
check(csv.hasPrefix("file,percorso,categoria"), "csv header")
check(csv.contains("Per tipo/Foto/jpg/2021-07-14 18.30.05.jpg,Foto,jpg") && csv.contains(",40,30,2021-07-14T"), "csv photo row")
check(csv.split(separator: "\n").count == 6, "csv rows")
let quoted = Organizer.csvReport(files: [RecoveredFile(url: URL(fileURLWithPath: "/b/a,\"b\".txt"), size: 1, modified: now)], relativeTo: URL(fileURLWithPath: "/b"))
check(quoted.contains("\"a,\"\"b\"\".txt\""), "csv quoting")
try? fm.removeItem(at: session)

// MARK: - Speed, history, saved options
var meter = SpeedMeter()
let t0 = Date()
meter.add(sector: 0, sectorSize: 512, at: t0)
meter.add(sector: 20480, sectorSize: 512, at: t0.addingTimeInterval(1))
check(abs(meter.bytesPerSecond - 10_485_760) < 1, "speed 10 MiB/s: \(meter.bytesPerSecond)")
meter.add(sector: 10000, sectorSize: 512, at: t0.addingTimeInterval(2))
check(abs(meter.bytesPerSecond - 10_485_760) < 1, "backward step ignored")
var resumed = SpeedMeter()
resumed.add(sector: 0, sectorSize: 512, at: t0)
resumed.add(sector: 13_000_000, sectorSize: 512, at: t0.addingTimeInterval(0.001))
check(resumed.bytesPerSecond == 0, "jump in the same instant ignored (resumed run)")

var hist: [HistoryEntry] = []
hist = HistoryEntry.upsert(HistoryEntry(path: "/a", sourceName: "A", date: now, totalFiles: 1, completed: false), into: hist)
hist = HistoryEntry.upsert(HistoryEntry(path: "/b", sourceName: "B", date: now, totalFiles: 2, completed: true), into: hist)
hist = HistoryEntry.upsert(HistoryEntry(path: "/a", sourceName: "A", date: now, totalFiles: 9, completed: true), into: hist)
check(hist.map(\.path) == ["/a", "/b"] && hist[0].totalFiles == 9, "history upsert")
let histData = try! JSONEncoder().encode(hist)
check((try? JSONDecoder().decode([HistoryEntry].self, from: histData)) == hist, "history codable")

var saved = RecoveryOptions(enabledFormats: ["jpg", "png"])
saved.filters = ImageFilters(minWidth: 300, minHeight: 300)
saved.searchSpace = .free
let savedData = try! JSONEncoder().encode(saved)
check((try? JSONDecoder().decode(RecoveryOptions.self, from: savedData)) == saved, "options codable")


// MARK: - Disk events and eject, with a virtual disk
func sh(_ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try! p.run()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return (p.terminationStatus, out)
}
check((DiskTools.freeSpace(at: fm.temporaryDirectory) ?? 0) > 0, "free space readable")
let dmg = fm.temporaryDirectory.appendingPathComponent("ritrovo-watch-\(UUID().uuidString).dmg")
check(sh(["/usr/bin/hdiutil", "create", "-size", "8m", "-fs", "MS-DOS", "-volname", "RTEST", dmg.path]).0 == 0, "test dmg created")
var diskEvents = 0
let watcher = DiskWatcher(debounce: 0.2) { diskEvents += 1 }
RunLoop.main.run(until: Date().addingTimeInterval(1.5))   // initial callbacks for the disks already there
let baseline = diskEvents
let attach = sh(["/usr/bin/hdiutil", "attach", dmg.path])
let dev = attach.1.split(separator: "\n").compactMap { line -> String? in
    let first = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init) ?? ""
    return first.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil ? first : nil
}.first
RunLoop.main.run(until: Date().addingTimeInterval(2))
check(attach.0 == 0 && diskEvents > baseline, "watcher notices an attached disk (\(diskEvents - baseline) events)")
if let dev {
    let ident = String(dev.dropFirst(5))
    let afterAttach = diskEvents
    check(DiskTools.eject(ident) == nil, "eject \(ident)")
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    check(diskEvents > afterAttach, "watcher notices the ejected disk")
    check(DiskTools.eject(ident) != nil, "ejecting a missing disk reports an error")
} else {
    check(false, "attached device not found in: \(attach.1)")
}
withExtendedLifetime(watcher) {}
try? fm.removeItem(at: dmg)

print(failures == 0 ? "All tests passed" : "\(failures) test(s) failed")
exit(failures == 0 ? 0 : 1)
