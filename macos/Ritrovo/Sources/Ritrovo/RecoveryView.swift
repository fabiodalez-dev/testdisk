import AppKit
import ImageIO
import SwiftUI
import RitrovoCore

struct RecoveryView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: RecoverySession

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)
            Divider()
            if session.recentImages.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(isRunning ? "Le immagini recuperate compariranno qui." : "Nessuna immagine recuperata.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(session.recentImages, id: \.self) { url in
                            Thumbnail(url: url)
                                .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                                .contextMenu {
                                    Button("Apri") { NSWorkspace.shared.open(url) }
                                    Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(session.sourceName)
    }

    private var isRunning: Bool { session.state == .running || session.state == .stopping }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle).font(.title2.weight(.semibold))
                    Text(statusDetail).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(session.totalFiles)")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("file trovati").font(.caption).foregroundStyle(.secondary)
                }
            }
            if isRunning {
                ProgressView(value: session.progress?.fraction ?? 0)
                    .progressViewStyle(.linear)
                    .animation(.easeOut, value: session.progress?.fraction)
            }
            if !session.stats.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(session.stats.sorted { $0.value > $1.value }, id: \.key) { ext, count in
                            HStack(spacing: 4) {
                                Text(ext).font(.caption.monospaced().weight(.semibold))
                                Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            HStack {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([session.sessionDir])
                } label: {
                    Label("Mostra nel Finder", systemImage: "folder")
                }
                Spacer()
                if isRunning {
                    Button(role: .destructive) {
                        session.stop()
                    } label: {
                        Label(session.state == .stopping ? "Arresto…" : "Interrompi", systemImage: "stop.fill")
                    }
                    .disabled(session.state == .stopping)
                } else {
                    Button("Nuovo recupero") { model.closeSession() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var statusTitle: String {
        switch session.state {
        case .running: return "Recupero in corso"
        case .stopping: return "Arresto in corso…"
        case .finished: return session.stoppedByUser ? "Recupero interrotto" : "Recupero completato"
        case .failed: return "Recupero interrotto"
        }
    }

    private var statusDetail: String {
        switch session.state {
        case .running, .stopping:
            guard let p = session.progress else { return "Avvio di PhotoRec…" }
            var parts = ["Passaggio \(p.pass + 1)", "\(Int(p.fraction * 100))%"]
            if let e = p.elapsed { parts.append("trascorso \(e)") }
            if let r = p.estimated { parts.append("rimanente \(r)") }
            return parts.joined(separator: " · ")
        case .finished:
            if session.stoppedByUser {
                return "Lo stato è salvato in photorec.ses. I file trovati finora sono nella cartella \(session.sessionDir.lastPathComponent)."
            }
            return "I file sono nella cartella \(session.sessionDir.lastPathComponent)."
        case .failed(let message):
            return message
        }
    }
}

/// Small thumbnails decoded with ImageIO, off the main thread.
struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .frame(height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomLeading) {
            Text(url.pathExtension.uppercased())
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(5)
        }
        .help(url.lastPathComponent)
        .task(id: url) {
            let loaded = await Task.detached(priority: .utility) { LoadedImage(cg: Self.load(url)) }.value
            image = loaded.cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
    }

    private struct LoadedImage: @unchecked Sendable { let cg: CGImage? }

    nonisolated private static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 280,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
