import ActivityKit
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.statusLine)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                        ForEach(context.state.playerLines.prefix(3), id: \.self) { line in
                            Text(line)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white)
                                .lineLimit(1)
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
            HStack {
                Text(context.attributes.leagueName.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text(context.attributes.providerLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.myTeamName)
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
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(context.state.playerLines.prefix(4), id: \.self) { line in
                        Text(line)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                }
            }

            Text(context.state.statusLine)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(16)
    }

    private func shortScore(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}
