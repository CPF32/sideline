import SwiftUI

/// Nav-bar brand mark.
/// - Pull: lime fill grows top→bottom; slight stretch with pull.
/// - Loading: lime sheen sweeps at a fixed speed (same for initial load and pull-refresh).
struct SidelineNavTitle: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var pullChrome = NavPullChrome.shared

    private let title = BrandTheme.appName.uppercased()
    /// One full sheen pass — keep travel + gap in sync so speed never changes.
    private let sheenTravelDuration: TimeInterval = 1.15
    private let sheenGapDuration: TimeInterval = 0.2
    private var minimumLoadingDuration: TimeInterval {
        sheenTravelDuration + sheenGapDuration
    }

    @State private var sheenPhase: CGFloat = -0.35
    @State private var sheenTask: Task<Void, Never>?
    @State private var holdTask: Task<Void, Never>?
    @State private var displayLoading = false
    @State private var loadingGeneration = 0
    @State private var loadingShownAt: Date?

    private var isLoading: Bool {
        appState.isSyncing
            || appState.isLoadingLeague
            || appState.isLoadingProps
            || appState.isRunningAgent
    }

    private var pullProgress: CGFloat {
        min(1, max(0, pullChrome.progress))
    }

    private var fillProgress: CGFloat {
        displayLoading ? 0 : pullProgress
    }

    private var stretch: CGFloat {
        if displayLoading { return 1 }
        return 1 + pullProgress * 0.45
    }

    var body: some View {
        Text(title)
            .font(BrandTheme.display(18, weight: .bold))
            .tracking(1)
            .foregroundStyle(BrandTheme.ink)
            .overlay {
                Text(title)
                    .font(BrandTheme.display(18, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(BrandTheme.accent)
                    .mask(alignment: .top) {
                        Rectangle()
                            .scaleEffect(x: 1, y: max(0.001, fillProgress), anchor: .top)
                    }
                    .opacity(displayLoading ? 0 : 1)
            }
            .overlay {
                if displayLoading {
                    Text(title)
                        .font(BrandTheme.display(18, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(BrandTheme.accent)
                        .mask {
                            GeometryReader { geo in
                                let w = geo.size.width
                                let band = w * 0.5
                                LinearGradient(
                                    colors: [
                                        .clear,
                                        BrandTheme.accent.opacity(0.2),
                                        BrandTheme.accent,
                                        BrandTheme.accent.opacity(0.2),
                                        .clear
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: band)
                                .offset(x: sheenPhase * (w + band) - band)
                            }
                        }
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(x: 1, y: stretch, anchor: .center)
            .accessibilityLabel(BrandTheme.appName)
            .accessibilityValue(displayLoading ? "Loading" : (pullProgress > 0.05 ? "Pull to refresh" : ""))
            .onChange(of: isLoading) { _, loading in
                handleLoadingChange(loading)
            }
            .onAppear {
                if isLoading {
                    handleLoadingChange(true)
                }
            }
            .onDisappear {
                holdTask?.cancel()
                stopSheen()
                displayLoading = false
                loadingShownAt = nil
            }
    }

    private func handleLoadingChange(_ loading: Bool) {
        holdTask?.cancel()
        if loading {
            loadingGeneration += 1
            let wasShowing = displayLoading
            if !wasShowing {
                loadingShownAt = Date()
                // Drop pull fill so we don't flash full-green → sheen.
                NavPullChrome.shared.reset()
                displayLoading = true
                startSheen()
            }
            return
        }

        let generation = loadingGeneration
        let shownAt = loadingShownAt ?? Date()
        let elapsed = Date().timeIntervalSince(shownAt)
        let remaining = max(0, minimumLoadingDuration - elapsed)
        holdTask = Task { @MainActor in
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            guard generation == loadingGeneration else { return }
            guard !isLoading else { return }
            displayLoading = false
            loadingShownAt = nil
            stopSheen()
        }
    }

    private func startSheen() {
        stopSheen()
        // Set without animation so the first pass always starts off-screen left.
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            sheenPhase = -0.35
        }
        sheenTask = Task { @MainActor in
            // Let the reset land before the first animated pass.
            try? await Task.sleep(nanoseconds: 16_000_000)
            while !Task.isCancelled {
                var resetPass = Transaction()
                resetPass.disablesAnimations = true
                withTransaction(resetPass) {
                    sheenPhase = -0.35
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled else { break }
                // Linear = constant speed across the word (same every time).
                withAnimation(.linear(duration: sheenTravelDuration)) {
                    sheenPhase = 1.35
                }
                try? await Task.sleep(
                    nanoseconds: UInt64((sheenTravelDuration + sheenGapDuration) * 1_000_000_000)
                )
            }
        }
    }

    private func stopSheen() {
        sheenTask?.cancel()
        sheenTask = nil
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            sheenPhase = -0.35
        }
    }
}
