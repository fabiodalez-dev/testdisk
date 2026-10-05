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
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Informazioni su Ritrovo") { openWindow(id: "about") }
            }
            CommandGroup(replacing: .newItem) {}
        }

        Window("Informazioni su Ritrovo", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}
