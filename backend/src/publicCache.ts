import type { Env, WatchedMatchup } from "./types";

const UA = "Sideline/1.0 (com.cpf32.sideline; CloudflareWorker)";

const R2_PLAYERS = "catalogs/sleeper-players-nfl.json";
const R2_PLAYER_IDS = "catalogs/db_playerids.csv";
const KV_PLAYERS = "pub:catalog:sleeper-players";
const KV_PLAYER_IDS = "pub:catalog:player-ids";
const META_PLAYERS = "pub:meta:sleeper-players";
const META_PLAYER_IDS = "pub:meta:player-ids";
const WATCHED_KEY = "pub:watched:matchups";
const LOCK_TTL = 60;
const WATCHED_TTL = 60 * 60 * 12;
const WATCHED_MAX = 80;

export type CacheMeta = {
  etag: string;
  updatedAt: number;
  contentType: string;
  bytes: number;
};

function nflScheduleKey(season: number, week: number) {
  return `pub:nflSchedule:${season}:${week}`;
}

function matchupsKey(leagueId: string, week: number) {
  return `pub:sleeper:matchups:${leagueId}:${week}`;
}

function lockKey(resource: string) {
  return `pub:lock:${resource}`;
}

async function sha256Hex(data: ArrayBuffer | Uint8Array | string): Promise<string> {
  const bytes =
    typeof data === "string"
      ? new TextEncoder().encode(data)
      : data instanceof Uint8Array
        ? data
        : new Uint8Array(data);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function acquireLock(env: Env, resource: string): Promise<boolean> {
  const key = lockKey(resource);
  const existing = await env.CACHE.get(key);
  if (existing) return false;
  await env.CACHE.put(key, "1", { expirationTtl: LOCK_TTL });
  return true;
}

async function releaseLock(env: Env, resource: string) {
  await env.CACHE.delete(lockKey(resource));
}

async function waitBriefly(ms: number) {
  await new Promise((r) => setTimeout(r, ms));
}

async function fetchUpstream(
  url: string,
  init?: RequestInit
): Promise<{ body: ArrayBuffer; contentType: string; status: number }> {
  const res = await fetch(url, {
    ...init,
    headers: {
      "User-Agent": UA,
      Accept: "*/*",
      ...(init?.headers ?? {}),
    },
  });
  const body = await res.arrayBuffer();
  const contentType = res.headers.get("content-type") ?? "application/octet-stream";
  return { body, contentType, status: res.status };
}

async function putCatalog(env: Env, r2Key: string, kvKey: string, body: ArrayBuffer, contentType: string) {
  const bytes = new Uint8Array(body);
  await env.PUBLIC.put(r2Key, bytes, {
    httpMetadata: { contentType },
  });
  // Drop any legacy KV catalog blob so we don't keep a second copy.
  await env.CACHE.delete(kvKey);
}

async function getCatalog(env: Env, r2Key: string, kvKey: string): Promise<ArrayBuffer | null> {
  const obj = await env.PUBLIC.get(r2Key);
  if (obj) return await obj.arrayBuffer();
  // One-time fallback if an older deploy left the blob in KV only.
  return await env.CACHE.get(kvKey, "arrayBuffer");
}

async function putMeta(env: Env, key: string, meta: CacheMeta) {
  await env.CACHE.put(key, JSON.stringify(meta), { expirationTtl: 60 * 60 * 24 * 14 });
}

async function getMeta(env: Env, key: string): Promise<CacheMeta | null> {
  return (await env.CACHE.get(key, "json")) as CacheMeta | null;
}

function cacheHeaders(meta: CacheMeta, maxAge: number, hit: string): HeadersInit {
  return {
    "Content-Type": meta.contentType,
    ETag: `"${meta.etag}"`,
    "Cache-Control": `public, max-age=${maxAge}`,
    "X-Sideline-Cache": hit,
    "X-Sideline-Updated-At": String(meta.updatedAt),
  };
}

function wantsRevalidate(url: URL, req: Request): boolean {
  if (url.searchParams.get("revalidate") === "1") return true;
  const cc = req.headers.get("Cache-Control") ?? "";
  return /\bno-cache\b/i.test(cc) || /\bmax-age=0\b/i.test(cc);
}

function ifNoneMatch(req: Request, etag: string): boolean {
  const inm = req.headers.get("If-None-Match");
  if (!inm) return false;
  return inm.includes(etag) || inm.includes(`"${etag}"`);
}

async function respondBlob(
  req: Request,
  body: ArrayBuffer,
  meta: CacheMeta,
  maxAge: number,
  hit: string
): Promise<Response> {
  if (ifNoneMatch(req, meta.etag)) {
    return new Response(null, { status: 304, headers: cacheHeaders(meta, maxAge, hit) });
  }
  return new Response(body, { status: 200, headers: cacheHeaders(meta, maxAge, hit) });
}

async function respondKvJson(
  env: Env,
  req: Request,
  kvKey: string,
  maxAge: number,
  fetchFresh: () => Promise<{ body: ArrayBuffer; contentType: string }>
): Promise<Response> {
  const revalidate = wantsRevalidate(new URL(req.url), req);
  if (!revalidate) {
    const cached = await env.CACHE.get(kvKey, "arrayBuffer");
    const metaRaw = await env.CACHE.get(`${kvKey}:meta`, "json");
    if (cached && metaRaw) {
      const meta = metaRaw as CacheMeta;
      return respondBlob(req, cached, meta, maxAge, "HIT");
    }
  }

  const resource = kvKey;
  const gotLock = await acquireLock(env, resource);
  if (!gotLock) {
    // Another isolate is filling — wait and retry cache.
    for (let i = 0; i < 8; i++) {
      await waitBriefly(250);
      const cached = await env.CACHE.get(kvKey, "arrayBuffer");
      const metaRaw = await env.CACHE.get(`${kvKey}:meta`, "json");
      if (cached && metaRaw) {
        return respondBlob(req, cached, metaRaw as CacheMeta, maxAge, "HIT-WAIT");
      }
    }
  }

  try {
    const fresh = await fetchFresh();
    const bytes = new Uint8Array(fresh.body);
    const etag = await sha256Hex(bytes);
    const meta: CacheMeta = {
      etag,
      updatedAt: Math.floor(Date.now() / 1000),
      contentType: fresh.contentType,
      bytes: bytes.byteLength,
    };
    await env.CACHE.put(kvKey, bytes, { expirationTtl: Math.max(maxAge * 4, 3600) });
    await env.CACHE.put(`${kvKey}:meta`, JSON.stringify(meta), {
      expirationTtl: Math.max(maxAge * 4, 3600),
    });
    return respondBlob(req, fresh.body, meta, maxAge, revalidate ? "REVALIDATED" : "MISS");
  } finally {
    if (gotLock) await releaseLock(env, resource);
  }
}

// --- Public handlers ---

export async function handleNflSchedule(env: Env, req: Request, season: number, week: number): Promise<Response> {
  if (!Number.isFinite(season) || !Number.isFinite(week) || week < 1 || week > 22) {
    return Response.json({ error: "invalid season/week" }, { status: 400 });
  }
  const key = nflScheduleKey(season, week);
  // Live windows use short edge TTL; Worker still serves from KV until revalidate.
  const maxAge = 60;
  return respondKvJson(env, req, key, maxAge, async () => {
    const url = `https://api.myfantasyleague.com/${season}/export?TYPE=nflSchedule&W=${week}&JSON=1`;
    const { body, contentType, status } = await fetchUpstream(url);
    if (status < 200 || status >= 300) throw new Error(`nflSchedule upstream ${status}`);
    return { body, contentType: contentType.includes("json") ? contentType : "application/json" };
  });
}

export async function handleNflState(env: Env, req: Request): Promise<Response> {
  const key = "pub:nflState";
  return respondKvJson(env, req, key, 300, async () => {
    const { body, contentType, status } = await fetchUpstream("https://api.sleeper.app/v1/state/nfl");
    if (status < 200 || status >= 300) throw new Error(`nflState upstream ${status}`);
    return { body, contentType: contentType.includes("json") ? contentType : "application/json" };
  });
}

export async function handleSleeperMatchups(
  env: Env,
  req: Request,
  leagueId: string,
  week: number
): Promise<Response> {
  const id = leagueId.trim();
  if (!id || !Number.isFinite(week) || week < 1 || week > 22) {
    return Response.json({ error: "invalid leagueId/week" }, { status: 400 });
  }
  await touchWatched(env, id, week);
  const key = matchupsKey(id, week);
  return respondKvJson(env, req, key, 60, async () => {
    const url = `https://api.sleeper.app/v1/league/${encodeURIComponent(id)}/matchups/${week}`;
    const { body, contentType, status } = await fetchUpstream(url);
    if (status < 200 || status >= 300) throw new Error(`matchups upstream ${status}`);
    return { body, contentType: contentType.includes("json") ? contentType : "application/json" };
  });
}

async function respondCatalog(
  env: Env,
  req: Request,
  opts: {
    resource: string;
    r2Key: string;
    kvKey: string;
    metaKey: string;
    maxAge: number;
    upstreamUrl: string;
    defaultContentType: string;
  }
): Promise<Response> {
  const revalidate = wantsRevalidate(new URL(req.url), req);
  if (!revalidate) {
    const meta = await getMeta(env, opts.metaKey);
    if (meta) {
      const body = await getCatalog(env, opts.r2Key, opts.kvKey);
      if (body) return respondBlob(req, body, meta, opts.maxAge, "HIT");
    }
  }

  const gotLock = await acquireLock(env, opts.resource);
  if (!gotLock) {
    for (let i = 0; i < 20; i++) {
      await waitBriefly(500);
      const meta = await getMeta(env, opts.metaKey);
      if (meta) {
        const body = await getCatalog(env, opts.r2Key, opts.kvKey);
        if (body) return respondBlob(req, body, meta, opts.maxAge, "HIT-WAIT");
      }
    }
  }

  try {
    const { body, contentType, status } = await fetchUpstream(opts.upstreamUrl);
    if (status < 200 || status >= 300) throw new Error(`catalog upstream ${status}`);
    const ct = contentType.includes("json") || contentType.includes("csv") || contentType.includes("text")
      ? contentType
      : opts.defaultContentType;
    const etag = await sha256Hex(body);
    const meta: CacheMeta = {
      etag,
      updatedAt: Math.floor(Date.now() / 1000),
      contentType: ct,
      bytes: body.byteLength,
    };
    await putCatalog(env, opts.r2Key, opts.kvKey, body, ct);
    await putMeta(env, opts.metaKey, meta);
    return respondBlob(req, body, meta, opts.maxAge, revalidate ? "REVALIDATED" : "MISS");
  } finally {
    if (gotLock) await releaseLock(env, opts.resource);
  }
}

export async function handleSleeperPlayers(env: Env, req: Request): Promise<Response> {
  return respondCatalog(env, req, {
    resource: "catalog:sleeper-players",
    r2Key: R2_PLAYERS,
    kvKey: KV_PLAYERS,
    metaKey: META_PLAYERS,
    maxAge: 86_400,
    upstreamUrl: "https://api.sleeper.app/v1/players/nfl",
    defaultContentType: "application/json",
  });
}

export async function handlePlayerIds(env: Env, req: Request): Promise<Response> {
  return respondCatalog(env, req, {
    resource: "catalog:player-ids",
    r2Key: R2_PLAYER_IDS,
    kvKey: KV_PLAYER_IDS,
    metaKey: META_PLAYER_IDS,
    maxAge: 86_400 * 7,
    upstreamUrl: "https://raw.githubusercontent.com/dynastyprocess/data/master/files/db_playerids.csv",
    defaultContentType: "text/csv",
  });
}

// --- Watched matchups + cron refresh ---

async function readWatched(env: Env): Promise<WatchedMatchup[]> {
  return ((await env.CACHE.get(WATCHED_KEY, "json")) as WatchedMatchup[] | null) ?? [];
}

async function writeWatched(env: Env, list: WatchedMatchup[]) {
  await env.CACHE.put(WATCHED_KEY, JSON.stringify(list), { expirationTtl: WATCHED_TTL });
}

export async function touchWatched(env: Env, leagueId: string, week: number) {
  const now = Math.floor(Date.now() / 1000);
  const list = await readWatched(env);
  const filtered = list.filter((w) => now - w.touchedAt < WATCHED_TTL && !(w.leagueId === leagueId && w.week === week));
  filtered.push({ leagueId, week, touchedAt: now });
  // Keep most recently touched.
  filtered.sort((a, b) => b.touchedAt - a.touchedAt);
  await writeWatched(env, filtered.slice(0, WATCHED_MAX));
}

async function refreshKvKey(
  env: Env,
  kvKey: string,
  ttl: number,
  url: string
): Promise<boolean> {
  try {
    const { body, contentType, status } = await fetchUpstream(url);
    if (status < 200 || status >= 300) return false;
    const etag = await sha256Hex(body);
    const meta: CacheMeta = {
      etag,
      updatedAt: Math.floor(Date.now() / 1000),
      contentType: contentType.includes("json") ? contentType : "application/json",
      bytes: body.byteLength,
    };
    await env.CACHE.put(kvKey, body, { expirationTtl: ttl });
    await env.CACHE.put(`${kvKey}:meta`, JSON.stringify(meta), { expirationTtl: ttl });
    return true;
  } catch (e) {
    console.error("refresh fail", kvKey, e);
    return false;
  }
}

async function refreshCatalog(
  env: Env,
  opts: { r2Key: string; kvKey: string; metaKey: string; url: string; contentType: string }
): Promise<boolean> {
  try {
    const { body, contentType, status } = await fetchUpstream(opts.url);
    if (status < 200 || status >= 300) return false;
    const ct =
      contentType.includes("json") || contentType.includes("csv") || contentType.includes("text")
        ? contentType
        : opts.contentType;
    const etag = await sha256Hex(body);
    const meta: CacheMeta = {
      etag,
      updatedAt: Math.floor(Date.now() / 1000),
      contentType: ct,
      bytes: body.byteLength,
    };
    await putCatalog(env, opts.r2Key, opts.kvKey, body, ct);
    await putMeta(env, opts.metaKey, meta);
    return true;
  } catch (e) {
    console.error("catalog refresh fail", opts.kvKey, e);
    return false;
  }
}

export type PublicRefreshResult = {
  nflState: boolean;
  schedule: boolean;
  matchups: number;
  catalogs: boolean;
};

/** Game-window refresh: nflState, current week schedule, watched matchups. */
export async function refreshPublicHot(env: Env): Promise<PublicRefreshResult> {
  const result: PublicRefreshResult = { nflState: false, schedule: false, matchups: 0, catalogs: false };

  result.nflState = await refreshKvKey(env, "pub:nflState", 60 * 60, "https://api.sleeper.app/v1/state/nfl");

  let season = new Date().getUTCFullYear();
  let week = 1;
  try {
    const stateBuf = await env.CACHE.get("pub:nflState", "arrayBuffer");
    if (stateBuf) {
      const root = JSON.parse(new TextDecoder().decode(stateBuf)) as Record<string, unknown>;
      week = Number(root.week) || 1;
      season = Number(root.league_season ?? root.season) || season;
    }
  } catch {
    /* use defaults */
  }

  result.schedule = await refreshKvKey(
    env,
    nflScheduleKey(season, week),
    60 * 30,
    `https://api.myfantasyleague.com/${season}/export?TYPE=nflSchedule&W=${week}&JSON=1`
  );

  const watched = await readWatched(env);
  const now = Math.floor(Date.now() / 1000);
  const live = watched.filter((w) => now - w.touchedAt < WATCHED_TTL);
  for (const w of live) {
    const ok = await refreshKvKey(
      env,
      matchupsKey(w.leagueId, w.week),
      60 * 15,
      `https://api.sleeper.app/v1/league/${encodeURIComponent(w.leagueId)}/matchups/${w.week}`
    );
    if (ok) result.matchups += 1;
  }

  return result;
}

/** Daily catalog refresh (Sleeper players + DynastyProcess IDs). */
export async function refreshPublicCatalogs(env: Env): Promise<boolean> {
  const a = await refreshCatalog(env, {
    r2Key: R2_PLAYERS,
    kvKey: KV_PLAYERS,
    metaKey: META_PLAYERS,
    url: "https://api.sleeper.app/v1/players/nfl",
    contentType: "application/json",
  });
  const b = await refreshCatalog(env, {
    r2Key: R2_PLAYER_IDS,
    kvKey: KV_PLAYER_IDS,
    metaKey: META_PLAYER_IDS,
    url: "https://raw.githubusercontent.com/dynastyprocess/data/master/files/db_playerids.csv",
    contentType: "text/csv",
  });
  return a && b;
}

export function isDailyCatalogCron(cron: string | undefined): boolean {
  return cron === "0 10 * * *";
}

// --- MFL public player intel (bio + news articles from playerProfile) ---

const MFL_PROFILE_TTL = 60 * 60; // 1h — includes news lines when MFL embeds them
const MFL_DETAILS_TTL = 60 * 60 * 24; // 1d — height/weight/dob
const MFL_ID_MAX = 12;

function normalizeMflId(raw: string): string {
  const t = raw.trim();
  if (!t) return "";
  const n = Number(t);
  if (Number.isFinite(n) && /^\d+$/.test(t) && n < 1000) {
    return String(Math.trunc(n)).padStart(4, "0");
  }
  return t;
}

function profileKvKey(season: number, id: string) {
  return `pub:mfl:profile:${season}:${id}`;
}

function detailsKvKey(season: number, id: string) {
  return `pub:mfl:details:${season}:${id}`;
}

function parseIdList(raw: string): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const part of raw.split(/[,\s]+/)) {
    const id = normalizeMflId(part);
    if (!id || seen.has(id)) continue;
    seen.add(id);
    out.push(id);
    if (out.length >= MFL_ID_MAX) break;
  }
  return out;
}

