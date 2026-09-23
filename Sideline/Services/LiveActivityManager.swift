import Foundation
import ActivityKit

/// Starts / updates / ends Matchup Live Activities from Team sync snapshots.
/// When the live backend is configured, activities request a push token so APNs
/// can keep the Lock Screen fresh while the app is backgrounded.
@MainActor
enum LiveActivityManager {
    static let enabledKey = "sideline.liveActivity.enabled"

    private static var tokenTasks: [String: Task<Void, Never>] = [:]
    private static var lastLinked: LinkedFranchise?
    private static var lastSnapshot: TeamSnapshot?

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var areActivitiesSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Call after each successful team sync.
    static func sync(from snapshot: TeamSnapshot, linked: LinkedFranchise) {
        lastSnapshot = snapshot
        lastLinked = linked

        guard isEnabled, areActivitiesSupported else {
            Task { await endAll() }
            return
        }

        let liveStarters = snapshot.starters.filter { $0.gameLockState == "started" }
        let slateLive = snapshot.starters.contains {
            $0.gameLockState == "started" || $0.gameLockState == "final"
        }
        let matchup = snapshot.matchup
        guard !liveStarters.isEmpty || (slateLive && (matchup?.myScore != nil || matchup?.oppScore != nil)) else {
            Task { await endAll() }
            return
        }

        guard !liveStarters.isEmpty else {
            let state = contentState(from: snapshot, linked: linked, liveStarters: snapshot.starters.filter { $0.gameLockState == "final" })
            Task {
                await updateExisting(state: state)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await endAll()
            }
            return
        }

        let attributes = MatchupLiveAttributes(
            leagueName: linked.leagueName,
            myTeamName: snapshot.franchiseName.isEmpty ? linked.franchiseName : snapshot.franchiseName,
            providerLabel: linked.provider.shortName
        )
        let state = contentState(from: snapshot, linked: linked, liveStarters: liveStarters)
        let usePush = LiveActivityPushClient.isConfigured

        Task {
            if let existing = Activity<MatchupLiveAttributes>.activities.first {
                await existing.update(
                    ActivityContent(state: state, staleDate: Date().addingTimeInterval(180))
                )
                if usePush {
                    observePushToken(activity: existing, snapshot: snapshot, linked: linked)
                }
            } else {
                do {
                    let activity = try Activity.request(
                        attributes: attributes,
                        content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(180)),
                        pushType: usePush ? .token : nil
                    )
                    if usePush {
                        observePushToken(activity: activity, snapshot: snapshot, linked: linked)
                    }
                } catch {
                    // Soft fail — Live Activities may be disabled in Focus / Low Power.
                }
            }
        }
    }

    static func endAll() async {
        for (id, task) in tokenTasks {
            task.cancel()
            tokenTasks[id] = nil
            await LiveActivityPushClient.unregister(activityId: id)
        }
        tokenTasks.removeAll()
        for activity in Activity<MatchupLiveAttributes>.activities {
            await LiveActivityPushClient.unregister(activityId: activity.id)
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func observePushToken(
        activity: Activity<MatchupLiveAttributes>,
        snapshot: TeamSnapshot,
        linked: LinkedFranchise
    ) {
        tokenTasks[activity.id]?.cancel()
        tokenTasks[activity.id] = Task {
            for await tokenData in activity.pushTokenUpdates {
                guard !Task.isCancelled else { break }
                let hex = Self.hex(tokenData)
                let snap = lastSnapshot ?? snapshot
                let link = lastLinked ?? linked
                await registerPush(
                    activityId: activity.id,
                    tokenHex: hex,
                    snapshot: snap,
                    linked: link
                )
            }
        }
    }

    private static func registerPush(
        activityId: String,
        tokenHex: String,
        snapshot: TeamSnapshot,
        linked: LinkedFranchise
    ) async {
        let starters = snapshot.starters
        var names: [String: String] = [:]
        for p in starters {
            names[p.playerId] = p.name
        }
        let payload = LiveActivityPushClient.RegisterPayload(
            activityId: activityId,
            pushToken: tokenHex,
            provider: linked.isSleeper ? "sleeper" : "mfl",
            leagueId: linked.leagueId,
            franchiseId: linked.franchiseId,
            week: snapshot.week,
            season: linked.season,
            host: linked.isMFL ? linked.host : nil,
            mflCookie: linked.isMFL ? KeychainStore.get(.mflUserCookie) : nil,
            leagueName: linked.leagueName,
            myTeamName: snapshot.franchiseName.isEmpty ? linked.franchiseName : snapshot.franchiseName,
            providerLabel: linked.provider.shortName,
            opponentName: snapshot.matchup?.opponentName,
            playerNames: names,
            starterIds: starters.map(\.playerId),
            apnsEnvironment: LiveActivityPushClient.apnsEnvironment
        )
        await LiveActivityPushClient.register(payload)
    }

    private static func updateExisting(state: MatchupLiveAttributes.ContentState) async {
        for activity in Activity<MatchupLiveAttributes>.activities {
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(120)))
        }
    }

    private static func contentState(
        from snapshot: TeamSnapshot,
        linked: LinkedFranchise,
        liveStarters: [RosterPlayer]
    ) -> MatchupLiveAttributes.ContentState {
        let my = snapshot.matchup?.myScore ?? 0
        let opp = snapshot.matchup?.oppScore ?? 0
        let oppName = snapshot.matchup?.opponentName ?? "Opponent"

        let lines: [String] = liveStarters
            .sorted { ($0.actualPoints ?? 0) > ($1.actualPoints ?? 0) }
            .prefix(4)
            .map { player in
                let pts = player.actualPoints.map { String(format: "%.1f", $0) } ?? "—"
                let clock = player.gameStatusLabel ?? "LIVE"
                return "\(player.name)  \(pts)  ·  \(clock)"
            }

        let liveCount = snapshot.starters.filter { $0.gameLockState == "started" }.count
        let finalCount = snapshot.starters.filter { $0.gameLockState == "final" }.count
        let status: String
        if liveCount > 0 {
            status = "\(liveCount) starter\(liveCount == 1 ? "" : "s") live · \(linked.provider.shortName)"
        } else if finalCount > 0 {
            status = "Games final · \(linked.provider.shortName)"
        } else {
            status = "Week \(snapshot.week) · \(linked.provider.shortName)"
        }

        return MatchupLiveAttributes.ContentState(
            myScore: my,
            oppScore: opp,
            opponentName: oppName,
            week: snapshot.week,
            statusLine: status,
            playerLines: lines,
            lastUpdated: Date().timeIntervalSince1970
        )
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
