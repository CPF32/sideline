import SwiftUI

struct ConnectMFLView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var username = KeychainStore.get(.mflUsername) ?? ""
    @State private var password = ""
    @State private var leagues: [MFLLeagueSummary] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var step: ConnectStep = .credentials

    private enum ConnectStep {
        case credentials
        case pickLeague
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SidelineBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header

                        if step == .credentials {
                            credentialsBlock
                        } else {
                            leaguePickerBlock
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("CONNECT MFL")
                        .font(BrandTheme.display(16, weight: .bold))
                        .tracking(1)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(BrandTheme.ink)
                }
                if step == .pickLeague {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Back") {
                            step = .credentials
                            leagues = []
                            error = nil
                        }
                        .foregroundStyle(BrandTheme.muted)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(step == .credentials ? "Sign in to MyFantasyLeague" : "Choose your franchise")
                .font(BrandTheme.display(26, weight: .bold))
                .foregroundStyle(BrandTheme.ink)
            Text(
                step == .credentials
                ? "Password is used once for a session cookie. Sideline never writes to MFL until you Approve."
                : "Pick the league and franchise Sideline should manage."
            )
            .font(BrandTheme.body(14))
            .foregroundStyle(BrandTheme.muted)
            .fixedSize(horizontal: false, vertical: true)

            // Step indicator
            HStack(spacing: 8) {
                stepDot(active: true, label: "1")
                Rectangle()
                    .fill(BrandTheme.hairline)
                    .frame(height: 1)
                stepDot(active: step == .pickLeague, label: "2")
            }
            .padding(.top, 8)
            HStack {
                Text("Sign in")
                    .font(BrandTheme.body(11, weight: .medium))
                    .foregroundStyle(BrandTheme.ink)
                Spacer()
                Text("Pick league")
                    .font(BrandTheme.body(11, weight: .medium))
                    .foregroundStyle(step == .pickLeague ? BrandTheme.ink : BrandTheme.muted)
            }
        }
    }

    private func stepDot(active: Bool, label: String) -> some View {
        Text(label)
            .font(BrandTheme.body(11, weight: .bold))
            .foregroundStyle(active ? BrandTheme.onAccent : BrandTheme.muted)
            .frame(width: 24, height: 24)
            .background(active ? BrandTheme.accent : BrandTheme.surfaceStrong)
            .clipShape(Circle())
    }

    private var credentialsBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldGroup(title: "Username") {
                TextField("MFL username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
            }

            fieldGroup(title: "Password") {
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }

            if let error {
                Text(error)
                    .font(BrandTheme.body(13))
                    .foregroundStyle(BrandTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await login() }
            } label: {
                HStack(spacing: 8) {
                    if isLoading { ProgressView().tint(BrandTheme.ink) }
                    Text(isLoading ? "Signing in…" : "Continue")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(enabled: canSubmit))
            .disabled(!canSubmit)

            Text("api.myfantasyleague.com · HTTPS")
                .font(BrandTheme.body(11))
                .foregroundStyle(BrandTheme.muted)
        }
    }

    private var leaguePickerBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if leagues.isEmpty {
                Text("No leagues found for this account.")
                    .font(BrandTheme.body(14))
                    .foregroundStyle(BrandTheme.muted)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(leagues.enumerated()), id: \.element.id) { index, league in
                    Button {
                        appState.selectLeague(league)
                        dismiss()
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(league.name)
                                    .font(BrandTheme.body(16, weight: .semibold))
                                    .foregroundStyle(BrandTheme.ink)
                                    .multilineTextAlignment(.leading)
                                Text("\(league.franchiseName)  ·  \(league.leagueId)")
                                    .font(BrandTheme.body(12))
                                    .foregroundStyle(BrandTheme.muted)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(BrandTheme.muted)
                        }
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < leagues.count - 1 {
                        Rectangle()
                            .fill(BrandTheme.hairline)
                            .frame(height: 1)
                    }
                }
            }

            if let error {
                Text(error)
                    .font(BrandTheme.body(13))
                    .foregroundStyle(BrandTheme.danger)
                    .padding(.top, 16)
            }
        }
    }

    private func fieldGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(BrandTheme.display(11, weight: .semibold))
                .tracking(1)
                .foregroundStyle(BrandTheme.muted)
            content()
                .font(BrandTheme.body(16))
                .foregroundStyle(BrandTheme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BrandTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous)
                        .stroke(BrandTheme.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: BrandTheme.controlRadius, style: .continuous))
        }
    }

    private var canSubmit: Bool {
        !isLoading && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    private func login() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let result = try await appState.connectMFL(username: username, password: password)
            leagues = result
            password = ""
            if result.isEmpty {
                error = "Signed in, but no leagues were returned for this account."
            } else {
                step = .pickLeague
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
