import SwiftUI
import SwiftData
import UIKit

// MARK: - Shared chrome

private struct SettingsPageChrome<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            SidelineBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content
                }
                .padding(.horizontal, BrandTheme.pageGutter)
                .padding(.top, BrandTheme.space(12))
                .padding(.bottom, BrandTheme.space(40))
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func fieldShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
        .font(BrandTheme.body(16))
        .padding(.horizontal, BrandTheme.pageGutterTight)
        .padding(.vertical, BrandTheme.space(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                .fill(BrandTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                        .stroke(BrandTheme.hairline, lineWidth: 1)
                )
        )
}

private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title.uppercased())
            .font(BrandTheme.display(11, weight: .semibold))
            .tracking(1)
            .foregroundStyle(BrandTheme.muted)
        content()
    }
}

// MARK: - Pages

struct ThemeSettingsPage: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("sideline.appearance.darkMode") private var isDarkMode = false
    @AppStorage("sideline.liveActivity.enabled") private var liveActivityEnabled = false
    @AppStorage("sideline.propsTab.visible") private var propsTabVisible = true

    var body: some View {
        SettingsPageChrome(title: "Appearance") {
            Toggle(isOn: $isDarkMode) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dark mode")
                        .font(BrandTheme.body(16, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                    Text(isDarkMode ? "Entire app uses dark colors." : "Entire app uses light colors.")
                        .font(BrandTheme.body(13))
                        .foregroundStyle(BrandTheme.muted)
                }
            }
            .tint(BrandTheme.accent)
            .padding(.horizontal, BrandTheme.pageGutterTight)
            .padding(.vertical, BrandTheme.space(12))
            .background(
                RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                    .fill(BrandTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                            .stroke(BrandTheme.hairline, lineWidth: 1)
                    )
            )

            Toggle(isOn: $propsTabVisible) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Props tab")
                        .font(BrandTheme.body(16, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                    Text(propsTabVisible
                         ? "Shows player prop lines for your roster (Odds API)."
                         : "Hidden from the tab bar. Turn on anytime — or from the Props empty state.")
                        .font(BrandTheme.body(13))
                        .foregroundStyle(BrandTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(BrandTheme.accent)
            .padding(.horizontal, BrandTheme.pageGutterTight)
            .padding(.vertical, BrandTheme.space(12))
            .background(
                RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                    .fill(BrandTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                            .stroke(BrandTheme.hairline, lineWidth: 1)
                    )
            )
            .onChange(of: propsTabVisible) { _, visible in
                if !visible, appState.selectedTab == .props {
                    appState.selectedTab = .team
                }
            }

            Toggle(isOn: $liveActivityEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Matchup Live Activity")
                        .font(BrandTheme.body(16, weight: .semibold))
                        .foregroundStyle(BrandTheme.ink)
                    Text("Lock Screen + Dynamic Island while starters are in games. Scores refresh while Sideline is open; background updates use the Sideline live backend.")
                        .font(BrandTheme.body(13))
                        .foregroundStyle(BrandTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(BrandTheme.accent)
            .padding(.horizontal, BrandTheme.pageGutterTight)
            .padding(.vertical, BrandTheme.space(12))
            .background(
                RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                    .fill(BrandTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                            .stroke(BrandTheme.hairline, lineWidth: 1)
                    )
            )
            .onChange(of: liveActivityEnabled) { _, enabled in
                if !enabled {
                    Task { await LiveActivityManager.endAll() }
                } else if let team = appState.team, let linked = appState.linkedFranchise {
                    LiveActivityManager.setLinkedLeagueCount(appState.linkedLeagues.count)
                    LiveActivityManager.sync(
                        from: team,
                        linked: linked,
                        linkedLeagueCount: appState.linkedLeagues.count
                    )
                }
            }

            Text("Sideline ignores the system light/dark setting.")
                .font(BrandTheme.body(13))
                .foregroundStyle(BrandTheme.muted)
        }
    }
}

struct LeagueSettingsPage: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsPageChrome(title: "Leagues") {
            if appState.linkedLeagues.isEmpty {
                Text("No leagues linked.")
                    .foregroundStyle(BrandTheme.muted)
            } else {
                ForEach(appState.linkedLeagues, id: \.id) { link in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(link.provider.shortName.uppercased())
                                .font(BrandTheme.display(10, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(BrandTheme.muted)
                            if appState.linkedFranchise?.id == link.id {
                                Text("ACTIVE")
                                    .font(BrandTheme.display(10, weight: .bold))
                                    .tracking(0.8)
                                    .foregroundStyle(BrandTheme.accent)
                            }
                            Spacer()
                        }
                        meta("League", link.leagueName)
                        meta("Team", link.franchiseName)
                        meta("Season", "\(link.season)")
                        if link.isMFL {
                            meta("Host", link.host)
                        }
                        HStack(spacing: 12) {
                            if appState.linkedFranchise?.id != link.id {
                                Button("Switch") {
                                    appState.switchActiveLeague(link)
                                }
                                .buttonStyle(PrimaryButtonStyle())
                            }
                            Button("Remove") {
                                appState.removeLinkedLeague(link)
                            }
                            .font(BrandTheme.body(14, weight: .semibold))
                            .foregroundStyle(BrandTheme.danger)
                        }
                    }
                    .padding(.vertical, 8)
                    Divider().overlay(BrandTheme.hairline)
                }
            }
            Button {
                appState.showConnect = true
            } label: {
                Text("Add league")
            }
            .buttonStyle(PrimaryButtonStyle())

            Text("Sideline is a hub for MFL, Sleeper, and ESPN. Approve writes lineups only for MFL; Sleeper and ESPN stay read-only.")
                .font(BrandTheme.body(13))
                .foregroundStyle(BrandTheme.muted)
        }
    }

    private func meta(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(BrandTheme.display(11, weight: .semibold))
                .tracking(1)
                .foregroundStyle(BrandTheme.muted)
            Text(value)
                .font(BrandTheme.body(16, weight: .medium))
                .foregroundStyle(BrandTheme.ink)
        }
    }
}

struct ModelSettingsPage: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var llm: LLMSettingsStore
    @State private var saved = false
    @State private var modelSearch = ""

    private var filteredModels: [LLMModelOption] {
        let all = llm.pickerModels
        let q = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.id.localizedCaseInsensitiveContains(q)
                || $0.title.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        SettingsPageChrome(title: "Model") {
            labeledField("Provider") {
                fieldShell {
                    Picker("Provider", selection: $llm.provider) {
                        ForEach(LLMProvider.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .tint(BrandTheme.ink)
                }
            }
            .onChange(of: llm.provider) { _, newProvider in
                modelSearch = ""
                // Reset to this provider's default only when switching providers.
                llm.model = newProvider.defaultModel
                llm.reloadKeyDraft()
                llm.refreshModels(preferCheapestIfInvalid: false)
                saved = false
            }

            labeledField("Search models") {
                fieldShell {
                    TextField("Name or id…", text: $modelSearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            labeledField("Model") {
                VStack(alignment: .leading, spacing: 0) {
                    if llm.isLoadingModels {
                        HStack {
                            ProgressView()
                            Text("Loading live models…")
                                .font(BrandTheme.body(14))
                                .foregroundStyle(BrandTheme.muted)
                            Spacer()
                        }
                        .padding(.vertical, BrandTheme.space(12))
                        .padding(.horizontal, BrandTheme.pageGutterTight)
                    } else if filteredModels.isEmpty {
                        Text(modelSearch.isEmpty ? "No models loaded." : "No models match “\(modelSearch)”.")
                            .font(BrandTheme.body(14))
                            .foregroundStyle(BrandTheme.muted)
                            .padding(.vertical, BrandTheme.space(12))
                            .padding(.horizontal, BrandTheme.pageGutterTight)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(filteredModels) { option in
                                    Button {
                                        llm.model = option.id
                                        saved = false
                                    } label: {
                                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(option.title)
                                                    .font(BrandTheme.body(14, weight: llm.model == option.id ? .semibold : .medium))
                                                    .foregroundStyle(BrandTheme.ink)
                                                    .multilineTextAlignment(.leading)
                                                Text(option.id)
                                                    .font(BrandTheme.mono(11))
                                                    .foregroundStyle(BrandTheme.muted)
                                                    .lineLimit(1)
                                            }
                                            Spacer(minLength: 8)
                                            Text(option.costLabel)
                                                .font(BrandTheme.body(12, weight: .medium))
                                                .foregroundStyle(BrandTheme.muted)
                                            if llm.model == option.id {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 12, weight: .bold))
                                                    .foregroundStyle(BrandTheme.ink)
                                            }
                                        }
                                        .padding(.horizontal, BrandTheme.pageGutterTight)
                                        .padding(.vertical, BrandTheme.space(10))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    Rectangle()
                                        .fill(BrandTheme.hairline)
                                        .frame(height: 1)
                                        .padding(.leading, BrandTheme.pageGutterTight)
                                }
                            }
                        }
                        .frame(maxHeight: BrandTheme.space(280))
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                        .fill(BrandTheme.surface)
                )
            }
            .onChange(of: llm.model) { _, _ in
                saved = false
            }

            Text(llm.modelsSourceLabel)
                .font(BrandTheme.body(12))
                .foregroundStyle(BrandTheme.muted)

            Text(llm.provider.setupHint)
                .font(BrandTheme.body(12))
                .foregroundStyle(BrandTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                llm.refreshModels()
            } label: {
                Text(llm.isLoadingModels ? "Refreshing…" : "Refresh live models")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(llm.isLoadingModels)

            Button {
                UserDefaults.standard.set(llm.model, forKey: "sideline.llm.model")
                saved = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                Text(saved ? "Saved" : "Save model")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .task {
            llm.refreshModels()
        }
    }
}

struct APIKeySettingsPage: View {
    @ObservedObject var llm: LLMSettingsStore
    @State private var banner: String?
    @State private var bannerError = false
    @State private var isKeyVisible = false
    @State private var showScanner = false

    var body: some View {
        SettingsPageChrome(title: "Model API key") {
            if let banner {
                Text(banner)
                    .font(BrandTheme.body(14, weight: .medium))
                    .foregroundStyle(bannerError ? BrandTheme.danger : BrandTheme.ink)
                    .padding(BrandTheme.space(12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bannerError ? BrandTheme.danger.opacity(0.18) : BrandTheme.accentWash)
                    .clipShape(RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous))
            }

            labeledField(llm.provider.displayName) {
                fieldShell {
                    HStack(spacing: 10) {
                        Group {
                            if isKeyVisible {
                                TextField("Paste or scan API key", text: $llm.apiKeyDraft)
                            } else {
                                SecureField("Paste or scan API key", text: $llm.apiKeyDraft)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            isKeyVisible.toggle()
                        } label: {
                            Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(BrandTheme.muted)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isKeyVisible ? "Hide API key" : "Show API key")

                        Button {
                            showScanner = true
                        } label: {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(BrandTheme.ink)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Scan API key with camera")
                    }
                }
            }

            Text("Paste a key, tap the eye to reveal it, or scan a QR / on-screen key with the camera.")
                .font(BrandTheme.body(13))
                .foregroundStyle(BrandTheme.muted)

            Text(llm.maskedKeyHint)
                .font(BrandTheme.body(13))
                .foregroundStyle(BrandTheme.muted)

            Button {
                let ok = llm.saveAPIKey()
                banner = llm.keySaveMessage
                bannerError = !ok
                UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
            } label: {
                Text("Save API key")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .fullScreenCover(isPresented: $showScanner) {
            APIKeyCameraScanner(
                onScan: { value in
                    llm.apiKeyDraft = value
                    isKeyVisible = true
                    showScanner = false
                    banner = "Scanned key — tap Save API key to store it in Keychain."
                    bannerError = false
                },
                onCancel: {
                    showScanner = false
                }
            )
            .ignoresSafeArea()
        }
    }
}

struct APIsSettingsPage: View {
    private let rows: [SettingsDestination] = [.oddsAPI, .fantasyPros, .apiKey]

    var body: some View {
        SettingsPageChrome(title: "APIs") {
            Text("Keys for NFL props (Odds API), FantasyPros intel, and your LLM. Each is stored in Keychain on this device.")
                .font(BrandTheme.body(14))
                .foregroundStyle(BrandTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, dest in
                    NavigationLink(value: dest) {
                        HStack(spacing: 14) {
                            Image(systemName: dest.systemImage)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(BrandTheme.ink)
                                .frame(width: BrandTheme.space(28))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dest.title)
                                    .font(BrandTheme.body(16, weight: .semibold))
                                    .foregroundStyle(BrandTheme.ink)
                                Text(apiSubtitle(dest))
                                    .font(BrandTheme.body(12))
                                    .foregroundStyle(BrandTheme.muted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(BrandTheme.muted)
                        }
                        .padding(.vertical, BrandTheme.space(14))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < rows.count - 1 {
                        Rectangle()
                            .fill(BrandTheme.hairline)
                            .frame(height: 1)
                            .padding(.leading, BrandTheme.space(42))
                    }
                }
            }
        }
    }

    private func apiSubtitle(_ dest: SettingsDestination) -> String {
        switch dest {
        case .apiKey: return "OpenAI, Anthropic, Google, OpenRouter…"
        case .fantasyPros: return "Ranks, projections, player notes"
        case .oddsAPI: return "NFL player props (yards, TDs, catches)"
        default: return ""
        }
    }
}

struct OddsAPISettingsPage: View {
    @EnvironmentObject private var appState: AppState
    @State private var apiKeyDraft = KeychainStore.get(.oddsAPIKey) ?? ""
    @State private var isKeyVisible = false
    @State private var banner: String?
    @State private var bannerError = false
    @State private var isTesting = false
    @State private var showScanner = false

    var body: some View {
        SettingsPageChrome(title: "Odds API") {
            if let banner {
                Text(banner)
                    .font(BrandTheme.body(14, weight: .medium))
                    .foregroundStyle(bannerError ? BrandTheme.danger : BrandTheme.ink)
                    .padding(BrandTheme.space(12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bannerError ? BrandTheme.danger.opacity(0.18) : BrandTheme.accentWash)
                    .clipShape(RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous))
            }

            Text("The Odds API supplies NFL player props (pass/rush/receiving yards, receptions, anytime TD) for the Analysis tab and player sheet. Sideline only fetches games your roster is in to save quota.")
                .font(BrandTheme.body(14))
                .foregroundStyle(BrandTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("API KEY")
                    .font(BrandTheme.display(11, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(BrandTheme.muted)
                HStack(spacing: 10) {
                    Group {
                        if isKeyVisible {
                            TextField("Paste or scan API key", text: $apiKeyDraft)
                        } else {
                            SecureField("Paste or scan API key", text: $apiKeyDraft)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(BrandTheme.body(16))
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        isKeyVisible.toggle()
                    } label: {
                        Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(BrandTheme.muted)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        showScanner = true
                    } label: {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(BrandTheme.ink)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, BrandTheme.pageGutterTight)
                .padding(.vertical, BrandTheme.space(14))
                .background(BrandTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                        .stroke(BrandTheme.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous))
            }

            Text("Free keys at the-odds-api.com. Player props cost ~6 credits per game (markets × US region). Sideline caches for an hour (1 minute while games are live) and skips games your roster isn’t in.")
                .font(BrandTheme.body(13))
                .foregroundStyle(BrandTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let wrote = KeychainStore.set(trimmed.isEmpty ? nil : trimmed, for: .oddsAPIKey)
                let saved = KeychainStore.get(.oddsAPIKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let ok: Bool
                if trimmed.isEmpty {
                    ok = wrote && saved == nil
                    banner = ok ? "API key cleared." : "Couldn’t clear Keychain — try again."
                } else if trimmed.count < 8 {
                    ok = false
                    banner = "Key looks too short."
                } else {
                    ok = wrote && saved == trimmed
                    banner = ok ? "Odds API key saved." : "Couldn’t save API key to Keychain — try again."
                }
                bannerError = !ok
                UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
                if ok {
                    Task { await OddsIntelService.shared.reset() }
                }
            } label: {
                Text("Save")
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                Task { await testConnection() }
            } label: {
                Text(isTesting ? "Testing…" : "Test connection")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(isTesting || apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 8)

            Text("After saving, open Props or a player profile — props attach by player name for that game.")
                .font(BrandTheme.body(13))
                .foregroundStyle(BrandTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fullScreenCover(isPresented: $showScanner) {
            APIKeyCameraScanner(
                onScan: { value in
                    apiKeyDraft = value
                    isKeyVisible = true
                    showScanner = false
                    banner = "Scanned key — tap Save to store it in Keychain."
                    bannerError = false
                },
                onCancel: {
                    showScanner = false
                }
            )
            .ignoresSafeArea()
        }
        .task {
            // Don’t clobber a fresh save/test banner with a stale “No Odds API key”.
            if banner != nil { return }
            let status = await OddsIntelService.shared.lastStatus
            if let status, !status.isEmpty, status != "No Odds API key" {
                banner = status
                bannerError = await OddsIntelService.shared.lastWasError
            }
        }
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else {
            banner = "Paste an Odds API key first."
            bannerError = true
            return
        }
        let wrote = KeychainStore.set(trimmed, for: .oddsAPIKey)
        let saved = KeychainStore.get(.oddsAPIKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wrote, saved == trimmed, OddsAPIClient.hasAPIKey else {
            banner = "Couldn’t save API key to Keychain — try again."
            bannerError = true
            return
        }
        await OddsIntelService.shared.reset()
        let roster = (appState.team?.starters ?? []) + (appState.team?.bench ?? [])
        let season = appState.linkedFranchise?.season ?? Calendar.current.mflSeason
        let week = max(1, appState.team?.week ?? appState.selectedWeek)
        await OddsIntelService.shared.ensureLoaded(
            players: roster,
            season: season,
            week: week,
            isHistoric: appState.isViewingHistoricWeek,
            hasLiveGames: false
        )
        banner = await OddsIntelService.shared.lastStatus ?? "Connected."
        bannerError = await OddsIntelService.shared.lastWasError
        if banner == "No Odds API key" {
            banner = "Keychain save looked fine, but the client still can’t see the key. Force-quit Sideline and try again."
            bannerError = true
        }
    }
}

struct FantasyProsSettingsPage: View {
    @EnvironmentObject private var appState: AppState
    @State private var apiKeyDraft = KeychainStore.get(.fantasyProsAPIKey) ?? ""
    @State private var isKeyVisible = false
    @State private var scoring = FantasyProsClient.scoring
    @State private var banner: String?
    @State private var bannerError = false
    @State private var isTesting = false
    @State private var showScanner = false

    var body: some View {
        SettingsPageChrome(title: "FantasyPros") {
            if let banner {
                Text(banner)
                    .font(BrandTheme.body(14, weight: .medium))
                    .foregroundStyle(bannerError ? BrandTheme.danger : BrandTheme.ink)
                    .padding(BrandTheme.space(12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bannerError ? BrandTheme.danger.opacity(0.18) : BrandTheme.accentWash)
                    .clipShape(RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous))
            }

            Text("Sideline joins FantasyPros to MFL, Sleeper, and ESPN via the DynastyProcess player-ID map, so ranks, projections, and news attach the same way in every league. Your API key powers the data; the crosswalk powers the matching.")
                .font(BrandTheme.body(14))
                .foregroundStyle(BrandTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("API KEY")
                    .font(BrandTheme.display(11, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(BrandTheme.muted)
                HStack(spacing: 10) {
                    Group {
                        if isKeyVisible {
                            TextField("Paste or scan API key", text: $apiKeyDraft)
                        } else {
                            SecureField("Paste or scan API key", text: $apiKeyDraft)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(BrandTheme.body(16))
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        isKeyVisible.toggle()
                    } label: {
                        Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(BrandTheme.muted)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isKeyVisible ? "Hide API key" : "Show API key")

                    Button {
                        showScanner = true
                    } label: {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(BrandTheme.ink)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Scan FantasyPros API key with camera")
                }
                .padding(.horizontal, BrandTheme.pageGutterTight)
                .padding(.vertical, BrandTheme.space(14))
                .background(BrandTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                        .stroke(BrandTheme.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous))
            }

            Text("Paste a key, tap the eye to reveal it, or scan a QR / on-screen key. Request one at fantasypros.com/api-data — stored only in Keychain on this device.")
                .font(BrandTheme.body(13))
                .foregroundStyle(BrandTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("SCORING")
                    .font(BrandTheme.display(11, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(BrandTheme.muted)
                Picker("Scoring", selection: $scoring) {
                    ForEach(FantasyProsScoring.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: scoring) { _, newValue in
                    FantasyProsClient.scoring = newValue
                }
            }

            Button {
                let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                KeychainStore.set(trimmed.isEmpty ? nil : trimmed, for: .fantasyProsAPIKey)
                FantasyProsClient.scoring = scoring
                let ok = trimmed.isEmpty || trimmed.count >= 8
                banner = trimmed.isEmpty ? "API key cleared." : (ok ? "FantasyPros key saved." : "Key looks too short.")
                bannerError = !ok && !trimmed.isEmpty
                UINotificationFeedbackGenerator().notificationOccurred(bannerError ? .error : .success)
                if ok {
                    Task { await FantasyProsIntelService.shared.reset() }
                }
            } label: {
                Text("Save")
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                Task { await testConnection() }
            } label: {
                Text(isTesting ? "Testing…" : "Test connection")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(isTesting || apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 8)

            Text("After saving, open a player profile or pull to refresh Team — FantasyPros ranks/projections attach there. Notes load on the player sheet (FantasyPros news for that player).")
                .font(BrandTheme.body(13))
                .foregroundStyle(BrandTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fullScreenCover(isPresented: $showScanner) {
            APIKeyCameraScanner(
                onScan: { value in
                    apiKeyDraft = value
                    isKeyVisible = true
                    showScanner = false
                    banner = "Scanned key — tap Save to store it in Keychain."
                    bannerError = false
                },
                onCancel: {
                    showScanner = false
                }
            )
            .ignoresSafeArea()
        }
        .task {
            await refreshStatusBanner()
        }
    }

    private func refreshStatusBanner() async {
        let status = await FantasyProsIntelService.shared.lastStatus
        let ok = await FantasyProsIntelService.shared.hasData
        let quota = await FantasyProsIntelService.shared.lastWasQuotaError
        guard let status, !status.isEmpty else { return }
        // Don't clobber an in-progress save/scan message unless it's an error/quota.
        if banner == nil || quota || !ok {
            banner = status
            bannerError = !ok || quota
        }
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            KeychainStore.set(trimmed, for: .fantasyProsAPIKey)
        }
        await FantasyProsIntelService.shared.reset()
        let season = appState.linkedFranchise?.season ?? Calendar.current.mflSeason
        let week = max(1, appState.team?.week ?? appState.selectedWeek)
        await FantasyProsIntelService.shared.ensureLoaded(season: season, week: week)
        if let status = await FantasyProsIntelService.shared.lastStatus {
            let ok = await FantasyProsIntelService.shared.hasData
            let quota = await FantasyProsIntelService.shared.lastWasQuotaError
            banner = status
            bannerError = !ok || quota
        } else {
            banner = "Connected."
            bannerError = false
        }
    }
}

struct TeamGoalsSettingsPage: View {
    @EnvironmentObject private var appState: AppState
    @State private var saved = false

    var body: some View {
        SettingsPageChrome(title: "Team goals") {
            Text("Shared context and hard limits for every agent desk.")
                .font(BrandTheme.body(14))
                .foregroundStyle(BrandTheme.muted)

            labeledField("Season goals") {
                fieldShell {
                    TextField(
                        "e.g. Win the championship, upgrade RB2, protect FAAB",
                        text: $appState.agentCriteria.teamGoals,
                        axis: .vertical
                    )
                    .lineLimit(4...8)
                }
            }

            Text("LIMITS & GUARDRAILS")
                .font(BrandTheme.display(11, weight: .semibold))
                .tracking(1)
                .foregroundStyle(BrandTheme.muted)
                .padding(.top, 8)

            HStack {
                Text("Max FAAB bid")
                    .font(BrandTheme.body(16))
                    .foregroundStyle(BrandTheme.ink)
                Spacer()
                TextField("None", value: $appState.guardrails.maxFAABBid, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: BrandTheme.space(100))
                    .padding(BrandTheme.space(10))
                    .background(
                        RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                            .fill(BrandTheme.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                                    .stroke(BrandTheme.hairline, lineWidth: 1)
                            )
                    )
            }

            Stepper(value: $appState.guardrails.stopHoursBeforeKickoff, in: 0...12, step: 1) {
                Text("Stop \(Int(appState.guardrails.stopHoursBeforeKickoff))h before kickoff")
            }

            Text("Player lock lists (never bench / drop / trade) can be expanded next — IDs are stored in guardrails.")
                .font(BrandTheme.body(13))
                .foregroundStyle(BrandTheme.muted)

            Button {
                appState.saveAgentCriteria()
                appState.saveGuardrails()
                saved = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                Text(saved ? "Saved" : "Save")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}

struct AgentCriteriaListPage: View {
    var body: some View {
        ZStack {
            SidelineBackground()
            List {
                NavigationLink("Lineup desk") { LineupCriteriaPage() }
                NavigationLink("Waiver / FA desk") { WaiverCriteriaPage() }
                NavigationLink("Trade desk") { TradeCriteriaPage() }
                NavigationLink("Draft desk") { DraftCriteriaPage() }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Agent criteria")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LineupCriteriaPage: View {
    @EnvironmentObject private var appState: AppState
    @State private var saved = false

    var body: some View {
        SettingsPageChrome(title: "Lineup") {
            Text("Builds a legal week lineup from league starter slots, respects game locks (won't newly start players who already played), and adjusts IR/taxi when needed.")
                .font(BrandTheme.body(13))
                .foregroundStyle(BrandTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            criteriaEditor(
                goal: $appState.agentCriteria.lineup.goal,
                risk: $appState.agentCriteria.lineup.riskTolerance,
                notes: $appState.agentCriteria.lineup.notes
            )
            Toggle("Prefer ceiling over floor", isOn: $appState.agentCriteria.lineup.preferCeiling)
                .tint(BrandTheme.accent)
            Toggle("Avoid questionable starts", isOn: $appState.agentCriteria.lineup.avoidQuestionable)
                .tint(BrandTheme.accent)
            labeledField("Stack preference") {
                fieldShell {
                    TextField("Optional", text: $appState.agentCriteria.lineup.stackPreference)
                }
            }
            saveButton
        }
    }

    private var saveButton: some View {
        Button {
            appState.saveAgentCriteria()
            saved = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } label: { Text(saved ? "Saved" : "Save lineup criteria") }
        .buttonStyle(PrimaryButtonStyle())
    }
}

struct WaiverCriteriaPage: View {
    @EnvironmentObject private var appState: AppState
    @State private var saved = false

    var body: some View {
        SettingsPageChrome(title: "Waivers") {
            Text("Uses league-relative positional strength (weak vs strong by position), roster setup, and top free agents (YTD + last week) to propose concrete add/drops.")
                .font(BrandTheme.body(13))
                .foregroundStyle(BrandTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            criteriaEditor(
                goal: $appState.agentCriteria.waiver.goal,
                risk: $appState.agentCriteria.waiver.riskTolerance,
                notes: $appState.agentCriteria.waiver.notes
            )
            VStack(alignment: .leading, spacing: 8) {
                Text("Max FAAB % of budget: \(Int(appState.agentCriteria.waiver.maxFAABPercent))%")
                    .font(BrandTheme.body(14))
                Slider(value: $appState.agentCriteria.waiver.maxFAABPercent, in: 0...100, step: 5)
                    .tint(BrandTheme.accent)
            }
            Toggle("Prioritize need over best available", isOn: $appState.agentCriteria.waiver.prioritizeNeedOverBestAvailable)
                .tint(BrandTheme.accent)
            Toggle("Stash handcuffs", isOn: $appState.agentCriteria.waiver.stashHandcuffs)
                .tint(BrandTheme.accent)
            Button {
                appState.saveAgentCriteria()
                saved = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: { Text(saved ? "Saved" : "Save waiver criteria") }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}

struct TradeCriteriaPage: View {
    @EnvironmentObject private var appState: AppState
    @State private var saved = false

    var body: some View {
        SettingsPageChrome(title: "Trades") {
            Text("Uses positional strength vs the league plus draft pick assets to propose player and/or pick trades.")
                .font(BrandTheme.body(13))
                .foregroundStyle(BrandTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            criteriaEditor(
                goal: $appState.agentCriteria.trade.goal,
                risk: $appState.agentCriteria.trade.riskTolerance,
                notes: $appState.agentCriteria.trade.notes
            )
            labeledField("Mode") {
                fieldShell {
                    Picker("Mode", selection: $appState.agentCriteria.trade.contendMode) {
                        ForEach(ContendMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .tint(BrandTheme.ink)
                }
            }
            Toggle("Prefer sideways moves over panic sells", isOn: $appState.agentCriteria.trade.preferSidewaysOverPanic)
                .tint(BrandTheme.accent)
            labeledField("Target positions") {
                fieldShell {
                    TextField("e.g. RB depth, WR1", text: $appState.agentCriteria.trade.targetPositions)
                }
            }
            Button {
                appState.saveAgentCriteria()
                saved = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: { Text(saved ? "Saved" : "Save trade criteria") }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}

struct DraftCriteriaPage: View {
    @EnvironmentObject private var appState: AppState
    @State private var saved = false

    var body: some View {
        SettingsPageChrome(title: "Draft") {
            Text("Advises the next pick from remaining needs and early/late round bias.")
                .font(BrandTheme.body(13))
                .foregroundStyle(BrandTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            criteriaEditor(
                goal: $appState.agentCriteria.draft.goal,
                risk: $appState.agentCriteria.draft.riskTolerance,
                notes: $appState.agentCriteria.draft.notes
            )
            labeledField("Early rounds") {
                fieldShell {
                    TextField("Bias", text: $appState.agentCriteria.draft.earlyRoundBias, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            labeledField("Late rounds") {
                fieldShell {
                    TextField("Bias", text: $appState.agentCriteria.draft.lateRoundBias, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            Button {
                appState.saveAgentCriteria()
                saved = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: { Text(saved ? "Saved" : "Save draft criteria") }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}

struct ActivitySettingsPage: View {
    @Query(sort: \ActivityEvent.createdAt, order: .reverse) private var events: [ActivityEvent]

    var body: some View {
        SettingsPageChrome(title: "Activity") {
            if events.isEmpty {
                Text("No activity yet")
                    .foregroundStyle(BrandTheme.muted)
            } else {
                ForEach(events.prefix(40)) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.message)
                            .font(BrandTheme.body(14, weight: .medium))
                        Text(event.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(BrandTheme.body(11))
                            .foregroundStyle(BrandTheme.muted)
                    }
                    .padding(.vertical, BrandTheme.space(6))
                    Divider().overlay(BrandTheme.hairline)
                }
            }
        }
    }
}

struct AccountSettingsPage: View {
    @EnvironmentObject private var appState: AppState
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

    var body: some View {
        SettingsPageChrome(title: "Account") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Delete account")
                    .font(BrandTheme.body(18, weight: .semibold))
                    .foregroundStyle(BrandTheme.ink)

                Text(
                    """
                    Deleting your account permanently removes Sideline data stored on this device — your sign-in, connected leagues, API keys, preferences, agent activity, and saved proposals.

                    Sideline doesn’t keep a separate cloud account. After deletion you’ll return to the welcome screen and need to sign in again to start fresh. This can’t be undone.
                    """
                )
                .font(BrandTheme.body(14))
                .foregroundStyle(BrandTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Text(isDeleting ? "Deleting…" : "Delete account")
                        .font(BrandTheme.body(16, weight: .semibold))
                        .foregroundStyle(BrandTheme.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BrandTheme.space(14))
                        .background(BrandTheme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                                .stroke(BrandTheme.danger.opacity(0.35), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isDeleting)
                .opacity(isDeleting ? 0.5 : 1)
                .padding(.top, BrandTheme.space(4))
            }
            .padding(BrandTheme.pageGutterCompact)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                    .fill(BrandTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                            .stroke(BrandTheme.hairline, lineWidth: 1)
                    )
            )
        }
        .confirmationDialog(
            "Delete your Sideline account?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) {
                Task {
                    isDeleting = true
                    await appState.deleteAccount()
                    isDeleting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All Sideline data on this device will be permanently removed.")
        }
    }
}

struct AboutDeveloperSettingsPage: View {
    /// Opens in the system browser (not in-app). Required for optional support
    /// payments outside In-App Purchase on the US storefront.
    private static let coffeeURL = URL(string: "https://venmo.com/u/CPF32")!

    var body: some View {
        SettingsPageChrome(title: "About") {
            Text("Hey — I’m Chris")
                .font(BrandTheme.display(26, weight: .bold))
                .foregroundStyle(BrandTheme.ink)

            Text(
                """
                I’m a software engineer who got stuck in an overly complicated league with my college friends. As a way to make life easier (and make sure I set a fairly competitive lineup every week), I created Sideline.

                It’s totally free to use. If you want to buy me a cup of coffee, I’d appreciate it.
                """
            )
            .font(BrandTheme.body(15))
            .foregroundStyle(BrandTheme.ink)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                UIApplication.shared.open(Self.coffeeURL, options: [:], completionHandler: nil)
            } label: {
                Text("Buy me a coffee")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }
}

// MARK: - Shared criteria fields

private func criteriaEditor(
    goal: Binding<String>,
    risk: Binding<RiskTolerance>,
    notes: Binding<String>
) -> some View {
    VStack(alignment: .leading, spacing: 16) {
        labeledField("Goal") {
            fieldShell {
                TextField("What should this desk optimize for?", text: goal, axis: .vertical)
                    .lineLimit(3...6)
            }
        }
        labeledField("Risk") {
            fieldShell {
                Picker("Risk", selection: risk) {
                    ForEach(RiskTolerance.allCases) { r in
                        Text(r.title).tag(r)
                    }
                }
                .labelsHidden()
                .tint(BrandTheme.ink)
            }
        }
        labeledField("Notes") {
            fieldShell {
                TextField("Extra instructions", text: notes, axis: .vertical)
                    .lineLimit(2...5)
            }
        }
    }
}
