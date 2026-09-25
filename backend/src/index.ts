import { Hono } from "hono";
import { cors } from "hono/cors";
import { pushLiveActivityUpdate } from "./apns";
import { contentUnchanged, fetchLeague, leagueKey, snapshotFor, toContentState } from "./scores";
import type { ApnsEnvironment, ContentState, Env, LiveSession, RegisterBody } from "./types";

const app = new Hono<{ Bindings: Env }>();

app.use("*", cors());

app.get("/health", (c) => c.json({ ok: true, service: "sideline-live" }));

function unauthorized(c: { req: { header: (n: string) => string | undefined }; env: Env }) {
  const key = c.req.header("X-Sideline-Key") ?? "";
  return !c.env.REGISTER_SECRET || key !== c.env.REGISTER_SECRET;
}

// KV free tier allows 1,000 writes/day, so all app state lives in two keys:
//   la:sessions — every registered Live Activity. Written only by register/delete.
//   la:state    — what the cron last pushed per session. Written only by the cron,
//                 at most once per tick, and only when a score changed.
// Every tick still pushes to every live session (even with unchanged scores) so
// the "next sync" countdown on the Lock Screen resets.
// Keeping one writer per key avoids the cron and the app clobbering each other.
const SESSIONS_KEY = "la:sessions";
const STATE_KEY = "la:state";
const KEY_TTL = 60 * 60 * 12;
/** Live Activities max out around 8 hours. */
const SESSION_MAX_AGE = 60 * 60 * 8;

type SessionMap = Record<string, LiveSession>;

type PushState = {
  content?: ContentState;
  /** APNs environment that actually worked, if it differs from the app's hint. */
  environment?: ApnsEnvironment;
  /** Push token APNs reported gone (410); the session is skipped until it re-registers. */
  deadToken?: string;
};
type StateMap = Record<string, PushState>;

async function readSessions(env: Env): Promise<SessionMap> {
  return ((await env.SESSIONS.get(SESSIONS_KEY, "json")) as SessionMap | null) ?? {};
}

async function writeSessions(env: Env, sessions: SessionMap) {
  await env.SESSIONS.put(SESSIONS_KEY, JSON.stringify(sessions), { expirationTtl: KEY_TTL });
}

async function readState(env: Env): Promise<StateMap> {
  return ((await env.SESSIONS.get(STATE_KEY, "json")) as StateMap | null) ?? {};
}

function isLive(session: LiveSession, state: StateMap, now: number): boolean {
  return (
    now - session.updatedAt < SESSION_MAX_AGE &&
    state[session.id]?.deadToken !== session.pushToken
  );
}

/** Register / refresh a Live Activity push session (called from the iOS app). */
app.post("/v1/live-activity/register", async (c) => {
  if (unauthorized(c)) return c.json({ error: "unauthorized" }, 401);

  const body = (await c.req.json()) as RegisterBody;
  if (!body.activityId || !body.pushToken || !body.leagueId || !body.franchiseId) {
    return c.json({ error: "missing fields" }, 400);
  }
  if (body.provider !== "mfl" && body.provider !== "sleeper") {
    return c.json({ error: "invalid provider" }, 400);
  }
  if (body.provider === "mfl" && (!body.host || !body.mflCookie)) {
    return c.json({ error: "mfl requires host + mflCookie" }, 400);
  }

  const now = Math.floor(Date.now() / 1000);
  const [sessions, state] = await Promise.all([readSessions(c.env), readState(c.env)]);
  const existing = sessions[body.activityId];
  const preferredEnv =
    body.apnsEnvironment === "production" || body.apnsEnvironment === "sandbox"
      ? body.apnsEnvironment
      : existing?.apnsEnvironment;
  const session: LiveSession = {
    id: body.activityId,
    pushToken: body.pushToken.replace(/\s+/g, "").toLowerCase(),
    provider: body.provider,
    leagueId: body.leagueId,
    franchiseId: body.franchiseId,
    week: body.week,
    season: body.season,
    host: body.host,
    mflCookie: body.mflCookie,
    leagueName: body.leagueName,
    myTeamName: body.myTeamName,
    providerLabel: body.providerLabel,
    opponentName: body.opponentName,
    playerNames: body.playerNames,
    starterIds: body.starterIds,
    liveStarterIds: body.liveStarterIds,
    leagueLinkId: body.leagueLinkId,
    leagueCount: body.leagueCount,
    apnsEnvironment: preferredEnv,
    createdAt: existing?.createdAt ?? now,
    updatedAt: now,
  };

  // Immediate first push so Lock Screen isn't stuck on the local snapshot. The
  // cron doesn't know about it and will push once more next tick — harmless.
  try {
    const league = await fetchLeague([session]);
    const scores = league && snapshotFor(session, league);
    if (scores) {
      const result = await pushLiveActivityUpdate(
        c.env,
        session.pushToken,
        toContentState(session, scores),
        "update",
        session.apnsEnvironment
      );
      if (result.ok && result.environment) session.apnsEnvironment = result.environment;
    }
  } catch (e) {
    console.error("register immediate push failed", e);
  }

  // Prune expired / dead sessions while we're writing anyway.
  const next: SessionMap = {};
  for (const s of Object.values(sessions)) {
    if (s.id !== session.id && isLive(s, state, now)) next[s.id] = s;
  }
  next[session.id] = session;
  await writeSessions(c.env, next);

  return c.json({ ok: true, id: session.id });
});

