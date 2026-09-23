/** Mirrors Shared/MatchupLiveActivityAttributes.ContentState (JSON / APNs). */
export type ContentState = {
  myScore: number;
  oppScore: number;
  opponentName: string;
  week: number;
  statusLine: string;
  playerLines: string[];
  /** Unix seconds — keep as number for APNs Codable interop. */
  lastUpdated: number;
  /** Unix seconds of the next scheduled backend sync (drives the countdown). */
  nextSyncAt?: number;
};

export type Provider = "mfl" | "sleeper";

export type ApnsEnvironment = "sandbox" | "production";

export type LiveSession = {
  id: string;
  pushToken: string;
  provider: Provider;
  leagueId: string;
  franchiseId: string;
  week: number;
  season: number;
  /** MFL host e.g. www64.myfantasyleague.com */
  host?: string;
  /** MFL MFL_USER_ID cookie — short-lived, only while Live Activity is active. */
  mflCookie?: string;
  leagueName: string;
  myTeamName: string;
  providerLabel: string;
  opponentName?: string;
  /** Sleeper playerId → display name for live lines */
  playerNames?: Record<string, string>;
  starterIds?: string[];
  /** Hint from iOS; Worker may correct after a successful push. */
  apnsEnvironment?: ApnsEnvironment;
  createdAt: number;
  updatedAt: number;
};

export type RegisterBody = {
  activityId: string;
  pushToken: string;
  provider: Provider;
  leagueId: string;
  franchiseId: string;
  week: number;
  season: number;
  host?: string;
  mflCookie?: string;
  leagueName: string;
  myTeamName: string;
  providerLabel: string;
  opponentName?: string;
  playerNames?: Record<string, string>;
  starterIds?: string[];
  /** "sandbox" (Xcode) | "production" (TestFlight / App Store) */
  apnsEnvironment?: ApnsEnvironment;
};

export type Env = {
  SESSIONS: KVNamespace;
  /** Shared secret the iOS app sends as X-Sideline-Key */
  REGISTER_SECRET: string;
  APNS_TEAM_ID: string;
  APNS_KEY_ID: string;
  /** Full .p8 PEM including BEGIN/END lines (escaped newlines in secret). */
  APNS_PRIVATE_KEY: string;
  APNS_BUNDLE_ID: string;
};
