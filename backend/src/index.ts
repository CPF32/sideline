import { Hono } from "hono";
import { cors } from "hono/cors";
import { pushLiveActivityUpdate } from "./apns";
import { contentUnchanged, fetchLiveScores, toContentState } from "./scores";
import type { ContentState, Env, LiveSession, RegisterBody } from "./types";

const app = new Hono<{ Bindings: Env }>();

app.use("*", cors());

app.get("/health", (c) => c.json({ ok: true, service: "sideline-live" }));

function unauthorized(c: { req: { header: (n: string) => string | undefined }; env: Env }) {
  const key = c.req.header("X-Sideline-Key") ?? "";
  return !c.env.REGISTER_SECRET || key !== c.env.REGISTER_SECRET;
}

// KV free tier allows 1,000 writes/day, so the cron must not write unless
// something changed. Per-session "last pushed content" lives in one shared key
// (la:last) so a poll writes at most once no matter how many sessions exist.
const INDEX_KEY = "la:index";
const LAST_KEY = "la:last";
const INDEX_TTL = 60 * 60 * 12;

type LastContentMap = Record<string, ContentState>;

async function readIndex(env: Env): Promise<string[]> {
  return ((await env.SESSIONS.get(INDEX_KEY, "json")) as string[] | null) ?? [];
}

async function readLast(env: Env): Promise<LastContentMap> {
  return ((await env.SESSIONS.get(LAST_KEY, "json")) as LastContentMap | null) ?? {};
}

async function writeLast(env: Env, last: LastContentMap) {
  await env.SESSIONS.put(LAST_KEY, JSON.stringify(last), { expirationTtl: INDEX_TTL });
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
  const existing = await c.env.SESSIONS.get(`la:${body.activityId}`, "json") as LiveSession | null;
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
    apnsEnvironment: preferredEnv,
    createdAt: existing?.createdAt ?? now,
    updatedAt: now,
  };

  // 8h TTL — Live Activities max out around 8 hours anyway.
  await c.env.SESSIONS.put(`la:${session.id}`, JSON.stringify(session), {
    expirationTtl: 60 * 60 * 8,
  });

  // Index for cron sweep.
  const index = await readIndex(c.env);
  if (!index.includes(session.id)) {
    index.push(session.id);
    await c.env.SESSIONS.put(INDEX_KEY, JSON.stringify(index), { expirationTtl: INDEX_TTL });
  }

  // Immediate first push so Lock Screen isn't stuck on the local snapshot.
  try {
    const scores = await fetchLiveScores(session);
    if (scores) {
      const content = toContentState(session, scores);
      const result = await pushLiveActivityUpdate(
        c.env,
        session.pushToken,
        content,
        "update",
        session.apnsEnvironment
      );
      if (result.ok) {
        const last = await readLast(c.env);
        last[session.id] = content;
        await writeLast(c.env, last);
        if (result.environment && result.environment !== session.apnsEnvironment) {
          session.apnsEnvironment = result.environment;
          await c.env.SESSIONS.put(`la:${session.id}`, JSON.stringify(session), {
            expirationTtl: 60 * 60 * 8,
          });
        }
      }
    }
  } catch (e) {
    console.error("register immediate push failed", e);
  }

  return c.json({ ok: true, id: session.id });
});

app.delete("/v1/live-activity/:id", async (c) => {
  if (unauthorized(c)) return c.json({ error: "unauthorized" }, 401);
  const id = c.req.param("id");
  const session = (await c.env.SESSIONS.get(`la:${id}`, "json")) as LiveSession | null;
  const last = await readLast(c.env);
  if (session) {
    try {
      const endState = last[id] ?? {
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
        session.apnsEnvironment
      );
    } catch (e) {
      console.error("end push failed", e);
    }
  }
  await c.env.SESSIONS.delete(`la:${id}`);
  const index = await readIndex(c.env);
  if (index.includes(id)) {
    await c.env.SESSIONS.put(INDEX_KEY, JSON.stringify(index.filter((x) => x !== id)), {
      expirationTtl: INDEX_TTL,
    });
  }
  if (id in last) {
    delete last[id];
    await writeLast(c.env, last);
  }
  return c.json({ ok: true });
});

async function pollAll(env: Env): Promise<{ checked: number; pushed: number; ended: number }> {
  const index = await readIndex(env);
  // Nothing registered → no further KV reads or writes this tick.
  if (index.length === 0) return { checked: 0, pushed: 0, ended: 0 };

  const last = await readLast(env);
  let lastDirty = false;
  let pushed = 0;
  let ended = 0;
  const keep: string[] = [];

  for (const id of index) {
    const session = (await env.SESSIONS.get(`la:${id}`, "json")) as LiveSession | null;
    if (!session) continue;
    keep.push(id);

    try {
      const scores = await fetchLiveScores(session);
      if (!scores) continue;

      const content = toContentState(session, scores);
      if (contentUnchanged(last[id], content)) continue;

      const result = await pushLiveActivityUpdate(
        env,
        session.pushToken,
        content,
        "update",
        session.apnsEnvironment
      );
      if (result.ok) {
        pushed += 1;
        last[id] = content;
        lastDirty = true;
        // Only rewrite the session when APNs corrected its environment (rare).
        if (result.environment && result.environment !== session.apnsEnvironment) {
          session.apnsEnvironment = result.environment;
          await env.SESSIONS.put(`la:${id}`, JSON.stringify(session), {
            expirationTtl: 60 * 60 * 8,
          });
        }
      } else if (result.status === 410) {
        // Token gone — drop session.
        await env.SESSIONS.delete(`la:${id}`);
        keep.pop();
        ended += 1;
      } else {
        console.error("apns fail", id, result.status, result.body);
      }
    } catch (e) {
      console.error("poll fail", id, e);
    }
  }

  // Drop state for sessions that expired or ended.
  for (const id of Object.keys(last)) {
    if (!keep.includes(id)) {
      delete last[id];
      lastDirty = true;
    }
  }

  if (lastDirty) await writeLast(env, last);
  if (keep.length !== index.length) {
    await env.SESSIONS.put(INDEX_KEY, JSON.stringify(keep), { expirationTtl: INDEX_TTL });
  }

  return { checked: index.length, pushed, ended };
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
