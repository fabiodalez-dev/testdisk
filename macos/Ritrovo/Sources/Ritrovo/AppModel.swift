import AppKit
import Foundation
import RitrovoCore

enum FilterPreset: String, CaseIterable, Identifiable {
    case none, noThumbnails, photos1MP, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Nessun filtro"
        case .noThumbnails: return "Niente miniature"
        case .photos1MP: return "Solo foto vere"
        case .custom: return "Personalizzato"
        }
    }
    var detail: String {
        switch self {
        case .none: return "Recupera tutte le immagini, anche le più piccole."
        case .noThumbnails: return "Scarta le immagini sotto 300 × 300 pixel: icone e anteprime."
        case .photos1MP: return "Solo immagini da almeno 1 megapixel e 100 KB."
        case .custom: return "Imposta tu i valori minimi."
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

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum ProbeState: Equatable {
        case idle, loading, loaded([EnginePartition]), failed(String)
    }

    @Published var disks: [RecoverySource] = []
    @Published var images: [RecoverySource] = []
    @Published var selection: RecoverySource.ID?
    @Published var probe: ProbeState = .idle
    @Published var partitionOrder: Int?
    @Published var options: RecoveryOptions
    @Published var filterPreset: FilterPreset = .none {
        didSet { if let f = filterPreset.filters { options.filters = f } }
    }
    @Published var destination: URL? { didSet { checkDestination() } }
    @Published private(set) var destinationOnSource = false
    @Published var session: RecoverySession?
    @Published var alert: String?
    @Published var loadingDisks = false

    let catalog: [FileFormat]

    init() {
        let catalog = (EnginePaths.formats.flatMap { try? FormatCatalog.load(from: $0) }) ?? []
        self.catalog = catalog
        self.options = RecoveryOptions(enabledFormats: Set(catalog.filter(\.enabledByDefault).map(\.ext)))
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        self.destination = downloads
    }

    var selectedSource: RecoverySource? {
        (disks + images).first { $0.id == selection }
    }

    var selectedPartition: EnginePartition? {
        guard case .loaded(let parts) = probe else { return nil }
        return parts.first { $0.order == partitionOrder }
    }

    func refreshDisks() {
        loadingDisks = true
        Task.detached {
            let disks = DiskService.physicalDisks()
            await MainActor.run {
                self.disks = disks
                self.loadingDisks = false
            }
        }
    }

    func addImage(_ url: URL) {
        let source = RecoverySource.image(url)
        if !images.contains(source) { images.append(source) }
        select(source.id)
    }

    func select(_ id: RecoverySource.ID?) {
        selection = id
        probe = .idle
        partitionOrder = nil
        checkDestination()
    }

    func runProbe() {
        guard let source = selectedSource else { return }
        probe = .loading
        Task {
            do {
                let parts = try await Probe.partitions(target: source.target, needsAdmin: source.needsAdmin)
                guard source.id == selection else { return }
                probe = .loaded(parts)
                // Prefer the first real partition, like PhotoRec's CLI does.
                let chosen = parts.first { !$0.isWholeDisk } ?? parts.first
                partitionOrder = chosen?.order
                applyPartitionDefaults()
            } catch {
                guard source.id == selection else { return }
                probe = .failed(error.localizedDescription)
            }
        }
    }

    func applyPartitionDefaults() {
        guard let part = selectedPartition else { return }
        options.ext2Mode = part.isExtFamily
        if !part.supportsFreeSpace { options.searchSpace = .whole }
    }

    /// Saving on the disk being recovered could overwrite the lost files.
    func checkDestination() {
        guard let dest = destination, let disk = selectedSource?.diskIdentifier else {
            destinationOnSource = false
            return
        }
        Task.detached {
            let same = DiskService.physicalDisk(of: dest) == disk
            await MainActor.run { self.destinationOnSource = same }
        }
    }

    var canStart: Bool {
        selectedPartition != nil && destination != nil && !options.enabledFormats.isEmpty && !destinationOnSource
    }

    func startRecovery() {
        guard let source = selectedSource, let part = selectedPartition, let dest = destination else { return }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
            .replacingOccurrences(of: ":", with: ".")
        let dir = dest.appendingPathComponent("Ritrovo \(source.name) \(stamp)")
        let command = CommandBuilder.command(partitionOrder: part.order, options: options, catalog: catalog)
        let session = RecoverySession(sourceName: source.name, sessionDir: dir)
        do {
            try session.start(target: source.target, command: command, needsAdmin: source.needsAdmin)
            self.session = session
        } catch {
            alert = error.localizedDescription
        }
    }

    func closeSession() {
        session = nil
    }
}
