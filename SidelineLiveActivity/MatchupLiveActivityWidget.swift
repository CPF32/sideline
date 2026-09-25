import ActivityKit
import AppIntents
import WidgetKit
import SwiftUI

@main
struct SidelineLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        MatchupLiveActivityWidget()
    }
}

struct MatchupLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MatchupLiveAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(Color(red: 0.07, green: 0.08, blue: 0.09))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(shortScore(context.state.myScore))
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(shortScore(context.state.oppScore))
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("vs \(context.state.opponentName)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        playerCycleRow(state: context.state)
                        HStack {
                            Text(context.state.statusLine)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            verticalCycle(
                                lines: context.state.nflGameLines,
                                alignment: .trailing,
                                empty: "—"
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Text(shortScore(context.state.myScore))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
            } compactTrailing: {
                Text(shortScore(context.state.oppScore))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            } minimal: {
                Text(shortScore(context.state.myScore))
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
            }
        }
    }

    private func lockScreenView(context: ActivityViewContext<MatchupLiveAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                leagueLabel(context: context)
                Spacer(minLength: 8)
                Text(providerLabel(context))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(teamName(context))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                    Text(String(format: "%.1f", context.state.myScore))
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text("W\(context.state.week)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(context.state.opponentName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                    Text(String(format: "%.1f", context.state.oppScore))
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }

            playerCycleRow(state: context.state)

            HStack {
                Text(context.state.statusLine)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                Spacer(minLength: 8)
                verticalCycle(
                    lines: context.state.nflGameLines,
                    alignment: .trailing,
                    empty: "—"
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func playerCycleRow(state: MatchupLiveAttributes.ContentState) -> some View {
        HStack(alignment: .center, spacing: 12) {
            verticalCycle(
                lines: state.resolvedMyPlayerLines,
                alignment: .leading,
                empty: "—"
            )
            Spacer(minLength: 8)
            verticalCycle(
                lines: state.oppPlayerLines,
                alignment: .trailing,
                empty: "—"
            )
        }
        .frame(height: 18)
    }

    /// Cycles lines every 1.5s with a top→bottom push transition.
    private func verticalCycle(
        lines: [String],
        alignment: Alignment,
        empty: String
    ) -> some View {
        let interval = MatchupLiveSyncSchedule.cycleSeconds
        return TimelineView(.periodic(from: .now, by: interval)) { context in
            let idx: Int = {
                guard !lines.isEmpty else { return 0 }
                return Int(context.date.timeIntervalSince1970 / interval) % lines.count
            }()
            let text = lines.isEmpty ? empty : lines[idx]
            ZStack(alignment: alignment) {
                Text(text)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .id(text)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .bottom).combined(with: .opacity)
                        )
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .clipped()
            .animation(.easeInOut(duration: 0.4), value: text)
        }
        .frame(height: 18)
        .accessibilityLabel(lines.isEmpty ? empty : lines.joined(separator: ", "))
    }

    @ViewBuilder
    private func leagueLabel(context: ActivityViewContext<MatchupLiveAttributes>) -> some View {
        let name = leagueName(context)
        if context.state.leagueCount > 1 {
            Button(intent: CycleLiveActivityLeagueIntent()) {
                HStack(spacing: 4) {
                    Text(name.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(0.8)
                        .lineLimit(1)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        } else {
            Text(name.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
    }

    private func leagueName(_ context: ActivityViewContext<MatchupLiveAttributes>) -> String {
        displayName(
            state: context.state.leagueName,
            attributes: context.attributes.leagueName,
            leagueLinkId: context.state.leagueLinkId
        )
    }

    private func teamName(_ context: ActivityViewContext<MatchupLiveAttributes>) -> String {
        displayName(
            state: context.state.myTeamName,
            attributes: context.attributes.myTeamName,
            leagueLinkId: context.state.leagueLinkId
        )
    }

    private func providerLabel(_ context: ActivityViewContext<MatchupLiveAttributes>) -> String {
        displayName(
            state: context.state.providerLabel,
            attributes: context.attributes.providerLabel,
            leagueLinkId: context.state.leagueLinkId
        )
    }

    private func displayName(state: String, attributes: String, leagueLinkId: String) -> String {
        if !state.isEmpty { return state }
        if !leagueLinkId.isEmpty { return state }
        return attributes
    }

    private func shortScore(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}
