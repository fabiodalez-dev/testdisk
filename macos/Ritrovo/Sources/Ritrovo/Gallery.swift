import AppKit
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import RitrovoCore

/// Grid of recovered files: categories, search, sort, Quick Look (space),
/// multiple selection (⌘ and ⇧ click), drag to the Finder, copy to a folder.
struct ResultsGallery: View {
    let files: [RecoveredFile]
    var emptyText = "I file recuperati compariranno qui."

    @State private var category: FileCategory?
    @State private var query = ""
    @State private var sort: ResultSort = .newest
    @State private var tileSize: Double = 132
    @State private var selection = Set<URL>()
    @State private var preview: URL?

    private var shown: [RecoveredFile] { ResultFilter.apply(files, category: category, query: query, sort: sort) }
    private var counts: [FileCategory: Int] { ResultFilter.counts(files) }

    var body: some View {
        let shown = self.shown
        return VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            Hairline()
            if shown.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: files.isEmpty ? "tray" : "line.3.horizontal.decrease")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Theme.ink3)
                    Text(files.isEmpty ? emptyText : "Nessun file corrisponde ai filtri.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.35), spacing: 14)], spacing: 16) {
                        ForEach(shown) { file in
                            FileTile(file: file, size: tileSize, selected: selection.contains(file.url))
                                .onTapGesture(count: 2) { NSWorkspace.shared.open(file.url) }
                                .simultaneousGesture(TapGesture().onEnded { select(file) })
                                .onDrag { NSItemProvider(contentsOf: file.url) ?? NSItemProvider() }
                                .contextMenu { contextMenu(for: file) }
                        }
                    }
                    .padding(24)
                }
                .background(Color.clear.contentShape(Rectangle()).onTapGesture { selection.removeAll() })
            }
        }
        .quickLookPreview($preview, in: shown.map(\.url))
        .onChange(of: files) { _ in selection.formIntersection(Set(files.map(\.url))) }
        .background(
            // Space opens Quick Look on the selection, like the Finder.
            Button("") { preview = selection.first ?? shown.first?.url }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
                .disabled(shown.isEmpty)
        )
    }

    private func select(_ file: RecoveredFile) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(file.url) { selection.remove(file.url) } else { selection.insert(file.url) }
        } else if NSEvent.modifierFlags.contains(.shift), let anchor = selection.first,
                  let a = shown.firstIndex(where: { $0.url == anchor }), let b = shown.firstIndex(of: file) {
            selection.formUnion(shown[min(a, b)...max(a, b)].map(\.url))
        } else {
            selection = [file.url]
        }
    }

    @ViewBuilder private func contextMenu(for file: RecoveredFile) -> some View {
        let targets = selection.contains(file.url) ? Array(selection) : [file.url]
        Button("Apri") { targets.forEach { NSWorkspace.shared.open($0) } }
        Button("Anteprima") { preview = file.url }
        Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets) }
        Divider()
        Button(targets.count > 1 ? "Copia \(targets.count) file in…" : "Copia in…") { copy(targets) }
    }

    private var toolbar: some View {
        let counts = self.counts
        return HStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    FilterTab(title: "Tutti", count: files.count, selected: category == nil) { category = nil }
                    ForEach(FileCategory.allCases) { cat in
                        if let n = counts[cat], n > 0 {
                            FilterTab(title: cat.title, count: n, selected: category == cat) {
                                category = (category == cat ? nil : cat)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            TextField("Cerca", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
            Picker("Ordina", selection: $sort) {
                ForEach(ResultSort.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)
            Slider(value: $tileSize, in: 96...240)
                .frame(width: 80)
                .help("Dimensione delle anteprime")
            if !selection.isEmpty {
                Button("Copia \(selection.count)…") { copy(Array(selection)) }
                    .help("Copia i file selezionati in un'altra cartella")
            }
        }
    }

    private func copy(_ urls: [URL]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copia qui"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task.detached {
            for url in urls {
                let dest = Organizer.uniqueURL(dir.appendingPathComponent(url.lastPathComponent))
                try? FileManager.default.copyItem(at: url, to: dest)
            }
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
        }
    }
}

/// Text tab with a count; the selected one is ink on a soft copper ground.
struct FilterTab: View {
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                Text(Format.number(count)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.ink3)
            }
            .foregroundStyle(selected ? Theme.ink : Theme.ink2)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Theme.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

/// One file: Quick Look thumbnail (photos, videos, PDF...) or the file icon.
struct FileTile: View {
    let file: RecoveredFile
    let size: Double
    let selected: Bool
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle()
                .fill(Theme.panel)
                .frame(maxWidth: .infinity)
                .frame(height: size * 0.78)
                .overlay {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                            .resizable().scaledToFit().padding(size * 0.24)
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: selected ? 2.5 : 1)
            )
            .overlay(alignment: .bottomTrailing) {
                if file.category != .photo {
                    Image(systemName: file.category.outline)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.canvas.opacity(0.92)))
                        .padding(5)
                }
            }
            .brightness(hovering && !selected ? 0.03 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                Text("\(file.ext.uppercased()) · \(Format.bytes(file.size))").font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.ink3)
            }
        }
        .onHover { hovering = $0 }
        .help(file.url.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task(id: file.url) { thumbnail = await ThumbnailCache.shared.thumbnail(for: file.url, size: 260) }
    }
}

/// Thumbnails from Quick Look, cached by path.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