app.delete("/v1/live-activity/:id", async (c) => {
  if (unauthorized(c)) return c.json({ error: "unauthorized" }, 401);
  const id = c.req.param("id");
  const [sessions, state] = await Promise.all([readSessions(c.env), readState(c.env)]);
  const session = sessions[id];
  if (session) {
    try {
      const endState = state[id]?.content ?? {
        myScore: 0,
        oppScore: 0,
        opponentName: "Opponent",
        week: session.week,
        statusLine: "Ended",
        playerLines: [],
        lastUpdated: Math.floor(Date.now() / 1000),
      };
      await pushLiveActivityUpdate(
        c.env,
        session.pushToken,
        endState,
        "end",
        state[id]?.environment ?? session.apnsEnvironment
      );
    } catch (e) {
      console.error("end push failed", e);
    }
    delete sessions[id];
    await writeSessions(c.env, sessions);
  }
  return c.json({ ok: true });
});

type PollResult = { sessions: number; leagues: number; pushed: number; ended: number };

async function pollAll(env: Env): Promise<PollResult> {
  const sessions = await readSessions(env);
  // Nothing registered → one KV read, no writes, no API calls.
  if (Object.keys(sessions).length === 0) return { sessions: 0, leagues: 0, pushed: 0, ended: 0 };

  const state = await readState(env);
  const now = Math.floor(Date.now() / 1000);
  let stateDirty = false;
  let pushed = 0;
  let ended = 0;

  // One fetch per league/week, shared by every user in that league.
  const byLeague = new Map<string, LiveSession[]>();
  for (const session of Object.values(sessions)) {
    if (!isLive(session, state, now)) continue;
    const key = leagueKey(session);
    byLeague.set(key, [...(byLeague.get(key) ?? []), session]);
  }

  for (const [key, members] of byLeague) {
    let league;
    try {
      league = await fetchLeague(members);
    } catch (e) {
      console.error("league fetch fail", key, e);
      continue;
    }
    if (!league) continue;

    for (const session of members) {
      try {
        const scores = snapshotFor(session, league);
        if (!scores) continue;

        const content = toContentState(session, scores);
        const prev = state[session.id] ?? {};
        const changed = !contentUnchanged(prev.content, content);

        const result = await pushLiveActivityUpdate(
          env,
          session.pushToken,
          content,
          "update",
          prev.environment ?? session.apnsEnvironment
        );
        if (result.ok) {
          pushed += 1;
          const environment =
            result.environment && result.environment !== session.apnsEnvironment
              ? result.environment
              : prev.environment;
          // Only persist when something meaningful changed, to save KV writes.
          if (changed || environment !== prev.environment) {
            state[session.id] = { content, environment };
            stateDirty = true;
          }
        } else if (result.status === 410) {
          // Token gone — skip this session until the app registers a new token.
          state[session.id] = { deadToken: session.pushToken };
          stateDirty = true;
          ended += 1;
        } else {
          console.error("apns fail", session.id, result.status, result.body);
        }
      } catch (e) {
        console.error("poll fail", session.id, e);
      }
    }
  }

  // Forget state for sessions that were deleted or pruned.
  for (const id of Object.keys(state)) {
    if (!sessions[id]) {
      delete state[id];
      stateDirty = true;
    }
  }
  if (stateDirty) {
    await env.SESSIONS.put(STATE_KEY, JSON.stringify(state), { expirationTtl: KEY_TTL });
  }

  return { sessions: Object.keys(sessions).length, leagues: byLeague.size, pushed, ended };
}

app.post("/v1/live-activity/poll", async (c) => {
  if (unauthorized(c)) return c.json({ error: "unauthorized" }, 401);
  const result = await pollAll(c.env);
  return c.json({ ok: true, ...result });
});

export default {
  fetch: app.fetch,
  async scheduled(_event: ScheduledEvent, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(
      pollAll(env).then((r) => console.log("cron poll", r)).catch((e) => console.error("cron fail", e))
    );
  },
};
