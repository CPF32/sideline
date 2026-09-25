import type { Env } from "./types";

/**
 * Per-user BYOK cache proxy for FantasyPros + The Odds API.
 *
 * - Device sends X-Sideline-Key (REGISTER_SECRET), X-Sideline-User-Id, X-Vendor-API-Key.
 * - Vendor key is used only on cache MISS for the upstream fetch — never written to KV.
 * - Cache keys are scoped by hashed user id + API-key fingerprint so users never share data.
 * - Distinct from a future "pro mode" shared Sideline key (`pro:*` prefix) — this is `byok:*` only.
 */

const UA = "Sideline/1.0 (com.cpf32.sideline; CloudflareWorker)";

const FP_BASE = "https://api.fantasypros.com/public/v2/json";
const ODDS_BASE = "https://api.the-odds-api.com/v4";

const FP_TTL = 60 * 60; // 1h — rankings / projections / news
const ODDS_EVENTS_TTL = 60 * 60;
const ODDS_PROPS_TTL = 60 * 60;
const ODDS_PROPS_LIVE_TTL = 60;
const ODDS_HISTORIC_TTL = 60 * 60 * 24;

type Vendor = "fantasypros" | "odds";

async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function unauthorized(req: Request, env: Env): boolean {
  const key = req.headers.get("X-Sideline-Key") ?? "";
  return !env.REGISTER_SECRET || key !== env.REGISTER_SECRET;
}

