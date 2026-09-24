import SwiftUI

/// Renders a player-prop line with American odds tinted green (+) / red (−).
struct OddsPropLineLabel: View {
    let prop: OddsPlayerProp
    var compact: Bool = false

    var body: some View {
        Group {
            if let line = prop.line {
                HStack(spacing: compact ? 4 : 5) {
                    Text(OddsPlayerProp.trimPoint(line))
                        .foregroundStyle(BrandTheme.ink)
                    if let over = prop.overPrice, let under = prop.underPrice {
                        Text("O")
                            .foregroundStyle(BrandTheme.muted)
                        american(over)
                        Text("/")
                            .foregroundStyle(BrandTheme.muted.opacity(0.7))
                        Text("U")
                            .foregroundStyle(BrandTheme.muted)
                        american(under)
                    } else if let over = prop.overPrice {
                        Text("O")
                            .foregroundStyle(BrandTheme.muted)
                        american(over)
                    }
                }
            } else if let over = prop.overPrice {
                HStack(spacing: compact ? 4 : 5) {
                    Text("Yes")
                        .foregroundStyle(BrandTheme.ink)
                    american(over)
                }
            } else {
                Text(prop.marketLabel)
                    .foregroundStyle(BrandTheme.ink)
            }
        }
        .font(compact ? BrandTheme.mono(12, weight: .medium) : BrandTheme.mono(13, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func american(_ price: Int) -> some View {
        Text(OddsPlayerProp.formatAmerican(price))
            .foregroundStyle(Self.color(for: price))
    }

    static func color(for price: Int) -> Color {
        if price > 0 { return BrandTheme.standingsUp }
        if price < 0 { return BrandTheme.danger }
        return BrandTheme.ink
    }
}
