// Plain test runner: XCTest is not available with the Command Line Tools alone.
// swift run RitrovoCoreTests
import Foundation
import RitrovoCore

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
opts.deepJPEG = true
opts.keepCorrupted = true
let cmd = CommandBuilder.command(partitionOrder: 255, options: opts, catalog: catalog)
check(cmd == "255,options,paranoid_bf,keep_corrupted_file,mode_ext2,image_min_width,640,image_min_height,480,image_min_filesize,10000,fileopt,everything,disable,7z,enable,jpg,enable,freespace,search",
      "full command: \(cmd)")

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

print(failures == 0 ? "All tests passed" : "\(failures) test(s) failed")
exit(failures == 0 ? 0 : 1)
