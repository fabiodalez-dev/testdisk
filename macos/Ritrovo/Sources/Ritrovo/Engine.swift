// Drives the bundled recovery engine (credited in the About window).
// Recovery accuracy is the engine's own: the app only builds the /cmd
// line, reads the /logjson progress and watches the output folders.
import AppKit
import Foundation
import RitrovoCore

enum EngineError: LocalizedError {
    case missingEngine
    case cancelled
    case failed(String)
    case notAllowed

    /// Throws unless root is acceptable for this source (physical disks only).
    static func checkPrivilege(target: String, needsAdmin: Bool) throws {
        if needsAdmin && !PrivilegePolicy.mayRunAsRoot(target) { throw EngineError.notAllowed }
    }

    var errorDescription: String? {
        switch self {
        case .missingEngine: return "Il motore di recupero manca nel pacchetto dell'app. Reinstalla Ritrovo."
        case .cancelled: return "Autorizzazione annullata."
        case .failed(let msg): return msg
        case .notAllowed: return "Questo file non è leggibile dal tuo utente. Per sicurezza la password di amministratore si usa solo per leggere i dischi fisici: copia il file in una cartella tua e riprova."
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

    static func engine(privileged: Bool) -> URL? {
        override("RITROVO_ENGINE", privileged: privileged) ?? Bundle.main.url(forAuxiliaryExecutable: "ritrovo-engine")
    }

    static func runner(privileged: Bool) -> URL? {
        override("RITROVO_RUNNER", privileged: privileged) ?? Bundle.main.url(forResource: "ritrovo-run", withExtension: "sh")
    }

    static var formats: URL? {
        override("RITROVO_FORMATS", privileged: false) ?? Bundle.main.url(forResource: "formats", withExtension: "json")
    }
}

/// Starts ritrovo-run.sh, as the user or through the administrator prompt.
/// The script creates <workDir> itself and the engine writes only inside it,
/// with relative paths: see the comments in ritrovo-run.sh.
@MainActor
enum Runner {
    static func launch(workDir: URL, stopFile: URL, engineArgs: [String], seed: URL? = nil, needsAdmin: Bool) throws -> Process? {
        guard let engine = EnginePaths.engine(privileged: needsAdmin) else { throw EngineError.missingEngine }
        return try launch(workDir: workDir, stopFile: stopFile, command: [engine.path] + engineArgs, seed: seed, needsAdmin: needsAdmin)
    }

    /// `command[0]` must be an absolute path: the bundled engine or a system tool.
    static func launch(workDir: URL, stopFile: URL, command: [String], seed: URL? = nil, needsAdmin: Bool) throws -> Process? {
        guard let runner = EnginePaths.runner(privileged: needsAdmin) else { throw EngineError.missingEngine }
        let args = [runner.path, String(getuid()), String(getgid()), workDir.path, stopFile.path, seed?.path ?? "-"] + command
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
    /// Asks the engine for the partitions it sees: a /cmd with only the
    /// table type stops right after partition detection.
    @MainActor
    static func partitions(target: String, command: String, needsAdmin: Bool) async throws -> [EnginePartition] {
        try EngineError.checkPrivilege(target: target, needsAdmin: needsAdmin)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ritrovo-probe-\(UUID().uuidString)")
        let ctl = try Runner.controlDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: ctl)
        }
        let json = dir.appendingPathComponent("probe.jsonl")
        let done = dir.appendingPathComponent(".done")
        _ = try Runner.launch(workDir: dir, stopFile: ctl.appendingPathComponent("stop"),
                              engineArgs: ["/logjson", "probe.jsonl", "/cmd", target, command], needsAdmin: needsAdmin)
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
            throw EngineError.failed(errors.last.map(Format.engineMessage) ?? "Impossibile leggere la sorgente.")
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
    let startedAt = Date()
    @Published private(set) var state: State = .running
    @Published private(set) var progress: ProgressEvent?
    @Published private(set) var stats: [String: Int] = [:]
    @Published private(set) var totalFiles = 0
    @Published private(set) var files: [RecoveredFile] = []
    @Published private(set) var lastMessage = ""
    @Published private(set) var stoppedByUser = false
    @Published private(set) var stopRequestedAt: Date?
    @Published private(set) var bytesPerSecond: Double = 0
    @Published private(set) var readErrors = 0
    @Published private(set) var logLines: [LogLine] = []
    @Published private(set) var partitionSize: UInt64 = 0

    struct LogLine: Identifiable, Equatable {
        let id: Int
        let level: String
        let message: String
    }

    /// Called once when the run ends (history, notification, Dock).
    var onFinish: ((RecoverySession) -> Void)?
    /// Called when the number of files changes (Dock badge).
    var onProgress: ((RecoverySession) -> Void)?

    private var tail: JSONLTail
    private var scanner: RecoveryScanner
    private var process: Process?
    private var pollTask: Task<Void, Never>?
    private var speed = SpeedMeter()
    private var sectorSize: UInt64 = 512
    private var logCounter = 0
    private var activity: NSObjectProtocol?

    private var controlDir: URL?
    var stopFile: URL { (controlDir ?? sessionDir).appendingPathComponent("stop") }
    var doneFile: URL { sessionDir.appendingPathComponent(".done") }
    var jsonFile: URL { sessionDir.appendingPathComponent(".ritrovo-progress.jsonl") }
    var sessionFile: URL { sessionDir.appendingPathComponent(".ritrovo.ses") }

    var isActive: Bool { state == .running || state == .stopping }

    init(sourceName: String, sessionDir: URL) {
        self.sourceName = sourceName
        self.sessionDir = sessionDir
        self.tail = JSONLTail(url: sessionDir.appendingPathComponent(".ritrovo-progress.jsonl"))
        self.scanner = RecoveryScanner(sessionDir: sessionDir)
    }

    func start(target: String, command: String, needsAdmin: Bool, verbose: Bool = false, resumeFrom seed: URL? = nil) throws {
        try EngineError.checkPrivilege(target: target, needsAdmin: needsAdmin)
        controlDir = try Runner.controlDir()
        // "/cmd resume" reads device and options from .ritrovo.ses; the engine
        // wants it before the other arguments (it must not be the last one).
        var args = seed == nil ? [] : ["/cmd", "resume"]
        args += ["/log", "/logname", ".ritrovo.log", "/logjson", ".ritrovo-progress.jsonl", "/d", "recup_dir"]
        if verbose { args.append("/debug") }
        // Resuming, the device is given as a plain argument too: the engine only
        // looks among the devices it knows, and an image file is not one of them.
        args += seed == nil ? ["/cmd", target, command] : [target]
        process = try Runner.launch(workDir: sessionDir, stopFile: stopFile, engineArgs: args, seed: seed, needsAdmin: needsAdmin)
        // The Mac must not go to sleep in the middle of a recovery.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Recupero dati in corso")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                if self.poll() { return }
            }
        }
    }

