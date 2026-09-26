import type { ContentState, LiveSession } from "./types";

type ScoreSnapshot = {
  myScore: number;
  oppScore: number;
  opponentName: string;
  playerLines: string[];
  myPlayerLines: string[];
  oppPlayerLines: string[];
  nflGameLines: string[];
  liveCount: number;
  finalCount: number;
};

/** One league's live data, fetched once per tick and shared by every session in it. */
export type LeagueData =
  | { provider: "sleeper"; matchups: Array<Record<string, unknown>> }
  | { provider: "mfl"; franchises: Array<Record<string, unknown>> }
  | { provider: "espn"; schedule: Array<Record<string, unknown>>; week: number };

function mflHost(session: LiveSession): string {
  return (session.host ?? "").replace(/^https?:\/\//, "").replace(/\/+$/, "").toLowerCase();
}

/** Sessions with the same key read the same league/week and share one fetch. */
export function leagueKey(session: LiveSession): string {
  if (session.provider === "sleeper") {
    return `sleeper:${session.leagueId}:${session.week}`;
  }
  if (session.provider === "espn") {
    return `espn:${session.leagueId}:${session.season}:${session.week}`;
  }
  return `mfl:${mflHost(session)}:${session.season}:${session.leagueId}:${session.week}`;
}

/**
 * Fetches a league's live scores once for all of its sessions. MFL needs a
 * logged-in cookie, so try each member's cookie until one works. ESPN may need
 * espn_s2 + SWID for private leagues.
 */
export async function fetchLeague(sessions: LiveSession[]): Promise<LeagueData | null> {
  const first = sessions[0];
  if (!first) return null;
  if (first.provider === "sleeper") return fetchSleeper(first);
  if (first.provider === "espn") {
    const cookiePairs: Array<{ espnS2: string; espnSwid: string }> = [];
    const seen = new Set<string>();
    for (const s of sessions) {
      const s2 = (s.espnS2 ?? "").trim();
      const swid = (s.espnSwid ?? "").trim();
      if (!s2 || !swid) continue;
      const key = `${s2}|${swid}`;
      if (seen.has(key)) continue;
      seen.add(key);
      cookiePairs.push({ espnS2: s2, espnSwid: swid });
    }
    // Try authenticated cookies first, then public (no cookies).
    for (const cookies of cookiePairs) {
      const data = await fetchEspn(first, cookies);
      if (data) return data;
    }
    return fetchEspn(first, null);
  }

  const cookies = [...new Set(sessions.map((s) => s.mflCookie).filter((c): c is string => !!c))];
  for (const cookie of cookies) {
    const data = await fetchMFL(first, cookie);
    if (data) return data;
  }
  return null;
}

/** Pulls one session's matchup out of its league's shared data. */
export function snapshotFor(session: LiveSession, league: LeagueData): ScoreSnapshot | null {
  if (league.provider === "sleeper") return sleeperSnapshot(session, league.matchups);
  if (league.provider === "espn") return espnSnapshot(session, league.schedule, league.week);
  return mflSnapshot(session, league.franchises);
}

async function fetchSleeper(session: LiveSession): Promise<LeagueData | null> {
  const url = `https://api.sleeper.app/v1/league/${encodeURIComponent(session.leagueId)}/matchups/${session.week}`;
  const res = await fetch(url, {
    headers: { "User-Agent": "SidelineLive/1.0 (com.cpf32.sideline; backend)" },
  });
  if (!res.ok) return null;
  const matchups = (await res.json()) as Array<Record<string, unknown>> | null;
  return Array.isArray(matchups) ? { provider: "sleeper", matchups } : null;
}

function espnCookieHeader(cookies: { espnS2: string; espnSwid: string } | null): string | undefined {
  if (!cookies) return undefined;
  let swid = cookies.espnSwid.trim();
  if (!swid.startsWith("{")) swid = `{${swid}`;
  if (!swid.endsWith("}")) swid = `${swid}}`;
  return `espn_s2=${cookies.espnS2.trim()}; SWID=${swid}`;
}

async function fetchEspn(
  session: LiveSession,
  cookies: { espnS2: string; espnSwid: string } | null
): Promise<LeagueData | null> {
  const base = `https://lm-api-reads.fantasy.espn.com/apis/v3/games/ffl/seasons/${session.season}/segments/0/leagues/${encodeURIComponent(session.leagueId)}`;
  const qs = new URLSearchParams();
  qs.append("view", "mMatchupScore");
  qs.append("view", "mScoreboard");
  qs.append("view", "mTeam");
  qs.set("scoringPeriodId", String(session.week));
  const headers: Record<string, string> = {
    "User-Agent": "SidelineLive/1.0 (com.cpf32.sideline; backend)",
    Accept: "application/json",
    "X-Fantasy-Filter": JSON.stringify({
      schedule: { filterMatchupPeriodIds: { value: [session.week] } },
    }),
  };
  const cookie = espnCookieHeader(cookies);
  if (cookie) headers.Cookie = cookie;

  const res = await fetch(`${base}?${qs.toString()}`, { headers });
  if (!res.ok) return null;
  const root = (await res.json()) as Record<string, unknown>;
  const scheduleRaw = root.schedule;
  const schedule = Array.isArray(scheduleRaw)
    ? (scheduleRaw as Array<Record<string, unknown>>)
    : [];
  return schedule.length > 0 ? { provider: "espn", schedule, week: session.week } : null;
}

function espnSideTeamId(side: unknown): number | null {
  if (!side || typeof side !== "object") return null;
  const id = (side as Record<string, unknown>).teamId;
  const n = Number(id);
  return Number.isFinite(n) ? n : null;
}

function espnSideScore(side: unknown): number {
  if (!side || typeof side !== "object") return 0;
  const s = side as Record<string, unknown>;
  const live = Number(s.totalPointsLive);
  if (Number.isFinite(live)) return live;
  const roster = s.rosterForCurrentScoringPeriod as Record<string, unknown> | undefined;
  const applied = Number(roster?.appliedStatTotal);
  if (Number.isFinite(applied)) return applied;
  const total = Number(s.totalPoints);
  return Number.isFinite(total) ? total : 0;
}

function espnPlayerLinesFromSide(
  side: unknown,
  session: LiveSession
): string[] {
  if (!side || typeof side !== "object") return [];
  const s = side as Record<string, unknown>;
  const roster =
    (s.rosterForCurrentScoringPeriod as Record<string, unknown> | undefined) ??
    (s.roster as Record<string, unknown> | undefined);
  const entriesRaw = roster?.entries;
  const entries = Array.isArray(entriesRaw)
    ? (entriesRaw as Array<Record<string, unknown>>)
    : [];
  const liveIds = new Set((session.liveStarterIds ?? []).map(String).filter((id) => id.length > 0));
  const names = session.playerNames ?? {};

  const scored = entries
    .map((entry) => {
      const slot = Number(entry.lineupSlotId ?? 20);
      // 20 = bench, 21 = IR
      if (slot === 20 || slot === 21) return null;
      const pid = String(entry.playerId ?? "");
      if (!pid) return null;
      if (liveIds.size > 0 && !liveIds.has(pid)) return null;
      const pool = entry.playerPoolEntry as Record<string, unknown> | undefined;
      const player = (pool?.player as Record<string, unknown> | undefined) ?? {};
      const name =
        names[pid] ||
        String(player.fullName ?? names[pid] ?? `Player ${pid}`);
      const pts = Number(pool?.appliedStatTotal ?? 0);
      return { name, pts };
    })
    .filter((x): x is { name: string; pts: number } => !!x)
    .sort((a, b) => b.pts - a.pts)
    .slice(0, 10)
    .map((p) => `${p.name}  ${p.pts.toFixed(1)}`);

  return scored;
}

function espnSnapshot(
  session: LiveSession,
  schedule: Array<Record<string, unknown>>,
  week: number
): ScoreSnapshot | null {
  const teamId = Number(session.franchiseId);
  const row = schedule.find((m) => {
    const period = Number(m.matchupPeriodId ?? m.scoringPeriodId);
    if (period !== week) return false;
    return espnSideTeamId(m.home) === teamId || espnSideTeamId(m.away) === teamId;
  });
  if (!row) return null;

  const homeId = espnSideTeamId(row.home);
  const mineIsHome = homeId === teamId;
  const mySide = mineIsHome ? row.home : row.away;
  const oppSide = mineIsHome ? row.away : row.home;

  const myPlayerLines = espnPlayerLinesFromSide(mySide, session);
  const oppPlayerLines = (session.oppLivePlayerLines ?? []).slice(0, 10);

  return {
    myScore: espnSideScore(mySide),
    oppScore: espnSideScore(oppSide),
    opponentName: session.opponentName || "Opponent",
    playerLines: myPlayerLines,
    myPlayerLines,
    oppPlayerLines,
    nflGameLines: (session.nflGameLines ?? []).slice(0, 10),
    liveCount: myPlayerLines.length,
    finalCount: 0,
  };
}

function sleeperSnapshot(
  session: LiveSession,
  matchups: Array<Record<string, unknown>>
): ScoreSnapshot | null {
  const rosterId = Number(session.franchiseId);
  const mine = matchups.find((m) => Number(m.roster_id) === rosterId);
  if (!mine) return null;

  const matchupId = mine.matchup_id;
  const opp =
    matchups.find(
      (m) => m.matchup_id === matchupId && Number(m.roster_id) !== rosterId
    ) ?? null;

  const playersPoints = (mine.players_points as Record<string, number> | undefined) ?? {};
  const liveIds = new Set(
    (session.liveStarterIds ?? []).map(String).filter((id) => id.length > 0)
  );
  // Prefer the live-only list from the app; never fall back to "anyone with points"
  // (that includes players whose games already finished).
  const ids =
    liveIds.size > 0
      ? [...liveIds]
      : [];

  const names = session.playerNames ?? {};
  const myPlayerLines = ids
    .map((id) => {
      const pts = playersPoints[id];
      const name = names[id] ?? `Player ${id}`;
      const score = pts == null ? "—" : Number(pts).toFixed(1);
      return `${name}  ${score}`;
    })
    .slice(0, 10);

  const oppPlayerLines = (session.oppLivePlayerLines ?? []).slice(0, 10);
  const nflGameLines = (session.nflGameLines ?? []).slice(0, 10);

  // Prefer summing starter players_points (so-far) over host `points`, which can be
  // null mid-week. Only count starters from the matchup payload.
  const starterIds = Array.isArray(mine.starters)
    ? (mine.starters as unknown[]).map(String).filter((id) => id && id !== "0")
    : [];
  const starterTotal = (row: Record<string, unknown> | null): number | null => {
    if (!row) return null;
    const pp = (row.players_points as Record<string, number> | undefined) ?? {};
    const starters = Array.isArray(row.starters)
      ? (row.starters as unknown[]).map(String).filter((id) => id && id !== "0")
      : starterIds;
    if (starters.length === 0) {
      const pts = Number(row.points);
      return Number.isFinite(pts) ? pts : null;
    }
    let total = 0;
    let any = false;
    for (const id of starters) {
      if (pp[id] != null && Number.isFinite(Number(pp[id]))) {
        total += Number(pp[id]);
        any = true;
      }
    }
    if (any) return total;
    const pts = Number(row.points);
    return Number.isFinite(pts) ? pts : null;
  };

  const myScore = starterTotal(mine) ?? Number(mine.points ?? 0);
  const oppScore = starterTotal(opp) ?? Number(opp?.points ?? 0);

  return {
    myScore,
    oppScore,
    opponentName: session.opponentName || (opp ? `Roster ${opp.roster_id}` : "Opponent"),
    playerLines: myPlayerLines,
    myPlayerLines,
    oppPlayerLines,
    nflGameLines,
    liveCount: myPlayerLines.length,
    finalCount: 0,
  };
}

async function fetchMFL(session: LiveSession, cookie: string): Promise<LeagueData | null> {
  const host = mflHost(session);
  if (!host) return null;
  const base = `https://${host}/${session.season}/export`;
  const qs = new URLSearchParams({
    TYPE: "liveScoring",
    L: session.leagueId,
    W: String(session.week),
    DETAILS: "1",
    JSON: "1",
  });
  const res = await fetch(`${base}?${qs.toString()}`, {
    headers: {
      Cookie: `MFL_USER_ID=${cookie}`,
      "User-Agent": "Sideline/1.0 (com.cpf32.sideline; iOS)",
      Accept: "application/json",
    },
  });
  if (!res.ok) return null;
  const root = (await res.json()) as Record<string, unknown>;
  const live = (root.liveScoring as Record<string, unknown>) ?? root;
  const franchiseBag = live.franchise;
  const franchises = Array.isArray(franchiseBag)
    ? (franchiseBag as Array<Record<string, unknown>>)
    : franchiseBag
      ? [franchiseBag as Record<string, unknown>]
      : [];
  return franchises.length > 0 ? { provider: "mfl", franchises } : null;
}

function mflSnapshot(
  session: LiveSession,
  franchises: Array<Record<string, unknown>>
): ScoreSnapshot | null {
  const mine =
    franchises.find((f) => String(f.id) === session.franchiseId) ??
    franchises.find((f) => String(f.id).padStart(4, "0") === session.franchiseId.padStart(4, "0"));
  if (!mine) return null;

  // Pair via matchup / opponent field when present.
  let opp: Record<string, unknown> | undefined;
  const oppId = String(mine.opponent ?? mine.opp ?? "");
  if (oppId) {
    opp = franchises.find((f) => String(f.id) === oppId);
  }

  const playersRaw = mine.player;
  const players = Array.isArray(playersRaw)
    ? (playersRaw as Array<Record<string, unknown>>)
    : playersRaw
      ? [playersRaw as Record<string, unknown>]
      : [];

  const myPlayerLines = players
    .map((p) => {
      const name = String(p.name ?? p.id ?? "Player");
      const score = Number(p.score ?? p.pts ?? 0);
      // Don't default to LIVE — missing status is not "in progress".
      const status = String(p.status ?? "").toUpperCase().replace(/\s+/g, "");
      const id = String(p.id ?? "");
      return { name, score, status, id };
    })
    .filter((p) => {
      // Only currently playing — not final / upcoming with leftover points.
      const inProgress =
        p.status.includes("LIVE") ||
        p.status.includes("INPLAY") ||
        p.status.includes("IN_PROGRESS");
      if (!inProgress) return false;
      const liveIds = session.liveStarterIds ?? [];
      if (liveIds.length === 0) return true;
      return liveIds.includes(p.id);
    })
    .sort((a, b) => b.score - a.score)
    .slice(0, 10)
    .map((p) => `${p.name}  ${p.score.toFixed(1)}`);

  const oppPlayerLines = oppLivePlayerLines(opp).length
    ? oppLivePlayerLines(opp)
    : (session.oppLivePlayerLines ?? []).slice(0, 10);

  return {
    myScore: Number(mine.score ?? mine.pts ?? 0),
    oppScore: Number(opp?.score ?? opp?.pts ?? 0),
    opponentName: String(opp?.name ?? session.opponentName ?? "Opponent"),
    playerLines: myPlayerLines,
    myPlayerLines,
    oppPlayerLines,
    nflGameLines: (session.nflGameLines ?? []).slice(0, 10),
    liveCount: myPlayerLines.length,
    finalCount: 0,
  };
}

function oppLivePlayerLines(opp?: Record<string, unknown>): string[] {
  if (!opp) return [];
  const playersRaw = opp.player;
  const players = Array.isArray(playersRaw)
    ? (playersRaw as Array<Record<string, unknown>>)
    : playersRaw
      ? [playersRaw as Record<string, unknown>]
      : [];
  return players
    .map((p) => {
      const name = String(p.name ?? p.id ?? "Player");
      const score = Number(p.score ?? p.pts ?? 0);
      const status = String(p.status ?? "").toUpperCase().replace(/\s+/g, "");
      return { name, score, status };
    })
    .filter(
      (p) =>
        p.status.includes("LIVE") ||
        p.status.includes("INPLAY") ||
        p.status.includes("IN_PROGRESS")
    )
    .sort((a, b) => b.score - a.score)
    .slice(0, 10)
    .map((p) => `${p.name}  ${p.score.toFixed(1)}`);
}

/** Matches the every-5-minutes cron schedule in wrangler.toml. */
export const SYNC_INTERVAL_SECONDS = 5 * 60;

/** ~5 minutes after `now` — matches the poll cadence, not a clock-aligned boundary.
 *  Clock alignment made late pushes reset the Lock Screen timer to a short leftover
 *  (e.g. 3:50) instead of a full interval. */
export function nextSyncAt(now = Math.floor(Date.now() / 1000)): number {
  return now + SYNC_INTERVAL_SECONDS;
}

export function toContentState(
  session: LiveSession,
  scores: ScoreSnapshot
): ContentState {
  const status =
    scores.liveCount > 0
      ? `${scores.liveCount} starter${scores.liveCount === 1 ? "" : "s"} live · ${session.providerLabel}`
      : `Week ${session.week} · ${session.providerLabel}`;

  return {
    myScore: scores.myScore,
    oppScore: scores.oppScore,
    opponentName: scores.opponentName,
    week: session.week,
    statusLine: status,
    playerLines: scores.myPlayerLines,
    lastUpdated: Math.floor(Date.now() / 1000),
    nextSyncAt: nextSyncAt(),
    leagueName: session.leagueName,
    myTeamName: session.myTeamName,
    providerLabel: session.providerLabel,
    leagueLinkId: session.leagueLinkId,
    leagueCount: session.leagueCount ?? 1,
    myPlayerLines: scores.myPlayerLines,
    oppPlayerLines: scores.oppPlayerLines,
    nflGameLines: scores.nflGameLines,
  };
}

export function contentUnchanged(a?: ContentState, b?: ContentState): boolean {
  if (!a || !b) return false;
  return (
    a.myScore === b.myScore &&
    a.oppScore === b.oppScore &&
    a.opponentName === b.opponentName &&
    a.statusLine === b.statusLine &&
    a.playerLines.join("|") === b.playerLines.join("|") &&
    (a.myPlayerLines ?? []).join("|") === (b.myPlayerLines ?? []).join("|") &&
    (a.oppPlayerLines ?? []).join("|") === (b.oppPlayerLines ?? []).join("|") &&
    (a.nflGameLines ?? []).join("|") === (b.nflGameLines ?? []).join("|") &&
    a.leagueName === b.leagueName &&
    a.myTeamName === b.myTeamName &&
    a.providerLabel === b.providerLabel &&
    a.leagueLinkId === b.leagueLinkId
  );
}
