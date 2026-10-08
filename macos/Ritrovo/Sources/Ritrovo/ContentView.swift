import SwiftUI
import RitrovoCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
        }
        .tint(Theme.accent)
        .alert("Ritrovo", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
        .onAppear { model.refreshDisks() }
        // Disk images dropped on the window
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isBusy, let url = urls.first(where: \.isFileURL) else { return false }
            model.addImage(url)
            return true
        }
    }

    @ViewBuilder private var detail: some View {
        if let clone = model.clone {
            CloneView(clone: clone)
        } else if let session = model.session {
            RecoveryView(session: session)
        } else if let entry = model.selectedHistory {
            ResultsView(entry: entry).id(entry.path)
        } else if let source = model.selectedSource {
            SetupView(source: source).id(source.id)
        } else {
            WelcomeView()
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
            Section("Dischi") {
                if model.disks.isEmpty {
                    Text(model.loadingDisks ? "Ricerca dei dischi…" : "Nessun disco collegato")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink3)
                }
                ForEach(model.disks) { disk in
                    SourceRow(source: disk)
                        .tag(SidebarItem.source(disk.id))
                        .contextMenu {
                            if case .disk(let isInternal) = disk.kind, !isInternal {
                                Button("Espelli \(disk.name)") { model.eject(disk) }
                            }
                        }
                }
            }

            Section("Immagini disco") {
                ForEach(model.images) { SourceRow(source: $0).tag(SidebarItem.source($0.id)) }
                Button(action: model.openImagePanel) {
                    Label("Apri immagine…", systemImage: "plus")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink2)
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
            }

            if !model.history.isEmpty {
                Section("Recuperi") {
                    ForEach(model.history) { entry in
                        HistoryRow(entry: entry)
                            .tag(SidebarItem.history(entry.path))
                            .contextMenu {
                                if model.canResume(entry) {
                                    Button("Riprendi il recupero") { model.resume(entry) }
                                }
                                Button("Mostra nel Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                                }
                                Divider()
                                Button("Rimuovi dall'elenco") { model.forget(entry) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(model.isBusy)
        .toolbar {
            ToolbarItem {
                Button(action: model.refreshDisks) { Label("Aggiorna dischi", systemImage: "arrow.clockwise") }
                    .disabled(model.isBusy)
                    .help("Aggiorna l'elenco dei dischi")
            }
        }
    }
}

struct SourceRow: View {
    let source: RecoverySource

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name).font(.system(size: 13)).lineLimit(1)
                Text(Format.bytes(source.size) + detailSuffix)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: source.symbol)
        }
        .padding(.vertical, 1)
    }

    private var detailSuffix: String {
        switch source.kind {
        case .disk: return " · " + source.detail
        case .image: return ""
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.sourceName).font(.system(size: 13)).lineLimit(1)
                Text("\(Format.number(entry.totalFiles)) file · \(entry.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: entry.completed ? "checkmark.circle" : "pause.circle")
                .foregroundStyle(entry.completed ? Theme.ok : Theme.warn)
        }
        .padding(.vertical, 1)
    }
}

/// Empty state that teaches the first step.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropHover = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Da dove vuoi recuperare?")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("Scegli un disco, una scheda di memoria o una chiavetta nella barra laterale. Ritrovo la legge soltanto: non scrive mai sulla sorgente, così i file persi restano dove sono.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.ink2)
                        .lineSpacing(3)
                        .frame(maxWidth: 520, alignment: .leading)
                }

                VStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.plus")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(dropHover ? Theme.accent : Theme.ink3)
                    Text("Trascina qui un'immagine disco")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text(".img, .dd, .dmg, .iso, .raw")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink3)
                    Button("Scegli un'immagine…", action: model.openImagePanel)
                        .controlSize(.regular)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(dropHover ? Theme.accent : Theme.hairline, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                )
                .onDrop(of: [.fileURL], isTargeted: $dropHover) { providers in
                    _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in model.addImage(url) } }
                    }
                    return true
                }

                if !model.history.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Recuperi recenti")
                        Panel {
                            VStack(spacing: 0) {
                                ForEach(Array(model.history.prefix(4).enumerated()), id: \.element.id) { index, entry in
                                    if index > 0 { Hairline() }
                                    Button { model.select(.history(entry.path)) } label: {
                                        HStack {
                                            HistoryRow(entry: entry)
                                            Spacer()
                                            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 9)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                Text("Consiglio: salva i file recuperati su un disco diverso da quello che stai analizzando.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 44)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Ritrovo")
    }
}
