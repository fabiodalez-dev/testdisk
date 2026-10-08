import AppKit
import SwiftUI
import RitrovoCore

struct RecoveryView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: RecoverySession
    @State private var showingLog = false

    var body: some View {
        VStack(spacing: 0) {
            status
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 18)
            Hairline()
            ResultsGallery(files: session.files)
        }
        .navigationTitle(session.sourceName)
        .toolbar {
            ToolbarItem {
                Button { showingLog.toggle() } label: { Label("Registro", systemImage: "list.bullet.rectangle") }
                    .help("Messaggi del motore di recupero")
                    .popover(isPresented: $showingLog, arrowEdge: .bottom) { LogView(lines: session.logLines) }
            }
        }
    }

    private var running: Bool { session.isActive }

    private var status: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                if let passText { Text(passText).font(.system(size: 12)).foregroundStyle(Theme.ink3) }
                Spacer()
                actions
            }
            if running {
                ProgressTrack(fraction: session.progress?.fraction ?? 0, indeterminate: session.progress == nil)
            }
            Text(facts)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.ink2)
                .lineLimit(2)
            if session.readErrors > 0 {
                Notice(kind: .warning, text: "\(Format.number(session.readErrors)) errori di lettura",
                       detail: "Il disco ha settori illeggibili. Conviene interrompere, copiarlo in un'immagine e recuperare dalla copia: così il disco viene letto una volta sola.")
            }
            if case .failed(let message) = session.state {
                Notice(kind: .danger, text: "Il recupero si è interrotto", detail: message)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.sessionDir]) }
            if session.state == .stopping, let since = session.stopRequestedAt {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    if context.date.timeIntervalSince(since) > 20 {
                        Button("Il disco non risponde: torna indietro") {
                            session.abandon()
                            model.closeSession()
                        }
                    }
                }
            }
            if running {
                Button(session.state == .stopping ? "Arresto…" : "Interrompi") { session.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(session.state == .stopping)
            } else {
                Button("Nuovo recupero") { model.closeSession() }
                Button("Apri i risultati") {
                    let path = session.sessionDir.path
                    model.closeSession()
                    model.select(.history(path))
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var title: String {
        switch session.state {
        case .running: return "Recupero in corso"
        case .stopping: return "Arresto in corso"
        case .finished: return session.stoppedByUser ? "Recupero interrotto" : "Recupero completato"
        case .failed: return "Recupero interrotto"
        }
    }

    private var passText: String? {
        guard running, let p = session.progress else { return nil }
        return "passaggio \(p.pass + 1)"
    }

    private var facts: String {
        var parts: [String] = []
        if running, let p = session.progress {
            parts.append("\(Int(p.fraction * 100))%")
            if session.partitionSize > 0 {
                let done = UInt64(Double(session.partitionSize) * p.fraction)
                parts.append("\(Format.bytes(done)) di \(Format.bytes(session.partitionSize))")
            }
        }
        parts.append("\(Format.number(session.totalFiles)) file trovati")
        if running {
            let speed = Format.speed(session.bytesPerSecond)
            if !speed.isEmpty { parts.append(speed) }
            if let t = Format.engineDuration(session.progress?.estimated), t > 0 { parts.append("circa \(Format.duration(t)) al termine") }
        } else if let t = Format.engineDuration(session.progress?.elapsed) {
            parts.append("durata \(Format.duration(t))")
        }
        if !running && session.stoppedByUser { parts.append("si può riprendere dalla barra laterale") }
        if running && session.progress == nil { return "Avvio del recupero…" }
        return parts.joined(separator: "  ·  ")
    }
}

struct LogView: View {
    let lines: [RecoverySession.LogLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Registro").font(.system(size: 13, weight: .semibold)).padding(12)
            Hairline()
            if lines.isEmpty {
                Text("Nessun messaggio.").font(.system(size: 12)).foregroundStyle(Theme.ink2).padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(lines) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Circle().fill(color(line.level)).frame(width: 5, height: 5)
                                    Text(line.message).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                }
                                .id(line.id)
                            }
                        }
                        .padding(12)
                    }
                    .onAppear { proxy.scrollTo(lines.last?.id, anchor: .bottom) }
                }
            }
        }
        .frame(width: 540, height: 340)
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "critical", "error": return Theme.bad
        case "warning": return Theme.warn
        default: return Theme.ink3
        }
    }
}

/// A recovery from the list: browse and tidy the results, or resume it.
struct ResultsView: View {
    @EnvironmentObject var model: AppModel
    let entry: HistoryEntry
    @State private var files: [RecoveredFile] = []
    @State private var loading = true
    @State private var working: String?
    @State private var message: String?
    @State private var organizing = false
    @State private var renameByDate = true

