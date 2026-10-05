import AppKit
import SwiftUI
import RitrovoCore

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    let source: RecoverySource
    @State private var showingFormats = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: source.symbol)
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name).font(.title2.weight(.semibold))
                        Text("\(ByteCountFormatter.string(fromByteCount: source.size, countStyle: .file)) · \(source.target)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if source.needsAdmin {
                        Label("Richiede la password di amministratore", systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Partizione") { partitionSection }

            if model.selectedPartition != nil {
                Section("Cosa cercare") {
                    LabeledContent("Tipi di file") {
                        HStack {
                            Text(formatSummary).foregroundStyle(.secondary)
                            Button("Scegli…") { showingFormats = true }
                        }
                    }
                    Picker("Dove cercare", selection: $model.options.searchSpace) {
                        Text("Tutto lo spazio").tag(SearchSpace.whole)
                        Text("Solo spazio libero").tag(SearchSpace.free)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!(model.selectedPartition?.supportsFreeSpace ?? false))
                    Text(model.options.searchSpace == .free
                         ? "Analizza solo i blocchi non usati dal file system: più veloce, trova i file cancellati."
                         : "Analizza ogni settore: necessario dopo una formattazione o con file system danneggiato.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Filtri immagini (JPG e PNG)") {
                    Picker("Filtro", selection: $model.filterPreset) {
                        ForEach(FilterPreset.allCases) { Text($0.title).tag($0) }
                    }
                    Text(model.filterPreset.detail).font(.caption).foregroundStyle(.secondary)
                    if model.filterPreset == .custom {
                        NumberRow(title: "Larghezza minima", unit: "px", value: widthBinding)
                        NumberRow(title: "Altezza minima", unit: "px", value: heightBinding)
                        NumberRow(title: "Megapixel minimi", unit: "MP", value: megapixelBinding, fractional: true)
                        NumberRow(title: "Dimensione minima", unit: "KB", value: kilobyteBinding)
                    }
                    if model.options.filters.isActive {
                        Label("Le immagini con dimensioni non leggibili dall'intestazione vengono sempre recuperate.",
                              systemImage: "checkmark.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Avanzate") {
                    Toggle("File system ext2/ext3/ext4", isOn: $model.options.ext2Mode)
                    Toggle("Ricostruzione approfondita dei JPEG frammentati (molto più lenta)", isOn: $model.options.deepJPEG)
                    Toggle("Conserva anche i file danneggiati", isOn: $model.options.keepCorrupted)
                }

                Section("Destinazione") {
                    LabeledContent("Salva in") {
                        HStack {
                            Text(model.destination?.path ?? "Nessuna cartella")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Scegli…", action: chooseDestination)
                        }
                    }
                    if model.destinationOnSource {
                        Label("La cartella è sullo stesso disco da recuperare: i file salvati potrebbero sovrascrivere quelli da ritrovare. Scegli un altro disco.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button {
                    model.startRecovery()
                } label: {
                    Label("Avvia recupero", systemImage: "play.fill").frame(minWidth: 140)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
            }
            .padding()
            .background(.bar)
        }
        .sheet(isPresented: $showingFormats) {
            FormatsSheet(enabled: $model.options.enabledFormats, catalog: model.catalog)
        }
        .onAppear { if case .idle = model.probe, !source.needsAdmin { model.runProbe() } }
    }

    @ViewBuilder private var partitionSection: some View {
        switch model.probe {
        case .idle where source.needsAdmin:
            VStack(alignment: .leading, spacing: 8) {
                Text("Per leggere un disco fisico macOS richiede la password di amministratore. Ritrovo accede al disco solo in lettura.")
                    .foregroundStyle(.secondary)
                Button("Leggi le partizioni…") { model.runProbe() }
            }
        case .idle:
            HStack {
                ProgressView().controlSize(.small)
                Text("Lettura della tabella delle partizioni…").foregroundStyle(.secondary)
            }
        case .loading(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                let seconds = Int(context.date.timeIntervalSince(since))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Lettura della tabella delle partizioni… \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Annulla") { model.cancelProbe() }
                    }
                    if seconds >= 20 {
                        Label("Il disco risponde lentamente. Succede con dischi danneggiati o già letti da un altro programma (per esempio un altro PhotoRec): può servire qualche minuto.",
                              systemImage: "tortoise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Riprova") { model.runProbe() }
            }
        case .loaded(let parts):
            Picker("Partizione", selection: Binding(get: { model.partitionOrder ?? -1 }, set: {
                model.partitionOrder = $0
                model.applyPartitionDefaults()
            })) {
                ForEach(parts) { part in
                    PartitionLabel(part: part).tag(part.order)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private var formatSummary: String {
        let n = model.options.enabledFormats.count
        let defaults = Set(model.catalog.filter(\.enabledByDefault).map(\.ext))
        if model.options.enabledFormats == defaults { return "Tutti i formati predefiniti (\(n))" }
        if n <= 4 { return model.options.enabledFormats.sorted().joined(separator: ", ") }
        return "\(n) formati"
    }

    private var widthBinding: Binding<Double> {
        Binding(get: { Double(model.options.filters.minWidth) },
                set: { model.options.filters.minWidth = UInt32(clamping: Int(max(0, $0))) })
    }
    private var heightBinding: Binding<Double> {
        Binding(get: { Double(model.options.filters.minHeight) },
                set: { model.options.filters.minHeight = UInt32(clamping: Int(max(0, $0))) })
    }
    private var megapixelBinding: Binding<Double> {
        Binding(get: { Double(model.options.filters.minPixels) / 1_000_000 },
                set: { model.options.filters.minPixels = UInt64(max(0, $0 * 1_000_000).rounded()) })
    }
    private var kilobyteBinding: Binding<Double> {
        Binding(get: { Double(model.options.filters.minBytes) / 1000 },
                set: { model.options.filters.minBytes = UInt64(max(0, $0 * 1000).rounded()) })
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Scegli"
        panel.message = "Scegli dove salvare i file recuperati, su un disco diverso da quello da analizzare."
        if panel.runModal() == .OK { model.destination = panel.url }
    }
}

struct PartitionLabel: View {
    let part: EnginePartition
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
    private var title: String {
        if part.isWholeDisk { return "Disco intero" }
        let name = part.label.isEmpty ? "Senza nome" : part.label
        return "\(part.order). \(name) — \(part.fileSystem)"
    }
    private var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: part.size), countStyle: .file)
        if part.isWholeDisk { return "\(size) · ignora le partizioni, utile se la tabella è danneggiata" }
        return part.info.isEmpty ? size : "\(size) · \(part.info)"
    }
}

struct NumberRow: View {
    let title: String
    let unit: String
    @Binding var value: Double
    var fractional = false
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: $value, format: fractional ? .number.precision(.fractionLength(0...1)) : .number.precision(.fractionLength(0)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Text(unit).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
            }
        }
    }
}

/// Format list with search, as proposed for QPhotoRec in PR #198.
struct FormatsSheet: View {
    @Binding var enabled: Set<String>
    let catalog: [FileFormat]
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [FileFormat] { catalog.filter { $0.matches(query) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tipi di file").font(.title3.weight(.semibold))
                Spacer()
                Text("\(enabled.count) di \(catalog.count) selezionati").foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top])
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Cerca per estensione o descrizione", text: $query)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)
            .padding(.top, 10)
            HStack {
                Menu("Selezione rapida") {
                    Button("Formati predefiniti") { enabled = Set(catalog.filter(\.enabledByDefault).map(\.ext)) }
                    Button("Solo foto") { enabled = present(FormatCatalog.photoExtensions) }
                    Button("Foto e video") { enabled = present(FormatCatalog.photoExtensions.union(FormatCatalog.videoExtensions)) }
                    Divider()
                    Button("Tutti") { enabled = Set(catalog.map(\.ext)) }
                    Button("Nessuno") { enabled = [] }
                }
                .fixedSize()
                Spacer()
                if !query.isEmpty {
                    Button("Seleziona i \(filtered.count) trovati") { enabled.formUnion(filtered.map(\.ext)) }
                    Button("Deseleziona") { enabled.subtract(filtered.map(\.ext)) }
                }
            }
            .padding()
            List(filtered) { format in
                Toggle(isOn: Binding(get: { enabled.contains(format.ext) },
                                     set: { if $0 { enabled.insert(format.ext) } else { enabled.remove(format.ext) } })) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(format.ext).font(.body.monospaced()).frame(width: 64, alignment: .leading)
                        Text(format.description).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .overlay {
                if filtered.isEmpty { Text("Nessun formato corrisponde a “\(query)”").foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button("Fine") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 600)
    }

    private func present(_ set: Set<String>) -> Set<String> {
        Set(catalog.map(\.ext)).intersection(set)
    }
}
