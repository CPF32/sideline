import SwiftUI

/// Entry sheet: pick MFL or Sleeper, then continue into provider-specific connect.
struct ConnectLeagueHubView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Destination: String, Identifiable {
        case mfl
        case sleeper
        case espn
        var id: String { rawValue }
    }

    @State private var destination: Destination?

    var body: some View {
        NavigationStack {
            ZStack {
                SidelineBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("League hub")
                                .font(BrandTheme.display(26, weight: .bold))
                                .foregroundStyle(BrandTheme.ink)
                            Text("Connect MFL, Sleeper, and ESPN leagues, then switch between them from Team or Settings. Sideline keeps each league’s roster and intel in one place.")
                                .font(BrandTheme.body(14))
                                .foregroundStyle(BrandTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !appState.linkedLeagues.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("CONNECTED")
                                    .font(BrandTheme.display(12, weight: .semibold))
                                    .tracking(1)
                                    .foregroundStyle(BrandTheme.muted)
                                ForEach(appState.linkedLeagues, id: \.id) { link in
                                    connectedRow(link)
                                }
                            }
                        }

                        VStack(spacing: 12) {
                            Button {
                                destination = .mfl
                            } label: {
                                providerCard(
                                    title: "MyFantasyLeague",
                                    subtitle: "Sign in · lineups write back on Approve",
                                    provider: .mfl
                                )
                            }
                            .buttonStyle(.plain)

                            Button {
                                destination = .sleeper
                            } label: {
                                providerCard(
                                    title: "Sleeper",
                                    subtitle: "Username only · read-only sync + player intel",
                                    provider: .sleeper
                                )
                            }
                            .buttonStyle(.plain)

                            Button {
                                destination = .espn
                            } label: {
                                providerCard(
                                    title: "ESPN",
                                    subtitle: "League ID · cookies for private leagues · read-only",
                                    provider: .espn
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, BrandTheme.pageGutter)
                    .padding(.top, BrandTheme.space(12))
                    .padding(.bottom, BrandTheme.space(40))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("CONNECT")
                        .font(BrandTheme.display(16, weight: .bold))
                        .tracking(1)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(BrandTheme.ink)
                }
            }
            .navigationDestination(item: $destination) { dest in
                switch dest {
                case .mfl:
                    ConnectMFLView(embedded: true)
                case .sleeper:
                    ConnectSleeperView()
                case .espn:
                    ConnectESPNView()
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func connectedRow(_ link: LinkedFranchise) -> some View {
        let active = appState.linkedFranchise?.id == link.id
        return Button {
            appState.switchActiveLeague(link)
            dismiss()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                ProviderLogoView(provider: link.provider, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.leagueName)
                        .font(BrandTheme.body(15, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                        .multilineTextAlignment(.leading)
                    Text(link.franchiseName)
                        .font(BrandTheme.body(12))
                        .foregroundStyle(BrandTheme.muted)
                }
                Spacer(minLength: 8)
                if active {
                    Text("ACTIVE")
                        .font(BrandTheme.display(10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(BrandTheme.accent)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                    .fill(BrandTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                            .stroke(active ? BrandTheme.accent.opacity(0.55) : BrandTheme.hairline, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func providerCard(title: String, subtitle: String, provider: LeagueProvider) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ProviderLogoView(provider: provider, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(BrandTheme.body(16, weight: .semibold))
                    .foregroundStyle(BrandTheme.ink)
                Text(subtitle)
                    .font(BrandTheme.body(13))
                    .foregroundStyle(BrandTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BrandTheme.muted)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                .fill(BrandTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                        .stroke(BrandTheme.hairline, lineWidth: 1)
                )
        )
    }
}

struct LeagueSwitcherMenu: View {
    @EnvironmentObject private var appState: AppState
    @State private var showOptions = false

    var body: some View {
        Button {
            showOptions = true
        } label: {
            if let provider = appState.linkedFranchise?.provider {
                ProviderLogoView(provider: provider, size: 24)
            } else {
                Text("League")
                    .font(BrandTheme.body(14, weight: .semibold))
                    .foregroundStyle(BrandTheme.ink)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
        .popover(isPresented: $showOptions, attachmentAnchor: .point(.bottom), arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(appState.linkedLeagues, id: \.id) { link in
                    let active = appState.linkedFranchise?.id == link.id
                    Button {
                        appState.switchActiveLeague(link)
                        showOptions = false
                    } label: {
                        HStack(spacing: 10) {
                            ProviderLogoView(provider: link.provider, size: 22)
                            Text(link.leagueName)
                                .font(BrandTheme.body(15, weight: active ? .semibold : .regular))
                                .foregroundStyle(BrandTheme.ink)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                                .fill(active ? BrandTheme.accentWash : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                                .stroke(active ? BrandTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                    .padding(.vertical, 2)

                Button {
                    showOptions = false
                    appState.showConnect = true
                } label: {
                    Text("Add league…")
                        .font(BrandTheme.body(15, weight: .medium))
                        .foregroundStyle(BrandTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
            .frame(minWidth: 220)
            .presentationCompactAdaptation(.popover)
        }
    }

    private var accessibilityTitle: String {
        guard let link = appState.linkedFranchise else { return "Switch league" }
        return "\(link.provider.shortName) · \(link.leagueName). Switch league"
    }
}
