import AppKit
import SwiftUI

/// Files opened from Finder ("Open With", drag on the Dock icon): handled
/// here, SwiftUI would otherwise open a new window for each of them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            let model = AppModel.shared
            guard model.session == nil, let url = urls.first(where: \.isFileURL) else { return }
            model.addImage(url)
        }
    }
}

@main
struct RitrovoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        // Launched as a bare executable (swift run): behave like an app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Ritrovo", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 680)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
                .task { if SelfTest.outDir != nil { await SelfTest.run(model) } }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Informazioni su Ritrovo") { openWindow(id: "about") }
            }
            CommandGroup(replacing: .newItem) {
                Button("Apri immagine disco…") { model.openImagePanel() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.isBusy)
            }
            CommandMenu("Recupero") {
                Button("Avvia recupero") { model.startRecovery() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.canStart)
                Button("Interrompi") { model.stopActive() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isBusy)
                Divider()
                Button("Scegli i formati…") { model.showingFormats = true }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(model.selectedPartition == nil)
                Button("Aggiorna dischi") { model.refreshDisks() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.isBusy)
            }
        }

        Window("Informazioni su Ritrovo", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}