function asPlayerRows(node: unknown): Record<string, unknown>[] {
  if (Array.isArray(node)) {
    return node.filter((x): x is Record<string, unknown> => !!x && typeof x === "object");
  }
  if (node && typeof node === "object") {
    return [node as Record<string, unknown>];
  }
  return [];
}

function extractPlayerId(row: Record<string, unknown>): string | null {
  const nested = (row.player as Record<string, unknown> | undefined) ?? row;
  const raw =
    (typeof row.id === "string" ? row.id : null) ??
    (typeof nested.id === "string" ? nested.id : null) ??
    (typeof row.id === "number" ? String(row.id) : null) ??
    (typeof nested.id === "number" ? String(nested.id) : null);
  if (!raw) return null;
  return normalizeMflId(raw);
}

function collectProfileRows(root: Record<string, unknown>): Record<string, unknown>[] {
  const rows: Record<string, unknown>[] = [];
  const push = (any: unknown) => {
    for (const row of asPlayerRows(any)) rows.push(row);
  };

  // Single: { playerProfile: { id, name, news, player } }
  // Multi (rare): { playerProfiles: { playerProfile: [...] } }
  const plural = root.playerProfiles as Record<string, unknown> | undefined;
  if (plural) {
    push(plural.playerProfile);
  }

  const profileRoot = (root.playerProfile as Record<string, unknown>) ?? root;
  if (profileRoot.id != null || profileRoot.name != null || profileRoot.news != null) {
    push(profileRoot);
  }
  push(profileRoot.playerProfile);
  // Do not push nested `player` alone — it drops top-level news/name.
  push(root.playerProfile);
  return rows;
}

