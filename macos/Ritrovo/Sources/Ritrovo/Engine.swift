// Drives the bundled, unmodified PhotoRec command line program.
// Recovery accuracy is PhotoRec's own: the app only builds the /cmd
// line, reads the /logjson progress and watches the output folders.
import AppKit
import Foundation
import RitrovoCore

enum EngineError: LocalizedError {
    case missingEngine
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingEngine: return "Motore PhotoRec non trovato nel pacchetto dell'app."
        case .cancelled: return "Autorizzazione annullata."
        case .failed(let msg): return msg
        }
    }
}

enum EnginePaths {
    static var photorec: URL? {
        if let env = ProcessInfo.processInfo.environment["RITROVO_PHOTOREC"] { return URL(fileURLWithPath: env) }
        return Bundle.main.url(forAuxiliaryExecutable: "photorec")
    }

    static var runner: URL? {
        if let env = ProcessInfo.processInfo.environment["RITROVO_RUNNER"] { return URL(fileURLWithPath: env) }
        return Bundle.main.url(forResource: "ritrovo-run", withExtension: "sh")
    }

    static var formats: URL? {
        if let env = ProcessInfo.processInfo.environment["RITROVO_FORMATS"] { return URL(fileURLWithPath: env) }
        return Bundle.main.url(forResource: "formats", withExtension: "json")
    }
}

/// Raw devices need root: the request goes through the standard macOS
/// administrator prompt. NSAppleScript keeps the authorization for a few
/// minutes, so probing and recovering ask only once.
@MainActor
enum Privileged {
    static func run(shell command: String) throws {
        let source = "do shell script \(Shell.appleScriptString(command)) with administrator privileges"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw EngineError.failed("AppleScript non valido") }
        script.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw EngineError.cancelled }
            throw EngineError.failed(error[NSAppleScript.errorMessage] as? String ?? "Errore di autorizzazione")
        }
    }
}

enum Probe {
    /// Asks PhotoRec for the partitions it sees: an empty /cmd stops
    /// right after partition detection, nothing is read beyond that.
    @MainActor
    static func partitions(target: String, needsAdmin: Bool) async throws -> [EnginePartition] {
        guard let photorec = EnginePaths.photorec else { throw EngineError.missingEngine }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ritrovo-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = dir.appendingPathComponent("probe.jsonl")
        let args = [photorec.path, "/logjson", json.path, "/cmd", target, ""]
        if needsAdmin {
            // Detached, so the interface never waits on a slow or failing disk.
            let done = dir.appendingPathComponent("done")
            let cmd = "( cd \(Shell.quote(dir.path)) && " + args.map(Shell.quote).joined(separator: " ")
                + " </dev/null >/dev/null 2>&1; chmod 644 \(Shell.quote(json.path)); touch \(Shell.quote(done.path)) ) >/dev/null 2>&1 &"
            try Privileged.run(shell: cmd)
            let deadline = Date().addingTimeInterval(120)
            while !FileManager.default.fileExists(atPath: done.path) {
                if Date() > deadline {
                    throw EngineError.failed("Il disco non risponde: la lettura delle partizioni non è terminata in due minuti. Il disco potrebbe essere danneggiato o in uso da un altro programma.")
                }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        } else {
            try await Task.detached {
                let p = Process()
                p.executableURL = photorec
                p.arguments = Array(args.dropFirst())
                p.currentDirectoryURL = dir
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try p.run()
                p.waitUntilExit()
            }.value
        }
        let events = EventParser.parse(text: (try? String(contentsOf: json, encoding: .utf8)) ?? "")
        let parts = events.compactMap { event -> EnginePartition? in
            if case .partition(let p) = event { return p }
            return nil
        }
        if parts.isEmpty {
            let errors = events.compactMap { event -> String? in
                if case .log(let level, let msg) = event, level == "critical" || level == "error" { return msg }
                return nil
            }
            throw EngineError.failed(errors.last ?? "PhotoRec non è riuscito a leggere la sorgente.")
        }
        return parts
    }
}

/// One recovery run.
@MainActor
final class RecoverySession: ObservableObject {
    enum State: Equatable {
        case running
        case stopping
        case finished(exitCode: Int32)
        case failed(String)
    }

