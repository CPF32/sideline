import SwiftUI

struct ConnectESPNView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var leagueId = ""
    @State private var seasonText = "\(Calendar.current.mflSeason)"
    @State private var espnS2 = KeychainStore.get(.espnS2) ?? ""
    @State private var swid = KeychainStore.get(.espnSWID) ?? ""
    @State private var showCookieHelp = false
    @State private var scanTarget: CookieScanTarget?
    @State private var scanBanner: String?

    @State private var probe: ESPNLeagueProbe?
    @State private var selectedTeamId: Int?
    @State private var isLoading = false
    @State private var error: String?
    @State private var step: Step = .league

    private enum Step {
        case league
        case pickTeam
    }

    private enum CookieScanTarget: String, Identifiable {
        case espnS2
        case swid

        var id: String { rawValue }
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
        .fullScreenCover(item: $scanTarget) { target in
            APIKeyCameraScanner(
                onScan: { value in
                    applyScannedCookies(value, prefer: target)
                    scanTarget = nil
                },
                onCancel: {
                    scanTarget = nil
                },
                title: target == .swid ? "Scan SWID" : "Scan ESPN cookie",
                hint: "Point at a QR code or the cookie text",
                requireAPIKeyShape: false
            )
            .ignoresSafeArea()
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
                    Text("On a desktop browser: log into fantasy.espn.com → DevTools → Application → Cookies → copy espn_s2 and SWID, or scan either value with the camera on the fields below. Required for private leagues.")
                        .font(BrandTheme.body(13))
                        .foregroundStyle(BrandTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    if let scanBanner {
                        Text(scanBanner)
                            .font(BrandTheme.body(13, weight: .medium))
                            .foregroundStyle(BrandTheme.ink)
                            .padding(BrandTheme.space(10))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(BrandTheme.accentWash)
                            .clipShape(RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous))
                    }

                    fieldLabel("espn_s2 (optional)")
                    cookieField(text: $espnS2, placeholder: "cookie value", scan: .espnS2)

                    fieldLabel("SWID (optional)")
                    cookieField(text: $swid, placeholder: "{XXXXXXXX-…}", scan: .swid)
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

    private func cookieField(text: Binding<String>, placeholder: String, scan: CookieScanTarget) -> some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(BrandTheme.body(14))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                scanTarget = scan
            } label: {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(BrandTheme.ink)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(scan == .swid ? "Scan SWID with camera" : "Scan espn_s2 with camera")
        }
        .padding(14)
        .background(fieldBackground)
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

    private func applyScannedCookies(_ raw: String, prefer: CookieScanTarget) {
        let parsed = Self.parseESPNCookiePayload(raw)
        var filled: [String] = []

        if let s2 = parsed.espnS2, !s2.isEmpty {
            espnS2 = s2
            filled.append("espn_s2")
        }
        if let sw = parsed.swid, !sw.isEmpty {
            swid = sw
            filled.append("SWID")
        }

        if filled.isEmpty {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            switch prefer {
            case .espnS2:
                espnS2 = trimmed
                filled.append("espn_s2")
            case .swid:
                swid = trimmed
                filled.append("SWID")
            }
        }

        showCookieHelp = true
        scanBanner = "Scanned \(filled.joined(separator: " + ")). Tap Find league when ready."
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Accepts cookie-header, labeled lines, JSON, or a bare value.
    static func parseESPNCookiePayload(_ raw: String) -> (espnS2: String?, swid: String?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (nil, nil) }

        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let s2 = stringValue(obj["espn_s2"] ?? obj["espnS2"] ?? obj["ESPN_S2"])
            let sw = stringValue(obj["SWID"] ?? obj["swid"] ?? obj["Swid"])
            if s2 != nil || sw != nil {
                return (s2, sw.map(normalizeSWID))
            }
        }

        var s2: String?
        var sw: String?

        // Cookie header / query style: espn_s2=…; SWID={…}
        let pairs = text.split(whereSeparator: { $0 == ";" || $0 == "\n" || $0 == "," })
        for pair in pairs {
            let part = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = part.firstIndex(of: "=") ?? part.firstIndex(of: ":") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'{"))
                .lowercased()
            let value = part[part.index(after: eq)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if key == "espn_s2" || key == "espns2" {
                s2 = String(value)
            } else if key == "swid" {
                sw = normalizeSWID(String(value))
            }
        }

        if s2 == nil, sw == nil, looksLikeSWID(text) {
            sw = normalizeSWID(text)
        }

        return (s2, sw)
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    private static func looksLikeSWID(_ value: String) -> Bool {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = t.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        // UUID shape
        let parts = bare.split(separator: "-")
        return parts.count == 5 && bare.count >= 32
    }

    private static func normalizeSWID(_ value: String) -> String {
        var sw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sw.hasPrefix("{") { sw = "{\(sw)" }
        if !sw.hasSuffix("}") { sw = "\(sw)}" }
        return sw
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
