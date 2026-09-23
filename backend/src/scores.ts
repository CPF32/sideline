import type { ContentState, LiveSession } from "./types";

type ScoreSnapshot = {
  myScore: number;
  oppScore: number;
  opponentName: string;
  playerLines: string[];
  liveCount: number;
  finalCount: number;
};

export async function fetchLiveScores(session: LiveSession): Promise<ScoreSnapshot | null> {
  if (session.provider === "sleeper") {
    return fetchSleeper(session);
  }
  return fetchMFL(session);
}

async function fetchSleeper(session: LiveSession): Promise<ScoreSnapshot | null> {
  const url = `https://api.sleeper.app/v1/league/${encodeURIComponent(session.leagueId)}/matchups/${session.week}`;
  const res = await fetch(url, {
    headers: { "User-Agent": "SidelineLive/1.0 (com.cpf32.sideline; backend)" },
  });
  if (!res.ok) return null;
  const matchups = (await res.json()) as Array<Record<string, unknown>>;
  const rosterId = Number(session.franchiseId);
  const mine = matchups.find((m) => Number(m.roster_id) === rosterId);
  if (!mine) return null;

  const matchupId = mine.matchup_id;
  const opp =
    matchups.find(
      (m) => m.matchup_id === matchupId && Number(m.roster_id) !== rosterId
    ) ?? null;

  const playersPoints = (mine.players_points as Record<string, number> | undefined) ?? {};
  const starters =
    session.starterIds && session.starterIds.length > 0
      ? session.starterIds
      : ((mine.starters as string[] | undefined) ?? []);

  const names = session.playerNames ?? {};
  const playerLines = starters
    .map((id) => {
      const pts = playersPoints[id];
      if (pts == null) return null;
      const name = names[id] ?? `Player ${id}`;
      return `${name}  ${Number(pts).toFixed(1)}  ·  LIVE`;
    })
    .filter((x): x is string => Boolean(x))
    .slice(0, 4);

  const myScore = Number(mine.points ?? 0);
  const oppScore = Number(opp?.points ?? 0);

  return {
    myScore,
    oppScore,
    opponentName: session.opponentName || (opp ? `Roster ${opp.roster_id}` : "Opponent"),
    playerLines,
    liveCount: starters.filter((id) => playersPoints[id] != null).length,
    finalCount: 0,
  };
}

async function fetchMFL(session: LiveSession): Promise<ScoreSnapshot | null> {
  if (!session.host || !session.mflCookie) return null;
  const host = session.host.replace(/^https?:\/\//, "");
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
      Cookie: `MFL_USER_ID=${session.mflCookie}`,
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

  const playerLines = players
    .map((p) => {
      const name = String(p.name ?? p.id ?? "Player");
      const score = Number(p.score ?? p.pts ?? 0);
      const status = String(p.status ?? "LIVE").toUpperCase();
      return { name, score, status };
    })
    .filter((p) => p.status.includes("LIVE") || p.status.includes("INPLAY") || p.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, 4)
    .map((p) => `${p.name}  ${p.score.toFixed(1)}  ·  ${p.status}`);

  return {
    myScore: Number(mine.score ?? mine.pts ?? 0),
    oppScore: Number(opp?.score ?? opp?.pts ?? 0),
    opponentName: String(opp?.name ?? "Opponent"),
    playerLines,
    liveCount: playerLines.length,
    finalCount: 0,
  };
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
    playerLines: scores.playerLines,
    lastUpdated: Math.floor(Date.now() / 1000),
  };
}

export function contentUnchanged(a?: ContentState, b?: ContentState): boolean {
  if (!a || !b) return false;
  return (
    a.myScore === b.myScore &&
    a.oppScore === b.oppScore &&
    a.opponentName === b.opponentName &&
    a.statusLine === b.statusLine &&
    a.playerLines.join("|") === b.playerLines.join("|")
  );
}