function requireUserAndVendorKey(req: Request): { userId: string; vendorKey: string } | Response {
  const userId = (req.headers.get("X-Sideline-User-Id") ?? "").trim();
  const vendorKey = (req.headers.get("X-Vendor-API-Key") ?? "").trim();
  if (!userId || userId.length < 4) {
    return new Response(JSON.stringify({ error: "missing_user" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }
  if (!vendorKey || vendorKey.length < 8) {
    return new Response(JSON.stringify({ error: "missing_vendor_key" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }
  return { userId, vendorKey };
}

async function cacheIdentity(userId: string, vendorKey: string): Promise<{ userHash: string; keyFp: string }> {
  const [userHash, keyFp] = await Promise.all([
    sha256Hex(`sideline-user:${userId}`),
    sha256Hex(`sideline-key:${vendorKey}`),
  ]);
  return { userHash: userHash.slice(0, 24), keyFp: keyFp.slice(0, 16) };
}

function wantsRevalidate(req: Request, url: URL): boolean {
  if (url.searchParams.get("revalidate") === "1") return true;
  const cc = req.headers.get("Cache-Control") ?? "";
  return cc.toLowerCase().includes("no-cache");
}

function jsonError(status: number, error: string, detail?: string): Response {
  return new Response(JSON.stringify({ error, detail: detail?.slice(0, 240) }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function cachedResponse(
  body: ArrayBuffer,
  contentType: string,
  ttl: number,
  status: "HIT" | "MISS" | "REVALIDATED"
): Response {
  return new Response(body, {
    status: 200,
    headers: {
      "Content-Type": contentType || "application/json",
      "Cache-Control": `private, max-age=${ttl}`,
      "X-Sideline-Cache": status,
      "X-Sideline-Byok": "1",
    },
  });
}

async function serveByok(opts: {
  env: Env;
  req: Request;
  vendor: Vendor;
  upstreamUrl: string;
  cachePathKey: string;
  ttl: number;
  upstreamHeaders: Record<string, string>;
}): Promise<Response> {
  const { env, req, vendor, upstreamUrl, cachePathKey, ttl, upstreamHeaders } = opts;
  const auth = requireUserAndVendorKey(req);
  if (auth instanceof Response) return auth;

  const { userHash, keyFp } = await cacheIdentity(auth.userId, auth.vendorKey);
  const pathHash = (await sha256Hex(cachePathKey)).slice(0, 32);
  const kvKey = `byok:${vendor}:${userHash}:${keyFp}:${pathHash}`;

  const revalidate = wantsRevalidate(req, new URL(req.url));
  if (!revalidate) {
    const hit = await env.CACHE.get(kvKey, "arrayBuffer");
    if (hit && hit.byteLength > 0) {
      return cachedResponse(hit, "application/json", ttl, "HIT");
    }
  }

  const upstream = await fetch(upstreamUrl, {
    headers: {
      "User-Agent": UA,
      Accept: "application/json",
      ...upstreamHeaders,
    },
  });
  const body = await upstream.arrayBuffer();
  if (!upstream.ok) {
    const text = new TextDecoder().decode(body).slice(0, 240);
    return jsonError(upstream.status, "upstream_failed", text);
  }
  if (body.byteLength === 0) {
    return jsonError(502, "upstream_empty");
  }

  await env.CACHE.put(kvKey, body, { expirationTtl: Math.max(60, ttl) });
  return cachedResponse(body, upstream.headers.get("content-type") ?? "application/json", ttl, revalidate ? "REVALIDATED" : "MISS");
}

/** Strip our control params; keep vendor query as-is (except Odds apiKey). */
function vendorQuery(url: URL, stripApiKey: boolean): string {
  const params = new URLSearchParams(url.searchParams);
  params.delete("revalidate");
  if (stripApiKey) params.delete("apiKey");
  const qs = params.toString();
  return qs ? `?${qs}` : "";
}

/**
 * GET /v1/byok/fantasypros/<path>?… 
 * → https://api.fantasypros.com/public/v2/json/<path>?…
 */
export async function handleByokFantasyPros(env: Env, req: Request): Promise<Response> {
  if (unauthorized(req, env)) return jsonError(401, "unauthorized");
  if (req.method !== "GET" && req.method !== "HEAD") {
    return jsonError(405, "method_not_allowed");
  }

  const url = new URL(req.url);
  const prefix = "/v1/byok/fantasypros/";
  if (!url.pathname.startsWith(prefix)) {
    return jsonError(404, "not_found");
  }
  const rest = url.pathname.slice(prefix.length).replace(/^\/+/, "");
  if (!rest || rest.includes("..")) return jsonError(400, "bad_path");

  const qs = vendorQuery(url, false);
  const upstreamUrl = `${FP_BASE}/${rest}${qs}`;
  const cachePathKey = `${rest}${qs}`;

  const auth = requireUserAndVendorKey(req);
  if (auth instanceof Response) return auth;

  return serveByok({
    env,
    req,
    vendor: "fantasypros",
    upstreamUrl,
    cachePathKey,
    ttl: FP_TTL,
    upstreamHeaders: { "x-api-key": auth.vendorKey },
  });
}

/**
 * GET /v1/byok/odds/<path>?… 
 * → https://api.the-odds-api.com/v4/<path>?…&apiKey=<header>
 * apiKey must not appear in the query from the client (Worker injects it).
 */
export async function handleByokOdds(env: Env, req: Request): Promise<Response> {
  if (unauthorized(req, env)) return jsonError(401, "unauthorized");
  if (req.method !== "GET" && req.method !== "HEAD") {
    return jsonError(405, "method_not_allowed");
  }

  const url = new URL(req.url);
  const prefix = "/v1/byok/odds/";
  if (!url.pathname.startsWith(prefix)) {
    return jsonError(404, "not_found");
  }
  const rest = url.pathname.slice(prefix.length).replace(/^\/+/, "");
  if (!rest || rest.includes("..")) return jsonError(400, "bad_path");

  const auth = requireUserAndVendorKey(req);
  if (auth instanceof Response) return auth;

  const qs = vendorQuery(url, true);
  const cachePathKey = `${rest}${qs}`;
  const join = qs.includes("?") ? "&" : "?";
  const upstreamUrl = `${ODDS_BASE}/${rest}${qs}${join}apiKey=${encodeURIComponent(auth.vendorKey)}`;

  const live = (req.headers.get("X-Sideline-Live") ?? "") === "1";
  const historic = rest.startsWith("historical/");
  let ttl = ODDS_PROPS_TTL;
  if (historic) ttl = ODDS_HISTORIC_TTL;
  else if (!rest.includes("/odds")) ttl = ODDS_EVENTS_TTL;
  else if (live) ttl = ODDS_PROPS_LIVE_TTL;

  return serveByok({
    env,
    req,
    vendor: "odds",
    upstreamUrl,
    cachePathKey,
    ttl,
    upstreamHeaders: {},
  });
}
