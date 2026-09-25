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
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(context.state.statusLine)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                            Spacer()
                            syncCountdown(context.state)
                        }
                        if !context.state.playerLines.isEmpty {
                            playerTicker(lines: context.state.playerLines)
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

            if !context.state.playerLines.isEmpty {
                playerTicker(lines: context.state.playerLines)
            }

            HStack {
                Text(context.state.statusLine)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                Spacer()
                syncCountdown(context.state)
            }
        }
        .padding(16)
        // Lock Screen Live Activities get clipped around ~160pt — keep the shell compact.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Continuous horizontal score ticker (no manual scroll). Driven by TimelineView so
    /// it keeps moving without ActivityKit updates.
    private func playerTicker(lines: [String]) -> some View {
        let unit = lines.prefix(10).joined(separator: "   ·   ") + "   ·   "
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            GeometryReader { geo in
                let speed: CGFloat = 38
                // Monospaced caption ≈ 6.2pt/char — good enough for seamless wrap.
                let contentWidth = max(CGFloat(unit.count) * 6.2, geo.size.width + 1)
                let distance = CGFloat(context.date.timeIntervalSinceReferenceDate) * speed
                let offset = -(distance.truncatingRemainder(dividingBy: contentWidth))

                HStack(spacing: 0) {
                    Text(unit)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: true, vertical: false)
                    Text(unit)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .offset(x: offset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            }
        }
        .frame(height: 16)
        .clipped()
        .accessibilityLabel(lines.joined(separator: ", "))
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

    /// Countdown to the next refresh. Uses TimelineView so when the push is late
    /// we can leave 0:00 and show a waiting ellipsis instead of a stuck timer.
    @ViewBuilder
    private func syncCountdown(_ state: MatchupLiveAttributes.ContentState) -> some View {
        if let next = state.nextSyncAt, next > state.lastUpdated {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = context.date.timeIntervalSince1970
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                    if next > now {
                        Text(
                            timerInterval: Date(timeIntervalSince1970: state.lastUpdated)...Date(timeIntervalSince1970: next),
                            countsDown: true
                        )
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 34, alignment: .trailing)
                    } else {
                        // Push is overdue — don't sit on 0:00 until the update lands.
                        Text("…")
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .accessibilityLabel(next > now ? "Next refresh" : "Refresh due")
            }
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

    /// Prefer ContentState. Once a league switch has written `leagueLinkId`, never fall
    /// back to immutable attributes — those stay locked to the league that started the Activity.
    private func displayName(state: String, attributes: String, leagueLinkId: String) -> String {
        if !state.isEmpty { return state }
        if !leagueLinkId.isEmpty { return state }
        return attributes
    }

    private func shortScore(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}
