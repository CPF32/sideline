import SwiftUI

/// Shared page header so Team and League league-name blocks match.
struct LeaguePageHeader<Accessory: View>: View {
    let leagueName: String
    let subtitle: String
    /// Optional detail after the subtitle (e.g. season PF) — keep as a fixed slot to avoid layout jump.
    var subtitleDetail: AnyView? = nil
    var trailing: AnyView? = nil
    var footnote: String? = nil
    @ViewBuilder var accessory: () -> Accessory

    init(
        leagueName: String,
        subtitle: String,
        subtitleDetail: AnyView? = nil,
        trailing: AnyView? = nil,
        footnote: String? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.leagueName = leagueName
        self.subtitle = subtitle
        self.subtitleDetail = subtitleDetail
        self.trailing = trailing
        self.footnote = footnote
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(leagueName)
                .font(BrandTheme.display(26, weight: .bold))
                .foregroundStyle(BrandTheme.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(subtitle)
                            .font(BrandTheme.body(14))
                            .foregroundStyle(BrandTheme.muted)
                            .lineLimit(1)
                        if let subtitleDetail {
                            subtitleDetail
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    if let trailing {
                        trailing
                    }
                }

                accessory()
            }

            if let footnote, !footnote.isEmpty {
                Text(footnote)
                    .font(BrandTheme.body(12))
                    .foregroundStyle(BrandTheme.muted)
            }
        }
        .padding(.horizontal, BrandTheme.pageGutter)
        .padding(.top, BrandTheme.tabContentTop)
        .padding(.bottom, BrandTheme.space(16))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
