import SwiftUI

/// Credits: Ritrovo is only an interface, the recovery is PhotoRec's work.
struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text("Ritrovo").font(.largeTitle.weight(.semibold))
            Text("Versione \(version)").foregroundStyle(.secondary)
            Divider()
            VStack(spacing: 6) {
                Text("Il motore di recupero è **PhotoRec**")
                Text("di Christophe Grenier · CGSecurity")
                Link("www.cgsecurity.org", destination: URL(string: "https://www.cgsecurity.org")!)
            }
            Text("Ritrovo è un'interfaccia nativa per macOS: ogni file viene trovato e ricostruito dal programma PhotoRec originale, incluso senza modifiche agli algoritmi di riconoscimento. Ritrovo non è un prodotto ufficiale di CGSecurity.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Software libero distribuito secondo la GNU General Public License, versione 2 o successiva, senza alcuna garanzia.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Testo della licenza", destination: URL(string: "https://www.gnu.org/licenses/old-licenses/gpl-2.0.html")!)
                .font(.footnote)
        }
        .padding(28)
        .frame(width: 420)
    }
}
