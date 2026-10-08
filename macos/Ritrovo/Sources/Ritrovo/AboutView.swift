import SwiftUI

/// Credits: the only place where the recovery engine is named.
struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ritrovo").font(.system(size: 22, weight: .semibold))
                    Text("Versione \(version)").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                }
            }
            Hairline()
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Motore di recupero")
                Text("PhotoRec, di Christophe Grenier · CGSecurity").font(.system(size: 13, weight: .medium))
                Link("www.cgsecurity.org", destination: URL(string: "https://www.cgsecurity.org")!)
                    .font(.system(size: 12))
                Text("Ogni file viene trovato e ricostruito da PhotoRec, incluso senza modifiche agli algoritmi di riconoscimento. Ritrovo è un'interfaccia per macOS e non è un prodotto ufficiale di CGSecurity.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Hairline()
            VStack(alignment: .leading, spacing: 4) {
                Text("Software libero, GNU General Public License versione 2 o successiva, senza alcuna garanzia.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Testo della licenza", destination: URL(string: "https://www.gnu.org/licenses/old-licenses/gpl-2.0.html")!)
                    .font(.system(size: 11))
            }
        }
        .padding(26)
        .frame(width: 420)
        .background(Theme.canvas)
        .tint(Theme.accent)
    }
}