    /// The engine stops on SIGINT and saves .ritrovo.ses, the runner script
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
        finish()
    }

    private func finish() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        onFinish?(self)
        onFinish = nil
    }

    private func appendLog(level: String, message: String) {
        logCounter += 1
        logLines.append(LogLine(id: logCounter, level: level, message: message))
        if logLines.count > 300 { logLines.removeFirst(logLines.count - 300) }
    }

    /// Returns true when the run is over.
    private func poll() -> Bool {
        // The runner exits without .done only if it could not start.
        if let process, !process.isRunning, !FileManager.default.fileExists(atPath: doneFile.path) {
            state = .failed("Impossibile avviare il recupero (codice \(process.terminationStatus)). Controlla che la cartella di destinazione sia scrivibile.")
            finish()
            return true
        }
        let before = totalFiles
        for event in tail.readNew() {
            switch event {
            case .progress(let p):
                if p != progress {
                    speed.add(sector: p.currentSector, sectorSize: sectorSize, at: Date())
                    bytesPerSecond = speed.bytesPerSecond
                }
                progress = p
                totalFiles = p.filesFound
                if !p.stats.isEmpty { stats = p.stats }
                if p.totalSectors > 0 { partitionSize = p.totalSectors * sectorSize }
            case .completion(let total, _, let s):
                totalFiles = total
                if !s.isEmpty { stats = s }
            case .diskInfo(_, _, let size):
                sectorSize = size
            case .log(let level, let message):
                if message.contains("read err") || message.hasPrefix("Error reading") { readErrors += 1 }
                let text = Format.engineMessage(message)
                if level == "critical" || level == "error" { lastMessage = text }
                if level != "info" || message.contains("Pass ") || message.contains("reject") {
                    appendLog(level: level, message: text)
                }
            default:
                break
            }
        }
        let new = scanner.scanNew()
        if !new.isEmpty { files.insert(contentsOf: new.reversed(), at: 0) }
        if totalFiles != before { onProgress?(self) }
        if let text = try? String(contentsOf: doneFile, encoding: .utf8) {
            let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            _ = tail.readNew()
            // Files rejected at the end (too small, corrupted) are deleted by the engine.
            files = RecoveryScanner.allFiles(in: sessionDir).reversed()
            // The engine's counter restarts after some passes: trust the folder.
            totalFiles = max(totalFiles, files.count)
            state = code == 0 ? .finished(exitCode: code)
                : .failed(lastMessage.isEmpty ? "Il recupero si è interrotto (codice \(code))." : lastMessage)
            finish()
            return true
        }
        return false
    }
}