function collectDetailsRows(root: Record<string, unknown>): Record<string, unknown>[] {
  const players = root.players as Record<string, unknown> | undefined;
  const any = players?.player ?? root.player;
  return asPlayerRows(any);
}

async function putJson(env: Env, key: string, value: unknown, ttl: number) {
  const body = new TextEncoder().encode(JSON.stringify(value));
  await env.CACHE.put(key, body, { expirationTtl: Math.max(ttl, 60) });
}

async function getJson<T>(env: Env, key: string): Promise<T | null> {
  return (await env.CACHE.get(key, "json")) as T | null;
}

async function fetchAndCacheMflProfiles(env: Env, season: number, ids: string[]): Promise<void> {
  // MFL playerProfile effectively returns one player per request.
  await Promise.all(
    ids.map(async (id) => {
      const url =
        `https://api.myfantasyleague.com/${season}/export?TYPE=playerProfile&P=${encodeURIComponent(id)}&JSON=1`;
      const { body, status } = await fetchUpstream(url);
      if (status < 200 || status >= 300) {
        console.error("mfl playerProfile", id, status);
        return;
      }
      const root = JSON.parse(new TextDecoder().decode(body)) as Record<string, unknown>;
      const rows = collectProfileRows(root);
      const row = rows.find((r) => extractPlayerId(r) === id) ?? rows[0];
      if (row) {
        // Ensure id is present for later assembly.
        if (row.id == null) row.id = id;
        await putJson(env, profileKvKey(season, id), row, MFL_PROFILE_TTL);
      }
    })
  );
}

