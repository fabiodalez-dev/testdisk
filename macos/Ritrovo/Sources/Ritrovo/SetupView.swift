import AppKit
import SwiftUI
import RitrovoCore

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    let source: RecoverySource
    @State private var showAdvanced = SelfTest.outDir != nil
    @State private var customBlock = false

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                section("Partizione", trailing: partitionTrailing) { partitionContent }
                if model.selectedPartition != nil {
                    section("Cosa recuperare", trailing: "\(model.options.enabledFormats.count) formati su \(model.catalog.count)") { categories }
                    section("Dove cercare") { searchSpace }
                    section("Filtro immagini") { filters }
                    section("Destinazione") { destination }
                    advanced.id("advanced")
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 30)
            .padding(.bottom, 40)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ritrovoShowAdvanced)) { _ in
            showAdvanced = true
            proxy.scrollTo("advanced", anchor: .top)
        }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $model.showingFormats) {
            FormatsSheet(enabled: $model.options.enabledFormats, catalog: model.catalog)
        }
        .onAppear {
            if case .idle = model.probe, !source.needsAdmin { model.runProbe() }
            customBlock = model.options.blockSize > 0 && !Self.blockSizes.contains(model.options.blockSize)
        }
        .navigationTitle(source.name)
    }

    private func section<C: View>(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: title, trailing: trailing)
            content()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: source.symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.ink2)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 5) {
                Text(source.name).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text("\(Format.bytes(source.size)) · \(kindText) · \(source.target)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label("Solo lettura: la sorgente non viene mai modificata", systemImage: "lock")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ok)
            }
            Spacer()
            if canClone {
                Button("Copia in un'immagine…") { model.startClone() }
                    .help("Legge il disco una volta sola e lo salva in un file .img da cui recuperare. Consigliato per dischi lenti o danneggiati.")
                    .disabled(model.isBusy)
            }
        }
    }

    private var canClone: Bool {
        if case .disk = source.kind { return true }
        return ProcessInfo.processInfo.environment["RITROVO_ALLOW_IMAGE_CLONE"] == "1"
    }

    private var kindText: String {
        switch source.kind {
        case .disk(let isInternal): return isInternal ? "disco interno" : "disco esterno"
        case .image: return "immagine disco"
        }
    }

    // MARK: Partition

    private var partitionTrailing: String? {
        if case .loaded(let parts) = model.probe { return parts.count == 1 ? "1 elemento" : "\(parts.count) elementi" }
        return nil
    }

    @ViewBuilder private var partitionContent: some View {
        switch model.probe {
        case .idle where source.needsAdmin:
            Panel(padding: 16) {
                HStack(spacing: 14) {
                    Text("Per leggere un disco fisico macOS chiede la password di amministratore. L'accesso resta in sola lettura.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Leggi le partizioni") { model.runProbe() }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
        case .idle:
            ProgressTrack(fraction: 0, indeterminate: true).frame(maxWidth: 240)
        case .loading(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                let seconds = Int(context.date.timeIntervalSince(since))
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        ProgressTrack(fraction: 0, indeterminate: true).frame(width: 160)
                        Text("Lettura della tabella delle partizioni  \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.ink2)
                        Spacer()
                        Button("Annulla") { model.cancelProbe() }
                    }
                    if seconds >= 20 {
                        Notice(kind: .warning, text: "Il disco risponde lentamente",
                               detail: "Succede con dischi danneggiati o già letti da un altro programma. Può servire qualche minuto.")
                    }
                }
            }
        case .failed(let message):
            HStack(alignment: .top) {
                Notice(kind: .danger, text: "Impossibile leggere le partizioni", detail: message)
                Button("Riprova") { model.runProbe() }
            }
        case .loaded(let parts):
            Panel {
                VStack(spacing: 0) {
                    ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                        if index > 0 { Hairline() }
                        ChoiceRow(title: partitionTitle(part), subtitle: partitionSubtitle(part),
                                  symbol: part.isWholeDisk ? "internaldrive" : "square.split.2x1",
                                  selected: model.partitionOrder == part.order) {
                            model.partitionOrder = part.order
                            model.applyPartitionDefaults()
                        } trailing: {
                            Text(Format.bytes(part.size))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Theme.ink2)
                        }
                    }
                }
            }
        }
    }

    private func partitionTitle(_ part: EnginePartition) -> String {
        if part.isWholeDisk { return "Disco intero" }
        let name = part.label.isEmpty ? "Partizione \(part.order)" : part.label
        return part.fileSystem.isEmpty ? name : "\(name)  ·  \(part.fileSystem)"
    }

    private func partitionSubtitle(_ part: EnginePartition) -> String {
        if part.isWholeDisk { return "Ignora le partizioni: utile se la tabella è danneggiata o dopo una riformattazione." }
        return part.info.isEmpty ? "Partizione \(part.order)" : part.info
    }

    // MARK: What

    private var categories: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      alignment: .leading, spacing: 10) {
                ForEach(FileCategory.allCases) { cat in
                    CategoryToggle(category: cat, state: model.state(of: cat), formats: model.formats(in: cat).count) {
                        model.toggle(cat)
                    }
                }
            }
            Button { model.showingFormats = true } label: {
                Text("Scegli i singoli formati…").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
    }

    // MARK: Where

    private var searchSpace: some View {
        let freeOK = model.selectedPartition?.supportsFreeSpace ?? false
        return Panel {
            VStack(spacing: 0) {
                ChoiceRow(title: "Tutto lo spazio", subtitle: "Analizza ogni settore. Necessario dopo una formattazione o con un file system danneggiato.",
                          selected: model.options.searchSpace == .whole) { model.options.searchSpace = .whole }
                Hairline()
                ChoiceRow(title: "Solo lo spazio libero",
                          subtitle: freeOK ? "Solo i blocchi non usati dal file system: più veloce, trova i file cancellati."
                                           : "Disponibile su partizioni FAT, exFAT, NTFS ed ext2/3/4 riconosciute.",
                          selected: model.options.searchSpace == .free, enabled: freeOK) { model.options.searchSpace = .free }
            }
        }
    }

    // MARK: Filters

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Panel {
                VStack(spacing: 0) {
                    ForEach(Array(FilterPreset.allCases.enumerated()), id: \.element.id) { index, preset in
                        if index > 0 { Hairline() }
                        ChoiceRow(title: preset.title, subtitle: preset.detail, selected: model.filterPreset == preset) {
                            model.filterPreset = preset
                        }
                    }
                }
            }
            if model.filterPreset == .custom {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        NumberField(title: "Larghezza minima", unit: "px", value: binding(\.filters.minWidth))
                        NumberField(title: "Altezza minima", unit: "px", value: binding(\.filters.minHeight))
                    }
                    GridRow {
                        NumberField(title: "Megapixel minimi", unit: "MP", value: megapixelBinding, fractional: true)
                        NumberField(title: "Dimensione minima", unit: "KB", value: kilobyteBinding)
                    }
                }
                .padding(.leading, 2)
            }
            Text("Dimensioni lette da JPG, PNG, GIF, BMP, ICO, WebP, PSD e PCX; per RAW e TIFF vale la dimensione del file. Un'immagine con dimensioni illeggibili viene sempre recuperata.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Destination

    private var destination: some View {
        VStack(alignment: .leading, spacing: 8) {
            Panel(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 16)).foregroundStyle(Theme.ink2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.destination?.lastPathComponent ?? "Nessuna cartella").font(.system(size: 13, weight: .medium))
                        Text(model.destination?.path ?? "").font(.system(size: 11)).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if let free = model.destinationFree {
                        Text("\(Format.bytes(free)) liberi")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(model.destinationTooFull ? Theme.bad : Theme.ink2)
                    }
                    Button("Cambia…", action: model.chooseDestination)
                }
            }
            if model.destinationOnSource {
                Notice(kind: .danger, text: "La cartella è sul disco da recuperare",
                       detail: "I file salvati sovrascriverebbero quelli da ritrovare. Scegli una cartella su un altro disco.")
            } else if model.destinationTooFull {
                Notice(kind: .danger, text: "Meno di 1 GB libero", detail: "La destinazione si riempirebbe in pochi minuti.")
            }
        }
    }

    // MARK: Advanced: every other engine option

    static let blockSizes: [UInt32] = [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]

    private var advanced: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 22) {
                option("Verifica dei file") {
                    Picker("", selection: $model.options.validation) {
                        Text("Normale").tag(Validation.standard)
                        Text("Disattivata").tag(Validation.off)
                        Text("Approfondita").tag(Validation.bruteForce)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 330)
                } hint: {
                    switch model.options.validation {
                    case .standard: return "Controlla ogni file e scarta quelli non validi."
                    case .off: return "Tiene tutto quello che trova, anche file incompleti. Più veloce, più file da sfogliare."
                    case .bruteForce: return "Prova anche a ricostruire i JPEG frammentati. Molto più lenta."
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Conserva i file danneggiati", isOn: $model.options.keepCorrupted)
                    Toggle("Modalità a memoria ridotta, per dischi molto grandi o frammentati", isOn: $model.options.lowMemory)
                    Toggle("Registro dettagliato", isOn: $model.options.verboseLog)
                }
                .toggleStyle(.checkbox)

                option("File system Linux") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Partizione ext2, ext3 o ext4", isOn: $model.options.ext2Mode).toggleStyle(.checkbox)
                        if model.options.ext2Mode {
                            HStack(spacing: 20) {
                                NumberField(title: "Inizia dal gruppo", unit: "", value: binding(\.ext2Group))
                                NumberField(title: "oppure dall'inode", unit: "", value: binding(\.ext2Inode))
                            }
                        }
                    }
                } hint: { "Gruppo o inode di partenza: 0 analizza tutto." }

                option("Partizione FAT formattata") {
                    Toggle("Ricostruisci prima la FAT formattata", isOn: $model.options.unformatFAT)
                        .toggleStyle(.checkbox)
                        .disabled(!(model.selectedPartition?.isFAT ?? false))
                } hint: { "Dopo una formattazione rapida ritrova anche nomi e cartelle. Solo per partizioni FAT." }

                option("Dimensione del blocco") {
                    HStack(spacing: 10) {
                        Picker("", selection: Binding(
                            get: { customBlock ? UInt32.max : model.options.blockSize },
                            set: { v in
                                customBlock = (v == .max)
                                if v != .max { model.options.blockSize = v }
                            })) {
                            Text("Automatica").tag(UInt32(0))
                            ForEach(Self.blockSizes, id: \.self) { Text(Format.bytes(Int64($0))).tag($0) }
                            Text("Personalizzata").tag(UInt32.max)
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        if customBlock { NumberField(title: "Byte", unit: "", value: binding(\.blockSize)) }
                    }
                } hint: { "Automatica di solito è giusta. Va impostata solo se si conosce il cluster del file system." }

                option("Tabella delle partizioni") {
                    Picker("", selection: Binding(get: { model.options.partitionTable }, set: { model.setPartitionTable($0) })) {
                        Text("Rilevata automaticamente").tag(PartitionTable.auto)
                        Divider()
                        Text("Intel / MBR").tag(PartitionTable.intel)
                        Text("EFI GPT").tag(PartitionTable.gpt)
                        Text("Apple").tag(PartitionTable.mac)
                        Text("Nessuna").tag(PartitionTable.none)
                        Text("Sun").tag(PartitionTable.sun)
                        Text("Xbox").tag(PartitionTable.xbox)
                        Text("Humax").tag(PartitionTable.humax)
                    }
                    .labelsHidden()
                    .frame(width: 230)
                } hint: { "Cambiandola, l'elenco delle partizioni viene riletto." }

                option("Geometria del disco") {
                    HStack(spacing: 16) {
                        NumberField(title: "Cilindri", unit: "", value: binding(\.geometry.cylinders), labelWidth: 60)
                        NumberField(title: "Testine", unit: "", value: binding(\.geometry.heads), labelWidth: 56)
                        NumberField(title: "Settori", unit: "", value: binding(\.geometry.sectors), labelWidth: 50)
                        NumberField(title: "Byte/settore", unit: "", value: binding(\.geometry.sectorSize), labelWidth: 80)
                    }
                } hint: { "Solo per dischi molto vecchi o immagini senza informazioni. 0 lascia il valore rilevato." }
            }
            .padding(.top, 14)
        } label: {
            SectionLabel(text: "Opzioni avanzate")
        }
    }

    private func option<C: View>(_ title: String, @ViewBuilder control: () -> C, hint: () -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
            control()
            Text(hint()).font(.system(size: 11)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
            Spacer()
            Button(action: model.startRecovery) {
                Text("Avvia il recupero")
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.canStart)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Theme.panel)
        .overlay(alignment: .top) { Hairline() }
    }

    private var summary: String {
        guard let part = model.selectedPartition else { return "Scegli una partizione per continuare." }
        let name = part.isWholeDisk ? "Disco intero" : (part.label.isEmpty ? "Partizione \(part.order)" : part.label)
        let states = FileCategory.allCases.map { ($0, model.state(of: $0)) }
        let what: String
        if model.options.enabledFormats.count == model.catalog.count {
            what = "tutti i formati"
        } else if states.allSatisfy({ $0.1 == .none }) {
            what = "nessun formato"
        } else {
            what = states.filter { $0.1 != .none }.map { $0.0.title.lowercased() + ($0.1 == .some ? " (in parte)" : "") }.joined(separator: ", ")
        }
        return "\(name) · \(what) · \(model.filterPreset.title.lowercased())"
    }

    // MARK: Bindings

    private func binding<T: BinaryInteger>(_ path: WritableKeyPath<RecoveryOptions, T>) -> Binding<Double> {
        Binding(get: { Double(model.options[keyPath: path]) },
                set: { model.options[keyPath: path] = T(clamping: Int64(max(0, min($0, 9_000_000_000_000)))) })
    }
    private var megapixelBinding: Binding<Double> {
        Binding(get: { Double(model.options.filters.minPixels) / 1_000_000 },
                set: { model.options.filters.minPixels = UInt64(max(0, $0 * 1_000_000).rounded()) })
    }
    private var kilobyteBinding: Binding<Double> {
        Binding(get: { Double(model.options.filters.minBytes) / 1000 },
                set: { model.options.filters.minBytes = UInt64(max(0, $0 * 1000).rounded()) })
    }
}

