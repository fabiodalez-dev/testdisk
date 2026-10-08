import AppKit
import Foundation
import RitrovoCore
import UniformTypeIdentifiers
import UserNotifications

enum FilterPreset: String, CaseIterable, Identifiable, Codable {
    case none, noThumbnails, photos1MP, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Tutte le immagini"
        case .noThumbnails: return "Niente miniature"
        case .photos1MP: return "Solo foto vere"
        case .custom: return "Personalizzato"
        }
    }
    var symbol: String {
        switch self {
        case .none: return "square.grid.3x3"
        case .noThumbnails: return "rectangle.badge.minus"
        case .photos1MP: return "camera.fill"
        case .custom: return "slider.horizontal.3"
        }
    }
    var detail: String {
        switch self {
        case .none: return "Anche icone, anteprime e immagini dei siti web."
        case .noThumbnails: return "Scarta le immagini sotto i 300 × 300 pixel."
        case .photos1MP: return "Solo immagini da almeno 1 megapixel e 100 KB: le foto vere."
        case .custom: return "Larghezza, altezza, megapixel e peso minimi a scelta."
        }
    }
    var filters: ImageFilters? {
        switch self {
        case .none: return ImageFilters()
        case .noThumbnails: return ImageFilters(minWidth: 300, minHeight: 300)
        case .photos1MP: return ImageFilters(minPixels: 1_000_000, minBytes: 100_000)
        case .custom: return nil
        }
    }
}

/// What the main area shows.
enum SidebarItem: Hashable {
    case source(String)
    case history(String)
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum ProbeState: Equatable {
        case idle, loading(since: Date), loaded([EnginePartition]), failed(String)
    }

    @Published var disks: [RecoverySource] = []
    @Published var images: [RecoverySource] = []
    @Published var selection: SidebarItem?
    @Published var probe: ProbeState = .idle
    @Published var partitionOrder: Int?
    @Published var options: RecoveryOptions { didSet { save() } }
    @Published var filterPreset: FilterPreset = .none {
        didSet {
            if let f = filterPreset.filters { options.filters = f }
            save()
        }
    }
    @Published var destination: URL? {
        didSet {
            checkDestination()
            save()
        }
    }
    @Published private(set) var destinationOnSource = false
    @Published private(set) var destinationFree: Int64?
    @Published var session: RecoverySession?
    @Published var clone: CloneSession?
    @Published var history: [HistoryEntry] = []
    @Published var alert: String?
    @Published var loadingDisks = false
    @Published var showingFormats = false
    private var probeTask: Task<Void, Never>?
    private var watcher: DiskWatcher?
    private var loading = true

    let catalog: [FileFormat]
    private let defaults = UserDefaults.standard

    init() {
        let catalog = (EnginePaths.formats.flatMap { try? FormatCatalog.load(from: $0) }) ?? []
        self.catalog = catalog
        let defaultFormats = Set(catalog.filter(\.enabledByDefault).map(\.ext))
        var opts = RecoveryOptions(enabledFormats: defaultFormats)
        if let data = defaults.data(forKey: "options"), let saved = try? JSONDecoder().decode(RecoveryOptions.self, from: data) {
            opts = saved
            // Formats unknown to this build are dropped.
            opts.enabledFormats.formIntersection(Set(catalog.map(\.ext)))
            if opts.enabledFormats.isEmpty { opts.enabledFormats = defaultFormats }
        }
        options = opts
        if let raw = defaults.string(forKey: "filterPreset"), let p = FilterPreset(rawValue: raw) { filterPreset = p }
        if let path = defaults.string(forKey: "destination"), FileManager.default.fileExists(atPath: path) {
            destination = URL(fileURLWithPath: path)
        } else {
            destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }
        if let data = defaults.data(forKey: "history"), let h = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = h.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        loading = false
        checkDestination()
        watcher = DiskWatcher { [weak self] in
            Task { @MainActor in self?.refreshDisks() }
        }
    }

