import SwiftUI
import UniformTypeIdentifiers
import RitrovoCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var importingImage = false

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                Section("Dischi") {
                    if model.disks.isEmpty && !model.loadingDisks {
                        Text("Nessun disco trovato").foregroundStyle(.secondary)
                    }
                    ForEach(model.disks) { SourceRow(source: $0).tag($0.id) }
                }
                Section("Immagini disco") {
                    ForEach(model.images) { SourceRow(source: $0).tag($0.id) }
                    Button {
                        importingImage = true
                    } label: {
                        Label("Apri immagine…", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260)
            .toolbar {
                ToolbarItem {
                    Button { model.refreshDisks() } label: { Label("Aggiorna dischi", systemImage: "arrow.clockwise") }
                        .disabled(model.session != nil)
                }
            }
            .disabled(model.session != nil)
        } detail: {
            Group {
                if let session = model.session {
                    RecoveryView(session: session)
                } else if let source = model.selectedSource {
                    SetupView(source: source)
                        .id(source.id)
                } else {
                    WelcomeView(openImage: { importingImage = true })
                }
            }
        }
        .fileImporter(isPresented: $importingImage, allowedContentTypes: [.data, .diskImage]) { result in
            if case .success(let url) = result { model.addImage(url) }
        }
        .alert("Ritrovo", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
        .onAppear { model.refreshDisks() }
        // Images dropped on the window
        .dropDestination(for: URL.self) { urls, _ in
            guard model.session == nil, let url = urls.first(where: \.isFileURL) else { return false }
            model.addImage(url)
            return true
        }
    }
}

struct SourceRow: View {
    let source: RecoverySource
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).lineLimit(1)
                Text("\(ByteCountFormatter.string(fromByteCount: source.size, countStyle: .file)) · \(source.detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: source.symbol)
        }
        .padding(.vertical, 2)
    }
}

struct WelcomeView: View {
    let openImage: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
            Text("Recupera foto, video e documenti")
                .font(.title.weight(.semibold))
            Text("Scegli a sinistra il disco o la scheda di memoria da analizzare, oppure apri un'immagine disco. Ritrovo legge la sorgente senza mai scriverci.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            Button("Apri immagine disco…", action: openImage)
                .controlSize(.large)
            Text("Motore di recupero: PhotoRec di Christophe Grenier")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 24)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