/// Category checkbox with a mixed state.
struct CategoryToggle: View {
    let category: FileCategory
    let state: AppModel.CategoryState
    let formats: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(state == .none ? Color.clear : Theme.accent)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(state == .none ? Theme.ink3 : Theme.accent, lineWidth: 1.2))
                        .frame(width: 15, height: 15)
                    if state != .none {
                        Image(systemName: state == .all ? "checkmark" : "minus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                    }
                }
                Image(systemName: category.outline).font(.system(size: 13)).foregroundStyle(Theme.ink2).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(state == .some ? "alcuni formati" : "\(formats) formati").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(state == .none ? Theme.hairline : Theme.accent.opacity(0.55)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(category.title), \(state == .all ? "tutti" : state == .some ? "alcuni" : "nessuno")")
        .animation(.easeOut(duration: 0.15), value: state == .none)
    }
}

struct NumberField: View {
    let title: String
    let unit: String
    @Binding var value: Double
    var fractional = false
    var labelWidth: CGFloat = 120

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.ink2).frame(width: labelWidth, alignment: .leading)
            TextField(title, value: $value, format: fractional ? .number.precision(.fractionLength(0...1)) : .number.precision(.fractionLength(0)).grouping(.never))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 76)
            if !unit.isEmpty { Text(unit).font(.system(size: 12)).foregroundStyle(Theme.ink3) }
        }
    }
}

