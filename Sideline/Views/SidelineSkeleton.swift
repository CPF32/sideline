import SwiftUI

/// Shape-matched loading placeholders — same typography/spacing as real content so layout does not jump.
enum SidelineSkeleton {
    static func bone(width: CGFloat, height: CGFloat, radius: CGFloat = 3) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(BrandTheme.muted.opacity(0.22))
            .frame(width: width, height: height)
    }

    /// Redacted text that reserves the final glyph size.
    static func text(_ sample: String, font: Font) -> some View {
        Text(sample)
            .font(font)
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
    }
}

/// Props `$` mark — only rendered when an Odds API key is stored (or screenshot demo).
/// Shows only once we know the player has lines; no loading flash on refresh.
struct PropsAvailabilityMark: View {
    let hasProps: Bool
    /// Kept for call-site compatibility; row marks no longer pulse while props refresh
    /// (SIDELINE title already shows the loading motion).
    var isLoading: Bool = false
    var monoSize: CGFloat = 11

    private var showSlot: Bool {
        OddsAPIClient.hasAPIKey || ScreenshotDemo.isEnabled
    }

    var body: some View {
        Group {
            if showSlot, hasProps {
                Text("$")
                    .font(BrandTheme.mono(monoSize, weight: .bold))
                    .foregroundStyle(BrandTheme.propsMark)
                    .accessibilityLabel("Props available")
            }
        }
    }
}

/// Same mark at the smaller matchup-row size.
struct PropsAvailabilityMarkCompact: View {
    let hasProps: Bool
    var isLoading: Bool = false

    var body: some View {
        PropsAvailabilityMark(hasProps: hasProps, isLoading: isLoading, monoSize: 10)
    }
}
