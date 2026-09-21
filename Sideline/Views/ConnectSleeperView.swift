import SwiftUI

struct ConnectSleeperView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var username = KeychainStore.get(.sleeperUsername) ?? ""
    @State private var leagues: [SleeperLeagueSummary] = []
    @State private var sleeperUser: SleeperUser?
    @State private var isLoading = false
    @State private var error: String?
    @State private var step: Step = .username

    private enum Step {
        case username
        case pickLeague
    }

    var body: some View {
        ZStack {
            SidelineBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(step == .username ? "Find your Sleeper user" : "Choose a Sleeper league")
                            .font(BrandTheme.display(24, weight: .bold))
                            .foregroundStyle(BrandTheme.ink)
                        Text(
                            step == .username
                            ? "Enter your Sleeper username (public). No password — Sideline reads leagues and rosters from the Sleeper API."
                            : "Pick a league to add to your hub. You can connect more anytime."
                        )
                        .font(BrandTheme.body(14))
                        .foregroundStyle(BrandTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if step == .username {
                        usernameBlock
                    } else {
                        leaguePickerBlock
                    }

                    if let error {
                        Text(error)
                            .font(BrandTheme.body(13))
                            .foregroundStyle(BrandTheme.danger)
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
                Text("SLEEPER")
                    .font(BrandTheme.display(16, weight: .bold))
                    .tracking(1)
            }
            if step == .pickLeague {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Back") {
                        step = .username
                        leagues = []
                        error = nil
                    }
                    .foregroundStyle(BrandTheme.muted)
                }
            }
        }
    }

    private var usernameBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("USERNAME")
                .font(BrandTheme.display(11, weight: .semibold))
                .tracking(1)
                .foregroundStyle(BrandTheme.muted)
            TextField("your_sleeper_name", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(BrandTheme.body(16))
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                        .fill(BrandTheme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                                .stroke(BrandTheme.hairline, lineWidth: 1)
                        )
                )

            Button {
                Task { await lookup() }
            } label: {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Find leagues")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
        }
    }

    private var leaguePickerBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if leagues.isEmpty {
                Text("No NFL leagues found for this user this season.")
                    .font(BrandTheme.body(14))
                    .foregroundStyle(BrandTheme.muted)
            } else {
                ForEach(leagues) { league in
                    Button {
                        guard let user = sleeperUser else { return }
                        appState.selectSleeperLeague(league, user: user)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(league.name)
                                    .font(BrandTheme.body(16, weight: .semibold))
                                    .foregroundStyle(BrandTheme.ink)
                                    .multilineTextAlignment(.leading)
                                Text(league.franchiseName.isEmpty ? "Your roster" : league.franchiseName)
                                    .font(BrandTheme.body(13))
                                    .foregroundStyle(BrandTheme.muted)
                            }
                            Spacer()
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(BrandTheme.accent)
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
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func lookup() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let result = try await appState.connectSleeper(username: username)
            sleeperUser = result.user
            leagues = result.leagues
            step = .pickLeague
        } catch {
            self.error = error.localizedDescription
        }
    }
}
