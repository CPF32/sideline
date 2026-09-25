import SwiftUI

struct ConnectESPNView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var leagueId = ""
    @State private var seasonText = "\(Calendar.current.mflSeason)"
    @State private var espnS2 = KeychainStore.get(.espnS2) ?? ""
    @State private var swid = KeychainStore.get(.espnSWID) ?? ""
    @State private var showCookieHelp = false

    @State private var probe: ESPNLeagueProbe?
    @State private var selectedTeamId: Int?
    @State private var isLoading = false
    @State private var error: String?
    @State private var step: Step = .league

    private enum Step {
        case league
        case pickTeam
    }

    var body: some View {
        ZStack {
            SidelineBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(step == .league ? "Connect ESPN league" : "Choose your team")
                            .font(BrandTheme.display(24, weight: .bold))
                            .foregroundStyle(BrandTheme.ink)
                        Text(
                            step == .league
                            ? "Paste the league ID from your fantasy.espn.com URL. Public leagues need only the ID; private leagues also need espn_s2 and SWID cookies."
                            : "Pick your franchise. Sideline reads rosters and scores — lineup changes stay in the ESPN app."
                        )
                        .font(BrandTheme.body(14))
                        .foregroundStyle(BrandTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if step == .league {
                        leagueBlock
                    } else {
                        teamPickerBlock
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
                Text("ESPN")
                    .font(BrandTheme.display(16, weight: .bold))
                    .tracking(1)
            }
            if step == .pickTeam {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Back") {
                        step = .league
                        probe = nil
                        selectedTeamId = nil
                        error = nil
                    }
                    .foregroundStyle(BrandTheme.muted)
                }
            }
        }
    }

    private var leagueBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldLabel("LEAGUE ID")
            TextField("e.g. 123456789", text: $leagueId)
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(BrandTheme.body(16))
                .padding(14)
                .background(fieldBackground)

            fieldLabel("SEASON")
            TextField("2025", text: $seasonText)
                .keyboardType(.numberPad)
                .font(BrandTheme.body(16))
                .padding(14)
                .background(fieldBackground)

            DisclosureGroup(isExpanded: $showCookieHelp) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("On a desktop browser: log into fantasy.espn.com → DevTools → Application → Cookies → copy espn_s2 and SWID. Required for private leagues.")
                        .font(BrandTheme.body(13))
                        .foregroundStyle(BrandTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    fieldLabel("espn_s2 (optional)")
                    TextField("cookie value", text: $espnS2)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(BrandTheme.body(14))
                        .padding(14)
                        .background(fieldBackground)

                    fieldLabel("SWID (optional)")
                    TextField("{XXXXXXXX-…}", text: $swid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(BrandTheme.body(14))
                        .padding(14)
                        .background(fieldBackground)
                }
                .padding(.top, 8)
            } label: {
                Text("Private league cookies")
                    .font(BrandTheme.body(14, weight: .semibold))
                    .foregroundStyle(BrandTheme.ink)
            }

            Button {
                Task { await lookup() }
            } label: {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Find league")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(leagueId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
        }
    }

    private var teamPickerBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let probe {
                Text(probe.name)
                    .font(BrandTheme.body(15, weight: .semibold))
                    .foregroundStyle(BrandTheme.ink)
                Text("Season \(probe.season) · week \(probe.scoringPeriodId)")
                    .font(BrandTheme.body(13))
                    .foregroundStyle(BrandTheme.muted)

                if probe.teams.isEmpty {
                    Text("No teams found in this league.")
                        .font(BrandTheme.body(14))
                        .foregroundStyle(BrandTheme.muted)
                } else {
                    ForEach(probe.teams) { team in
                        let isSuggested = selectedTeamId == team.teamId
                        Button {
                            appState.selectESPNLeague(probe: probe, team: team)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(team.name)
                                        .font(BrandTheme.body(16, weight: .semibold))
                                        .foregroundStyle(BrandTheme.ink)
                                        .multilineTextAlignment(.leading)
                                    Text("\(team.wins)-\(team.losses)\(team.ties > 0 ? "-\(team.ties)" : "") · Team \(team.teamId)")
                                        .font(BrandTheme.body(13))
                                        .foregroundStyle(BrandTheme.muted)
                                }
                                Spacer()
                                if isSuggested {
                                    Text("YOU")
                                        .font(BrandTheme.display(10, weight: .bold))
                                        .tracking(0.8)
                                        .foregroundStyle(BrandTheme.accent)
                                }
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(BrandTheme.accent)
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                                    .fill(BrandTheme.surface)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                                            .stroke(
                                                isSuggested ? BrandTheme.accent.opacity(0.55) : BrandTheme.hairline,
                                                lineWidth: 1
                                            )
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(BrandTheme.display(11, weight: .semibold))
            .tracking(1)
            .foregroundStyle(BrandTheme.muted)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
            .fill(BrandTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                    .stroke(BrandTheme.hairline, lineWidth: 1)
            )
    }

    private func lookup() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        let season = Int(seasonText.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? Calendar.current.mflSeason
        do {
            let result = try await appState.connectESPN(
                leagueId: leagueId,
                season: season,
                espnS2: espnS2,
                swid: swid
            )
            probe = result.probe
            selectedTeamId = result.suggestedTeam?.teamId
            step = .pickTeam
        } catch {
            self.error = error.localizedDescription
        }
    }
}