    private var dir: URL { URL(fileURLWithPath: entry.path) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.sourceName).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("\(entry.completed ? "Completato" : "Interrotto") il \(entry.date.formatted(date: .long, time: .shortened))  ·  \(Format.number(files.count)) file  ·  \(Format.bytes(files.reduce(0) { $0 + $1.size }))")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.ink2)
                    }
                    Spacer()
                    Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                    if model.canResume(entry) {
                        Button("Riprendi il recupero") { model.resume(entry) }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(model.isBusy)
                    }
                }
                HStack(spacing: 8) {
                    Button("Organizza per tipo…") { organizing = true }
                    Button("Sposta i duplicati") {
                        run("Ricerca dei duplicati…") {
                            let n = try Organizer.moveDuplicates(sessionDir: dir)
                            return n == 0 ? "Nessun duplicato." : "\(n) duplicati spostati nella cartella Duplicati."
                        }
                    }
                    Button("Esporta elenco CSV…") { exportCSV() }
                    Spacer()
                    if let working {
                        ProgressView().controlSize(.small)
                        Text(working).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    } else if let message {
                        Label(message, systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Theme.ok)
                    }
                }
                .disabled(working != nil || files.isEmpty)
                if organizing {
                    Panel(padding: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("I file vengono spostati in cartelle per tipo, come “Per tipo/Foto/jpg”, dentro la cartella del recupero. Nessun file viene cancellato.")
                                .font(.system(size: 12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                            Toggle("Rinomina le foto con la data di scatto (2021-07-14 18.30.05.jpg)", isOn: $renameByDate)
                                .toggleStyle(.checkbox)
                            HStack {
                                Spacer()
                                Button("Annulla") { organizing = false }
                                Button("Organizza") {
                                    organizing = false
                                    let rename = renameByDate
                                    run("Organizzazione…") {
                                        let r = try Organizer.organizeByType(sessionDir: dir, renameByDate: rename)
                                        return "\(r.moved) file organizzati" + (r.renamedByDate > 0 ? ", \(r.renamedByDate) foto rinominate." : ".")
                                    }
                                }
                                .buttonStyle(PrimaryButtonStyle())
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            Hairline()
            if loading {
                ProgressTrack(fraction: 0, indeterminate: true).frame(width: 200).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ResultsGallery(files: files, emptyText: "La cartella non contiene file recuperati.")
            }
        }
        .navigationTitle(entry.sourceName)
        .task { await reload() }
    }

    private func reload() async {
        let dir = self.dir
        let found = await Task.detached { RecoveryScanner.allFiles(in: dir) }.value
        files = found
        loading = false
    }

    private func run(_ label: String, _ work: @escaping @Sendable () throws -> String) {
        working = label
        message = nil
        Task {
            let result = await Task.detached { () -> String in
                do { return try work() } catch { return "Errore: \(error.localizedDescription)" }
            }.value
            working = nil
            message = result
            await reload()
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Ritrovo \(entry.sourceName).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.directoryURL = dir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let files = self.files, dir = self.dir
        run("Creazione dell'elenco…") {
            try Organizer.csvReport(files: files, relativeTo: dir).write(to: url, atomically: true, encoding: .utf8)
            return "Elenco salvato: \(url.lastPathComponent)"
        }
    }
}

/// Copy of a whole disk into disco.img.
struct CloneView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var clone: CloneSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(detail).font(.system(size: 13)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            ProgressTrack(fraction: clone.state == .finished ? 1 : clone.fraction)
            Text(facts).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.ink2)
            if case .failed(let message) = clone.state { Notice(kind: .danger, text: "Copia interrotta", detail: message) }
            HStack(spacing: 8) {
                Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([clone.workDir]) }
                Spacer()
                switch clone.state {
                case .running, .stopping:
                    Button(clone.state == .stopping ? "Arresto…" : "Interrompi") { clone.stop() }
                        .disabled(clone.state == .stopping)
                case .finished:
                    Button("Chiudi") { model.closeClone(openImage: false) }
                    Button("Recupera dall'immagine") { model.closeClone(openImage: true) }
                        .buttonStyle(PrimaryButtonStyle())
                case .failed:
                    Button("Chiudi") { model.closeClone(openImage: false) }
                }
            }
            .padding(.top, 6)
        }
        .padding(48)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Copia di \(clone.sourceName)")
    }

    private var title: String {
        switch clone.state {
        case .running: return "Copia del disco in corso"
        case .stopping: return "Arresto in corso"
        case .finished: return "Immagine pronta"
        case .failed: return "Copia interrotta"
        }
    }

    private var detail: String {
        switch clone.state {
        case .running, .stopping:
            return "\(clone.sourceName) viene letto una volta sola. I blocchi illeggibili vengono riempiti di zeri, così tutto il resto rimane al suo posto."
        case .finished:
            return "Ora puoi recuperare dall'immagine senza toccare più il disco."
        case .failed:
            return "L'immagine contiene la parte del disco già letta."
        }
    }

    private var facts: String {
        var parts = ["\(Int((clone.state == .finished ? 1 : clone.fraction) * 100))%",
                     "\(Format.bytes(clone.copiedBytes)) di \(Format.bytes(clone.totalBytes))"]
        if clone.state == .running {
            let speed = Format.speed(clone.bytesPerSecond)
            if !speed.isEmpty { parts.append(speed) }
            if clone.bytesPerSecond > 0 {
                parts.append("circa \(Format.duration(Double(clone.totalBytes - clone.copiedBytes) / clone.bytesPerSecond)) al termine")
            }
        }
        return parts.joined(separator: "  ·  ")
    }
}
