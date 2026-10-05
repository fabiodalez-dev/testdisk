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
    /// RITROVO_* variables point to development builds. They are ignored
    /// for anything run as root: the environment of the app is not trusted.
    private static func override(_ key: String, privileged: Bool) -> URL? {
        guard !privileged, let env = ProcessInfo.processInfo.environment[key] else { return nil }
        return URL(fileURLWithPath: env)
    }

    static func photorec(privileged: Bool) -> URL? {
        override("RITROVO_PHOTOREC", privileged: privileged) ?? Bundle.main.url(forAuxiliaryExecutable: "photorec")
    }

    static func runner(privileged: Bool) -> URL? {
        override("RITROVO_RUNNER", privileged: privileged) ?? Bundle.main.url(forResource: "ritrovo-run", withExtension: "sh")
    }

    static var formats: URL? {
        override("RITROVO_FORMATS", privileged: false) ?? Bundle.main.url(forResource: "formats", withExtension: "json")
    }
}

/// Starts ritrovo-run.sh, as the user or through the administrator prompt.
/// The script creates <workDir> itself and PhotoRec writes only inside it,
/// with relative paths: see the comments in ritrovo-run.sh.
@MainActor
enum Runner {
    static func launch(workDir: URL, stopFile: URL, photorecArgs: [String], needsAdmin: Bool) throws -> Process? {
        guard let photorec = EnginePaths.photorec(privileged: needsAdmin),
              let runner = EnginePaths.runner(privileged: needsAdmin) else { throw EngineError.missingEngine }
        let args = [runner.path, String(getuid()), String(getgid()), workDir.path, stopFile.path, photorec.path] + photorecArgs
        if needsAdmin {
            try Privileged.run(shell: "/bin/sh " + args.map(Shell.quote).joined(separator: " ") + " </dev/null >/dev/null 2>&1 &")
            return nil
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    /// Private folder of the app for the stop request, never touched by root.
    static func controlDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ritrovo-ctl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ritrovo-probe-\(UUID().uuidString)")
        let ctl = try Runner.controlDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: ctl)
        }
        let json = dir.appendingPathComponent("probe.jsonl")
        let done = dir.appendingPathComponent(".done")
        _ = try Runner.launch(workDir: dir, stopFile: ctl.appendingPathComponent("stop"),
                              photorecArgs: ["/logjson", "probe.jsonl", "/cmd", target, ""], needsAdmin: needsAdmin)
        // Polled, so the interface never waits on a slow or failing disk.
        // Polled, so the interface never waits on a slow disk. A disk read by
        // another program, or with bad sectors, can need several minutes.
        let stop = ctl.appendingPathComponent("stop")
        let deadline = Date().addingTimeInterval(20 * 60)
        while !FileManager.default.fileExists(atPath: done.path) {
            if Task.isCancelled {
                FileManager.default.createFile(atPath: stop.path, contents: nil)
                throw CancellationError()
            }
            if Date() > deadline {
                FileManager.default.createFile(atPath: stop.path, contents: nil)
                throw EngineError.failed("Il disco non ha risposto in 20 minuti. Potrebbe essere danneggiato o in uso da un altro programma.")
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
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
    @Published private(set) var stopRequestedAt: Date?

    private var tail: JSONLTail
    private var process: Process?
    private var pollTask: Task<Void, Never>?
    private var finishedDirs: [String: Int] = [:]
    private var seenImages = Set<String>()
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "heic", "webp"]

    private var controlDir: URL?
    var stopFile: URL { (controlDir ?? sessionDir).appendingPathComponent("stop") }
    var doneFile: URL { sessionDir.appendingPathComponent(".done") }
    var jsonFile: URL { sessionDir.appendingPathComponent("progress.jsonl") }

    init(sourceName: String, sessionDir: URL) {
        self.sourceName = sourceName
        self.sessionDir = sessionDir
        self.tail = JSONLTail(url: sessionDir.appendingPathComponent("progress.jsonl"))
    }

    func start(target: String, command: String, needsAdmin: Bool) throws {
        controlDir = try Runner.controlDir()
        process = try Runner.launch(workDir: sessionDir, stopFile: stopFile,
                                    photorecArgs: ["/log", "/logname", "photorec.log", "/logjson", "progress.jsonl",
                                                   "/d", "recup_dir", "/cmd", target, command],
                                    needsAdmin: needsAdmin)
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
        stopRequestedAt = Date()
        FileManager.default.createFile(atPath: stopFile.path, contents: nil)
    }

    /// Leaves a run that does not stop (a disk blocked on bad sectors keeps
    /// the process in an uninterruptible read): the interface goes back,
    /// the runner keeps forcing the stop in the background.
    func abandon() {
        pollTask?.cancel()
        state = .failed("Il recupero è stato abbandonato: il disco non rispondeva. Il processo viene terminato appena il disco restituisce la lettura in corso.")
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