    private func save() {
        guard !loading else { return }
        if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: "options") }
        defaults.set(filterPreset.rawValue, forKey: "filterPreset")
        defaults.set(destination?.path, forKey: "destination")
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: "history") }
    }

    // MARK: Selection

    var selectedSource: RecoverySource? {
        guard case .source(let id) = selection else { return nil }
        return (disks + images).first { $0.id == id }
    }

    var selectedHistory: HistoryEntry? {
        guard case .history(let path) = selection else { return nil }
        return history.first { $0.path == path }
    }

    var selectedPartition: EnginePartition? {
        guard case .loaded(let parts) = probe else { return nil }
        return parts.first { $0.order == partitionOrder }
    }

    var isBusy: Bool { (session?.isActive ?? false) || clone?.state == .running || clone?.state == .stopping }

    func select(_ item: SidebarItem?) {
        guard item != selection else { return }
        probeTask?.cancel()
        probeTask = nil
        selection = item
        probe = .idle
        partitionOrder = nil
        checkDestination()
    }

    // MARK: Sources

    func refreshDisks() {
        loadingDisks = true
        Task.detached {
            let disks = DiskService.physicalDisks()
            await MainActor.run {
                self.disks = disks
                self.loadingDisks = false
                if case .source(let id) = self.selection, id.hasPrefix("disk:"), !disks.contains(where: { $0.id == id }), !self.isBusy {
                    self.select(nil)
                }
            }
        }
    }

    func addImage(_ url: URL) {
        let source = RecoverySource.image(url)
        if !images.contains(source) { images.append(source) }
        session = nil
        clone = nil
        select(.source(source.id))
    }

    func openImagePanel() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Scegli un'immagine disco (.img, .dd, .dmg, .iso, .raw)"
        panel.prompt = "Apri"
        if panel.runModal() == .OK, let url = panel.url { addImage(url) }
    }

    func eject(_ source: RecoverySource) {
        guard let ident = source.diskIdentifier else { return }
        Task.detached {
            let error = DiskService.eject(ident)
            await MainActor.run {
                if let error { self.alert = "Impossibile espellere \(source.name): \(error)" }
                self.refreshDisks()
            }
        }
    }

    // MARK: Partitions

    func runProbe() {
        guard let source = selectedSource else { return }
        probeTask?.cancel()
        probe = .loading(since: Date())
        let wanted = selection
        probeTask = Task {
            do {
                let parts = try await Probe.partitions(target: source.target, command: CommandBuilder.probeCommand(options: options),
                                                       needsAdmin: source.needsAdmin)
                guard wanted == selection else { return }
                probe = .loaded(parts)
                // Prefer the first real partition, like the engine's batch mode.
                let chosen = parts.first { !$0.isWholeDisk } ?? parts.first
                partitionOrder = chosen?.order
                applyPartitionDefaults()
            } catch is CancellationError {
                return
            } catch {
                guard wanted == selection else { return }
                probe = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops the partition reading (the engine gets SIGINT).
    func cancelProbe() {
        probeTask?.cancel()
        probeTask = nil
        probe = .idle
    }

    func applyPartitionDefaults() {
        guard let part = selectedPartition else { return }
        options.ext2Mode = part.isExtFamily
        if !part.supportsFreeSpace { options.searchSpace = .whole }
        if !part.isFAT { options.unformatFAT = false }
    }

    /// The partition list depends on the table type: read it again.
    func setPartitionTable(_ table: PartitionTable) {
        guard table != options.partitionTable else { return }
        options.partitionTable = table
        if selectedSource != nil, case .loaded = probe { runProbe() }
    }

    // MARK: Formats by category

    enum CategoryState { case all, some, none }

    func formats(in category: FileCategory) -> [FileFormat] { catalog.filter { $0.category == category } }

    func state(of category: FileCategory) -> CategoryState {
        let exts = formats(in: category).map(\.ext)
        let on = exts.filter { options.enabledFormats.contains($0) }.count
        return on == 0 ? .none : (on == exts.count ? .all : .some)
    }

    func toggle(_ category: FileCategory) {
        let exts = Set(formats(in: category).map(\.ext))
        if state(of: category) == .all {
            options.enabledFormats.subtract(exts)
        } else {
            options.enabledFormats.formUnion(exts)
        }
    }

    // MARK: Destination

    /// Saving on the disk being recovered could overwrite the lost files.
    func checkDestination() {
        guard let dest = destination else {
            destinationOnSource = false
            destinationFree = nil
            return
        }
        let disk = selectedSource?.diskIdentifier
        Task.detached {
            let same = disk != nil && DiskService.physicalDisk(of: dest) == disk
            let free = DiskService.freeSpace(at: dest)
            await MainActor.run {
                self.destinationOnSource = same
                self.destinationFree = free
            }
        }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Scegli"
        panel.message = "Scegli dove salvare i file, su un disco diverso da quello da analizzare."
        if panel.runModal() == .OK { destination = panel.url }
    }

    /// Below 1 GB a recovery fills the disk in minutes.
    var destinationTooFull: Bool { (destinationFree ?? .max) < 1_000_000_000 }

    var canStart: Bool {
        selectedPartition != nil && destination != nil && !options.enabledFormats.isEmpty
            && !destinationOnSource && !destinationTooFull && !isBusy
    }

    private func sessionFolder(_ prefix: String, _ name: String) -> URL? {
        guard let dest = destination else { return nil }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
            .replacingOccurrences(of: ":", with: ".")
        let safe = name.replacingOccurrences(of: "/", with: "-")
        return dest.appendingPathComponent("\(prefix) \(safe) \(stamp)")
    }

    // MARK: Recovery

    func startRecovery() {
        guard canStart, let source = selectedSource, let part = selectedPartition,
              let dir = sessionFolder("Ritrovo", source.name) else { return }
        let command = CommandBuilder.command(partitionOrder: part.order, options: options, catalog: catalog)
        let session = RecoverySession(sourceName: source.name, sessionDir: dir)
        session.onProgress = { s in Dock.badge(s.totalFiles) }
        session.onFinish = { [weak self] s in self?.recoveryFinished(s) }
        do {
            try session.start(target: source.target, command: command, needsAdmin: source.needsAdmin, verbose: options.verboseLog)
            self.session = session
            record(session, completed: false)
            Notifier.requestPermission()
        } catch {
            alert = error.localizedDescription
        }
    }

    /// A stopped recovery keeps .ritrovo.ses: continue it in a new folder.
    func canResume(_ entry: HistoryEntry) -> Bool {
        !entry.completed && FileManager.default.fileExists(atPath: URL(fileURLWithPath: entry.path).appendingPathComponent(".ritrovo.ses").path)
    }

    func resume(_ entry: HistoryEntry) {
        guard !isBusy, canResume(entry) else { return }
        let saved = URL(fileURLWithPath: entry.path).appendingPathComponent(".ritrovo.ses")
        guard var text = try? String(contentsOf: saved, encoding: .utf8) else { return }
        // Second line of the session file: "<device> <commands>". The engine
        // ends it with "inter" (back to its text menus once done): without a
        // terminal that would never end, so the copy given to it drops it.
        var lines = text.components(separatedBy: "\n")
        guard lines.count > 1 else { return }
        if lines[1].hasSuffix(",inter") { lines[1].removeLast(",inter".count) }
        text = lines.joined(separator: "\n")
        let device = lines[1].split(separator: " ").first.map(String.init) ?? ""
        guard let ctl = try? Runner.controlDir() else { return }
        let seed = ctl.appendingPathComponent("resume.ses")
        do { try text.write(to: seed, atomically: true, encoding: .utf8) } catch { alert = error.localizedDescription; return }
        guard let dir = sessionFolder("Ritrovo", entry.sourceName + " (ripresa)") else { return }
        let session = RecoverySession(sourceName: entry.sourceName, sessionDir: dir)
        session.onProgress = { s in Dock.badge(s.totalFiles) }
        session.onFinish = { [weak self] s in self?.recoveryFinished(s) }
        do {
            try session.start(target: device, command: "", needsAdmin: !FileManager.default.isReadableFile(atPath: device),
                              verbose: options.verboseLog, resumeFrom: seed)
            self.session = session
            record(session, completed: false)
        } catch {
            alert = error.localizedDescription
        }
    }

    func stopActive() {
        session?.stop()
        clone?.stop()
    }

    private func record(_ s: RecoverySession, completed: Bool) {
        history = HistoryEntry.upsert(HistoryEntry(path: s.sessionDir.path, sourceName: s.sourceName, date: s.startedAt,
                                                   totalFiles: s.totalFiles, completed: completed), into: history)
        saveHistory()
    }

    private func recoveryFinished(_ s: RecoverySession) {
        let completed: Bool
        if case .finished = s.state { completed = !s.stoppedByUser } else { completed = false }
        record(s, completed: completed)
        Dock.badge(0)
        Dock.bounce()
        Notifier.post(title: completed ? "Recupero completato" : "Recupero interrotto",
                      body: "\(s.sourceName): \(s.totalFiles) file trovati.")
    }

    func closeSession() {
        session = nil
        Dock.badge(0)
    }

    func forget(_ entry: HistoryEntry) {
        history.removeAll { $0.path == entry.path }
        saveHistory()
        if selection == .history(entry.path) { select(nil) }
    }

    // MARK: Disk image

    func startClone() {
        guard !isBusy, let source = selectedSource, let dir = sessionFolder("Immagine", source.name) else { return }
        let free = destinationFree ?? 0
        if free < source.size {
            alert = "Spazio insufficiente: l'immagine di \(source.name) occupa \(Format.bytes(source.size)), sulla destinazione restano \(Format.bytes(free))."
            return
        }
        let clone = CloneSession(sourceName: source.name, totalBytes: source.size, workDir: dir)
        do {
            try clone.start(device: source.target, needsAdmin: source.needsAdmin)
            self.clone = clone
        } catch {
            alert = error.localizedDescription
        }
    }

    func closeClone(openImage: Bool) {
        if openImage, let clone, clone.state == .finished { addImage(clone.imageURL) }
        clone = nil
    }
}

enum Dock {
    static func badge(_ n: Int) {
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    static func bounce() {
        NSApp.requestUserAttention(.informationalRequest)
    }
}

enum Notifier {
    /// The notification center needs a real app bundle (not `swift run`).
    private static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        NSSound(named: "Glass")?.play()
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