/// Every format, grouped by category, with search.
struct FormatsSheet: View {
    @Binding var enabled: Set<String>
    let catalog: [FileFormat]
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [FileFormat] { catalog.filter { $0.matches(query) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Formati da recuperare").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Text("\(enabled.count) di \(catalog.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.ink2)
                }
                HStack(spacing: 10) {
                    TextField("Cerca per estensione o descrizione", text: $query)
                        .textFieldStyle(.roundedBorder)
                    Menu("Selezione rapida") {
                        Button("Formati predefiniti") { enabled = Set(catalog.filter(\.enabledByDefault).map(\.ext)) }
                        Button("Solo foto") { enabled = set(of: [.photo]) }
                        Button("Foto e video") { enabled = set(of: [.photo, .video]) }
                        Button("Documenti") { enabled = set(of: [.document]) }
                        Divider()
                        Button("Tutti") { enabled = Set(catalog.map(\.ext)) }
                        Button("Nessuno") { enabled = [] }
                    }
                    .fixedSize()
                }
            }
            .padding(18)
            Hairline()
            List {
                ForEach(FileCategory.allCases) { cat in
                    let items = filtered.filter { $0.category == cat }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { format in
                                Toggle(isOn: Binding(get: { enabled.contains(format.ext) },
                                                     set: { if $0 { enabled.insert(format.ext) } else { enabled.remove(format.ext) } })) {
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text(format.ext).font(.system(size: 12, design: .monospaced)).frame(width: 64, alignment: .leading)
                                        Text(format.description).font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(2)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        } header: {
                            HStack {
                                Label(cat.title, systemImage: cat.outline)
                                Spacer()
                                Button("Tutti") { enabled.formUnion(items.map(\.ext)) }.buttonStyle(.link)
                                Button("Nessuno") { enabled.subtract(items.map(\.ext)) }.buttonStyle(.link)
                            }
                            .font(.system(size: 11, weight: .semibold))
                        }
                    }
                }
            }
            .overlay {
                if filtered.isEmpty {
                    Text("Nessun formato corrisponde a “\(query)”.").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                }
            }
            Hairline()
            HStack {
                Text("I file vengono riconosciuti dal contenuto: un formato in più non rallenta il recupero.")
                    .font(.system(size: 11)).foregroundStyle(Theme.ink3)
                Spacer()
                Button("Fine") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: 640)
        .background(Theme.canvas)
    }

    private func set(of cats: Set<FileCategory>) -> Set<String> {
        Set(catalog.filter { cats.contains($0.category) }.map(\.ext))
    }
}

extension Notification.Name {
    /// Scrolls the settings to the advanced options (self test snapshots).
    static let ritrovoShowAdvanced = Notification.Name("ritrovoShowAdvanced")
}