    let sessionDir: URL
    let sourceName: String
    @Published private(set) var state: State = .running
    @Published private(set) var progress: ProgressEvent?
    @Published private(set) var stats: [String: Int] = [:]
    @Published private(set) var totalFiles = 0
    @Published private(set) var recentImages: [URL] = []
    @Published private(set) var lastMessage = ""
    @Published private(set) var stoppedByUser = false

    private var tail: JSONLTail
    private var process: Process?
    private var pollTask: Task<Void, Never>?
    private var finishedDirs: [String: Int] = [:]
    private var seenImages = Set<String>()
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "heic", "webp"]

    var stopFile: URL { sessionDir.appendingPathComponent(".stop") }
    var doneFile: URL { sessionDir.appendingPathComponent(".done") }
    var jsonFile: URL { sessionDir.appendingPathComponent("progress.jsonl") }

    init(sourceName: String, sessionDir: URL) {
        self.sourceName = sourceName
        self.sessionDir = sessionDir
        self.tail = JSONLTail(url: sessionDir.appendingPathComponent("progress.jsonl"))
    }

    func start(target: String, command: String, needsAdmin: Bool) throws {
        guard let photorec = EnginePaths.photorec, let runner = EnginePaths.runner else { throw EngineError.missingEngine }
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let owner = "\(getuid()):\(getgid())"
        let args: [String] = [runner.path, owner, sessionDir.path, stopFile.path, doneFile.path,
                              photorec.path, "/log", "/logname", sessionDir.appendingPathComponent("photorec.log").path,
                              "/logjson", jsonFile.path,
                              "/d", sessionDir.appendingPathComponent("recup_dir").path,
                              "/cmd", target, command]
        if needsAdmin {
            let cmd = "/bin/sh " + args.map(Shell.quote).joined(separator: " ") + " </dev/null >/dev/null 2>&1 &"
            try Privileged.run(shell: cmd)
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = args
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            process = p
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                if self.poll() { return }
            }
        }
    }

    /// PhotoRec stops on SIGINT and saves photorec.ses, the runner script
    /// sends it when the stop file appears (it may run as root).
    func stop() {
        guard state == .running else { return }
        state = .stopping
        stoppedByUser = true
        FileManager.default.createFile(atPath: stopFile.path, contents: nil)
    }

    /// Returns true when the run is over.
    private func poll() -> Bool {
        for event in tail.readNew() {
            switch event {
            case .progress(let p):
                progress = p
                totalFiles = p.filesFound
                if !p.stats.isEmpty { stats = p.stats }
            case .completion(let total, _, let s):
                totalFiles = total
                if !s.isEmpty { stats = s }
            case .log(let level, let message) where level == "critical" || level == "error":
                lastMessage = message
            default:
                break
            }
        }
        scanImages()
        if let text = try? String(contentsOf: doneFile, encoding: .utf8) {
            let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            _ = tail.readNew()
            scanImages()
            pruneDeletedImages()
            state = code == 0 ? .finished(exitCode: code) : .failed(lastMessage.isEmpty ? "PhotoRec è terminato con codice \(code)" : lastMessage)
            return true
        }
        return false
    }

    /// recup_dir.N folders hold up to 500 files, only the last ones change.
    private func scanImages() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: sessionDir.path) else { return }
        let recup = dirs.filter { $0.hasPrefix("recup_dir.") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for (index, dir) in recup.enumerated() {
            let isLastTwo = index >= recup.count - 2
            if !isLastTwo && finishedDirs[dir] != nil { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: sessionDir.appendingPathComponent(dir).path) else { continue }
            if !isLastTwo { finishedDirs[dir] = files.count }
            for name in files.sorted() where !seenImages.contains(dir + "/" + name) {
                let ext = (name as NSString).pathExtension.lowercased()
                guard Self.imageExtensions.contains(ext) else { continue }
                seenImages.insert(dir + "/" + name)
                recentImages.insert(sessionDir.appendingPathComponent(dir).appendingPathComponent(name), at: 0)
            }
        }
        if recentImages.count > 120 { recentImages.removeLast(recentImages.count - 120) }
    }

    /// Files rejected at the end of a pass (too small, corrupted) are deleted by PhotoRec.
    private func pruneDeletedImages() {
        recentImages.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
    }
}
