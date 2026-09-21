import SwiftUI

/// Entry sheet: pick MFL or Sleeper, then continue into provider-specific connect.
struct ConnectLeagueHubView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Destination: String, Identifiable {
        case mfl
        case sleeper
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
                            Text("Connect MFL and Sleeper leagues, then switch between them from Team or Settings. Sideline keeps each league’s roster and intel in one place.")
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
                                    subtitle: "Sign in · lineups write back on Approve"
                                )
                            }
                            .buttonStyle(.plain)

                            Button {
                                destination = .sleeper
                            } label: {
                                providerCard(
                                    title: "Sleeper",
                                    subtitle: "Username only · read-only sync + player intel"
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
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.leagueName)
                        .font(BrandTheme.body(15, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                        .multilineTextAlignment(.leading)
                    Text("\(link.provider.shortName) · \(link.franchiseName)")
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

    private func providerCard(title: String, subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
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
    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            Text(appState.linkedFranchise?.provider.shortName ?? "League")
                .font(BrandTheme.body(14, weight: .semibold))
                .foregroundStyle(BrandTheme.ink)
        }
        .buttonStyle(.plain)
        .confirmationDialog("Switch league", isPresented: $showPicker, titleVisibility: .visible) {
            ForEach(appState.linkedLeagues, id: \.id) { link in
                Button(dialogLabel(link)) {
                    appState.switchActiveLeague(link)
                }
            }
            Button("Add league…") {
                appState.showConnect = true
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func dialogLabel(_ link: LinkedFranchise) -> String {
        let mark = appState.linkedFranchise?.id == link.id ? "✓ " : ""
        return "\(mark)\(link.provider.shortName) · \(link.leagueName)"
    }
}
