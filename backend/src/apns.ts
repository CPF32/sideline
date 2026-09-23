import { SignJWT, importPKCS8, type KeyLike } from "jose";
import type { ApnsEnvironment, Env } from "./types";
import type { ContentState } from "./types";

let cachedKey: KeyLike | null = null;
let cachedJwt: { token: string; exp: number } | null = null;

const HOSTS: Record<ApnsEnvironment, string> = {
  sandbox: "api.sandbox.push.apple.com",
  production: "api.push.apple.com",
};

async function apnsKey(env: Env): Promise<KeyLike> {
  if (cachedKey) return cachedKey;
  const pem = env.APNS_PRIVATE_KEY.replace(/\\n/g, "\n");
  cachedKey = await importPKCS8(pem, "ES256");
  return cachedKey;
}

async function apnsJwt(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && cachedJwt.exp - 60 > now) return cachedJwt.token;
  const key = await apnsKey(env);
  const exp = now + 3500;
  const token = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: env.APNS_KEY_ID })
    .setIssuer(env.APNS_TEAM_ID)
    .setIssuedAt(now)
    .sign(key);
  cachedJwt = { token, exp };
  return token;
}

function hostOrder(preferred?: ApnsEnvironment): ApnsEnvironment[] {
  if (preferred === "production") return ["production", "sandbox"];
  // Default: try sandbox first (Xcode/dev), then production (TestFlight/App Store).
  return ["sandbox", "production"];
}

function isWrongEnvironment(status: number, body: string): boolean {
  if (status !== 400 && status !== 403) return false;
  const lower = body.toLowerCase();
  return (
    lower.includes("baddevicetoken") ||
    lower.includes("devicetokennotfortopic") ||
    lower.includes("badenvironment") ||
    lower.includes("invalidprovider") ||
    lower.includes("topicdisallowed")
  );
}

async function pushToHost(
  env: Env,
  host: string,
  pushTokenHex: string,
  contentState: ContentState,
  event: "update" | "end"
): Promise<{ ok: boolean; status: number; body: string }> {
  const jwt = await apnsJwt(env);
  const topic = `${env.APNS_BUNDLE_ID}.push-type.liveactivity`;
  const url = `https://${host}/3/device/${pushTokenHex}`;

  const payload = {
    aps: {
      timestamp: Math.floor(Date.now() / 1000),
      event,
      "content-state": contentState,
      // Stale shortly after the next scheduled sync is missed.
      "stale-date": (contentState.nextSyncAt ?? Math.floor(Date.now() / 1000)) + 120,
      ...(event === "end" ? { "dismissal-date": Math.floor(Date.now() / 1000) } : {}),
    },
  };

  const res = await fetch(url, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": topic,
      "apns-push-type": "liveactivity",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  const body = await res.text();
  return { ok: res.ok, status: res.status, body };
}

/**
 * Pushes a Live Activity update. Tries sandbox + production automatically
 * (hint from the app first, then the other host on environment/token errors).
 */
export async function pushLiveActivityUpdate(
  env: Env,
  pushTokenHex: string,
  contentState: ContentState,
  event: "update" | "end" = "update",
  preferred?: ApnsEnvironment
): Promise<{ ok: boolean; status: number; body: string; environment?: ApnsEnvironment }> {
  const order = hostOrder(preferred);
  let last = { ok: false, status: 0, body: "" };

  for (const environment of order) {
    const result = await pushToHost(env, HOSTS[environment], pushTokenHex, contentState, event);
    if (result.ok) {
      return { ...result, environment };
    }
    last = result;
    // Token expired / unregistered — don't try the other host.
    if (result.status === 410) {
      return { ...result, environment };
    }
    if (!isWrongEnvironment(result.status, result.body)) {
      return { ...result, environment };
    }
    // Wrong APNs environment for this device token — try the other host.
  }

  return last;
}
