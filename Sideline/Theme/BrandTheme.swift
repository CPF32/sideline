import SwiftUI
import UIKit

enum BrandTheme {
    static let appName = "Sideline"

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
    static let danger = Color.adaptive(light: "B33A2E", dark: "F07166")
    static let standingsUp = Color.adaptive(light: "2F7D4A", dark: "6DD492")
    static let standingsDown = Color.adaptive(light: "B33A2E", dark: "F07166")
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
    static let controlRadius: CGFloat = 9
    /// Shared top inset so tab body content lines up under the nav bar.
    static let tabContentTop: CGFloat = 12

    // MARK: - Typography

    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .default).width(.condensed)
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
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

struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandTheme.body(16, weight: .semibold))
            .foregroundStyle(BrandTheme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
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
            .padding(.vertical, 12)
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
            .padding(.vertical, 16)
            .background(BrandTheme.danger)
            .clipShape(RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