async function fetchAndCacheMflDetails(env: Env, season: number, ids: string[]): Promise<void> {
  // DETAILS with a comma list often returns only the first id — fetch per player.
  await Promise.all(
    ids.map(async (id) => {
      const url =
        `https://api.myfantasyleague.com/${season}/export?TYPE=players&DETAILS=1&PLAYERS=${encodeURIComponent(id)}&JSON=1`;
      const { body, status } = await fetchUpstream(url);
      if (status < 200 || status >= 300) {
        console.error("mfl players DETAILS", id, status);
        return;
      }
      const root = JSON.parse(new TextDecoder().decode(body)) as Record<string, unknown>;
      const rows = collectDetailsRows(root);
      const row = rows.find((r) => extractPlayerId(r) === id) ?? rows[0];
      if (row) {
        if (row.id == null) row.id = id;
        await putJson(env, detailsKvKey(season, id), row, MFL_DETAILS_TTL);
      }
    })
  );
}

/**
 * Public MFL bio + news (from playerProfile articles) + DETAILS height/weight/dob.
 * League-scoped ranks/injuries stay on-device.
 */
export async function handleMflPlayerIntel(env: Env, req: Request, season: number, idsRaw: string): Promise<Response> {
  if (!Number.isFinite(season) || season < 2000 || season > 2100) {
    return Response.json({ error: "invalid season" }, { status: 400 });
  }
  const ids = parseIdList(idsRaw);
  if (ids.length === 0) {
    return Response.json({ error: "missing ids" }, { status: 400 });
  }

  const revalidate = wantsRevalidate(new URL(req.url), req);
  const missProfile: string[] = [];
  const missDetails: string[] = [];
  const profiles: Record<string, unknown>[] = [];
  const details: Record<string, unknown>[] = [];

  for (const id of ids) {
    if (!revalidate) {
      const cachedP = await getJson<Record<string, unknown>>(env, profileKvKey(season, id));
      if (cachedP) profiles.push(cachedP);
      else missProfile.push(id);

      const cachedD = await getJson<Record<string, unknown>>(env, detailsKvKey(season, id));
      if (cachedD) details.push(cachedD);
      else missDetails.push(id);
    } else {
      missProfile.push(id);
      missDetails.push(id);
    }
  }

  const lockResource = `mfl-intel:${season}:${[...missProfile, ...missDetails].sort().join(",")}`;
  let gotLock = true;
  if (missProfile.length > 0 || missDetails.length > 0) {
    gotLock = await acquireLock(env, lockResource);
    if (!gotLock) {
      for (let i = 0; i < 10; i++) {
        await waitBriefly(300);
        const stillMissP: string[] = [];
        const stillMissD: string[] = [];
        for (const id of missProfile) {
          const cachedP = await getJson<Record<string, unknown>>(env, profileKvKey(season, id));
          if (!cachedP) stillMissP.push(id);
        }
        for (const id of missDetails) {
          const cachedD = await getJson<Record<string, unknown>>(env, detailsKvKey(season, id));
          if (!cachedD) stillMissD.push(id);
        }
        if (stillMissP.length === 0 && stillMissD.length === 0) break;
      }
      // Rebuild from cache after wait.
      profiles.length = 0;
      details.length = 0;
      for (const id of ids) {
        const cachedP = await getJson<Record<string, unknown>>(env, profileKvKey(season, id));
        if (cachedP) profiles.push(cachedP);
        const cachedD = await getJson<Record<string, unknown>>(env, detailsKvKey(season, id));
        if (cachedD) details.push(cachedD);
      }
    } else {
      try {
        // Re-check after lock (another isolate may have filled).
        const needP: string[] = [];
        const needD: string[] = [];
        for (const id of missProfile) {
          if (revalidate) needP.push(id);
          else {
            const cachedP = await getJson<Record<string, unknown>>(env, profileKvKey(season, id));
            if (cachedP) profiles.push(cachedP);
            else needP.push(id);
          }
        }
        for (const id of missDetails) {
          if (revalidate) needD.push(id);
          else {
            const cachedD = await getJson<Record<string, unknown>>(env, detailsKvKey(season, id));
            if (cachedD) details.push(cachedD);
            else needD.push(id);
          }
        }
        if (needP.length) await fetchAndCacheMflProfiles(env, season, needP);
        if (needD.length) await fetchAndCacheMflDetails(env, season, needD);

        profiles.length = 0;
        details.length = 0;
        for (const id of ids) {
          const cachedP = await getJson<Record<string, unknown>>(env, profileKvKey(season, id));
          if (cachedP) profiles.push(cachedP);
          const cachedD = await getJson<Record<string, unknown>>(env, detailsKvKey(season, id));
          if (cachedD) details.push(cachedD);
        }
      } finally {
        await releaseLock(env, lockResource);
      }
    }
  }

  const payload = {
    season,
    ids,
    playerProfile: { player: profiles },
    players: { player: details },
  };
  const body = new TextEncoder().encode(JSON.stringify(payload));
  const etag = await sha256Hex(body);
  const hit =
    missProfile.length === 0 && missDetails.length === 0 && !revalidate
      ? "HIT"
      : revalidate
        ? "REVALIDATED"
        : "MISS";
  const headers = {
    "Content-Type": "application/json",
    ETag: `"${etag}"`,
    "Cache-Control": `public, max-age=${MFL_PROFILE_TTL}`,
    "X-Sideline-Cache": hit,
    "X-Sideline-Updated-At": String(Math.floor(Date.now() / 1000)),
  };
  if (ifNoneMatch(req, etag)) {
    return new Response(null, { status: 304, headers });
  }
  return new Response(body, { status: 200, headers });
}