/// Byte for byte copy of a disk into an image file, through the same
/// runner as the engine. A failing disk is read once, then the recovery
/// works on the copy. dd with conv=noerror,sync goes on after read errors
/// and fills the unreadable blocks (256 KB) with zeros, keeping every offset.
@MainActor
final class CloneSession: ObservableObject {
    enum State: Equatable { case running, stopping, finished, failed(String) }

    let workDir: URL
    let sourceName: String
    let totalBytes: Int64
    let startedAt = Date()
    @Published private(set) var state: State = .running
    @Published private(set) var copiedBytes: Int64 = 0
    @Published private(set) var bytesPerSecond: Double = 0

    var imageURL: URL { workDir.appendingPathComponent("disco.img") }
    private var controlDir: URL?
    private var pollTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var lastSample: (bytes: Int64, time: Date)?

    var fraction: Double { totalBytes > 0 ? min(1, Double(copiedBytes) / Double(totalBytes)) : 0 }

    init(sourceName: String, totalBytes: Int64, workDir: URL) {
        self.sourceName = sourceName
        self.totalBytes = totalBytes
        self.workDir = workDir
    }

    func start(device: String, needsAdmin: Bool) throws {
        try EngineError.checkPrivilege(target: device, needsAdmin: needsAdmin)
        let ctl = try Runner.controlDir()
        controlDir = ctl
        _ = try Runner.launch(workDir: workDir, stopFile: ctl.appendingPathComponent("stop"),
                              command: ["/bin/dd", "if=\(device)", "of=disco.img", "bs=256k", "conv=noerror,sync"],
                              needsAdmin: needsAdmin)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Copia del disco in corso")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.poll() { return }
            }
        }
    }

    func stop() {
        guard state == .running, let controlDir else { return }
        state = .stopping
        FileManager.default.createFile(atPath: controlDir.appendingPathComponent("stop").path, contents: nil)
    }

    private func poll() -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: imageURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let now = Date()
        if let last = lastSample, now > last.time, size >= last.bytes {
            let rate = Double(size - last.bytes) / now.timeIntervalSince(last.time)
            bytesPerSecond = bytesPerSecond == 0 ? rate : 0.3 * rate + 0.7 * bytesPerSecond
        }
        lastSample = (size, now)
        copiedBytes = size
        let done = workDir.appendingPathComponent(".done")
        if let text = try? String(contentsOf: done, encoding: .utf8) {
            // Run as root: wait until the runner has given the files back.
            let owner = (try? FileManager.default.attributesOfItem(atPath: imageURL.path)[.ownerAccountID] as? NSNumber)?.uint32Value
            if let owner, owner != getuid() { return false }
            let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            // conv=sync pads the last block: cut the image to the disk size.
            if totalBytes > 0, copiedBytes > totalBytes, let handle = try? FileHandle(forWritingTo: imageURL) {
                try? handle.truncate(atOffset: UInt64(totalBytes))
                try? handle.close()
                copiedBytes = totalBytes
            }
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
            state = (code == 0 && copiedBytes > 0) ? .finished
                : .failed(state == .stopping ? "Copia interrotta: l'immagine contiene solo la parte già letta." : "dd è terminato con codice \(code).")
            return true
        }
        return false
    }
}
