// Visual language (see macos/DESIGN.md): warm graphite and paper neutrals,
// one copper accent for the primary action, the selection and progress.
// No gradients, no decorative shadows. Colors follow the system appearance.
import AppKit
import SwiftUI
import RitrovoCore

enum Theme {
    private static func dynamic(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    // OKLCH values in DESIGN.md, converted to sRGB.
    static let canvas = dynamic((0.9869, 0.9792, 0.9692), (0.0902, 0.0796, 0.0715))
    static let panel = dynamic((0.9623, 0.9528, 0.9402), (0.1234, 0.1105, 0.1006))
    static let hairline = dynamic((0.8812, 0.8680, 0.8508), (0.2219, 0.2057, 0.1934))
    static let ink = dynamic((0.1398, 0.1177, 0.1005), (0.9330, 0.9197, 0.9022))
    static let ink2 = dynamic((0.4137, 0.3824, 0.3585), (0.6617, 0.6415, 0.6195))
    static let ink3 = dynamic((0.5959, 0.5671, 0.5451), (0.4720, 0.4530, 0.4324))
    static let accent = dynamic((0.6659, 0.3651, 0.1980), (0.8450, 0.5745, 0.3867))
    static let accentSoft = dynamic((0.9750, 0.8909, 0.8368), (0.2437, 0.1560, 0.1068))
    static let onAccent = dynamic((0.9869, 0.9792, 0.9692), (0.0902, 0.0796, 0.0715))
    static let ok = dynamic((0.3053, 0.4974, 0.3468), (0.5032, 0.7025, 0.5419))
    static let warn = dynamic((0.6895, 0.4792, 0.1241), (0.8639, 0.6880, 0.3804))
    static let bad = dynamic((0.6984, 0.2524, 0.2153), (0.8927, 0.4904, 0.4277))

    static let radius: CGFloat = 8
}

/// Small uppercase label that opens a section.
struct SectionLabel: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.ink2)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 11)).foregroundStyle(Theme.ink3)
            }
        }
    }
}

/// Bordered surface for a group of controls the user acts on.
struct Panel<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

/// The one filled button: copper, standard macOS proportions.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.accent)
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Radio style row: one choice among several, in a Panel.
struct ChoiceRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    let selected: Bool
    var enabled = true
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().strokeBorder(selected ? Theme.accent : Theme.ink3, lineWidth: selected ? 5 : 1.2)
                        .frame(width: 16, height: 16)
                }
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.ink2).frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(selected ? Theme.accentSoft.opacity(0.55) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

extension ChoiceRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: String? = nil, selected: Bool, enabled: Bool = true, action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, selected: selected, enabled: enabled, action: action) { EmptyView() }
    }
}

/// Thin progress track.
struct ProgressTrack: View {
    let fraction: Double
    var indeterminate = false
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                if indeterminate {
                    Capsule().fill(Theme.accent)
                        .frame(width: geo.size.width * 0.25)
                        .offset(x: geo.size.width * phase)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase = 0.8 }
                        }
                } else {
                    Capsule().fill(Theme.accent)
                        .frame(width: max(6, geo.size.width * min(1, max(0, fraction))))
                        .animation(.easeOut(duration: 0.4), value: fraction)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Avanzamento")
        .accessibilityValue(indeterminate ? "in corso" : "\(Int(fraction * 100)) per cento")
    }
}

/// Inline notice: icon + text on a tinted background, never a side stripe.
struct Notice: View {
    enum Kind { case info, warning, danger, success }
    let kind: Kind
    let text: String
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.10)))
    }

    private var color: Color {
        switch kind {
        case .info: return Theme.ink2
        case .warning: return Theme.warn
        case .danger: return Theme.bad
        case .success: return Theme.ok
        }
    }

    private var symbol: String {
        switch kind {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .danger: return "xmark.octagon"
        case .success: return "checkmark.circle"
        }
    }
}

extension FileCategory {
    /// Outline symbols, always in a neutral ink: categories are not colors.
    var outline: String {
        switch self {
        case .photo: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .document: return "doc.text"
        case .archive: return "archivebox"
        case .other: return "questionmark.folder"
        }
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    static func bytes(_ n: UInt64) -> String { bytes(Int64(clamping: n)) }
    /// Never traps: absurd or non finite values are shown as unknown.
    static func speed(_ bps: Double) -> String {
        guard bps.isFinite, bps > 0, bps < 1e13 else { return "" }
        return bytes(Int64(bps)) + "/s"
    }
    static func number(_ n: Int) -> String { n.formatted(.number.grouping(.automatic)) }
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 1e8 else { return "" }
        let s = Int(seconds)
        if s >= 3600 { return String(format: "%d h %02d min", s / 3600, s / 60 % 60) }
        if s >= 60 { return String(format: "%d min", s / 60) }
        return "\(s) s"
    }
    /// The engine writes durations as "1h02m03s".
    static func engineDuration(_ text: String?) -> TimeInterval? {
        guard let text else { return nil }
        let parts = text.split(whereSeparator: { "hms".contains($0) }).compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
    /// Engine messages may carry its own name: the interface calls it Ritrovo.
    static func engineMessage(_ text: String) -> String {
        text.replacingOccurrences(of: "PhotoRec", with: "Ritrovo").replacingOccurrences(of: "photorec", with: "ritrovo")
    }
}
