import SwiftUI
import UIKit

enum BrandTheme {
    static let appName = "Sideline"

    // MARK: - Phone canvas (iPhone 17 Pro Max)

    /// Design reference width — iPhone 17 Pro Max portrait (440 × 956 pt).
    static let designWidth: CGFloat = 440
    /// Design reference height — iPhone 17 Pro Max portrait.
    static let designHeight: CGFloat = 956

    /// Scales Max-designed metrics down on smaller iPhones (never enlarges past 1).
    static var layoutScale: CGFloat {
        let width = keyWindowWidth ?? UIScreen.main.bounds.width
        guard width > 0 else { return 1 }
        return min(max(width / designWidth, 0.82), 1.0)
    }

    static func space(_ value: CGFloat) -> CGFloat { value * layoutScale }

    /// Standard page inset (20pt on Max).
    static var pageGutter: CGFloat { space(20) }
    /// Welcome / sparse screens (32pt on Max).
    static var pageGutterWide: CGFloat { space(32) }
    /// Nested cards / fields (14pt on Max).
    static var pageGutterTight: CGFloat { space(14) }
    /// Compact list / chat inset (16pt on Max).
    static var pageGutterCompact: CGFloat { space(16) }

    // MARK: - Colors (adaptive — follow preferredColorScheme)

    static let background = Color.adaptive(light: "F4F5F3", dark: "0E100E")
    static let backgroundTop = Color.adaptive(light: "EEF1F4", dark: "161A18")
    /// Primary text on page backgrounds.
    static let ink = Color.adaptive(light: "1A1C1A", dark: "F3F5F1")
    /// Secondary / supporting text — kept brighter in dark for readability.
    static let muted = Color.adaptive(light: "5C635C", dark: "B6BEB6")
    static let accent = Color(hex: "B8F000")
    /// Always dark — use on lime accent fills (buttons, banners, chips).
    static let onAccent = Color(hex: "1A1C1A")
    /// Final / completed-game points indicator (roster dots).
    static let finalPoints = Color.adaptive(light: "2F6FED", dark: "6B9FFF")
    static let danger = Color.adaptive(light: "B33A2E", dark: "F07166")
    static let standingsUp = Color.adaptive(light: "2F7D4A", dark: "6DD492")
    static let standingsDown = Color.adaptive(light: "B33A2E", dark: "F07166")
    /// Discrete “props available” mark on roster rows (true green — not lime accent).
    static let propsMark = Color.adaptive(light: "1F8A4C", dark: "3DCF7A")
    /// "Mine" fill for the win-probability gauge — a deeper, more legible green than the
    /// neon `accent` lime, which reads poorly as small text/fill against light backgrounds.
    static let gaugeMine = Color.adaptive(light: "5B8A00", dark: "9FE000")
    /// Opponent fill for the win-probability gauge (paired with `gaugeMine`).
    static let electricOrange = Color(hex: "FF5F1F")
    static let hairline = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.22)
            : UIColor.black.withAlphaComponent(0.10)
    })
    /// Fields, cards, chips — solid enough in dark to separate from the page.
    static let surface = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0x24 / 255, green: 0x2A / 255, blue: 0x24 / 255, alpha: 1)
        }
        return UIColor.white.withAlphaComponent(0.72)
    })
    static let surfaceStrong = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0x2E / 255, green: 0x35 / 255, blue: 0x2E / 255, alpha: 1)
        }
        return UIColor.white.withAlphaComponent(0.88)
    })
    /// Soft accent tint for selected rows / banners (readable under ink in both modes).
    static let accentWash = Color(uiColor: UIColor { traits in
        let base = UIColor(red: 0xB8 / 255, green: 0xF0 / 255, blue: 0x00 / 255, alpha: 1)
        return traits.userInterfaceStyle == .dark
            ? base.withAlphaComponent(0.32)
            : base.withAlphaComponent(0.45)
    })

    // MARK: - Position colors (fixed across all leagues)

    /// Roster / slot position label color. Same palette whether the host is Sleeper, MFL, or ESPN.
    /// Hues are spaced around the wheel so adjacent roster labels stay easy to tell apart.
    static func positionColor(for raw: String) -> Color {
        let key = normalizePositionKey(raw)
        switch key {
        case "QB": return Color(hex: "FF2A6D") // magenta
        case "RB": return Color(hex: "00BFA5") // teal
        case "WR": return Color(hex: "2E7BFF") // blue
        case "TE": return Color(hex: "F59E0B") // amber
        case "K", "PK": return Color(hex: "A855F7") // violet
        case "DEF", "DST", "D/ST": return Color(hex: "16A34A") // green
        case "DT", "DL": return Color(hex: "EF4444") // red
        case "DE": return Color(hex: "06B6D4") // cyan
        case "LB": return Color(hex: "4F46E5") // indigo
        case "CB", "DB": return Color(hex: "EAB308") // gold
        case "S", "SS", "FS": return Color(hex: "84CC16") // lime
        case "FLEX", "WR/RB", "RB/WR", "W/R", "WR/TE", "RB/TE", "W/R/T", "RB/WR/TE", "WR/RB/TE":
            return Color(hex: "0EA5E9") // sky
        case "SUPERFLEX", "Q/W/R/T", "SUPER_FLEX", "SF":
            return Color(hex: "F97316") // orange
        case "BN", "BENCH", "IR", "TAXI":
            return muted
        default:
            if key.contains("QB") { return Color(hex: "FF2A6D") }
            if key.contains("FLEX") { return Color(hex: "0EA5E9") }
            return muted
        }
    }

    private static func normalizePositionKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static var controlRadius: CGFloat { space(9) }
    /// Shared top inset so tab body content lines up under the nav bar.
    static var tabContentTop: CGFloat { space(12) }

    // MARK: - Typography (sizes track Max canvas)

    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size * layoutScale, weight: weight, design: .default).width(.condensed)
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * layoutScale, weight: weight, design: .default)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size * layoutScale, weight: weight, design: .monospaced)
    }

    private static var keyWindowWidth: CGFloat? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .bounds.width
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: Double
        switch cleaned.count {
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        default:
            r = 0; g = 0; b = 0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    static func adaptive(light: String, dark: String) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(Color(hex: hex))
        })
    }
}

struct SidelineBackground: View {
    var body: some View {
        LinearGradient(
            colors: [BrandTheme.backgroundTop, BrandTheme.background],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

/// Keeps Dynamic Type in a band so layout stays close to the Max design across phones.
struct PhoneLayoutRoot: ViewModifier {
    func body(content: Content) -> some View {
        content
            .dynamicTypeSize(.medium ... .xxLarge)
    }
}

extension View {
    func phoneLayoutRoot() -> some View {
        modifier(PhoneLayoutRoot())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandTheme.body(16, weight: .semibold))
            .foregroundStyle(BrandTheme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, BrandTheme.space(14))
            .background(enabled ? BrandTheme.accent : BrandTheme.muted.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandTheme.body(15, weight: .medium))
            .foregroundStyle(BrandTheme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, BrandTheme.space(12))
            .background(BrandTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                    .stroke(BrandTheme.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandTheme.body(16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, BrandTheme.space(16))
            .background(BrandTheme.danger)
            .clipShape(RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
