import Foundation
import ActivityKit

/// Starts / updates / ends Matchup Live Activities from Team sync snapshots.
/// When the live backend is configured, activities request a push token so APNs
/// can keep the Lock Screen fresh while the app is backgrounded.
@MainActor
enum LiveActivityManager {
    static let enabledKey = "sideline.liveActivity.enabled"

    private static var tokenTasks: [String: Task<Void, Never>] = [:]
    private static var lastPushTokens: [String: String] = [:]
    private static var lastLinked: LinkedFranchise?
    private static var lastSnapshot: TeamSnapshot?
    private static var leagueCount: Int = 1

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var areActivitiesSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Keep the cycle control accurate when the hub has multiple leagues.
    static func setLinkedLeagueCount(_ count: Int) {
        leagueCount = max(1, count)
    }

    /// Call after each successful team sync.
    static func sync(from snapshot: TeamSnapshot, linked: LinkedFranchise, linkedLeagueCount: Int? = nil) {
        lastSnapshot = snapshot
        lastLinked = linked
        if let linkedLeagueCount {
            leagueCount = max(1, linkedLeagueCount)
        }

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
                let previousLink = existing.content.state.leagueLinkId
                let attrs = existing.attributes
                let leagueChanged =
                    (!previousLink.isEmpty && previousLink != linked.id)
                    || (previousLink.isEmpty && (
                        attrs.leagueName != linked.leagueName
                            || attrs.providerLabel != linked.provider.shortName
                    ))
                if leagueChanged {
                    // Attributes are immutable — end + restart so team/league labels
                    // can't stay locked on the previous franchise after a switch.
                    tokenTasks[existing.id]?.cancel()
                    tokenTasks[existing.id] = nil
                    lastPushTokens[existing.id] = nil
                    await LiveActivityPushClient.unregister(activityId: existing.id)
                    await existing.end(nil, dismissalPolicy: .immediate)
                    await startActivity(
                        attributes: attributes,
                        state: state,
                        usePush: usePush,
                        snapshot: snapshot,
                        linked: linked
                    )
                } else {
                    await existing.update(
                        ActivityContent(
                            state: state,
                            staleDate: Date().addingTimeInterval(MatchupLiveSyncSchedule.intervalSeconds + 60)
                        )
                    )
                    if usePush {
                        observePushToken(activity: existing, snapshot: snapshot, linked: linked)
                        await reregisterIfPossible(activityId: existing.id, snapshot: snapshot, linked: linked)
                    }
                }
            } else {
                await startActivity(
                    attributes: attributes,
                    state: state,
                    usePush: usePush,
                    snapshot: snapshot,
                    linked: linked
                )
            }
        }
    }

    private static func startActivity(
        attributes: MatchupLiveAttributes,
        state: MatchupLiveAttributes.ContentState,
        usePush: Bool,
        snapshot: TeamSnapshot,
        linked: LinkedFranchise
    ) async {
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(
                    state: state,
                    staleDate: Date().addingTimeInterval(MatchupLiveSyncSchedule.intervalSeconds + 60)
                ),
                pushType: usePush ? .token : nil
            )
            if usePush {
                observePushToken(activity: activity, snapshot: snapshot, linked: linked)
            }
        } catch {
            // Soft fail — Live Activities may be disabled in Focus / Low Power.
        }
    }

    static func endAll() async {
        for (id, task) in tokenTasks {
            task.cancel()
            tokenTasks[id] = nil
            await LiveActivityPushClient.unregister(activityId: id)
        }
        tokenTasks.removeAll()
        lastPushTokens.removeAll()
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
                lastPushTokens[activity.id] = hex
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

    /// Re-POSTs the last known token on every sync so the Worker session stays fresh
    /// even if the token stream already yielded and the app was backgrounded.
    private static func reregisterIfPossible(
        activityId: String,
        snapshot: TeamSnapshot,
        linked: LinkedFranchise
    ) async {
        guard let hex = lastPushTokens[activityId] else { return }
        await registerPush(
            activityId: activityId,
            tokenHex: hex,
            snapshot: snapshot,
            linked: linked
        )
    }

    private static func registerPush(
        activityId: String,
        tokenHex: String,
        snapshot: TeamSnapshot,
        linked: LinkedFranchise
    ) async {
        let starters = snapshot.starters
        let liveStarters = starters.filter { $0.gameLockState == "started" }
        var names: [String: String] = [:]
        for p in liveStarters {
            names[p.playerId] = p.name
        }
        let payload = LiveActivityPushClient.RegisterPayload(
            activityId: activityId,
            pushToken: tokenHex,
            provider: linked.isSleeper ? "sleeper" : (linked.isESPN ? "espn" : "mfl"),
            leagueId: linked.leagueId,
            franchiseId: linked.franchiseId,
            week: snapshot.week,
            season: linked.season,
            host: linked.isMFL ? linked.host : nil,
            mflCookie: linked.isMFL ? KeychainStore.get(.mflUserCookie) : nil,
            espnS2: linked.isESPN ? KeychainStore.get(.espnS2) : nil,
            espnSwid: linked.isESPN ? KeychainStore.get(.espnSWID) : nil,
            leagueName: linked.leagueName,
            myTeamName: snapshot.franchiseName.isEmpty ? linked.franchiseName : snapshot.franchiseName,
            providerLabel: linked.provider.shortName,
            opponentName: snapshot.matchup?.opponentName,
            playerNames: names,
            starterIds: starters.map(\.playerId),
            liveStarterIds: liveStarters.map(\.playerId),
            oppLivePlayerLines: snapshot.matchup?.oppLivePlayerLines,
            nflGameLines: Self.nflGameLines(from: liveStarters),
            leagueLinkId: linked.id,
            leagueCount: leagueCount,
            apnsEnvironment: LiveActivityPushClient.apnsEnvironment
        )
        await LiveActivityPushClient.register(payload)
    }

    private static func updateExisting(state: MatchupLiveAttributes.ContentState) async {
        for activity in Activity<MatchupLiveAttributes>.activities {
            await activity.update(
                ActivityContent(
                    state: state,
                    staleDate: Date().addingTimeInterval(MatchupLiveSyncSchedule.intervalSeconds + 60)
                )
            )
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
        let now = Date()
        let live = liveStarters.filter { $0.gameLockState == "started" }
        let myLines = Self.fantasyLines(from: live)
        let oppLines = Array((snapshot.matchup?.oppLivePlayerLines ?? []).prefix(10))
        let nflLines = Self.nflGameLines(from: live)

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

        let teamName = snapshot.franchiseName.isEmpty ? linked.franchiseName : snapshot.franchiseName

        return MatchupLiveAttributes.ContentState(
            myScore: my,
            oppScore: opp,
            opponentName: oppName,
            week: snapshot.week,
            statusLine: status,
            playerLines: myLines,
            lastUpdated: now.timeIntervalSince1970,
            nextSyncAt: MatchupLiveSyncSchedule.nextSyncAt(after: now),
            leagueName: linked.leagueName,
            myTeamName: teamName,
            providerLabel: linked.provider.shortName,
            leagueLinkId: linked.id,
            leagueCount: leagueCount,
            myPlayerLines: myLines,
            oppPlayerLines: oppLines,
            nflGameLines: nflLines
        )
    }

    private static func fantasyLines(from players: [RosterPlayer]) -> [String] {
        players
            .sorted { ($0.actualPoints ?? 0) > ($1.actualPoints ?? 0) }
            .prefix(10)
            .map { player in
                let pts = player.actualPoints.map { String(format: "%.1f", $0) } ?? "—"
                return "\(player.name)  \(pts)"
            }
    }

    /// Unique in-progress NFL games from live starters (`KC @ LAC  12:34`).
    private static func nflGameLines(from players: [RosterPlayer]) -> [String] {
        var seen = Set<String>()
        var lines: [String] = []
        for player in players where player.gameLockState == "started" {
            let team = player.team.uppercased()
            guard !team.isEmpty, seen.insert(team).inserted else { continue }
            let matchup = player.opponent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let label = matchup.isEmpty ? team : "\(team) \(matchup)"
            let clock: String = {
                if let secs = player.gameSecondsRemaining, secs > 0 {
                    return String(format: "%d:%02d", secs / 60, secs % 60)
                }
                return "LIVE"
            }()
            lines.append("\(label)  \(clock)")
        }
        return Array(lines.prefix(10))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
